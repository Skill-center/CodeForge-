#!/usr/bin/env python3
"""Adds Flutter's Skia opt-out to an AndroidManifest.xml (Phase 3 W6).

For the phase gate's comparison APK only: the same release build rendering
with Skia, timed beside the shipped one in the cold-start group. The app
itself renders with Impeller, Flutter's default, since W6; the workflow puts
the manifest back right after the build.

Usage: skia_manifest.py <AndroidManifest.xml>
"""

import sys

NAME = 'io.flutter.embedding.android.EnableImpeller'
OPT_OUT = (
    '        <meta-data\n'
    f'            android:name="{NAME}"\n'
    '            android:value="false" />\n'
)
END = '    </application>'


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    with open(argv[1], encoding='utf-8') as f:
        text = f.read()
    if NAME in text:
        print(f'{argv[1]} already names {NAME}')
        return 1
    if text.count(END) != 1:
        print(f'{argv[1]}: expected one "{END.strip()}"')
        return 1
    with open(argv[1], 'w', encoding='utf-8') as f:
        f.write(text.replace(END, OPT_OUT + END))
    print(f'{argv[1]}: {NAME}=false added')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
