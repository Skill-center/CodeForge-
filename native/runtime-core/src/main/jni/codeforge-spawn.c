/*
 * CodeForge's launcher for the sealed runtime's commands (Phase 4 W4;
 * docs/SECURITY.md §2). CodeForge's own code (native/PROVENANCE.md).
 *
 * The app starts every runtime command through this program. It is built as
 * a PIE executable named libcodeforge-spawn.so (native/runtime-core/
 * build.gradle.kts), so Android extracts it into nativeLibraryDir with the
 * payload's executables, the one place an app targeting API 29+ may exec from.
 *
 * Java's ProcessBuilder cannot put a child in a process group of its own, and
 * ending a command has to end everything the command started. So this program:
 *
 *   1. starts a new session: the command, and whatever it starts, share a
 *      process group apart from the app's;
 *   2. becomes a child subreaper: a process that leaves the group (setsid, a
 *      double fork) stays its descendant, and comes back to it as an orphan;
 *   3. gives the command a clean signal state: every signal at its default
 *      and none blocked, so that the app's ignored SIGPIPE is not inherited;
 *   4. sets RLIMIT_CORE to 0: a crash writes no core file into the app's
 *      storage;
 *   5. starts the command and waits for it;
 *   6. ends what is left once the command exits, or everything when it is
 *      asked to stop (SIGTERM, SIGINT or SIGHUP, as Process.destroy() sends):
 *      SIGTERM and SIGCONT to every process of its group and every
 *      descendant, then SIGKILL to those still there after the grace period;
 *   7. writes what happened to the status file, as key=value lines.
 *
 * Usage:
 *   libcodeforge-spawn.so [--status FILE] [--grace MS] -- PROGRAM [ARGUMENT...]
 *
 * PROGRAM is a path; the environment and the working directory are the
 * caller's. Exit status: the command's own, 128 + the signal that ended it,
 * 125 when this program could not run it, and 126 or 127 when exec failed
 * (127 for a program that is not there). The status file says which.
 *
 * Status file keys: pid (this program's), group (its process group after
 * setsid, which is the pid), subreaper (1 or 0), then at the end: reason
 * (exited, signaled, stopped,
 * exec_failed or spawn_failed), exit or signal (the command's), exec_errno,
 * stop_signal (what asked this program to stop), ended (processes it had to
 * signal after the command, or with it when stopped) and remaining
 * (processes it could not end, which is 0 unless the kernel refused).
 */
#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef PR_SET_CHILD_SUBREAPER
#define PR_SET_CHILD_SUBREAPER 36
#endif

/* More processes than one command can sensibly start; the rest wait a pass. */
#define MAX_PROCESSES 4096
/* How long the SIGKILL phase may take before the count of survivors is final. */
#define KILL_WAIT_MS 3000

static pid_t self;
static pid_t group;
static int subreaper;
static const char *status_path;

typedef struct {
    pid_t pid;
    pid_t parent;
    pid_t group;
    char state;
} process_t;

static process_t table[MAX_PROCESSES];
/* How many entries of `table` the last read of /proc filled. */
static int table_count;

static long now_ms(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (long) now.tv_sec * 1000L + now.tv_nsec / 1000000L;
}

/* Writes the whole status file through a temporary file and a rename. */
static void write_status(const char *text) {
    if (status_path == NULL) return;
    char temporary[4096];
    if (snprintf(temporary, sizeof(temporary), "%s.part", status_path) >= (int) sizeof(temporary)) return;
    int file = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (file < 0) return;
    size_t length = strlen(text);
    size_t written = 0;
    while (written < length) {
        ssize_t count = write(file, text + written, length - written);
        if (count < 0) {
            if (errno == EINTR) continue;
            break;
        }
        written += (size_t) count;
    }
    close(file);
    if (rename(temporary, status_path) != 0) unlink(temporary);
}

/* The status file: the identity lines, then `body` (key=value lines, or ""). */
static void report(const char *body) {
    char text[1024];
    snprintf(text, sizeof(text), "pid=%d\ngroup=%d\nsubreaper=%d\n%s", (int) self, (int) group, subreaper, body);
    write_status(text);
}

/* Every process /proc lists: its parent, its group and its state. */
static int read_processes(void) {
    DIR *proc = opendir("/proc");
    if (proc == NULL) return 0;
    int count = 0;
    struct dirent *entry;
    while ((entry = readdir(proc)) != NULL && count < MAX_PROCESSES) {
        const char *name = entry->d_name;
        if (name[0] < '0' || name[0] > '9') continue;
        long pid = atol(name);
        if (pid <= 0) continue;
        char path[64];
        snprintf(path, sizeof(path), "/proc/%ld/stat", pid);
        int file = open(path, O_RDONLY | O_CLOEXEC);
        if (file < 0) continue;
        char buffer[512];
        ssize_t length = read(file, buffer, sizeof(buffer) - 1);
        close(file);
        if (length <= 0) continue;
        buffer[length] = '\0';
        /* "pid (comm) state ppid pgrp ...": comm may hold spaces and parentheses. */
        char *close_paren = strrchr(buffer, ')');
        if (close_paren == NULL) continue;
        char state = 0;
        int parent = 0;
        int process_group = 0;
        if (sscanf(close_paren + 1, " %c %d %d", &state, &parent, &process_group) != 3) continue;
        table[count].pid = (pid_t) pid;
        table[count].parent = (pid_t) parent;
        table[count].group = (pid_t) process_group;
        table[count].state = state;
        count++;
    }
    closedir(proc);
    table_count = count;
    return count;
}

