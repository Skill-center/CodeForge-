"""Builds assets/fonts/MaterialSymbolsRounded.ttf, the app's icon font.

The source is Google's variable Material Symbols Rounded font (Apache-2.0),
pinned below by commit and checksum. The script makes a static instance
(outlined, grade 0, optical size 20, weight 400) and keeps only the
codepoints that lib/design_system/tokens/icons.dart declares, so an icon
added there needs this script re-run. test/design_system/icons_test.dart
fails when the committed font lacks a declared codepoint.

    python3 -m venv /tmp/venv && /tmp/venv/bin/pip install -r tool/fonts/requirements.txt
    gh api -H "Accept: application/vnd.github.raw" \
      repos/google/material-design-icons/git/blobs/ff99804f914a1db645bcf066dafa9449d9196f8d \
      > /tmp/MaterialSymbolsRounded.ttf
    /tmp/venv/bin/python tool/fonts/subset_symbols.py /tmp/MaterialSymbolsRounded.ttf

Run it from app/. The output is reproducible: the same source and the same
codepoints give the same bytes.
"""

import hashlib
import pathlib
import re
import sys

from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

SOURCE_COMMIT = '10ecc14790612ca8fd164e3f4ffe9c16fc50d5b7'
SOURCE_PATH = 'variablefont/MaterialSymbolsRounded[FILL,GRAD,opsz,wght].ttf'
SOURCE_SHA256 = '7e74e36533ccee12c2b81e75bfcf3ccf123d3bb7e7e46d65d94445f23db0c97c'
AXES = {'FILL': 0, 'GRAD': 0, 'opsz': 20, 'wght': 400}
NOTICE = ('Modified by CodeForge from Material Symbols Rounded (commit '
          f'{SOURCE_COMMIT[:12]}): a static instance (FILL 0, GRAD 0, opsz 20, '
          'wght 400) holding only the icons the app uses, made by '
          'app/tool/fonts/subset_symbols.py.')
ICONS = pathlib.Path('lib/design_system/tokens/icons.dart')
OUTPUT = pathlib.Path('assets/fonts/MaterialSymbolsRounded.ttf')


def declared_codepoints():
    found = re.findall(r'IconData\(\s*0x([0-9a-f]{4,5})', ICONS.read_text())
    if not found:
        sys.exit(f'no codepoints found in {ICONS}')
    return sorted({int(c, 16) for c in found})


def main(source):
    digest = hashlib.sha256(pathlib.Path(source).read_bytes()).hexdigest()
    if digest != SOURCE_SHA256:
        sys.exit(f'{source}: sha256 {digest}, expected {SOURCE_SHA256}')
    codepoints = declared_codepoints()
    font = TTFont(source)
    missing = [hex(c) for c in codepoints if c not in font.getBestCmap()]
    if missing:
        sys.exit(f'not in Material Symbols Rounded: {missing}')
    font = instancer.instantiateVariableFont(font, AXES, updateFontNames=False)
    options = subset.Options()
    options.layout_features = []  # the ligatures map names to icons; unused
    options.name_IDs = ['*']
    options.notdef_outline = True
    options.recalc_timestamp = False
    subsetter = subset.Subsetter(options)
    subsetter.populate(unicodes=codepoints)
    subsetter.subset(font)
    # Apache-2.0 §4(b): modified files carry a notice saying so.
    font['name'].setName(NOTICE, 10, 3, 1, 0x409)
    font.recalcTimestamp = False  # keeps the source's dates: reproducible
    font.save(OUTPUT, reorderTables=True)
    print(f'{OUTPUT}: {len(codepoints)} icons, {OUTPUT.stat().st_size} bytes')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
