#!/usr/bin/env python3
"""What an APK carries of the sealed runtime (Phase 4 W3, gate G3).

CodeForge's own. A build that targets one ABI carries that ABI's payload
(app/android/build.gradle.kts); this checks the APK holds it whole, the way
native/runtime-core/build.gradle.kts puts it there:

  * the payload's assets: userland-<abi>.zip, its manifest, the exec and
    symlink lists, its identity, and runtime-info-<abi>.json, with the zip
    stored as it is (it is compressed already);
  * every library the exec manifest names, as lib/<abi>/<library>, and the
    preload (libharness-exec.so) and the exec probe (libharnessprobe.so);
  * native libraries for that ABI only: no APK carries two;
  * native libraries compressed in the APK (legacy packaging), which is what
    makes Android extract them into nativeLibraryDir as real files.

With --no-payload it checks the opposite: a build that carries no runtime
holds none of the payload's assets.

Usage:
  check_runtime_apk.py <apk> --abi x86_64     the payload of that ABI
  check_runtime_apk.py <apk> --no-payload     no payload at all
  check_runtime_apk.py --self-test            the check passing a good APK
                                              and failing bad ones

Prints key=value lines (runtime_apk_*), and exits 1 on any finding.
"""

import io
import os
import sys
import zipfile

ABIS = ("arm64-v8a", "x86_64")
OURS = ("libharness-exec.so", "libharnessprobe.so")


def payload_assets(abi):
    return [
        "assets/userland-%s.zip" % abi,
        "assets/sealed-manifest-%s.txt" % abi,
        "assets/sealed-exec-%s.txt" % abi,
        "assets/sealed-symlinks-%s.txt" % abi,
        "assets/sealed-payload-id-%s.txt" % abi,
        "assets/runtime-info-%s.json" % abi,
    ]


def exec_libraries(text):
    libraries = set()
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        pieces = line.split("\t")
        if len(pieces) == 2:
            libraries.add(pieces[1].strip())
    return libraries


def check(apk, abi=None):
    """(findings, facts) for the APK at `apk` (a path or a file object)."""
    findings = []
    facts = []
    with zipfile.ZipFile(apk) as archive:
        infos = {info.filename: info for info in archive.infolist()}
        names = set(infos)
        native = sorted(name for name in names
                        if name.startswith("lib/") and name.endswith(".so"))
        native_abis = sorted({name.split("/")[1] for name in native})
        facts.append("runtime_apk_native_abis=%s" % (",".join(native_abis) or "none"))
        facts.append("runtime_apk_native_libraries=%d" % len(native))
        stored = [name for name in native if infos[name].compress_type == zipfile.ZIP_STORED]
        facts.append("runtime_apk_native_stored=%d" % len(stored))
        if stored:
            findings.append("%d native libraries are stored, not compressed: the build "
                            "does not package them the legacy way (first: %s)"
                            % (len(stored), stored[0]))
        if abi is None:
            carried = [name for name in names
                       if any(name in payload_assets(each) for each in ABIS)]
            facts.append("runtime_apk_payload=none")
            if carried:
                findings.append("a build without a runtime carries %s" % ", ".join(sorted(carried)))
            return findings, facts

        for name in payload_assets(abi):
            if name not in names:
                findings.append("missing %s" % name)
        userland = "assets/userland-%s.zip" % abi
        if userland in infos:
            info = infos[userland]
            facts.append("runtime_apk_userland_bytes=%d" % info.file_size)
            if info.compress_type != zipfile.ZIP_STORED:
                findings.append("%s is compressed again in the APK" % userland)
        for other in ABIS:
            if other != abi and any(name.startswith("lib/%s/" % other) for name in native):
                findings.append("native libraries for %s too: an APK carries one ABI" % other)
            if other != abi:
                for name in payload_assets(other):
                    if name in names:
                        findings.append("the %s payload too: %s" % (other, name))
        for library in OURS:
            if "lib/%s/%s" % (abi, library) not in names:
                findings.append("missing lib/%s/%s" % (abi, library))
        exec_list = "assets/sealed-exec-%s.txt" % abi
        if exec_list in names:
            wanted = exec_libraries(archive.read(exec_list).decode("utf-8"))
            missing = sorted(library for library in wanted
                             if "lib/%s/%s" % (abi, library) not in names)
            facts.append("runtime_apk_executables=%d" % len(wanted))
            if missing:
                findings.append("%d executables the exec manifest names are not in the APK "
                                "(first: %s)" % (len(missing), missing[0]))
        library_bytes = sum(infos[name].file_size for name in native
                            if name.startswith("lib/%s/" % abi))
        library_compressed = sum(infos[name].compress_size for name in native
                                 if name.startswith("lib/%s/" % abi))
        facts.append("runtime_apk_library_bytes=%d" % library_bytes)
        facts.append("runtime_apk_library_compressed_bytes=%d" % library_compressed)
    return findings, facts


