package dev.codeforge.app.syncmodes;

import android.app.Instrumentation;
import android.app.UiAutomation;
import android.content.Context;
import android.os.ParcelFileDescriptor;
import android.os.SystemClock;
import android.util.Log;
import android.view.accessibility.AccessibilityNodeInfo;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * The gate's answers on a Test Lab phone (Phase 5 W6), where no computer
 * reads the device log. {@code integration_test/folder_gate.dart} leaves each
 * request beside its answer ({@code files/foldergate/<id>.request}); this
 * thread, started with the activity by {@link SyncModesTest}'s rule, answers
 * the requests the phone's tests make ({@code phone_terminal_test.dart}), as
 * the emulator gate's folder driver does, through the instrumentation: the
 * shell user's commands and the accessibility tree ({@link UiAutomation}).
 *
 * <ul>
 *   <li>{@code mem <label>}: dumpsys meminfo's TOTAL PSS, in KiB, of the app's
 *       process and of its WebView renderers (the sandboxed processes its own
 *       service records name, or any sandboxed process when they name none):
 *       {@code app:<kb>,renderer:<kb>,renderers:<n>,via:<services|ps>}.</li>
 *   <li>{@code fixture}: the gate folder, {@code Documents/cf-gate}, with
 *       folder_fixture.dart's five files and {@code many/0001.txt} to
 *       {@code many/1000.txt}, each holding its number, written by the shell
 *       user (another app, as far as the app can tell): {@code done:<n>}, the
 *       entries of {@code many/}.</li>
 *   <li>{@code pick <name>}: Android's folder picker, which the test opens
 *       inside the gate folder: "Use this folder" once the folder's entries
 *       show (walking into Documents and the folder if it opened elsewhere),
 *       then "Allow": {@code picked}, or {@code failed:<why>}.</li>
 *   <li>{@code put <path> <word>}: the shell user writes the word and a line
 *       break to the path in the gate folder: {@code done}.</li>
 *   <li>{@code heap <read|gc>}: {@code unavailable}. The emulator's driver
 *       reads the page's JavaScript heap through DevTools; here nothing
 *       does.</li>
 * </ul>
 *
 * <p>The shell runs one command at a time, with no shell of its own (no
 * pipes or redirections), so files reach shared storage staged in the app's
 * external files folder and copied with {@code cp}. Answers keep to the
 * characters the emulator's driver keeps to.</p>
 */
final class GateAnswers implements Runnable {
    private static final String TAG = "CodeForgeGate";
    private static final String PACKAGE = "dev.codeforge.app";
    private static final String DOCUMENTS = "/sdcard/Documents";
    private static final String FOLDER = "cf-gate";
    private static final Pattern SAFE_PATH = Pattern.compile("[A-Za-z0-9._/-]{1,120}");
    private static final Pattern SAFE_WORD = Pattern.compile("[A-Za-z0-9._,:-]{1,120}");
    private static final Pattern RENDERER = Pattern.compile(
        "app=ProcessRecord\\{[0-9a-f]+ ([0-9]+):[^/}]*sandboxed_process");
    private static final Pattern TOTAL_PSS = Pattern.compile("TOTAL PSS:\\s+(\\d+)");
    private static final Pattern TOTAL_ROW = Pattern.compile("(?m)^\\s*TOTAL\\s+(\\d+)");
    /** folder_fixture.dart's gateFixture: path, then content. */
    private static final String[] FIXTURE = {
        "hello.txt", "Hello from the gate\n",
        "Readme.md", "# cf-gate\n\nA folder on shared storage.\n",
        "src/app.js", "console.log('cf-gate');\n",
        "src/lib/util.js", "export const answer = 42;\n",
        "notes/todo.md", "- list\n- read\n- write\n",
    };

    private static boolean started;

    private final Instrumentation instrumentation;
    private final Context context;

    private GateAnswers(Instrumentation instrumentation) {
        this.instrumentation = instrumentation;
        this.context = instrumentation.getTargetContext();
    }

    /** Starts answering, once per process. */
    static synchronized void start(Instrumentation instrumentation) {
        if (started) return;
        started = true;
        Thread thread = new Thread(new GateAnswers(instrumentation), "codeforge-gate-answers");
        thread.setDaemon(true);
        thread.start();
        Log.i(TAG, "answering the gate's requests from " + instrumentation.getTargetContext().getFilesDir());
    }

