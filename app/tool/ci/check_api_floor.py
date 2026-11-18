#!/usr/bin/env python3
"""Checks that CodeForge's code in an APK keeps to its minSdk (Phase 4 W5).

Every method, field and class that CodeForge's own and vendored code refers to
(the classes under dev.codeforge.) in the APK's dex is looked up in the SDK's
API database, platforms/android-<n>/data/api-versions.xml, which records the
API level that brought each one. A reference that is newer than minSdk (26)
throws NoSuchMethodError, NoSuchFieldError or NoClassDefFoundError on older
Android, and nothing at build time says so: CodeForge compiles against API 36.
W5 found one such call through review, in vendored code: t1's
RuntimeManifest.read(InputStream) reads with InputStream.readAllBytes(), which
Android has only from API 33 (D8 does not backport it), and it made every
runtime install fail on Android 8.0 to 12L.

A newer reference passes only when ALLOWED names it, as one of two kinds:
  guarded  the method calls it behind a Build.VERSION.SDK_INT check;
  dead     vendored code the app never calls (vendored files are never
           edited, AGENTS.md §4). "Never called" is checked: a method that
           refers to something newer is tainted, and so is every method of
           ours that calls a tainted one, so a new call into dead code
           fails here.
An ALLOWED entry that matches nothing fails too: either it is stale, or
this script stopped reading the dex.

The dex is read with the SDK's dexdump (build-tools), disassembled (-d):
method headers ("|[0001a4] pkg.Class.method:(args)ret") and instructions
("invoke-virtual {v1}, Ljava/io/InputStream;.readAllBytes:()[B // method@0f").
Members are resolved as the runtime resolves them: on the referenced class,
then its superclasses and interfaces. A member the database does not list
(an Android hidden one, or a library's) is counted, never judged.

Usage:
  check_api_floor.py --apk APK [--out FILE] [--min-sdk N]
                     [--dexdump PATH] [--api-versions PATH]
  check_api_floor.py --self-test

Exit codes: 0 every reference keeps to minSdk; 1 a violation, a stale
ALLOWED entry, or too little read to judge; 2 usage or a missing tool.
"""

import glob
import os
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

MIN_SDK = 26        # app/android/app/build.gradle.kts (ADR-0007)
OURS = ("dev.codeforge.",)

# (kind, method prefix, reference prefix or None, why). A method prefix is
# matched against "pkg.Class.method:(args)ret", so "pkg.Class.method:" names
# every overload; a reference prefix against "Lpkg/Class;.member:type".
ALLOWED = [
    ("dead", "dev.codeforge.runtime.sealed.RuntimeManifest.read:(Ljava/io/InputStream;)", None,
     "t1's kernel (vendored): reads with InputStream.readAllBytes (API 33). The host parses "
     "the manifest itself (app/android/app/src/main/kotlin/dev/codeforge/app/runtime/"
     "PayloadInstall.kt)."),
    ("dead", "dev.codeforge.runtime.sealed.SealedInstaller.install:", None,
     "t1's kernel (vendored): its entry point reads the manifest through "
     "RuntimeManifest.read(InputStream). PayloadInstall makes its calls instead."),
    ("dead", "dev.codeforge.runtime.core.exec.SealedPayloadInstaller.install:", None,
     "t1's adapter (vendored): installs through SealedInstaller.install. The runtime host "
     "installs through PayloadInstall (native/PROVENANCE.md)."),
    ("guarded", "dev.codeforge.app.CodeForgeBackupAgent.onFullBackup:",
     "Landroid/app/backup/FullBackupDataOutput;.getTransportFlags:",
     "read only when Build.VERSION.SDK_INT >= P (28)."),
]

HEADER = re.compile(r"\|\[[0-9a-f]+\] (\S+)\s*$")
INVOKE = re.compile(
    r"\|[0-9a-f]+: invoke-[a-z-]+(?:/range)? \{[^}]*\}, "
    r"(\[*L[^;\s]+;|\[+[ZBSCIJFD])\.([^:\s]+):(\([^)]*\)[^\s,]+)(?:, \S+)? // method@")
FIELD = re.compile(
    r"\|[0-9a-f]+: [is](?:get|put)[a-z-]* v\d+, (?:v\d+, )?"
    r"(L[^;\s]+;)\.([^:\s]+):(\S+) // field@")
TYPE = re.compile(
    r"\|[0-9a-f]+: (?:new-instance|const-class|check-cast|instance-of|new-array|"
    r"filled-new-array(?:/range)?) .*, (\[*L[^;\s]+;) // type@")


