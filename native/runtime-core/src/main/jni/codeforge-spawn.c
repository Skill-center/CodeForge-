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
 *      storage; and, when asked (Phase 5 W5, docs/SECURITY.md §2.2), the
 *      limits below;
 *   5. starts the command and waits for it;
 *   6. ends what is left once the command exits, or everything when it is
 *      asked to stop (SIGTERM, SIGINT or SIGHUP, as Process.destroy() sends):
 *      SIGTERM and SIGCONT to every process of its group and every
 *      descendant, then SIGKILL to those still there after the grace period;
 *   7. writes what happened to the status file, as key=value lines.
 *
 * Usage:
 *   libcodeforge-spawn.so [--status FILE] [--grace MS] [LIMITS] -- PROGRAM [ARGUMENT...]
 *
 * LIMITS (Phase 5 W5), each for this program and everything it starts, set
 * before the command starts:
 *
 *   --fsize BYTES          RLIMIT_FSIZE, soft and hard: a write past BYTES in
 *                          a file fails, and its writer gets SIGXFSZ;
 *   --nproc COUNT          RLIMIT_NPROC, soft and hard: a fork fails (EAGAIN)
 *                          while the user has COUNT processes and threads,
 *                          the app's own included, since Linux counts them
 *                          all for the user;
 *   --oom-score-adj SCORE  /proc/self/oom_score_adj raised to SCORE (0 to
 *                          1000) when it is lower: the kernel's OOM killer
 *                          then takes the command's processes before the
 *                          app's.
 *
 * A limit is only ever lowered and a score only raised: never above a limit
 * the system set, never below a score it set. What is in effect goes to the
 * status file (fsize_limit, nproc_limit: a number or unlimited;
 * oom_score_adj: the score, or -1 when it could not be read).
 *
 * PROGRAM is a path; the environment and the working directory are the
 * caller's. Exit status: the command's own, 128 + the signal that ended it,
 * 125 when this program could not run it, and 126 or 127 when exec failed
 * (127 for a program that is not there). The status file says which.
 *
 * Status file keys: pid (this program's), group (its process group after
 * setsid, which is the pid), subreaper (1 or 0), the limits in effect, then
 * at the end: reason
 * (exited, signaled, stopped,
 * exec_failed or spawn_failed), exit or signal (the command's), exec_errno,
 * stop_signal (what asked this program to stop), ended (processes it had to
 * signal after the command, or with it when stopped) and remaining
 * (processes it could not end, which is 0 unless the kernel refused), and
 * child (the command's pid, once it is started).
 *
 * Terminal mode (Phase 5 W2; docs/TERMINAL_ARCHITECTURE.md, ADR-0014):
 *
 *   libcodeforge-spawn.so [--status FILE] [--grace MS] [LIMITS] --terminal ROWSxCOLS -- PROGRAM [ARGUMENT...]
 *
 * The command runs on a pseudo-terminal this program opens (posix_openpt,
 * grantpt, unlockpt and ptsname, from POSIX; TIOCSCTTY and TIOCSWINSZ, from
 * Linux's ioctl_tty(2)). It leads a session of its own with the terminal as
 * its controlling terminal, so job control, Ctrl-C and SIGWINCH work as in
 * any terminal. This program stays outside that session, keeps everything
 * above (its own group, the subreaper, the clean signals, the status file),
 * and relays:
 *
 *   * the terminal's output to its stdout, as it comes, bytes unchanged;
 *   * frames from its stdin to the terminal. A frame is a type byte, the
 *     payload's length in two bytes (big-endian), then the payload. Type 1
 *     is input, as typed. Type 2 is a window size: rows, then columns, each
 *     in two bytes (big-endian); the kernel sends SIGWINCH to the
 *     terminal's foreground job. Any other type, or a size of another
 *     length, ends the session (stop_cause=protocol): a stream out of step
 *     must never reach the shell as keystrokes.
 *
 * Both directions are bounded. While its stdout is full, it reads nothing
 * from the terminal, so a program flooding the terminal blocks in the
 * kernel and nothing is lost; while the program reads no input, it reads no
 * more frames. The session ends like a terminal that hangs up when its stdin
 * ends (the app closed the session, or went away), its stdout breaks, or a
 * stop signal comes: SIGHUP, SIGTERM and SIGCONT to the whole tree, then
 * SIGKILL after the grace period (an interactive bash ignores SIGTERM and
 * ends on SIGHUP). When the command exits, what it left is ended as in
 * command mode, and the output written before is relayed first.
 *
 * Terminal mode's status file also has mode=terminal, tty (the terminal's
 * name), stop_cause (signal, input_closed, output_closed, protocol or
 * relay_failed) when it was stopped, and reason=terminal_failed when no
 * terminal could be opened.
 */
#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/signalfd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#ifndef PR_SET_CHILD_SUBREAPER
#define PR_SET_CHILD_SUBREAPER 36
#endif

/* More processes than one command can sensibly start; the rest wait a pass. */
#define MAX_PROCESSES 4096
/* How long the SIGKILL phase may take before the count of survivors is final. */
#define KILL_WAIT_MS 3000

/* Terminal mode's frames on stdin: a type, a 16-bit length, the payload. */
#define FRAME_INPUT 1
#define FRAME_SIZE 2
#define FRAME_HEADER 3
#define FRAME_MAX_PAYLOAD 65535
/* Output read from the terminal and not yet taken by the reader of stdout. */
#define OUTPUT_CAPACITY (64 * 1024)
/* Input waiting for the program to read it: room for at least one frame. */
#define INPUT_CAPACITY (128 * 1024)
/* Frames read and not yet applied: room for two whole frames. */
#define FRAMES_CAPACITY (2 * (FRAME_HEADER + FRAME_MAX_PAYLOAD))
/* How long the output is relayed after the session ended: when the command
 * exited by itself (its last words), and when it was stopped. */
#define DRAIN_EXITED_MS 10000
#define DRAIN_STOPPED_MS 500
/* An exited session's relay gives up once its reader takes nothing for this long. */
#define DRAIN_IDLE_MS 2000

static pid_t self;
static pid_t group;
static int subreaper;
static const char *status_path;
static pid_t child_pid;
static int terminal_mode;
static char tty_name[64];
/* The limits in effect, as status file lines (Phase 5 W5). */
static char limits_text[160];

enum {
    CAUSE_NONE,
    CAUSE_SIGNAL,
    CAUSE_INPUT_CLOSED,
    CAUSE_OUTPUT_CLOSED,
    CAUSE_PROTOCOL,
    CAUSE_RELAY_FAILED,
};

static const char *const cause_names[] = {
    "", "signal", "input_closed", "output_closed", "protocol", "relay_failed",
};

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

/*
 * The status file: the identity lines (with terminal mode's and the
 * command's pid once known), then `body` (key=value lines, or "").
 */
static void report(const char *body) {
    char terminal[128] = "";
    if (terminal_mode) snprintf(terminal, sizeof(terminal), "mode=terminal\ntty=%s\n", tty_name);
    char child[32] = "";
    if (child_pid > 0) snprintf(child, sizeof(child), "child=%d\n", (int) child_pid);
    char text[1024];
    snprintf(text, sizeof(text), "pid=%d\ngroup=%d\nsubreaper=%d\n%s%s%s%s",
        (int) self, (int) group, subreaper, limits_text, terminal, child, body);
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

/* The first signals: SIGTERM and SIGCONT; with SIGHUP first in terminal mode, as a hang-up. */
static void tell_to_end(pid_t pid) {
    note_signalled(pid);
    if (terminal_mode) kill(pid, SIGHUP);
    kill(pid, SIGTERM);
    kill(pid, SIGCONT);
}

/*
 * Ends everything: the first signals to each target (tell_to_end), SIGKILL
 * to the ones left after `grace_ms`. Returns how many are left at the end.
 */
static int end_everything(const sigset_t *waited, long grace_ms, command_t *command) {
    static pid_t found[MAX_PROCESSES];
    int count = live_targets(found, MAX_PROCESSES);
    for (int i = 0; i < count; i++) tell_to_end(found[i]);
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
            if (!known) tell_to_end(found[i]);
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

/* ── Terminal mode ─────────────────────────────────────────────────── */

static unsigned char output_buffer[OUTPUT_CAPACITY];
static size_t output_length;
static unsigned char input_buffer[INPUT_CAPACITY];
static size_t input_length;
static unsigned char frames[FRAMES_CAPACITY];
static size_t frames_length;
/* No process holds the terminal any more (its reads end in EIO): input is dropped. */
static int terminal_gone;

static void set_nonblocking(int file) {
    int flags = fcntl(file, F_GETFL);
    if (flags >= 0) fcntl(file, F_SETFL, flags | O_NONBLOCK);
}

static void consume(unsigned char *buffer, size_t *length, size_t count) {
    memmove(buffer, buffer + count, *length - count);
    *length -= count;
}

static unsigned short window_dimension(unsigned long value) {
    if (value < 1) return 1;
    if (value > 9999) return 9999;
    return (unsigned short) value;
}

/* The window's size, for the terminal and its foreground job (SIGWINCH). */
static void set_window(int master, unsigned long rows, unsigned long columns) {
    struct winsize size;
    memset(&size, 0, sizeof(size));
    size.ws_row = window_dimension(rows);
    size.ws_col = window_dimension(columns);
    ioctl(master, TIOCSWINSZ, &size);
}

/* "ROWSxCOLS", both positive decimal numbers. 0, or -1 when it is not that. */
static int parse_size(const char *text, unsigned long *rows, unsigned long *columns) {
    char *end;
    errno = 0;
    if (text[0] < '0' || text[0] > '9') return -1;
    *rows = strtoul(text, &end, 10);
    if (errno != 0 || *end != 'x' || end[1] < '0' || end[1] > '9') return -1;
    *columns = strtoul(end + 1, &end, 10);
    if (errno != 0 || *end != '\0' || *rows == 0 || *columns == 0) return -1;
    return 0;
}

/*
 * Opens the terminal: the master for this program, the slave for the
 * command, each closed on exec, the slave in UTF-8 mode (IUTF8: erasing in
 * the line editor of the kernel takes a whole character) at the given size.
 * 0, or -1 with errno set.
 */
static int open_terminal(int *master_out, int *slave_out, unsigned long rows, unsigned long columns) {
    int master = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC);
    if (master < 0) return -1;
    int failure = 0;
    if (grantpt(master) != 0 || unlockpt(master) != 0) {
        failure = errno;
    } else {
        int named = ptsname_r(master, tty_name, sizeof(tty_name));
        if (named != 0) failure = errno != 0 ? errno : named;
    }
    if (failure != 0) {
        close(master);
        errno = failure;
        return -1;
    }
    fcntl(master, F_SETFD, FD_CLOEXEC);
    int slave = open(tty_name, O_RDWR | O_NOCTTY | O_CLOEXEC);
    if (slave < 0) {
        failure = errno;
        close(master);
        errno = failure;
        return -1;
    }
    struct termios settings;
    if (tcgetattr(slave, &settings) == 0) {
#ifdef IUTF8
        settings.c_iflag |= IUTF8;
#endif
        tcsetattr(slave, TCSANOW, &settings);
    }
    set_window(master, rows, columns);
    *master_out = master;
    *slave_out = slave;
    return 0;
}

/*
 * In the command's process, before exec: a session of its own, led by it,
 * with the terminal as its controlling terminal and as its stdin, stdout and
 * stderr. 0, or -1 with errno set.
 */
static int take_terminal(int slave) {
    if (setsid() < 0) return -1;
    if (ioctl(slave, TIOCSCTTY, 0) != 0) return -1;
    if (dup2(slave, STDIN_FILENO) < 0 || dup2(slave, STDOUT_FILENO) < 0 || dup2(slave, STDERR_FILENO) < 0) return -1;
    if (slave > STDERR_FILENO) close(slave);
    return 0;
}

/* Writes waiting input to the terminal. Input for a terminal no process holds is dropped. */
static void write_input(int master) {
    while (input_length > 0 && !terminal_gone) {
        ssize_t count = write(master, input_buffer, input_length);
        if (count > 0) {
            consume(input_buffer, &input_length, (size_t) count);
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else if (count < 0 && errno == EAGAIN) {
            return;
        } else {
            terminal_gone = 1;
        }
    }
    if (terminal_gone) input_length = 0;
}

/* Reads what the terminal has, as far as there is room. -1 once no process holds it (EIO). */
static int read_output(int master) {
    while (output_length < OUTPUT_CAPACITY) {
        ssize_t count = read(master, output_buffer + output_length, OUTPUT_CAPACITY - output_length);
        if (count > 0) {
            output_length += (size_t) count;
            return 0;
        }
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 && errno == EAGAIN) return 0;
        terminal_gone = 1;
        input_length = 0;
        return -1;
    }
    return 0;
}

/* Hands waiting output to the reader of stdout. -1 when stdout is broken. */
static int write_output(void) {
    while (output_length > 0) {
        ssize_t count = write(STDOUT_FILENO, output_buffer, output_length);
        if (count > 0) {
            consume(output_buffer, &output_length, (size_t) count);
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else if (count < 0 && errno == EAGAIN) {
            return 0;
        } else {
            output_length = 0;
            return -1;
        }
    }
    return 0;
}

/*
 * Applies the frames read so far, in their order, while there is room for
 * their input. -1 on a frame that is not one of the two kinds.
 */
static int apply_frames(int master) {
    size_t at = 0;
    while (frames_length - at >= FRAME_HEADER) {
        unsigned type = frames[at];
        size_t length = ((size_t) frames[at + 1] << 8) | frames[at + 2];
        if (frames_length - at - FRAME_HEADER < length) break;
        const unsigned char *payload = frames + at + FRAME_HEADER;
        if (type == FRAME_INPUT) {
            if (!terminal_gone) {
                if (INPUT_CAPACITY - input_length < length) break;
                memcpy(input_buffer + input_length, payload, length);
                input_length += length;
            }
        } else if (type == FRAME_SIZE && length == 4) {
            set_window(master, ((unsigned long) payload[0] << 8) | payload[1],
                ((unsigned long) payload[2] << 8) | payload[3]);
        } else {
            return -1;
        }
        at += FRAME_HEADER + length;
    }
    if (at > 0) consume(frames, &frames_length, at);
    return 0;
}

/*
 * Relays between the terminal and stdin and stdout until the command exits
 * or the session has to end. Answers why it has to end (CAUSE_NONE when the
 * command exited) and the stop signal, when one came.
 */
static int relay(int master, int signals, command_t *command, int *stop_signal) {
    set_nonblocking(master);
    set_nonblocking(STDIN_FILENO);
    set_nonblocking(STDOUT_FILENO);
    int input_open = 1;
    int cause = CAUSE_NONE;
    while (!command->done && cause == CAUSE_NONE) {
        struct pollfd watch[4];
        short terminal_events = 0;
        if (!terminal_gone && output_length < OUTPUT_CAPACITY) terminal_events |= POLLIN;
        if (!terminal_gone && input_length > 0) terminal_events |= POLLOUT;
        watch[0].fd = signals;
        watch[0].events = POLLIN;
        watch[1].fd = terminal_events != 0 ? master : -1;
        watch[1].events = terminal_events;
        watch[2].fd = input_open && frames_length < FRAMES_CAPACITY ? STDIN_FILENO : -1;
        watch[2].events = POLLIN;
        watch[3].fd = output_length > 0 ? STDOUT_FILENO : -1;
        watch[3].events = POLLOUT;
        for (int i = 0; i < 4; i++) watch[i].revents = 0;
        if (poll(watch, 4, -1) < 0) {
            if (errno == EINTR) continue;
            cause = CAUSE_RELAY_FAILED;
            break;
        }
        if (watch[0].revents != 0) {
            struct signalfd_siginfo info;
            while (read(signals, &info, sizeof(info)) == (ssize_t) sizeof(info)) {
                int sig = (int) info.ssi_signo;
                if (sig == SIGCHLD) {
                    reap(command);
                } else if (sig != SIGPIPE && cause == CAUSE_NONE) {
                    /* SIGPIPE needs nothing: the write that caused it saw EPIPE. */
                    *stop_signal = sig;
                    cause = CAUSE_SIGNAL;
                }
            }
        }
        short terminal = watch[1].revents;
        if (terminal & (POLLOUT | POLLERR | POLLHUP)) write_input(master);
        if ((terminal & (POLLIN | POLLERR | POLLHUP)) && output_length < OUTPUT_CAPACITY) read_output(master);
        if (watch[2].revents != 0) {
            ssize_t count = read(STDIN_FILENO, frames + frames_length, FRAMES_CAPACITY - frames_length);
            if (count > 0) {
                frames_length += (size_t) count;
            } else if (count == 0 || (errno != EINTR && errno != EAGAIN)) {
                input_open = 0;
            }
        }
        /* At once, without waiting for the next poll: a keystroke's echo is never held up. */
        if (apply_frames(master) != 0) {
            if (cause == CAUSE_NONE) cause = CAUSE_PROTOCOL;
        } else if (input_length > 0) {
            write_input(master);
            if (apply_frames(master) != 0 && cause == CAUSE_NONE) cause = CAUSE_PROTOCOL;
        }
        if (!input_open && cause == CAUSE_NONE) cause = CAUSE_INPUT_CLOSED;
        if (output_length > 0 && write_output() != 0 && cause == CAUSE_NONE) cause = CAUSE_OUTPUT_CLOSED;
    }
    return cause;
}

/*
 * After the session has ended: relays the output still waiting until no
 * process holds the terminal (EIO) and stdout has taken all of it, for at
 * most `limit_ms`, and no longer once stdout takes nothing for DRAIN_IDLE_MS.
 */
static void drain(int master, long limit_ms) {
    long started = now_ms();
    long progress = started;
    while (now_ms() - started < limit_ms && now_ms() - progress < DRAIN_IDLE_MS) {
        if (terminal_gone && output_length == 0) return;
        struct pollfd watch[2];
        watch[0].fd = !terminal_gone && output_length < OUTPUT_CAPACITY ? master : -1;
        watch[0].events = POLLIN;
        watch[1].fd = output_length > 0 ? STDOUT_FILENO : -1;
        watch[1].events = POLLOUT;
        watch[0].revents = 0;
        watch[1].revents = 0;
        if (poll(watch, 2, 20) < 0 && errno != EINTR) return;
        if (watch[0].revents != 0) {
            size_t before = output_length;
            read_output(master);
            if (output_length > before) progress = now_ms();
        }
        if (watch[1].revents != 0) {
            size_t before = output_length;
            if (write_output() != 0) return;
            if (output_length < before) progress = now_ms();
        }
    }
}

/*
 * Lowers `resource` to `wanted`, soft and hard, for this program and what it
 * starts: never above the limit already there (0 for `wanted` leaves it).
 */
static void lower_limit(int resource, unsigned long long wanted) {
    if (wanted == 0) return;
    struct rlimit current;
    if (getrlimit(resource, &current) != 0) return;
    rlim_t value = (rlim_t) wanted;
    if (current.rlim_max != RLIM_INFINITY && value > current.rlim_max) value = current.rlim_max;
    if (current.rlim_cur != RLIM_INFINITY && value > current.rlim_cur) value = current.rlim_cur;
    struct rlimit lowered = {value, value};
    setrlimit(resource, &lowered);
}

/* /proc/self/oom_score_adj, or -1001 when it cannot be read. */
static long read_oom_score(void) {
    int file = open("/proc/self/oom_score_adj", O_RDONLY | O_CLOEXEC);
    if (file < 0) return -1001;
    char buffer[16];
    ssize_t length = read(file, buffer, sizeof(buffer) - 1);
    close(file);
    if (length <= 0) return -1001;
    buffer[length] = '\0';
    char *end;
    long score = strtol(buffer, &end, 10);
    return end == buffer ? -1001 : score;
}

/* Raises /proc/self/oom_score_adj to `wanted` when it is lower; never lowers it. */
static void raise_oom_score(long wanted) {
    if (wanted < 0) return;
    long current = read_oom_score();
    if (current == -1001 || current >= wanted) return;
    int file = open("/proc/self/oom_score_adj", O_WRONLY | O_CLOEXEC);
    if (file < 0) return;
    char text[16];
    int length = snprintf(text, sizeof(text), "%ld", wanted);
    ssize_t ignored = write(file, text, (size_t) length);
    (void) ignored;
    close(file);
}

/* `name=value` for one limit in effect: a number, or unlimited. */
static int describe_limit(char *out, size_t size, const char *name, int resource) {
    struct rlimit current;
    if (getrlimit(resource, &current) != 0) return snprintf(out, size, "%s=unknown\n", name);
    if (current.rlim_cur == RLIM_INFINITY) return snprintf(out, size, "%s=unlimited\n", name);
    return snprintf(out, size, "%s=%llu\n", name, (unsigned long long) current.rlim_cur);
}

/* A whole decimal number from 1 to `max`, or 0 when `text` is not one. */
static unsigned long long parse_count(const char *text, unsigned long long max) {
    if (text[0] < '0' || text[0] > '9') return 0;
    char *end;
    errno = 0;
    unsigned long long value = strtoull(text, &end, 10);
    if (errno != 0 || *end != '\0' || value > max) return 0;
    return value;
}

static int usage(void) {
    fputs("usage: libcodeforge-spawn.so [--status FILE] [--grace MS] [--fsize BYTES] [--nproc COUNT]"
          " [--oom-score-adj SCORE] [--terminal ROWSxCOLS] -- PROGRAM [ARGUMENT...]\n",
        stderr);
    return 125;
}

int main(int argc, char **argv) {
    long grace_ms = 1000;
    unsigned long rows = 24;
    unsigned long columns = 80;
    unsigned long long fsize = 0;
    unsigned long long nproc = 0;
    long oom_score = -1;
    int index = 1;
    for (; index < argc; index++) {
        if (strcmp(argv[index], "--status") == 0 && index + 1 < argc) {
            status_path = argv[++index];
        } else if (strcmp(argv[index], "--grace") == 0 && index + 1 < argc) {
            grace_ms = atol(argv[++index]);
            if (grace_ms < 0) grace_ms = 0;
            if (grace_ms > 60000) grace_ms = 60000;
        } else if (strcmp(argv[index], "--terminal") == 0 && index + 1 < argc) {
            if (parse_size(argv[++index], &rows, &columns) != 0) return usage();
            terminal_mode = 1;
        } else if (strcmp(argv[index], "--fsize") == 0 && index + 1 < argc) {
            fsize = parse_count(argv[++index], 1ULL << 62);
            if (fsize == 0) return usage();
        } else if (strcmp(argv[index], "--nproc") == 0 && index + 1 < argc) {
            nproc = parse_count(argv[++index], 1ULL << 31);
            if (nproc == 0) return usage();
        } else if (strcmp(argv[index], "--oom-score-adj") == 0 && index + 1 < argc) {
            const char *score = argv[++index];
            /* 0 is a score too: parse_count's 0 means "not a number" only when the text is not "0". */
            if (strcmp(score, "0") == 0) {
                oom_score = 0;
            } else {
                unsigned long long parsed = parse_count(score, 1000);
                if (parsed == 0) return usage();
                oom_score = (long) parsed;
            }
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
    /* The limits, before the command starts: it and what it starts inherit them. */
    lower_limit(RLIMIT_FSIZE, fsize);
    lower_limit(RLIMIT_NPROC, nproc);
    raise_oom_score(oom_score);
    {
        size_t used = 0;
        used += (size_t) describe_limit(limits_text + used, sizeof(limits_text) - used, "fsize_limit", RLIMIT_FSIZE);
        if (used < sizeof(limits_text)) {
            used += (size_t) describe_limit(limits_text + used, sizeof(limits_text) - used, "nproc_limit", RLIMIT_NPROC);
        }
        long score = read_oom_score();
        if (used < sizeof(limits_text)) {
            snprintf(limits_text + used, sizeof(limits_text) - used, "oom_score_adj=%ld\n", score == -1001 ? -1L : score);
        }
    }

    char text[512];
    int master = -1;
    int slave = -1;
    if (terminal_mode && open_terminal(&master, &slave, rows, columns) != 0) {
        snprintf(text, sizeof(text), "reason=terminal_failed\nexec_errno=%d\nended=0\nremaining=0\n", errno);
        report(text);
        return 125;
    }
    report("");

    sigset_t waited;
    sigemptyset(&waited);
    sigaddset(&waited, SIGCHLD);
    sigaddset(&waited, SIGTERM);
    sigaddset(&waited, SIGINT);
    sigaddset(&waited, SIGHUP);
    /* The relay writes to a pipe the app may close: EPIPE, never a death by SIGPIPE. */
    if (terminal_mode) sigaddset(&waited, SIGPIPE);
    sigprocmask(SIG_BLOCK, &waited, NULL);
    int signals = -1;
    if (terminal_mode) {
        signals = signalfd(-1, &waited, SFD_NONBLOCK | SFD_CLOEXEC);
        if (signals < 0) {
            snprintf(text, sizeof(text), "reason=terminal_failed\nexec_errno=%d\nended=0\nremaining=0\n", errno);
            report(text);
            return 125;
        }
    }

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
        if (terminal_mode && take_terminal(slave) != 0) {
            /* Negative: the terminal failed, not exec. */
            int failure = -errno;
            ssize_t ignored = write(failure_pipe[1], &failure, sizeof(failure));
            (void) ignored;
            _exit(126);
        }
        execv(program[0], program);
        int failure = errno;
        ssize_t ignored = write(failure_pipe[1], &failure, sizeof(failure));
        (void) ignored;
        _exit(failure == ENOENT ? 127 : 126);
    }
    child_pid = command.child;
    report("");
    /* The command holds the slave now; once no process does, the master's reads end in EIO. */
    if (slave >= 0) close(slave);
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
        if (exec_errno < 0) {
            snprintf(text, sizeof(text), "reason=terminal_failed\nexec_errno=%d\nended=0\nremaining=0\n", -exec_errno);
            report(text);
            return 125;
        }
        snprintf(text, sizeof(text), "reason=exec_failed\nexec_errno=%d\nended=0\nremaining=0\n", exec_errno);
        report(text);
        return exec_errno == ENOENT ? 127 : 126;
    }

    int cause = CAUSE_NONE;
    if (terminal_mode) {
        cause = relay(master, signals, &command, &stop_signal);
    } else {
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
    }
    int stopping = stop_signal != 0 || cause != CAUSE_NONE;

    int remaining = end_everything(&waited, grace_ms, &command);
    if (terminal_mode && cause != CAUSE_OUTPUT_CLOSED) drain(master, stopping ? DRAIN_STOPPED_MS : DRAIN_EXITED_MS);
    if (!command.done) {
        /* Ended above with everything else; collect its status. */
        int status = 0;
        if (waitpid(command.child, &status, WNOHANG) == command.child) {
            command.done = 1;
            command.status = status;
        }
    }
    int ended = signalled_count;
    if (!stopping) {
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
        reason = stopping ? "stopped" : "exited";
    } else if (command.done && WIFSIGNALED(command.status)) {
        exit_code = 128 + WTERMSIG(command.status);
        snprintf(outcome, sizeof(outcome), "signal=%d", WTERMSIG(command.status));
        reason = stopping ? "stopped" : "signaled";
    } else {
        exit_code = 128 + (stop_signal ? stop_signal : SIGKILL);
        snprintf(outcome, sizeof(outcome), "signal=%d", SIGKILL);
        reason = "stopped";
    }
    char cause_line[64] = "";
    if (cause != CAUSE_NONE) snprintf(cause_line, sizeof(cause_line), "stop_cause=%s\n", cause_names[cause]);
    snprintf(text, sizeof(text), "reason=%s\n%s\nstop_signal=%d\n%sended=%d\nremaining=%d\n",
        reason, outcome, stop_signal, cause_line, ended, remaining);
    report(text);
    return exit_code;
}