/*
 * The processes to end: every descendant of this program, and every member
 * of its group (the same set while it is a subreaper), never itself.
 */
static int targets(pid_t *found, int capacity) {
    int count = read_processes();
    int total = 0;
    for (int i = 0; i < count && total < capacity; i++) {
        if (table[i].pid != self && table[i].group == self) found[total++] = table[i].pid;
    }
    /* Descendants, generation by generation: a parent already found brings its children. */
    int grew = 1;
    while (grew) {
        grew = 0;
        for (int i = 0; i < count && total < capacity; i++) {
            pid_t pid = table[i].pid;
            if (pid == self) continue;
            int known = 0;
            int parent_known = table[i].parent == self;
            for (int j = 0; j < total; j++) {
                if (found[j] == pid) known = 1;
                if (found[j] == table[i].parent) parent_known = 1;
            }
            if (!known && parent_known) {
                found[total++] = pid;
                grew = 1;
            }
        }
    }
    return total;
}

/* Whether any target is still a process that can run (zombies cannot). */
static int live_targets(pid_t *found, int capacity) {
    int total = targets(found, capacity);
    int live = 0;
    for (int i = 0; i < total; i++) {
        for (int j = 0; j < table_count; j++) {
            if (table[j].pid == found[i]) {
                if (table[j].state != 'Z' && table[j].state != 'X') found[live++] = found[i];
                break;
            }
        }
    }
    return live;
}

typedef struct {
    pid_t child;
    int done;
    int status;
} command_t;

/* Collects every child that has ended; notes the command's own status. */
static void reap(command_t *command) {
    for (;;) {
        int status = 0;
        pid_t pid = waitpid(-1, &status, WNOHANG);
        if (pid <= 0) return;
        if (pid == command->child && !command->done) {
            command->done = 1;
            command->status = status;
        }
    }
}

static pid_t signalled[MAX_PROCESSES];
static int signalled_count;

static void note_signalled(pid_t pid) {
    for (int i = 0; i < signalled_count; i++) {
        if (signalled[i] == pid) return;
    }
    if (signalled_count < MAX_PROCESSES) signalled[signalled_count++] = pid;
}

/* Waits up to `limit_ms` for a child to change, collecting the ended ones. */
static void wait_a_little(const sigset_t *waited, long limit_ms, command_t *command) {
    if (limit_ms <= 0) {
        reap(command);
        return;
    }
    if (limit_ms > 50) limit_ms = 50;
    struct timespec pause = {0, limit_ms * 1000000L};
    siginfo_t info;
    sigtimedwait(waited, &info, &pause);
    reap(command);
}

/*
 * Ends everything: SIGTERM and SIGCONT to each target, SIGKILL to the ones
 * left after `grace_ms`. Returns how many are left at the end.
 */
static int end_everything(const sigset_t *waited, long grace_ms, command_t *command) {
    static pid_t found[MAX_PROCESSES];
    int count = live_targets(found, MAX_PROCESSES);
    for (int i = 0; i < count; i++) {
        note_signalled(found[i]);
        kill(found[i], SIGTERM);
        kill(found[i], SIGCONT);
    }
    long deadline = now_ms() + grace_ms;
    while (count > 0 && now_ms() < deadline) {
        wait_a_little(waited, deadline - now_ms(), command);
        count = live_targets(found, MAX_PROCESSES);
        /* Started after the first pass, or orphaned since: they are told too. */
        for (int i = 0; i < count; i++) {
            int known = 0;
            for (int j = 0; j < signalled_count; j++) {
                if (signalled[j] == found[i]) known = 1;
            }
            if (!known) {
                note_signalled(found[i]);
                kill(found[i], SIGTERM);
                kill(found[i], SIGCONT);
            }
        }
    }
    long kill_deadline = now_ms() + KILL_WAIT_MS;
    while (count > 0 && now_ms() < kill_deadline) {
        for (int i = 0; i < count; i++) {
            note_signalled(found[i]);
            kill(found[i], SIGKILL);
        }
        wait_a_little(waited, kill_deadline - now_ms(), command);
        count = live_targets(found, MAX_PROCESSES);
    }
    /* Zombies left by parents that just died come back to this subreaper. */
    long reap_deadline = now_ms() + 500;
    while (targets(found, MAX_PROCESSES) > 0 && now_ms() < reap_deadline) {
        wait_a_little(waited, reap_deadline - now_ms(), command);
    }
    return count;
}

/* Every signal at its default and none blocked, as a fresh process has them. */
static void reset_signals(void) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    for (int sig = 1; sig < NSIG; sig++) {
        if (sig == SIGKILL || sig == SIGSTOP) continue;
        sigaction(sig, &action, NULL);
    }
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);
}