def level(text, default):
    match = re.match(r"\s*(\d+)", text or "")
    return int(match.group(1)) if match else default


class Api:
    """The API database: each class's level, supertypes, methods and fields."""

    def __init__(self):
        self.classes = {}

    @classmethod
    def load(cls, path):
        api = cls()
        current = None
        for event, element in ET.iterparse(path, events=("start", "end")):
            if event == "start" and element.tag == "class":
                since = level(element.get("since"), 1)
                current = {"since": since, "supers": [], "methods": {}, "fields": {}}
                api.classes[element.get("name")] = current
            elif event == "start" and current is not None:
                name = element.get("name")
                if element.tag in ("extends", "implements"):
                    current["supers"].append(name)
                elif element.tag == "method":
                    current["methods"][name] = level(element.get("since"), current["since"])
                elif element.tag == "field":
                    current["fields"][name] = level(element.get("since"), current["since"])
            elif event == "end" and element.tag == "class":
                current = None
                element.clear()
        return api

    def knows(self, name):
        return name in self.classes

    def class_level(self, name):
        return self.classes[name]["since"]

    def member_level(self, name, member, kind):
        """The level of the member the runtime would resolve, or None."""
        seen, queue = set(), [name]
        while queue:
            current = queue.pop(0)
            if current in seen or current not in self.classes:
                continue
            seen.add(current)
            entry = self.classes[current]
            if member in entry[kind]:
                return entry[kind][member]
            queue.extend(entry["supers"])
        return None


def internal(descriptor):
    """"Ljava/io/File;" -> "java/io/File"; arrays -> their element; primitives -> None."""
    stripped = descriptor.lstrip("[")
    if stripped.startswith("L") and stripped.endswith(";"):
        return stripped[1:-1]
    return None


def analyze(lines, api, min_sdk=MIN_SDK, allowed=ALLOWED, ours=OURS):
    """Reads dexdump -d output; returns the findings as a dict."""
    methods = {}
    current = None
    stats = {"methods": 0, "references": 0, "framework": 0, "unknown": 0}
    for line in lines:
        if "|[" in line:
            header = HEADER.search(line)
            if header:
                name = header.group(1)
                if name.startswith(ours) and ":" in name:
                    current = methods.setdefault(name, {"newer": [], "calls": set()})
                    stats["methods"] += 1
                else:
                    current = None
                continue
        if current is None or "@" not in line:
            continue
        found = None
        if "// method@" in line:
            invoke = INVOKE.search(line)
            if invoke:
                owner, member, descriptor = invoke.groups()
                found = (owner, member + descriptor, "methods",
                         "%s.%s:%s" % (owner, member, descriptor))
        elif "// field@" in line:
            field = FIELD.search(line)
            if field:
                owner, member, kind = field.groups()
                found = (owner, member, "fields", "%s.%s:%s" % (owner, member, kind))
        elif "// type@" in line:
            typed = TYPE.search(line)
            if typed:
                found = (typed.group(1), None, None, typed.group(1))
        if found is None:
            continue
        owner, member, kind, text = found
        stats["references"] += 1
        name = internal(owner)
        if name is None:
            continue
        dotted = name.replace("/", ".")
        if dotted.startswith(ours):
            if kind == "methods":
                current["calls"].add("%s.%s" % (dotted, member.replace("(", ":(", 1)))
            continue
        if not api.knows(name):
            continue
        stats["framework"] += 1
        since = api.class_level(name)
        if member is not None and since <= min_sdk:
            member_since = api.member_level(name, member, kind)
            if member_since is None:
                stats["unknown"] += 1
                continue
            since = member_since
        if since > min_sdk:
            current["newer"].append((text, since))

    used = [0] * len(allowed)
    guarded = []
    for method, info in methods.items():
        kept = []
        for text, since in info["newer"]:
            rule = None
            for index, (kind, prefix, reference, _) in enumerate(allowed):
                if kind == "guarded" and method.startswith(prefix) and text.startswith(reference):
                    rule = index
                    break
            if rule is None:
                kept.append((text, since))
            else:
                used[rule] += 1
                guarded.append((method, text, since, allowed[rule][3]))
        info["newer"] = kept

    tainted = {method: "refers to %s (API %d)" % info["newer"][0]
               for method, info in methods.items() if info["newer"]}
    changed = True
    while changed:
        changed = False
        for method, info in methods.items():
            if method in tainted:
                continue
            for callee in sorted(info["calls"]):
                if callee in tainted:
                    tainted[method] = "calls %s" % callee
                    changed = True
                    break

    dead, violations = [], []
    for method in sorted(tainted):
        rule = None
        for index, (kind, prefix, _, _) in enumerate(allowed):
            if kind == "dead" and method.startswith(prefix):
                rule = index
                break
        if rule is None:
            violations.append((method, tainted[method], methods[method]["newer"]))
        else:
            used[rule] += 1
            dead.append((method, tainted[method], allowed[rule][3]))
    stale = [allowed[index] for index, count in enumerate(used) if count == 0]
    return {"stats": stats, "guarded": guarded, "dead": dead,
            "violations": violations, "stale": stale}