def _apk(abi=None, *, stored_libs=False, extra_abi=False, drop=None, compress_zip=False):
    """A synthetic APK for the self-test."""
    data = io.BytesIO()
    lib_type = zipfile.ZIP_STORED if stored_libs else zipfile.ZIP_DEFLATED
    with zipfile.ZipFile(data, "w") as archive:
        archive.writestr("AndroidManifest.xml", b"<manifest/>")
        abis = [abi or "x86_64"] + (["arm64-v8a"] if extra_abi else [])
        for each in abis:
            for library in ("libflutter.so", "libapp.so") + OURS + ("libgit.so",):
                archive.writestr("lib/%s/%s" % (each, library), b"\x7fELF" + library.encode(),
                                 compress_type=lib_type)
        if abi:
            for name in payload_assets(abi):
                if name == drop:
                    continue
                if name.endswith(".zip"):
                    archive.writestr(name, b"PK userland",
                                     compress_type=zipfile.ZIP_DEFLATED if compress_zip
                                     else zipfile.ZIP_STORED)
                elif "sealed-exec" in name:
                    archive.writestr(name, b"# header\nbin/git\tlibgit.so\n")
                else:
                    archive.writestr(name, b"{}")
    data.seek(0)
    return data


def self_test():
    ok = True
    cases = [
        ("a payload APK", lambda: check(_apk("x86_64"), "x86_64"), False),
        ("a build without a runtime", lambda: check(_apk(None)), False),
        ("stored native libraries", lambda: check(_apk("x86_64", stored_libs=True), "x86_64"), True),
        ("two ABIs", lambda: check(_apk("x86_64", extra_abi=True), "x86_64"), True),
        ("no exec manifest", lambda: check(_apk("x86_64", drop="assets/sealed-exec-x86_64.txt"),
                                           "x86_64"), True),
        ("the zip compressed again", lambda: check(_apk("x86_64", compress_zip=True), "x86_64"), True),
        ("a payload where none belongs", lambda: check(_apk("x86_64")), True),
        ("the wrong ABI's payload", lambda: check(_apk("x86_64"), "arm64-v8a"), True),
    ]
    for name, run, should_find in cases:
        findings, _ = run()
        caught = bool(findings)
        good = caught == should_find
        ok &= good
        print("self-test: %s -> %s" % (name, ("caught: " + findings[0]) if caught
                                        else ("pass" if good else "MISSED")))
    return ok


def main(argv):
    if argv[1:2] == ["--self-test"]:
        return 0 if self_test() else 1
    if len(argv) == 4 and argv[2] == "--abi" and argv[3] in ABIS:
        apk, abi = argv[1], argv[3]
    elif len(argv) == 3 and argv[2] == "--no-payload":
        apk, abi = argv[1], None
    else:
        print(__doc__)
        return 2
    if not os.path.isfile(apk):
        print("no APK at %s" % apk)
        return 1
    findings, facts = check(apk, abi)
    print("runtime_apk=%s abi=%s bytes=%d" % (apk, abi or "none", os.path.getsize(apk)))
    for fact in facts:
        print(fact)
    for finding in findings:
        print("FINDING: %s" % finding)
    print("runtime_apk_check=%s findings=%d" % ("pass" if not findings else "fail", len(findings)))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