    @Override
    public void run() {
        File folder = new File(context.getFilesDir(), "foldergate");
        Set<String> answered = new HashSet<>();
        while (true) {
            File[] requests = folder.listFiles((dir, name) -> name.endsWith(".request"));
            if (requests != null) {
                Arrays.sort(requests);
                for (File request : requests) {
                    String name = request.getName();
                    String id = name.substring(0, name.length() - ".request".length());
                    if (answered.contains(id) || new File(folder, id).exists()) continue;
                    String text = read(request).trim();
                    // Not written yet: the next round reads it.
                    if (text.isEmpty()) continue;
                    answered.add(id);
                    String answer;
                    try {
                        answer = answer(text);
                    } catch (Throwable error) {
                        answer = "failed:" + error.getClass().getSimpleName();
                        Log.w(TAG, "request " + id + " (" + text + ") failed", error);
                    }
                    answer = answer.replaceAll("[^A-Za-z0-9._,:/-]", "?");
                    write(folder, id, answer + "\n");
                    Log.i(TAG, "request " + id + ": " + text + " -> " + answer);
                }
            }
            SystemClock.sleep(100);
        }
    }

    private String answer(String request) throws IOException {
        String[] words = request.split(" ");
        switch (words[0]) {
            case "mem":
                return memory();
            case "fixture":
                return fixture();
            case "pick":
                return pick();
            case "heap":
                return "unavailable";
            case "put":
                if (words.length != 3 || !SAFE_PATH.matcher(words[1]).matches()
                        || words[1].contains("..") || !SAFE_WORD.matcher(words[2]).matches()) {
                    return "bad-path";
                }
                return put(words[1], words[2]);
            default:
                return "unknown-request";
        }
    }

    // ------------------------------------------------------------ memory

    private String memory() {
        Integer app = totalPss(shell("dumpsys meminfo " + PACKAGE));
        Set<Integer> renderers = new TreeSet<>();
        Matcher match = RENDERER.matcher(shell("dumpsys activity services " + PACKAGE));
        while (match.find()) renderers.add(Integer.parseInt(match.group(1)));
        String via = "services";
        if (renderers.isEmpty()) {
            via = "ps";
            for (String line : shell("ps -A -o PID,NAME").split("\n")) {
                String[] fields = line.trim().split("\\s+");
                if (fields.length == 2 && fields[1].contains("sandboxed_process") && fields[0].matches("\\d+")) {
                    renderers.add(Integer.parseInt(fields[0]));
                }
            }
        }
        long renderer = 0;
        int count = 0;
        for (int pid : renderers) {
            Integer kb = totalPss(shell("dumpsys meminfo " + pid));
            if (kb == null) continue;
            renderer += kb;
            count += 1;
            Log.i(TAG, "mem: renderer " + pid + " " + kb + " KiB");
        }
        if (app == null) return "failed:no-app-pss";
        return "app:" + app + ",renderer:" + renderer + ",renderers:" + count + ",via:" + via;
    }

    /** dumpsys meminfo's TOTAL PSS in KiB, as the emulator's driver and editor/tool/cdp_kit.mjs read it. */
    static Integer totalPss(String meminfo) {
        Matcher summary = TOTAL_PSS.matcher(meminfo);
        if (summary.find()) return Integer.parseInt(summary.group(1));
        Matcher row = TOTAL_ROW.matcher(meminfo);
        return row.find() ? Integer.parseInt(row.group(1)) : null;
    }

    // ------------------------------------------------------------ the gate folder

    private File staging() throws IOException {
        File external = context.getExternalFilesDir(null);
        if (external == null) throw new IOException("no external files folder");
        return external;
    }

    private String fixture() throws IOException {
        File staged = new File(staging(), FOLDER);
        shell("rm -rf " + staged.getAbsolutePath());
        deleteTree(staged);
        for (int i = 0; i < FIXTURE.length; i += 2) {
            writeFile(new File(staged, FIXTURE[i]), FIXTURE[i + 1]);
        }
        File many = new File(staged, "many");
        for (int i = 1; i <= 1000; i++) {
            writeFile(new File(many, String.format(Locale.ROOT, "%04d.txt", i)), i + "\n");
        }
        shell("rm -rf " + DOCUMENTS + "/" + FOLDER);
        shell("mkdir -p " + DOCUMENTS);
        shell("cp -r " + staged.getAbsolutePath() + " " + DOCUMENTS + "/");
        deleteTree(staged);
        String listed = shell("ls " + DOCUMENTS + "/" + FOLDER + "/many").trim();
        int entries = listed.isEmpty() ? 0 : listed.split("\\s+").length;
        return "done:" + entries;
    }