def report(findings, min_sdk, source, enough=(100, 500)):
    stats = findings["stats"]
    too_little = stats["methods"] < enough[0] or stats["framework"] < enough[1]
    ok = not findings["violations"] and not findings["stale"] and not too_little
    lines = [
        "api_floor=%s min_sdk=%d %s" % ("pass" if ok else "fail", min_sdk, source),
        "methods=%d references=%d framework=%d unlisted=%d violations=%d guarded=%d dead=%d stale=%d"
        % (stats["methods"], stats["references"], stats["framework"], stats["unknown"],
           len(findings["violations"]), len(findings["guarded"]), len(findings["dead"]),
           len(findings["stale"])),
    ]
    if too_little:
        lines.append("too little read to judge: at least %d methods and %d framework references "
                     "expected (is dexdump's output what this script reads?)" % enough)
    for method, reason, newer in findings["violations"]:
        lines.append("VIOLATION %s %s" % (method, reason))
        for text, since in newer[1:]:
            lines.append("    also %s (API %d)" % (text, since))
    for entry in findings["stale"]:
        lines.append("STALE %s %s%s: matched nothing" % (
            entry[0], entry[1], (" " + entry[2]) if entry[2] else ""))
    for method, text, since, why in findings["guarded"]:
        lines.append("guarded %s -> %s (API %d): %s" % (method, text, since, why))
    for method, reason, why in findings["dead"]:
        lines.append("dead %s %s: %s" % (method, reason, why))
    return ok, lines


def newest(paths, pattern):
    def key(path):
        match = re.search(pattern, path)
        return tuple(int(part) for part in re.findall(r"\d+", match.group(1))) if match else ()
    return sorted(paths, key=key)[-1] if paths else None


def find_tools(dexdump, api_versions):
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT") or ""
    if not dexdump and sdk:
        dexdump = newest(glob.glob(os.path.join(sdk, "build-tools", "*", "dexdump")),
                         r"build-tools/([^/]+)/")
    if not api_versions and sdk:
        api_versions = newest(
            glob.glob(os.path.join(sdk, "platforms", "android-*", "data", "api-versions.xml")),
            r"android-([^/]+)/")
    return dexdump, api_versions


def run(apk, out, min_sdk, dexdump, api_versions):
    dexdump, api_versions = find_tools(dexdump, api_versions)
    if not dexdump or not os.path.exists(dexdump):
        print("no dexdump (ANDROID_HOME/build-tools/*/dexdump); pass --dexdump", file=sys.stderr)
        return 2
    if not api_versions or not os.path.exists(api_versions):
        print("no api-versions.xml (ANDROID_HOME/platforms/android-*/data); pass --api-versions",
              file=sys.stderr)
        return 2
    api = Api.load(api_versions)
    with tempfile.TemporaryDirectory() as work:
        with zipfile.ZipFile(apk) as archive:
            dexes = sorted(name for name in archive.namelist()
                           if re.match(r"^classes\d*\.dex$", name))
            for name in dexes:
                archive.extract(name, work)

        def lines():
            for name in dexes:
                process = subprocess.Popen([dexdump, "-d", os.path.join(work, name)],
                                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                           text=True, errors="replace")
                for line in process.stdout:
                    yield line
                process.wait()

        findings = analyze(lines(), api, min_sdk)
    source = "apk=%s dex=%d api=%s dexdump=%s" % (
        os.path.basename(apk), len(dexes),
        os.path.relpath(api_versions, os.path.dirname(os.path.dirname(os.path.dirname(api_versions)))),
        os.path.basename(os.path.dirname(dexdump)))
    ok, text = report(findings, min_sdk, source)
    output = "\n".join(text) + "\n"
    sys.stdout.write(output)
    if out:
        os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
        with open(out, "w", encoding="utf-8") as handle:
            handle.write(output)
    return 0 if ok else 1