static int usage(void) {
    fputs("usage: libcodeforge-spawn.so [--status FILE] [--grace MS] -- PROGRAM [ARGUMENT...]\n", stderr);
    return 125;
}

int main(int argc, char **argv) {
    long grace_ms = 1000;
    int index = 1;
    for (; index < argc; index++) {
        if (strcmp(argv[index], "--status") == 0 && index + 1 < argc) {
            status_path = argv[++index];
        } else if (strcmp(argv[index], "--grace") == 0 && index + 1 < argc) {
            grace_ms = atol(argv[++index]);
            if (grace_ms < 0) grace_ms = 0;
            if (grace_ms > 60000) grace_ms = 60000;
        } else if (strcmp(argv[index], "--") == 0) {
            index++;
            break;
        } else {
            return usage();
        }
    }
    if (index >= argc) return usage();
    char **program = argv + index;

    self = getpid();
    reset_signals();
    /* A fresh child of the app is never a group leader, so this succeeds. */
    setsid();
    group = getpgrp();
    subreaper = prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) == 0;
    struct rlimit no_core = {0, 0};
    setrlimit(RLIMIT_CORE, &no_core);

    char text[512];
    report("");

    sigset_t waited;
    sigemptyset(&waited);
    sigaddset(&waited, SIGCHLD);
    sigaddset(&waited, SIGTERM);
    sigaddset(&waited, SIGINT);
    sigaddset(&waited, SIGHUP);
    sigprocmask(SIG_BLOCK, &waited, NULL);

    /* exec's failure, if any, comes back through this pipe; success closes it. */
    int failure_pipe[2];
    if (pipe2(failure_pipe, O_CLOEXEC) != 0) {
        snprintf(text, sizeof(text), "reason=spawn_failed\nexec_errno=%d\nended=0\nremaining=0\n", errno);
        report(text);
        return 125;
    }
    command_t command = {0, 0, 0};
    command.child = fork();
    if (command.child < 0) {
        snprintf(text, sizeof(text), "reason=spawn_failed\nexec_errno=%d\nended=0\nremaining=0\n", errno);
        report(text);
        return 125;
    }
    if (command.child == 0) {
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        close(failure_pipe[0]);
        execv(program[0], program);
        int failure = errno;
        ssize_t ignored = write(failure_pipe[1], &failure, sizeof(failure));
        (void) ignored;
        _exit(failure == ENOENT ? 127 : 126);
    }
    close(failure_pipe[1]);
    int exec_errno = 0;
    ssize_t got;
    do {
        got = read(failure_pipe[0], &exec_errno, sizeof(exec_errno));
    } while (got < 0 && errno == EINTR);
    close(failure_pipe[0]);

    int stop_signal = 0;
    if (got == (ssize_t) sizeof(exec_errno)) {
        while (!command.done) {
            if (waitpid(command.child, &command.status, 0) == command.child) command.done = 1;
            else if (errno != EINTR) break;
        }
        snprintf(text, sizeof(text), "reason=exec_failed\nexec_errno=%d\nended=0\nremaining=0\n", exec_errno);
        report(text);
        return exec_errno == ENOENT ? 127 : 126;
    }

    while (!command.done && stop_signal == 0) {
        siginfo_t info;
        int sig = sigwaitinfo(&waited, &info);
        if (sig < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (sig == SIGCHLD) {
            reap(&command);
        } else {
            stop_signal = sig;
        }
    }

    int remaining = end_everything(&waited, grace_ms, &command);
    if (!command.done) {
        /* Ended above with everything else; collect its status. */
        int status = 0;
        if (waitpid(command.child, &status, WNOHANG) == command.child) {
            command.done = 1;
            command.status = status;
        }
    }
    int ended = signalled_count;
    if (stop_signal == 0) {
        /* The command had exited by itself: count only what it left behind. */
        for (int i = 0; i < signalled_count; i++) {
            if (signalled[i] == command.child) ended--;
        }
    }

    const char *reason;
    char outcome[64];
    int exit_code;
    if (command.done && WIFEXITED(command.status)) {
        exit_code = WEXITSTATUS(command.status);
        snprintf(outcome, sizeof(outcome), "exit=%d", exit_code);
        reason = stop_signal ? "stopped" : "exited";
    } else if (command.done && WIFSIGNALED(command.status)) {
        exit_code = 128 + WTERMSIG(command.status);
        snprintf(outcome, sizeof(outcome), "signal=%d", WTERMSIG(command.status));
        reason = stop_signal ? "stopped" : "signaled";
    } else {
        exit_code = 128 + (stop_signal ? stop_signal : SIGKILL);
        snprintf(outcome, sizeof(outcome), "signal=%d", SIGKILL);
        reason = "stopped";
    }
    snprintf(text, sizeof(text), "reason=%s\n%s\nstop_signal=%d\nended=%d\nremaining=%d\n",
        reason, outcome, stop_signal, ended, remaining);
    report(text);
    return exit_code;
}
