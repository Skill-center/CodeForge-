#!/usr/bin/env python3
"""The merged manifest's storage and backup check (Phase 3 W6, gate G8).

Fails if the app's merged AndroidManifest.xml (the app's own, every
library's, and the build type's, as AGP merged them for the APK):

  * declares a storage permission (Phase 3 reaches files through Android's
    picker and the storage access framework only, docs/SECURITY.md §4), or
    asks for legacy external storage;
  * has backup attributes on <application> other than ADR-0012's: Auto
    Backup kept on (allowBackup), decided per user by CodeForgeBackupAgent
    (backupAgent, fullBackupOnly), with the rules files of Android 11 and
    lower (fullBackupContent) and of Android 12 and later
    (dataExtractionRules).

Usage:
  check_manifest.py <build dir> [variant]   finds the merged manifest of
                                            <variant> (default debug) under
                                            <build dir>/intermediates
  check_manifest.py --file <manifest>       checks that file
  check_manifest.py --self-test             shows the check passing a good
                                            manifest and failing bad ones

Prints what it checked, and exits 1 on any finding.
"""

import glob
import os
import sys
import xml.etree.ElementTree as ET

ANDROID = '{http://schemas.android.com/apk/res/android}'

# Storage permissions, by name. READ_MEDIA_* and the like reach shared
# storage as surely as the old external-storage permissions do.
STORAGE_PERMISSIONS = {
    'android.permission.READ_EXTERNAL_STORAGE',
    'android.permission.WRITE_EXTERNAL_STORAGE',
    'android.permission.MANAGE_EXTERNAL_STORAGE',
    'android.permission.READ_MEDIA_IMAGES',
    'android.permission.READ_MEDIA_VIDEO',
    'android.permission.READ_MEDIA_AUDIO',
    'android.permission.READ_MEDIA_VISUAL_USER_SELECTED',
    'android.permission.ACCESS_MEDIA_LOCATION',
    'android.permission.MANAGE_MEDIA',
    'android.permission.MANAGE_DOCUMENTS',
}
STORAGE_MARKERS = ('EXTERNAL_STORAGE', 'READ_MEDIA_', 'MANAGE_MEDIA', 'MANAGE_DOCUMENTS')

PERMISSION_TAGS = ('uses-permission', 'uses-permission-sdk-23', 'uses-permission-sdk-m')

# ADR-0012, as AGP writes it into the merged manifest (a relative class name
# becomes the full one).
APP_ID = 'dev.codeforge.app'
EXPECTED_BACKUP = {
    'allowBackup': 'true',
    'backupAgent': f'{APP_ID}.CodeForgeBackupAgent',
    'fullBackupOnly': 'true',
    'fullBackupContent': '@xml/backup_rules',
    'dataExtractionRules': '@xml/data_extraction_rules',
}
# Every <application> attribute that has a say in backup and restore.
BACKUP_ATTRIBUTES = set(EXPECTED_BACKUP) | {
    'backupInForeground',
    'restoreAnyVersion',
    'killAfterRestore',
    'restoreNeedsApplication',
}


def is_storage_permission(name):
    return name in STORAGE_PERMISSIONS or any(m in name for m in STORAGE_MARKERS)


def check(xml_text):
    """The findings for one manifest's text, and what was checked."""
    findings = []
    checked = []
    root = ET.fromstring(xml_text)
    if root.get('package') not in (None, APP_ID):
        findings.append(f'package is {root.get("package")}, not {APP_ID}')
    permissions = []
    for tag in PERMISSION_TAGS:
        for element in root.iter(tag):
            permissions.append(element.get(ANDROID + 'name') or '')
    checked.append(f'permissions: {", ".join(sorted(permissions)) or "none"}')
    for name in sorted(permissions):
        if is_storage_permission(name):
            findings.append(f'storage permission declared: {name}')
    application = root.find('application')
    if application is None:
        findings.append('no <application> element')
        return findings, checked
    legacy = application.get(ANDROID + 'requestLegacyExternalStorage')
    if legacy not in (None, 'false'):
        findings.append(f'requestLegacyExternalStorage="{legacy}"')
    found = {
        name: application.get(ANDROID + name)
        for name in sorted(BACKUP_ATTRIBUTES)
        if application.get(ANDROID + name) is not None
    }
    # A class name relative to the package, if the merger left it so.
    if (found.get('backupAgent') or '').startswith('.'):
        found['backupAgent'] = APP_ID + found['backupAgent']
    checked.append('backup: ' + ', '.join(f'{k}={v}' for k, v in found.items()))
    for name, value in EXPECTED_BACKUP.items():
        if found.get(name) != value:
            findings.append(f'{name} is {found.get(name)!r}, ADR-0012 says {value!r}')
    for name in sorted(set(found) - set(EXPECTED_BACKUP)):
        findings.append(f'{name}="{found[name]}" is not in ADR-0012')
    return findings, checked