SAMPLE_API = """<?xml version="1.0" encoding="utf-8"?>
<api version="3">
  <class name="java/lang/Object" since="1">
    <method name="&lt;init>()V"/>
    <method name="hashCode()I"/>
  </class>
  <class name="java/io/InputStream" since="1">
    <extends name="java/lang/Object"/>
    <method name="read()I"/>
    <method name="readAllBytes()[B" since="33"/>
  </class>
  <class name="java/io/ByteArrayInputStream" since="1">
    <extends name="java/io/InputStream"/>
  </class>
  <class name="java/io/File" since="1">
    <extends name="java/lang/Object"/>
    <method name="&lt;init>(Ljava/lang/String;)V"/>
    <method name="toPath()Ljava/nio/file/Path;" since="26"/>
  </class>
  <class name="android/os/Build$VERSION" since="1">
    <field name="SDK_INT" since="4"/>
  </class>
  <class name="android/app/backup/FullBackupDataOutput" since="14">
    <method name="getTransportFlags()I" since="28"/>
  </class>
  <class name="android/app/Brand" since="31">
    <method name="&lt;init>()V"/>
  </class>
</api>
"""

SAMPLE_DUMP = """Processing 'classes.dex'...
Opened 'classes.dex', DEX version '035'
Class #0            -
  Class descriptor  : 'Ldev/codeforge/runtime/sealed/RuntimeManifest;'
00a1c8:                                        |[00a1c8] dev.codeforge.runtime.sealed.RuntimeManifest.read:(Ljava/io/InputStream;)Ldev/codeforge/runtime/sealed/RuntimeManifest;
00a1d8: 6e10 0e05 0200                         |0000: invoke-virtual {v2}, Ljava/io/InputStream;.readAllBytes:()[B // method@050e
00a1de: 0c00                                   |0003: move-result-object v0
00a1e0:                                        |[00a1e0] dev.codeforge.runtime.sealed.RuntimeManifest.read:(Ljava/io/File;)Ldev/codeforge/runtime/sealed/RuntimeManifest;
00a1f0: 6e10 1005 0200                         |0000: invoke-virtual {v2}, Ljava/io/File;.toPath:()Ljava/nio/file/Path; // method@0510
00a2c8:                                        |[00a2c8] dev.codeforge.runtime.sealed.SealedInstaller.install:(Ldev/codeforge/runtime/sealed/SealedInstaller$Request;)Ldev/codeforge/runtime/sealed/SealedInstaller$Result;
00a2d8: 7110 0f05 0300                         |0000: invoke-static {v3}, Ldev/codeforge/runtime/sealed/RuntimeManifest;.read:(Ljava/io/InputStream;)Ldev/codeforge/runtime/sealed/RuntimeManifest; // method@050f
00a3c8:                                        |[00a3c8] dev.codeforge.runtime.core.exec.SealedPayloadInstaller.install:(Landroid/content/Context;Ldev/codeforge/runtime/core/HarnessConfig;)Ldev/codeforge/runtime/core/exec/SealedPayloadInstaller$Result;
00a3d8: 7130 1105 3204                         |0000: invoke-static {v2, v3, v4}, Ldev/codeforge/runtime/sealed/SealedInstaller;.install:(Ldev/codeforge/runtime/sealed/SealedInstaller$Request;)Ldev/codeforge/runtime/sealed/SealedInstaller$Result; // method@0511
00a4c8:                                        |[00a4c8] dev.codeforge.app.CodeForgeBackupAgent.onFullBackup:(Landroid/app/backup/FullBackupDataOutput;)V
00a4d8: 6000 0100                              |0000: sget v0, Landroid/os/Build$VERSION;.SDK_INT:I // field@0001
00a4dc: 6e10 1205 0300                         |0002: invoke-virtual {v3}, Landroid/app/backup/FullBackupDataOutput;.getTransportFlags:()I // method@0512
00a5c8:                                        |[00a5c8] dev.codeforge.app.Fine.ok:(Ljava/lang/String;)V
00a5d8: 2200 4200                              |0000: new-instance v0, Ljava/io/File; // type@0042
00a5dc: 7020 1305 1000                         |0002: invoke-direct {v0, v1}, Ljava/io/File;.<init>:(Ljava/lang/String;)V // method@0513
00a5e2: 6e10 1405 0000                         |0005: invoke-virtual {v0}, Ljava/io/ByteArrayInputStream;.read:()I // method@0514
00a5e8: 6e10 1505 0000                         |0008: invoke-virtual {v0}, Landroid/hidden/Thing;.secret:()V // method@0515
00a5ee: 6e10 1705 0000                         |000b: invoke-virtual {v0}, Ljava/io/File;.hiddenLength:()J // method@0517
00a6c8:                                        |[00a6c8] androidx.core.Foo.bar:()V
00a6d8: 6e10 0e05 0000                         |0000: invoke-virtual {v0}, Ljava/io/InputStream;.readAllBytes:()[B // method@050e
"""


