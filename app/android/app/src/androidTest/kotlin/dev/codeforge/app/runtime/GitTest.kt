package dev.codeforge.app.runtime

import android.content.Context
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.util.Base64
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import dev.codeforge.runtime.core.HarnessConfig
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Collections
import java.util.concurrent.atomic.AtomicReference
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runners.MethodSorters

/**
 * Phase 7 W1, the Git spike (PHASE_7_PLAN §3): the sealed runtime's git on
 * every target, through the launcher's command mode, as Run runs a program,
 * before the app builds anything on it. Over the APK's own payload, installed
 * into a root of the class's own (files/runtime-gate/git).
 *
 *   a. Local work leaves exactly the state expected: `status --porcelain=v2
 *      -z --branch` compared byte for byte after each step (blob ids worked
 *      out from the files' text), a diff, the log, branches and a
 *      fast-forward merge.
 *   b. A merge with a conflict: the file listed as unmerged with its three
 *      stages, its markers, then resolved and committed with two parents.
 *   c. A remote with a password, on the device: `git http-backend` behind a
 *      small server in the runtime's Python on 127.0.0.1, with Basic
 *      authentication. Clone, push and pull get the credential from a
 *      credential helper only (Git's own protocol: get, store, erase), which
 *      the test answers over two FIFOs made for the run; a wrong password is
 *      refused and erased, no answer fails without a prompt, and the password
 *      is in no file of the runtime's home.
 *   d. HTTPS to a real host (github.com): recorded, not judged.
 *   e. SSH, as a probe: keys made, GitHub's handshake, and a clone over SSH
 *      from the runtime's own sshd on 127.0.0.1. Recorded, not judged.
 *   f. A repository of 10,000 files made as a new project is: written, its
 *      untracked status, added, committed, then status 20 times, with and
 *      without the index's optional lock, and 100 files changed.
 *   g. A repository of 50,000 files as a clone leaves one: one pack
 *      (fast-import), then checked out, and the same measures.
 *
 * Every figure goes to the device log (RUNTIME_GATE git_...) and to
 * files/runtime-gate/git-report.txt, which the gate copies out.
 */
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class GitTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val gate = File(context.filesDir, "runtime-gate")

    private fun record(key: String, value: Any?) {
        val line = "git_$key=$value"
        Log.i(TAG, "RUNTIME_GATE $line")
        gate.mkdirs()
        File(gate, REPORT).appendText(line + "\n")
    }

    /** git with the gate's identity and fixed settings, in [directory] (the runtime's home when null). */
    private fun git(directory: File?, vararg arguments: String, timeoutMs: Long = 120_000L): CommandResult =
        commands().runner.run(
            CommandRequest(
                "git",
                SETTINGS + arguments.toList(),
                directory = directory,
                timeoutMs = timeoutMs,
                outputLimit = OUTPUT_LIMIT,
            ),
        )

    private fun run(program: String, vararg arguments: String, timeoutMs: Long = 60_000L): CommandResult =
        commands().runner.run(
            CommandRequest(program, arguments.toList(), directory = null, timeoutMs = timeoutMs, outputLimit = OUTPUT_LIMIT),
        )

    /** [result], which must have run and exited 0. */
    private fun ok(result: CommandResult, what: String): CommandResult {
        assertTrue("$what: ${describe(result)}", result.succeeded)
        return result
    }

    private fun status(repo: File): String =
        ok(git(repo, "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"), "status").stdout.text

    /** The repository's status is exactly [records], each NUL-terminated. */
    private fun assertStatus(repo: File, vararg records: String) {
        val expected = records.joinToString("") { it + "\u0000" }
        assertEquals(visible(expected), visible(status(repo)))
    }

    private fun revParse(repo: File, revision: String): String =
        ok(git(repo, "rev-parse", revision), "rev-parse $revision").stdout.text.trim()

    /** A folder of the runtime's home for one test, empty. */
    private fun fresh(name: String): File = File(home(), "work/$name").apply {
        deleteRecursively()
        mkdirs()
    }

    private fun write(directory: File, path: String, text: String) {
        File(directory, path).apply {
            parentFile?.mkdirs()
            writeText(text)
        }
    }

    @Test
    fun a_localWorkLeavesExactlyTheStateExpected() {
        File(gate, REPORT).delete()
        val started = System.nanoTime()
        record("version", ok(git(null, "--version"), "git --version").stdout.text.trim())
        val repo = fresh("local")
        write(repo, "a.txt", "alpha\nbeta\n")
        write(repo, "src/b.txt", "bravo\n")
        ok(git(repo, "init", "-q"), "init")
        assertStatus(repo, "# branch.oid (initial)", "# branch.head main", "? a.txt", "? src/b.txt")

        ok(git(repo, "add", "-A"), "add")
        val a1 = blob("alpha\nbeta\n")
        assertStatus(
            repo,
            "# branch.oid (initial)",
            "# branch.head main",
            "1 A. N... 000000 100644 100644 $ZERO $a1 a.txt",
            "1 A. N... 000000 100644 100644 $ZERO ${blob("bravo\n")} src/b.txt",
        )
        ok(git(repo, "commit", "-q", "-m", "First"), "commit")
        val first = revParse(repo, "HEAD")

        write(repo, "a.txt", "alpha\ngamma\n")
        write(repo, "c.txt", "charlie\n")
        assertStatus(repo, "# branch.oid $first", "# branch.head main", "1 .M N... 100644 100644 100644 $a1 $a1 a.txt", "? c.txt")
        val a2 = blob("alpha\ngamma\n")
        assertEquals(
            "diff --git a/a.txt b/a.txt\nindex ${a1.take(7)}..${a2.take(7)} 100644\n--- a/a.txt\n+++ b/a.txt\n" +
                "@@ -1,2 +1,2 @@\n alpha\n-beta\n+gamma\n",
            ok(git(repo, "diff", "--no-ext-diff", "--no-color"), "diff").stdout.text,
        )
        ok(git(repo, "add", "a.txt", "c.txt"), "add two")
        ok(git(repo, "commit", "-q", "-m", "Second"), "commit two")
        val second = revParse(repo, "HEAD")

        ok(git(repo, "mv", "c.txt", "d.txt"), "mv")
        val c1 = blob("charlie\n")
        assertStatus(repo, "# branch.oid $second", "# branch.head main", "2 R. N... 100644 100644 100644 $c1 $c1 R100 d.txt", "c.txt")
        ok(git(repo, "commit", "-q", "-m", "Third"), "commit three")

        val log = ok(git(repo, "log", "-z", "--format=%s%x1f%an%x1f%ae%x1f%P"), "log").stdout.text
            .split('\u0000')
            .filter { it.isNotEmpty() }
            .map { it.split('\u001f') }
        assertEquals(listOf("Third", "Second", "First"), log.map { it[0] })
        assertTrue("every commit is the gate's: $log", log.all { it[1] == NAME && it[2] == EMAIL })
        assertEquals(listOf(1, 1, 0), log.map { entry -> entry[3].split(' ').count { it.isNotEmpty() } })

        ok(git(repo, "branch", "feature"), "branch")
        ok(git(repo, "switch", "-q", "feature"), "switch to feature")
        write(repo, "e.txt", "echo\n")
        ok(git(repo, "add", "e.txt"), "add on feature")
        ok(git(repo, "commit", "-q", "-m", "Fourth"), "commit on feature")
        ok(git(repo, "switch", "-q", "main"), "switch to main")
        assertFalse("e.txt is not on main", File(repo, "e.txt").exists())
        ok(git(repo, "merge", "-q", "--ff-only", "feature"), "fast-forward")
        val head = revParse(repo, "HEAD")
        assertEquals(revParse(repo, "feature"), head)
        assertEquals(
            "feature\nmain\n",
            ok(git(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads"), "refs").stdout.text,
        )
        assertStatus(repo, "# branch.oid $head", "# branch.head main")

        val times = LongArray(20) { ok(git(repo, "status", "--porcelain=v2", "-z", "--branch"), "status").durationMs }
        record("local_status_ms", spread(times))
        record("local", "ok ms=${(System.nanoTime() - started) / 1_000_000}")
    }

    @Test
    fun b_aConflictIsListedThenResolved() {
        val repo = fresh("conflict")
        val base = "one\ntwo\nthree\n"
        val ours = "one\nTWO-main\nthree\n"
        val theirs = "one\nTWO-feature\nthree\n"
        write(repo, "a.txt", base)
        ok(git(repo, "init", "-q"), "init")
        ok(git(repo, "add", "-A"), "add")
        ok(git(repo, "commit", "-q", "-m", "Base"), "base")
        ok(git(repo, "switch", "-q", "-c", "feature"), "feature")
        write(repo, "a.txt", theirs)
        ok(git(repo, "commit", "-q", "-am", "Feature"), "feature's commit")
        ok(git(repo, "switch", "-q", "main"), "main")
        write(repo, "a.txt", ours)
        ok(git(repo, "commit", "-q", "-am", "Main"), "main's commit")
        val main = revParse(repo, "HEAD")

        val merge = git(repo, "merge", "feature")
        assertEquals("the merge stops at the conflict: ${describe(merge)}", 1, merge.exitCode)
        assertTrue(merge.stdout.text, merge.stdout.text.contains("CONFLICT (content): Merge conflict in a.txt"))
        assertStatus(
            repo,
            "# branch.oid $main",
            "# branch.head main",
            "u UU N... 100644 100644 100644 100644 ${blob(base)} ${blob(ours)} ${blob(theirs)} a.txt",
        )
        assertEquals(
            "one\n<<<<<<< HEAD\nTWO-main\n=======\nTWO-feature\n>>>>>>> feature\nthree\n",
            File(repo, "a.txt").readText(),
        )

        write(repo, "a.txt", "one\nTWO-both\nthree\n")
        ok(git(repo, "add", "a.txt"), "resolved")
        ok(git(repo, "commit", "-q", "--no-edit"), "the merge's commit")
        val parents = ok(git(repo, "log", "-1", "--format=%P"), "parents").stdout.text.trim().split(' ')
        assertEquals(2, parents.size)
        assertStatus(repo, "# branch.oid ${revParse(repo, "HEAD")}", "# branch.head main")
        record("conflict", "listed=1 markers=1 resolved=1 parents=2 merge_ms=${merge.durationMs}")
    }

    @Test
    fun c_aRemoteWithAPasswordGetsItFromTheCredentialHelperOnly() {
        val secret = "cf-" + hex(16)
        val wrong = "cf-" + hex(16)
        val served = fresh("served")
        val seed = fresh("seed")
        write(seed, "README.md", "hello\n")
        ok(git(seed, "init", "-q"), "seed's init")
        ok(git(seed, "add", "-A"), "seed's add")
        ok(git(seed, "commit", "-q", "-m", "Seed"), "seed's commit")
        ok(git(served, "clone", "-q", "--bare", seed.path, "repo.git"), "the served repository")

        val script = File(home(), "git-gate-server.py").apply { writeText(SERVER_PY) }
        val credentials = File(home(), "git-gate-credentials").apply {
            writeText(Base64.encodeToString("$USER:$secret".toByteArray(), Base64.NO_WRAP))
        }
        val portFile = File(home(), "git-gate-port").apply { delete() }
        val server = Background("python", listOf(script.path, served.path, portFile.path, credentials.path), 9 * 60_000L)
        val fifos = File(home(), "git-gate-credential").apply {
            deleteRecursively()
            mkdirs()
        }
        Os.mkfifo(File(fifos, "request").path, MODE_0600)
        Os.mkfifo(File(fifos, "answer").path, MODE_0600)
        val helper = File(home(), "git-gate-credential.sh").apply { writeText(HELPER_SH) }
        val answerer = CredentialAnswerer(fifos).apply { start() }
        // Only CodeForge's helper, on this command's line: an empty value resets the list first.
        val helped = arrayOf("-c", "credential.helper=", "-c", "credential.helper=!bash '${helper.path}' '${fifos.path}'")
        try {
            val port = waitFor(20_000L) { portFile.takeIf { it.isFile }?.readText()?.trim()?.toIntOrNull() }
            assertNotNull("the server listens: ${server.output}", port)
            val url = "http://127.0.0.1:$port/repo.git"
            val work = fresh("clones")

            answerer.answer = "username=$USER\npassword=$secret\n"
            val clone = ok(git(work, *helped, "clone", "-q", url, "first"), "clone")
            assertEquals(listOf("get", "store"), answerer.operations())
            val asked = answerer.asked.first()
            assertEquals("http", asked["protocol"])
            assertEquals("127.0.0.1:$port", asked["host"])
            val first = File(work, "first")
            assertStatus(
                first,
                "# branch.oid ${revParse(first, "HEAD")}",
                "# branch.head main",
                "# branch.upstream origin/main",
                "# branch.ab +0 -0",
            )
            assertFalse("the clone's config holds no secret", File(first, ".git/config").readText().contains(secret))
            record("remote_clone", "ok ms=${clone.durationMs}")

            answerer.clear()
            ok(git(work, *helped, "clone", "-q", url, "second"), "second clone")
            val second = File(work, "second")

            write(first, "NEWS.md", "pushed from the device\n")
            ok(git(first, "add", "NEWS.md"), "add")
            ok(git(first, "commit", "-q", "-m", "From the device"), "commit")
            answerer.clear()
            val push = ok(git(first, *helped, "push", "-q", "origin", "main"), "push")
            assertEquals(listOf("get", "store"), answerer.operations())
            val pushed = revParse(first, "HEAD")
            assertEquals(pushed, ok(git(served, "--git-dir=repo.git", "rev-parse", "main"), "served main").stdout.text.trim())
            record("remote_push", "ok ms=${push.durationMs}")

            answerer.clear()
            val pull = ok(git(second, *helped, "pull", "-q", "--ff-only"), "pull")
            assertEquals(pushed, revParse(second, "HEAD"))
            record("remote_pull", "ok ms=${pull.durationMs}")

            answerer.clear()
            answerer.answer = "username=$USER\npassword=$wrong\n"
            val refused = git(work, *helped, "clone", "-q", url, "refused")
            assertEquals("a wrong password is refused: ${describe(refused)}", 128, refused.exitCode)
            assertTrue(refused.stderr.text, refused.stderr.text.contains("Authentication failed"))
            assertEquals(listOf("get", "erase"), answerer.operations())
            assertFalse(File(work, "refused").exists())
            record("remote_wrong_password", "refused erased=1 ms=${refused.durationMs}")

            answerer.clear()
            answerer.answer = null
            val unanswered = git(work, *helped, "clone", "-q", url, "unanswered", timeoutMs = 60_000L)
            assertEquals("no credential, no prompt: ${describe(unanswered)}", 128, unanswered.exitCode)
            assertTrue("it stopped by itself: ${describe(unanswered)}", unanswered.failure == null)
            record("remote_no_credential", "refused ms=${unanswered.durationMs} detail=${lastLine(unanswered.stderr.text)}")

            val leaks = filesContaining(home(), secret)
            assertTrue("the password is in no file of the runtime's home: $leaks", leaks.isEmpty())
            record("remote_secret_in_files", leaks.size)
        } finally {
            answerer.quit()
            val ended = server.stop()
            record("remote_server", "ended=${ended?.failure?.code} leftovers=${ended?.leftovers}")
        }
    }

    @Test
    fun d_httpsToARealHostIsRecorded() {
        val work = fresh("https")
        val plain = git(work, "ls-remote", PUBLIC_REPOSITORY, "HEAD", timeoutMs = 60_000L)
        record("https_ls_remote", outcome(plain))
        if (!plain.succeeded) {
            val bundle = File(prefix(), "etc/tls/cert.pem")
            val withBundle = git(work, "-c", "http.sslCAInfo=${bundle.path}", "ls-remote", PUBLIC_REPOSITORY, "HEAD", timeoutMs = 60_000L)
            record("https_ls_remote_with_ca_info", outcome(withBundle))
        }
        val clone = git(work, "clone", "-q", "--depth", "1", PUBLIC_REPOSITORY, "hello", timeoutMs = 120_000L)
        record("https_clone", outcome(clone) + " files=${File(work, "hello").list()?.size ?: 0}")
    }

    @Test
    fun e_sshIsProbedAndRecorded() {
        val ssh = fresh("ssh")
        val version = run("ssh", "-V")
        record("ssh_version", lastLine(version.stderr.text + version.stdout.text))

        val passphrase = hex(12)
        val protectedKey = File(ssh, "id_passphrase")
        val made = run("ssh-keygen", "-q", "-t", "ed25519", "-N", passphrase, "-C", "codeforge-gate", "-f", protectedKey.path)
        val readBack = run("ssh-keygen", "-y", "-P", passphrase, "-f", protectedKey.path)
        val publicKey = File(ssh, "id_passphrase.pub").takeIf { it.isFile }?.readText()?.trim()?.split(' ')?.take(2)?.joinToString(" ")
        record(
            "ssh_keygen",
            "exit=${made.exitCode} read_back=${publicKey != null && readBack.succeeded && readBack.stdout.text.trim().startsWith(publicKey)}",
        )

        val key = File(ssh, "id_gate")
        run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "codeforge-gate", "-f", key.path)
        val known = File(ssh, "known_hosts")
        val hello = run(
            "ssh", "-F", "/dev/null", "-i", key.path, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=${known.path}",
            "-o", "ConnectTimeout=15", "-T", "git@github.com",
            timeoutMs = 45_000L,
        )
        val fingerprints = run("ssh-keygen", "-l", "-F", "github.com", "-f", known.path).stdout.text
        val denied = hello.stderr.text.contains("Permission denied (publickey)")
        record(
            "ssh_github",
            "handshake=${if (denied) "ok" else "failed"} exit=${hello.exitCode} ms=${hello.durationMs} " +
                "host_key_matches=${fingerprints.contains(GITHUB_ED25519)} detail=${lastLine(hello.stderr.text)}",
        )

        val seed = fresh("ssh-seed")
        write(seed, "README.md", "over ssh\n")
        ok(git(seed, "init", "-q"), "seed's init")
        ok(git(seed, "add", "-A"), "seed's add")
        ok(git(seed, "commit", "-q", "-m", "Seed"), "seed's commit")
        val bare = File(ssh, "repo.git")
        ok(git(ssh, "clone", "-q", "--bare", seed.path, bare.path), "the served repository")
        val hostKey = File(ssh, "host_ed25519")
        run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", hostKey.path)
        val authorized = File(ssh, "authorized_keys").apply { writeText(File(ssh, "id_gate.pub").readText()) }
        val port = 20_000 + SecureRandom().nextInt(20_000)
        val daemon = Background(
            "bash",
            listOf(
                "-c",
                "exec \"\$PREFIX/bin/sshd\" -D -e -f /dev/null -p $port -o ListenAddress=127.0.0.1 " +
                    "-o HostKey=${hostKey.path} -o AuthorizedKeysFile=${authorized.path} -o PidFile=none " +
                    "-o StrictModes=no -o PasswordAuthentication=no " +
                    "-o \"SetEnv=PATH=\$PATH LD_LIBRARY_PATH=\$LD_LIBRARY_PATH LD_PRELOAD=\$LD_PRELOAD PREFIX=\$PREFIX HOME=\$HOME\"",
            ),
            3 * 60_000L,
        )
        try {
            val listening = waitFor(15_000L) { if (canConnect(port)) true else null } == true
            if (!listening) {
                record("ssh_local_clone", "sshd_not_listening")
                return
            }
            // The app's own user name, as the runtime's coreutils give it (Os.getpwuid is not public).
            val user = run("whoami").stdout.text.trim().ifEmpty { "gate" }
            val command = "ssh -F /dev/null -i ${key.path} -o IdentitiesOnly=yes -o BatchMode=yes " +
                "-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${File(ssh, "known_local").path}"
            val clone = git(ssh, "-c", "core.sshCommand=$command", "clone", "-q", "ssh://$user@127.0.0.1:$port${bare.path}", "cloned", timeoutMs = 60_000L)
            record("ssh_local_clone", outcome(clone) + " files=${File(ssh, "cloned").list()?.size ?: 0}")
        } finally {
            val ended = daemon.stop()
            record("ssh_local_sshd", "ended=${ended?.failure?.code} log=${lastLine(ended?.stderr?.text ?: "")}")
        }
    }

    @Test
    fun f_aRepositoryOfTenThousandFiles() {
        val name = "large"
        val files = 10_000
        val repo = fresh(name)
        val folders = files / FILES_PER_FOLDER
        val writing = System.nanoTime()
        for (folder in 0 until folders) {
            val directory = File(repo, "d%04d".format(folder)).apply { mkdirs() }
            for (file in 0 until FILES_PER_FOLDER) File(directory, "f%02d.txt".format(file)).writeText("folder $folder, file $file\n")
        }
        val written = (System.nanoTime() - writing) / 1_000_000
        ok(git(repo, *HOUSEKEEPING, "init", "-q"), "init")
        val untracked = ok(git(repo, *HOUSEKEEPING, "status", "--porcelain=v2", "-z", "--untracked-files=all", timeoutMs = LONG_MS), "untracked status")
        if (!untracked.stdout.truncated) assertEquals(files, untracked.stdout.text.count { it == '\u0000' })
        val added = ok(git(repo, *HOUSEKEEPING, "add", "-A", timeoutMs = LONG_MS), "add")
        val committed = ok(git(repo, *HOUSEKEEPING, "commit", "-q", "-m", "Generated", timeoutMs = LONG_MS), "commit")
        record(
            name,
            "files=$files written_ms=$written untracked_status_ms=${untracked.durationMs} " +
                "untracked_status_bytes=${untracked.stdout.bytes} add_ms=${added.durationMs} commit_ms=${committed.durationMs}",
        )
        measureStatus(name, repo, folders)
        repo.deleteRecursively()
    }

    @Test
    fun g_aRepositoryOfFiftyThousandFiles() {
        val name = "very_large"
        val files = 50_000
        val repo = fresh(name)
        val folders = files / FILES_PER_FOLDER
        val stream = File(home(), "work/very_large.fi")
        stream.bufferedWriter().use { out ->
            out.write("commit refs/heads/main\ncommitter $NAME <$EMAIL> 1700000000 +0000\ndata 9\nGenerated\n")
            for (folder in 0 until folders) {
                for (file in 0 until FILES_PER_FOLDER) {
                    val text = "folder $folder, file $file\n"
                    out.write("M 100644 inline d%04d/f%02d.txt\ndata ${text.length}\n$text\n".format(folder, file))
                }
            }
            out.write("\n")
        }
        ok(git(repo, *HOUSEKEEPING, "init", "-q"), "init")
        val imported = ok(
            run("bash", "-c", "cd '${repo.path}' && git -c gc.auto=0 fast-import --quiet < '${stream.path}'", timeoutMs = LONG_MS),
            "fast-import",
        )
        stream.delete()
        val checkout = ok(git(repo, *HOUSEKEEPING, "reset", "-q", "--hard", "main", timeoutMs = LONG_MS), "checkout")
        record(name, "files=$files import_ms=${imported.durationMs} checkout_ms=${checkout.durationMs}")
        measureStatus(name, repo, folders)
        repo.deleteRecursively()
    }

    /** Status 20 times with and without the index's optional lock, then 100 files changed, added and committed. */
    private fun measureStatus(name: String, repo: File, folders: Int) {
        val first = ok(git(repo, *HOUSEKEEPING, "status", "--porcelain=v2", "-z", "--branch", timeoutMs = LONG_MS), "first status")
        val warm = LongArray(20) {
            ok(git(repo, *HOUSEKEEPING, "status", "--porcelain=v2", "-z", "--branch", timeoutMs = LONG_MS), "status").durationMs
        }
        val unlocked = LongArray(20) {
            ok(
                git(repo, *HOUSEKEEPING, "--no-optional-locks", "status", "--porcelain=v2", "-z", "--branch", timeoutMs = LONG_MS),
                "status without the lock",
            ).durationMs
        }
        record("${name}_status_first_ms", first.durationMs)
        record("${name}_status_ms", spread(warm))
        record("${name}_status_no_locks_ms", spread(unlocked))

        for (change in 0 until 100) {
            File(repo, "d%04d/f00.txt".format(change * folders / 100)).writeText("changed $change\n")
        }
        val changed = ok(git(repo, *HOUSEKEEPING, "status", "--porcelain=v2", "-z", "--branch", timeoutMs = LONG_MS), "changed status")
        assertEquals(100, changed.stdout.text.split('\u0000').count { it.startsWith("1 .M ") })
        val added = ok(git(repo, *HOUSEKEEPING, "add", "-A", timeoutMs = LONG_MS), "add the changes")
        val committed = ok(git(repo, *HOUSEKEEPING, "commit", "-q", "-m", "Changed", timeoutMs = LONG_MS), "commit the changes")
        val log = ok(git(repo, *HOUSEKEEPING, "log", "-n", "100", "--format=%H", timeoutMs = LONG_MS), "log")
        val stat = ok(git(repo, *HOUSEKEEPING, "diff", "--stat", "HEAD~1", "HEAD", timeoutMs = LONG_MS), "diff --stat")
        assertTrue(stat.stdout.text, stat.stdout.text.contains("100 files changed"))
        record(
            "${name}_changes",
            "status_ms=${changed.durationMs} add_ms=${added.durationMs} commit_ms=${committed.durationMs} " +
                "log_ms=${log.durationMs} diff_stat_ms=${stat.durationMs}",
        )
        val objects = ok(git(repo, *HOUSEKEEPING, "count-objects", "-v"), "count-objects").stdout.text.lines()
            .mapNotNull { line -> line.split(": ").takeIf { it.size == 2 }?.let { it[0] to it[1] } }
            .toMap()
        record("${name}_objects", "loose=${objects["count"]} packs=${objects["packs"]} pack_kib=${objects["size-pack"]}")
    }

    /** A long-lived command on a thread of its own (a server), ended by [stop]. */
    private inner class Background(program: String, arguments: List<String>, timeoutMs: Long) {
        private val session = AtomicReference<SessionRegistry.Session?>()
        private val result = AtomicReference<CommandResult?>()
        private val lines = StringBuffer()
        private val thread = Thread {
            result.set(
                commands().runner.stream(
                    CommandRequest(program, arguments, directory = null, timeoutMs = timeoutMs, outputLimit = OUTPUT_LIMIT),
                    object : LineSink {
                        override fun line(text: String): Boolean {
                            if (lines.length < 16_384) lines.append(text).append('\n')
                            return true
                        }
                    },
                    started = { session.set(it) },
                ),
            )
        }.apply {
            isDaemon = true
            start()
        }

        val output: String get() = lines.toString()

        fun stop(): CommandResult? {
            session.get()?.end(EndReason.ENDED)
            thread.join(15_000L)
            return result.get()
        }
    }

    /**
     * The host's side of the credential helper: reads each request git's
     * helper writes into the request FIFO, and answers `get` through the
     * answer FIFO with [answer] (nothing when null).
     */
    private class CredentialAnswerer(private val fifos: File) : Thread("git-gate-credential") {
        @Volatile
        var answer: String? = null
        val asked: MutableList<Map<String, String>> = Collections.synchronizedList(mutableListOf())

        init {
            isDaemon = true
        }

        fun operations(): List<String> = synchronized(asked) { asked.map { it["operation"] ?: "?" } }

        fun clear() = asked.clear()

        override fun run() {
            while (true) {
                val text = try {
                    File(fifos, "request").readText()
                } catch (failure: Exception) {
                    return
                }
                val fields = text.lines()
                    .mapNotNull { line -> line.indexOf('=').takeIf { it > 0 }?.let { line.substring(0, it) to line.substring(it + 1) } }
                    .toMap()
                when (fields["operation"]) {
                    null -> continue
                    "quit" -> return
                    "get" -> {
                        asked.add(fields)
                        if (!writeWhenRead(File(fifos, "answer"), answer ?: "", 10_000L)) return
                    }
                    else -> asked.add(fields)
                }
            }
        }

        fun quit() {
            writeWhenRead(File(fifos, "request"), "operation=quit\n", 1_000L)
            join(5_000L)
        }
    }

    private companion object {
        const val TAG = "CodeForgeRuntimeGate"
        const val REPORT = "git-report.txt"
        const val NAME = "CodeForge Gate"
        const val EMAIL = "gate@codeforge.invalid"
        const val USER = "gate"
        const val ZERO = "0000000000000000000000000000000000000000"
        const val OUTPUT_LIMIT = 1024 * 1024
        const val LONG_MS = 10L * 60_000L
        const val FILES_PER_FOLDER = 20
        const val MODE_0600 = 384
        const val PUBLIC_REPOSITORY = "https://github.com/octocat/Hello-World.git"

        /** GitHub's published Ed25519 host key fingerprint. */
        const val GITHUB_ED25519 = "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"

        /** Before every command: the identity, the branch name, nothing paged or coloured, paths as they are. */
        val SETTINGS = listOf(
            "-c", "user.name=$NAME", "-c", "user.email=$EMAIL", "-c", "init.defaultBranch=main",
            "-c", "core.pager=cat", "-c", "color.ui=false", "-c", "core.quotePath=false",
        )

        /** No housekeeping in the background, which the launcher would end with the command. */
        val HOUSEKEEPING = arrayOf("-c", "gc.auto=0", "-c", "maintenance.auto=false")

        /** git http-backend behind Basic authentication, for test c. */
        val SERVER_PY = """
import http.server
import os
import subprocess
import sys

root, port_file, credential_file = sys.argv[1], sys.argv[2], sys.argv[3]
with open(credential_file, encoding="ascii") as handle:
    expected = "Basic " + handle.read().strip()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def body(self):
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            chunks = []
            while True:
                size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                if size == 0:
                    self.rfile.readline()
                    return b"".join(chunks)
                chunks.append(self.rfile.read(size))
                self.rfile.readline()
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def answer(self, status, headers, payload):
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def serve(self):
        data = self.body()
        if self.headers.get("Authorization", "") != expected:
            self.answer(401, [("WWW-Authenticate", 'Basic realm="codeforge-gate"')], b"authentication required\n")
            return
        path, _, query = self.path.partition("?")
        env = dict(os.environ)
        env.update({
            "GIT_PROJECT_ROOT": root,
            "GIT_HTTP_EXPORT_ALL": "1",
            "PATH_INFO": path,
            "QUERY_STRING": query,
            "REQUEST_METHOD": self.command,
            "CONTENT_TYPE": self.headers.get("Content-Type", ""),
            "CONTENT_LENGTH": str(len(data)),
            "REMOTE_USER": "gate",
            "REMOTE_ADDR": "127.0.0.1",
        })
        if self.headers.get("Content-Encoding"):
            env["HTTP_CONTENT_ENCODING"] = self.headers["Content-Encoding"]
        if self.headers.get("Git-Protocol"):
            env["GIT_PROTOCOL"] = self.headers["Git-Protocol"]
        out = subprocess.run(["git", "http-backend"], input=data, env=env, capture_output=True).stdout
        separator, skip = out.find(b"\r\n\r\n"), 4
        if separator < 0:
            separator, skip = out.find(b"\n\n"), 2
        head, payload = (out[:separator], out[separator + skip:]) if separator >= 0 else (b"", out)
        status, headers = 200, []
        for line in head.splitlines():
            name, _, value = line.decode("latin-1").partition(":")
            if name.lower() == "status":
                status = int(value.strip().split()[0])
            elif name and name.lower() != "content-length":
                headers.append((name, value.strip()))
        self.answer(status, headers, payload)

    do_GET = serve
    do_POST = serve


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file + ".tmp", "w", encoding="ascii") as handle:
    handle.write(str(server.server_address[1]))
os.rename(port_file + ".tmp", port_file)
server.serve_forever()
"""

        /** Git's credential helper protocol over the run's two FIFOs: the first argument is their folder, the second the operation. */
        val HELPER_SH = """
request=${'$'}(cat)
printf 'operation=%s\n%s\n\n' "${'$'}2" "${'$'}request" > "${'$'}1/request"
if [ "${'$'}2" = get ]; then
  cat "${'$'}1/answer"
fi
"""

        private var installed: RuntimeCommands? = null
        private var homeDir: File? = null
        private var prefixDir: File? = null

        fun home(): File {
            commands()
            return homeDir!!
        }

        fun prefix(): File {
            commands()
            return prefixDir!!
        }

        /** The payload installed once for the class, in a root of its own, and its command side. */
        @Synchronized
        fun commands(): RuntimeCommands {
            installed?.let { return it }
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val root = File(context.filesDir, "runtime-gate/git")
            root.deleteRecursively()
            val rootfs = File(root, "rootfs")
            val prefix = File(rootfs, "data/data/com.termux/files/usr")
            val home = File(root, "home")
            val config = HarnessConfig.Builder()
                .workspace(File(root, "workspace"))
                .home(home)
                .prefix(prefix)
                .rootfs(rootfs)
                .toolDirectory(File(prefix, "bin"))
                .libraryDirectory(File(prefix, "lib"))
                .nativeLibraryDirectory(File(context.applicationInfo.nativeLibraryDir))
                .build()
            val runtime = SealedRuntime(AssetPayloadSource(context), config)
            if (runtime.payload() == null) throw AssertionError("this APK carries no payload")
            runtime.install(null)
            val created = RuntimeCommands.create(
                config = config,
                killGroup = { group -> Os.kill(-group, OsConstants.SIGKILL) },
            )
            homeDir = home.apply { mkdirs() }
            prefixDir = prefix
            installed = created
            return created
        }

        /** The class's runtime root goes once its tests are done: each gate class installs its own. */
        @JvmStatic
        @AfterClass
        fun removeTheRuntime() {
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            File(context.filesDir, "runtime-gate/git").deleteRecursively()
            installed = null
            homeDir = null
            prefixDir = null
        }

        /** Writes [text] once a reader has the FIFO open, within [timeoutMs]; false when none came. */
        fun writeWhenRead(fifo: File, text: String, timeoutMs: Long): Boolean {
            val deadline = System.currentTimeMillis() + timeoutMs
            val bytes = text.toByteArray()
            while (System.currentTimeMillis() < deadline) {
                try {
                    val descriptor = Os.open(fifo.path, OsConstants.O_WRONLY or OsConstants.O_NONBLOCK, 0)
                    try {
                        if (bytes.isNotEmpty()) Os.write(descriptor, bytes, 0, bytes.size)
                    } finally {
                        Os.close(descriptor)
                    }
                    return true
                } catch (failure: ErrnoException) {
                    if (failure.errno != OsConstants.ENXIO) return false
                    Thread.sleep(10L)
                }
            }
            return false
        }

        /** Git's object id of a file holding [text]. */
        fun blob(text: String): String {
            val bytes = text.toByteArray(Charsets.UTF_8)
            val digest = MessageDigest.getInstance("SHA-1")
            digest.update("blob ${bytes.size}\u0000".toByteArray(Charsets.UTF_8))
            digest.update(bytes)
            return digest.digest().joinToString("") { "%02x".format(it) }
        }

        fun hex(bytes: Int): String {
            val random = ByteArray(bytes)
            SecureRandom().nextBytes(random)
            return random.joinToString("") { "%02x".format(it) }
        }

        fun spread(values: LongArray): String {
            val sorted = values.sorted()
            fun rank(quantile: Double) = sorted[((quantile * sorted.size).toInt()).coerceAtMost(sorted.size - 1)]
            return "n=${sorted.size} p50=${rank(0.50)} p95=${rank(0.95)} max=${sorted.last()}"
        }

        fun visible(text: String): String = text.replace("\u0000", "\\0\n")

        fun lastLine(text: String): String =
            text.lines().lastOrNull { it.isNotBlank() }?.trim()?.take(200)?.replace('=', ':') ?: ""

        fun describe(result: CommandResult): String =
            "exit=${result.exitCode} failure=${result.failure?.code} detail=${result.detail} " +
                "stderr=${result.stderr.text.takeLast(600)}"

        fun outcome(result: CommandResult): String =
            "${if (result.succeeded) "ok" else "failed"} exit=${result.exitCode} failure=${result.failure?.code} " +
                "ms=${result.durationMs} detail=${lastLine(result.stderr.text)}"

        fun <T> waitFor(timeoutMs: Long, probe: () -> T?): T? {
            val deadline = System.currentTimeMillis() + timeoutMs
            while (System.currentTimeMillis() < deadline) {
                probe()?.let { return it }
                Thread.sleep(50L)
            }
            return probe()
        }

        fun canConnect(port: Int): Boolean = try {
            Socket().use { it.connect(InetSocketAddress("127.0.0.1", port), 200) }
            true
        } catch (failure: Exception) {
            false
        }

        /** Regular files under [root], up to 4 MB each, that hold [secret]. */
        fun filesContaining(root: File, secret: String): List<String> {
            val needle = secret.toByteArray()
            return root.walkTopDown()
                .filter { it.isFile && it.length() <= 4L * 1024 * 1024 }
                .filter { file -> contains(file.readBytes(), needle) }
                .map { it.relativeTo(root).path }
                .toList()
        }

        private fun contains(haystack: ByteArray, needle: ByteArray): Boolean {
            if (needle.isEmpty() || haystack.size < needle.size) return false
            outer@ for (start in 0..haystack.size - needle.size) {
                for (index in needle.indices) {
                    if (haystack[start + index] != needle[index]) continue@outer
                }
                return true
            }
            return false
        }
    }
}