def merged_manifest(build_dir, variant):
    """The merged manifest AGP wrote for `variant`, wherever its version puts it."""
    cap = variant[:1].upper() + variant[1:]
    patterns = [
        f'intermediates/merged_manifest/{variant}/process{cap}MainManifest/AndroidManifest.xml',
        f'intermediates/merged_manifest/{variant}/*/AndroidManifest.xml',
        f'intermediates/merged_manifests/{variant}/*/AndroidManifest.xml',
        f'intermediates/packaged_manifests/{variant}/*/AndroidManifest.xml',
    ]
    for pattern in patterns:
        matches = sorted(glob.glob(os.path.join(build_dir, pattern)))
        if matches:
            return matches[0]
    return None


GOOD = f'''<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="{APP_ID}">
  <uses-permission android:name="android.permission.INTERNET"/>
  <application android:allowBackup="true" android:backupAgent="{APP_ID}.CodeForgeBackupAgent"
      android:fullBackupOnly="true" android:fullBackupContent="@xml/backup_rules"
      android:dataExtractionRules="@xml/data_extraction_rules"/>
</manifest>'''

BAD = {
    'a storage permission': GOOD.replace(
        'android.permission.INTERNET"/>',
        'android.permission.INTERNET"/>\n  <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"/>',
    ),
    'a media permission from a library': GOOD.replace(
        'android.permission.INTERNET"/>',
        'android.permission.INTERNET"/>\n  <uses-permission-sdk-23 android:name="android.permission.READ_MEDIA_IMAGES"/>',
    ),
    'legacy external storage': GOOD.replace('<application ', '<application android:requestLegacyExternalStorage="true" '),
    'backup turned off': GOOD.replace('android:allowBackup="true"', 'android:allowBackup="false"'),
    'no backup agent': GOOD.replace(f'android:backupAgent="{APP_ID}.CodeForgeBackupAgent"', ''),
    'the old rules only': GOOD.replace('android:dataExtractionRules="@xml/data_extraction_rules"', ''),
    'an extra backup attribute': GOOD.replace('<application ', '<application android:backupInForeground="true" '),
}


def self_test():
    ok = True
    findings, _ = check(GOOD)
    print(f'self-test: good manifest -> {"pass" if not findings else "FAIL " + "; ".join(findings)}')
    ok &= not findings
    for name, text in BAD.items():
        findings, _ = check(text)
        print(f'self-test: {name} -> {"caught: " + findings[0] if findings else "MISSED"}')
        ok &= bool(findings)
    return ok


def main(argv):
    if argv[1:2] == ['--self-test']:
        return 0 if self_test() else 1
    if argv[1:2] == ['--file'] and len(argv) == 3:
        path = argv[2]
    elif len(argv) in (2, 3) and not argv[1].startswith('-'):
        variant = argv[2] if len(argv) == 3 else 'debug'
        path = merged_manifest(argv[1], variant)
        if path is None:
            print(f'no merged {variant} manifest under {argv[1]}/intermediates')
            return 1
    else:
        print(__doc__)
        return 2
    with open(path, encoding='utf-8') as f:
        findings, checked = check(f.read())
    print(f'manifest: {path}')
    for line in checked:
        print(line)
    for finding in findings:
        print(f'FINDING: {finding}')
    print(f'manifest_check={"pass" if not findings else "fail"} findings={len(findings)}')
    return 1 if findings else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