def self_test():
    with tempfile.TemporaryDirectory() as work:
        path = os.path.join(work, "api-versions.xml")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(SAMPLE_API)
        api = Api.load(path)
    base = SAMPLE_DUMP.splitlines()

    def extra(*lines):
        return base + list(lines)

    new_caller = [
        "00b1c8:                                        |[00b1c8] dev.codeforge.app.runtime.SealedRuntime.install:()V",
        "00b1d8: 7110 1105 0300                         |0000: invoke-static {v3}, Ldev/codeforge/runtime/sealed/SealedInstaller;.install:(Ldev/codeforge/runtime/sealed/SealedInstaller$Request;)Ldev/codeforge/runtime/sealed/SealedInstaller$Result; // method@0511",
    ]
    direct = [
        "00c1c8:                                        |[00c1c8] dev.codeforge.app.Reader.all:(Ljava/io/ByteArrayInputStream;)[B",
        "00c1d8: 6e10 1605 0200                         |0000: invoke-virtual/range {v2 .. v2}, Ljava/io/ByteArrayInputStream;.readAllBytes:()[B // method@0516",
    ]
    new_class = [
        "00d1c8:                                        |[00d1c8] dev.codeforge.app.Theme.brand:()V",
        "00d1d8: 2200 4300                              |0000: new-instance v0, Landroid/app/Brand; // type@0043",
    ]
    stale = ALLOWED + [("guarded", "dev.codeforge.app.Gone.method:", "Ljava/io/File;.toPath:", "x")]
    cases = [
        ("the vendored dead chain and a guarded call pass", base, ALLOWED,
         {"violations": 0, "dead": 3, "guarded": 1, "stale": 0}),
        ("a new call into the dead chain fails", extra(*new_caller), ALLOWED,
         {"violations": 1, "dead": 3, "guarded": 1, "stale": 0}),
        ("an inherited API 33 method in our code fails", extra(*direct), ALLOWED,
         {"violations": 1, "dead": 3, "guarded": 1, "stale": 0}),
        ("a class from API 31 fails", extra(*new_class), ALLOWED,
         {"violations": 1, "dead": 3, "guarded": 1, "stale": 0}),
        ("an entry that matches nothing is stale", base, stale,
         {"violations": 0, "dead": 3, "guarded": 1, "stale": 1}),
        ("without the allowlist, all four are violations", base, [],
         {"violations": 4, "dead": 0, "guarded": 0, "stale": 0}),
    ]
    failed = 0
    for name, lines, allowed, expected in cases:
        findings = analyze(lines, api, MIN_SDK, allowed)
        got = {key: len(findings[key]) for key in expected}
        status = "ok" if got == expected else "FAILED"
        failed += got != expected
        print("self-test %-6s %s: %s" % (status, name, got))
    findings = analyze(base, api, MIN_SDK, ALLOWED)
    counts = (findings["stats"]["methods"], findings["stats"]["unknown"])
    status = "ok" if counts == (6, 1) else "FAILED"
    failed += counts != (6, 1)
    print("self-test %-6s six methods of ours read, androidx skipped, one unlisted member: %s"
          % (status, counts))
    ok, _ = report(findings, MIN_SDK, "sample", enough=(1, 1))
    status = "ok" if ok else "FAILED"
    failed += not ok
    print("self-test %-6s the sample's report passes" % status)
    ok, _ = report(findings, MIN_SDK, "sample")
    status = "ok" if not ok else "FAILED"
    failed += ok
    print("self-test %-6s too little read fails the real check" % status)
    print("self-test: %s" % ("all cases pass" if not failed else "%d case(s) failed" % failed))
    return 1 if failed else 0


def main(argv):
    if argv[1:] == ["--self-test"]:
        return self_test()
    args = {"--apk": None, "--out": None, "--min-sdk": str(MIN_SDK), "--dexdump": None,
            "--api-versions": None}
    rest = argv[1:]
    while rest:
        flag = rest.pop(0)
        if flag not in args or not rest:
            print(__doc__, file=sys.stderr)
            return 2
        args[flag] = rest.pop(0)
    if not args["--apk"]:
        print(__doc__, file=sys.stderr)
        return 2
    return run(args["--apk"], args["--out"], int(args["--min-sdk"]), args["--dexdump"],
               args["--api-versions"])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