    private String put(String path, String word) throws IOException {
        File staged = new File(staging(), "gate-put.txt");
        writeFile(staged, word + "\n");
        shell("cp " + staged.getAbsolutePath() + " " + DOCUMENTS + "/" + FOLDER + "/" + path);
        staged.delete();
        return "done";
    }

    // ------------------------------------------------------------ the picker

    private String pick() {
        UiAutomation ui = instrumentation.getUiAutomation();
        long deadline = SystemClock.uptimeMillis() + 120_000L;
        boolean chosen = false;
        while (SystemClock.uptimeMillis() < deadline) {
            AccessibilityNodeInfo root = ui.getRootInActiveWindow();
            CharSequence owner = root == null ? null : root.getPackageName();
            if (owner != null && owner.toString().contains("documentsui")) {
                if (!chosen) {
                    boolean inside = exact(root, "hello.txt") != null || exact(root, "notes") != null;
                    AccessibilityNodeInfo use = exact(root, "Use this folder");
                    if (inside && use != null && click(use)) {
                        chosen = true;
                        Log.i(TAG, "pick: Use this folder");
                    } else if (!inside) {
                        AccessibilityNodeInfo step = exact(root, FOLDER);
                        if (step == null) step = exact(root, "Documents");
                        if (step != null && click(step)) Log.i(TAG, "pick: walked into " + step.getText());
                    }
                } else {
                    List<AccessibilityNodeInfo> buttons = root.findAccessibilityNodeInfosByViewId("android:id/button1");
                    AccessibilityNodeInfo allow = buttons.isEmpty() ? exact(root, "Allow") : buttons.get(0);
                    if (allow != null && click(allow)) {
                        Log.i(TAG, "pick: Allow");
                        return "picked";
                    }
                }
            }
            SystemClock.sleep(chosen ? 500 : 1000);
        }
        return chosen ? "failed:no-allow" : "failed:no-use-this-folder";
    }

    /** The node whose text or description is [text], ignoring case. */
    private static AccessibilityNodeInfo exact(AccessibilityNodeInfo root, String text) {
        for (AccessibilityNodeInfo node : root.findAccessibilityNodeInfosByText(text)) {
            CharSequence shown = node.getText() != null ? node.getText() : node.getContentDescription();
            if (shown != null && shown.toString().trim().equalsIgnoreCase(text)) return node;
        }
        return null;
    }

    /** Clicks [node], or the nearest ancestor that takes clicks. */
    private static boolean click(AccessibilityNodeInfo node) {
        AccessibilityNodeInfo target = node;
        while (target != null && !target.isClickable()) target = target.getParent();
        return target != null && target.isEnabled() && target.performAction(AccessibilityNodeInfo.ACTION_CLICK);
    }

    // ------------------------------------------------------------ helpers

    /** Runs [command] as the shell user and answers what it printed. */
    private String shell(String command) {
        ParcelFileDescriptor descriptor = instrumentation.getUiAutomation().executeShellCommand(command);
        try (InputStream in = new ParcelFileDescriptor.AutoCloseInputStream(descriptor)) {
            return new String(readAll(in), StandardCharsets.UTF_8);
        } catch (IOException error) {
            Log.w(TAG, "shell: " + command, error);
            return "";
        }
    }

    private static String read(File file) {
        try (InputStream in = new FileInputStream(file)) {
            return new String(readAll(in), StandardCharsets.UTF_8);
        } catch (IOException gone) {
            return "";
        }
    }

    private static byte[] readAll(InputStream in) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buffer = new byte[8192];
        int n;
        while ((n = in.read(buffer)) > 0) out.write(buffer, 0, n);
        return out.toByteArray();
    }

    /** [text] into [folder]/[id], whole: written beside it, then renamed. */
    private static void write(File folder, String id, String text) {
        File partial = new File(folder, id + ".partial");
        try {
            writeFile(partial, text);
            if (!partial.renameTo(new File(folder, id))) Log.w(TAG, "could not answer " + id);
        } catch (IOException error) {
            Log.w(TAG, "could not answer " + id, error);
        }
    }

    private static void writeFile(File file, String text) throws IOException {
        File parent = file.getParentFile();
        if (parent != null && !parent.isDirectory() && !parent.mkdirs()) throw new IOException("mkdirs " + parent);
        try (FileOutputStream out = new FileOutputStream(file)) {
            out.write(text.getBytes(StandardCharsets.UTF_8));
        }
    }

    private static void deleteTree(File file) {
        File[] children = file.listFiles();
        if (children != null) for (File child : children) deleteTree(child);
        file.delete();
    }
}
