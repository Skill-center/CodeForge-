"""Builds assets/fonts/CfFileGlyphs.ttf, the explorer's file-type glyphs.

docs/UI_DESIGN_SYSTEM.md §6: custom glyphs on a 16 dp grid with a 1.5 px
stroke, round caps and joins, for the 20 most common kinds of file, and a
generic page for everything else. Each glyph below is SVG path data for
the strokes' centre lines on that grid (`fill` paths are filled as drawn);
skia-pathops turns the strokes into outlines. Letters are drawn by
`_monogram`, not taken from a typeface.

The codepoints must match lib/design_system/tokens/file_glyphs.dart, which
maps names and extensions to these glyphs; test/design_system/icons_test.dart
checks the committed font against it.

    /tmp/venv/bin/python tool/fonts/build_file_glyphs.py [--preview out.png]

Run it from app/ (requirements.txt beside it). The output is reproducible.
"""

import math
import pathlib
import sys

import pathops
from fontTools.fontBuilder import FontBuilder
from fontTools.misc.timeTools import timestampFromString
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.recordingPen import RecordingPen
from fontTools.pens.reverseContourPen import ReverseContourPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.svgLib.path import parse_path

OUTPUT = pathlib.Path('assets/fonts/CfFileGlyphs.ttf')
GRID = 16
STROKE = 1.5
UNIT = 100  # font units per grid unit: 1600 units per em
FAMILY = 'CfFileGlyphs'

# ---------------------------------------------------------------- letters
# Each letter is drawn in a box w wide and h tall, origin top-left.


def _arc(r, large, sweep, x, y):
    return f'A{r:g} {r:g} 0 {large} {sweep} {x:g} {y:g}'


def _letter(ch, w, h):
    r = w / 2
    if ch == 'C':
        a = math.radians(38)
        cx, cy, rr = r, h / 2, h / 2
        x0, y0 = cx + rr * math.cos(a), cy - rr * math.sin(a)
        return [f'M{x0:g} {y0:g} {_arc(rr, 1, 0, x0, h - y0)}']
    if ch == 'G':
        a = math.radians(40)
        x0, y0 = r + r * math.cos(a), r - r * math.sin(a)
        return [f'M{x0:g} {y0:g} {_arc(r, 0, 0, 0, r)} V{h - r:g} '
                f'{_arc(r, 0, 0, w, h - r)} V{h * 0.52:g} H{w * 0.55:g}']
    if ch == 'J':
        return [f'M{w:g} 0 V{h - r:g} {_arc(r, 0, 1, 0, h - r)}']
    if ch == 'K':
        return [f'M0 0 V{h:g}', f'M{w:g} 0 L0 {h * 0.6:g}',
                f'M{w * 0.42:g} {h * 0.348:g} L{w:g} {h:g}']
    if ch == 'O':
        return [f'M{r:g} 0 {_arc(r, 0, 1, w, r)} V{h - r:g} '
                f'{_arc(r, 0, 1, 0, h - r)} V{r:g} {_arc(r, 0, 1, r, 0)} Z']
    if ch in 'PR':
        b = h * 0.55
        bowl = (f'M0 {h:g} V0 H{w - b / 2:g} {_arc(b / 2, 0, 1, w - b / 2, b)} '
                f'H0')
        return [bowl] + ([f'M{w * 0.5:g} {b:g} L{w:g} {h:g}'] if ch == 'R' else [])
    if ch == 'S':
        sx, sy = w / 4.5, h / 8
        pts = [(4.4, 1.2), (3.95, .4), (3.2, 0), (2.25, 0), (1.0, 0), (.1, .85),
               (.1, 2.0), (.1, 3.2), (1.1, 3.6), (2.25, 4.0), (3.4, 4.4),
               (4.4, 4.9), (4.4, 6.0), (4.4, 7.15), (3.45, 8), (2.25, 8),
               (1.25, 8), (.4, 7.6), (0, 6.7)]
        p = [f'{x * sx:g} {y * sy:g}' for x, y in pts]
        return [f'M{p[0]} C{p[1]} {p[2]} {p[3]} C{p[4]} {p[5]} {p[6]} '
                f'C{p[7]} {p[8]} {p[9]} C{p[10]} {p[11]} {p[12]} '
                f'C{p[13]} {p[14]} {p[15]} C{p[16]} {p[17]} {p[18]}']
    if ch == 'T':
        return [f'M0 0 H{w:g}', f'M{r:g} 0 V{h:g}']
    if ch == 'Y':
        return [f'M0 0 L{r:g} {h * 0.5:g} L{w:g} 0', f'M{r:g} {h * 0.5:g} V{h:g}']
    raise ValueError(ch)


def _move(paths, dx, dy):
    """Translates path data written with absolute commands only."""
    out = []
    for d in paths:
        rec = RecordingPen()
        parse_path(d, TransformPen(rec, (1, 0, 0, 1, dx, dy)))
        out.append(rec)
    return out


def _monogram(text, w=4.25, h=8, gap=2.5, top=4):
    total = len(text) * w + (len(text) - 1) * gap
    x = (GRID - total) / 2
    out = []
    for ch in text:
        out += _move(_letter(ch, w, h), x, top)
        x += w + gap
    return out


# ----------------------------------------------------------------- glyphs
PAGE = ['M3 1.75 H9.25 L13 5.5 V14.25 H3 Z', 'M9.25 1.75 V5.5 H13']


def _dot(x, y):
    return f'M{x:g} {y:g} H{x + 0.01:g}'


GLYPHS = {
    # name: (codepoint, stroked paths, filled paths)
    'file': (0xE000, PAGE, []),
    'text': (0xE001, PAGE + ['M5.5 8.75 H10.5', 'M5.5 11.5 H10.5'], []),
    # A dart: a filled head, the shaft and one pair of flights.
    'dart': (0xE002, ['M10.5 5.5 L3.5 12.5', 'M6.5 9.5 H2.75', 'M6.5 9.5 V13.25'],
             ['M14 2 L12.35 7.65 L8.35 3.65 Z']),
    'javascript': (0xE003, _monogram('JS'), []),
    'typescript': (0xE004, _monogram('TS'), []),
    'python': (0xE005, _monogram('PY'), []),
    'kotlin': (0xE006, _monogram('KT'), []),
    'go': (0xE007, _monogram('GO'), []),
    'rust': (0xE008, _monogram('RS'), []),
    'cFamily': (0xE009, _monogram('C', w=8.5, h=9, top=3.5), []),
    'java': (0xE00A, ['M3 6.75 H11 V10 A3 3 0 0 1 8 13 H6 A3 3 0 0 1 3 10 Z',
                      'M11 7.5 H11.75 A1.75 1.75 0 0 1 11.75 11 H10.5',
                      'M5.75 2 C5 2.75 6.5 3.5 5.75 4.25',
                      'M8.5 2 C7.75 2.75 9.25 3.5 8.5 4.25'], []),
    'json': (0xE00B, ['M6 2.5 C4.5 2.5 4.5 3.25 4.5 4.5 V6.25 C4.5 7.25 4 8 2.75 8 '
                      'C4 8 4.5 8.75 4.5 9.75 V11.5 C4.5 12.75 4.5 13.5 6 13.5',
                      'M10 2.5 C11.5 2.5 11.5 3.25 11.5 4.5 V6.25 C11.5 7.25 12 8 '
                      '13.25 8 C12 8 11.5 8.75 11.5 9.75 V11.5 C11.5 12.75 11.5 '
                      '13.5 10 13.5'], []),
    'yaml': (0xE00C, ['M2.5 3.75 H9', _dot(5.25, 8), 'M7.75 8 H13.5',
                      _dot(5.25, 12.25), 'M7.75 12.25 H11.75'], []),
    'markdown': (0xE00D, ['M1.75 11.75 V4.25 L4.75 8 L7.75 4.25 V11.75',
                          'M11.75 4.25 V11.5', 'M9.5 9.25 L11.75 11.5 L14 9.25'],
                 []),
    'markup': (0xE00E, ['M5.25 4.5 L1.75 8 L5.25 11.5', 'M10.75 4.5 L14.25 8 '
                        'L10.75 11.5', 'M9.25 3 L6.75 13'], []),
    'css': (0xE00F, ['M6.75 2.5 L5.5 13.5', 'M10.75 2.5 L9.5 13.5',
                     'M3 6 H13.25', 'M2.75 10 H13'], []),
    'shell': (0xE010, ['M2.75 4.5 L6.25 8 L2.75 11.5', 'M8.5 11.5 H13.25'], []),
    'config': (0xE011, ['M2.5 3.5 H8.25', 'M11.75 3.5 H13.5',
                        f'M10 1.75 {_arc(1.75, 1, 1, 10, 5.25)} {_arc(1.75, 1, 1, 10, 1.75)}',
                        'M2.5 8 H3.75', 'M7.25 8 H13.5',
                        f'M5.5 6.25 {_arc(1.75, 1, 1, 5.5, 9.75)} {_arc(1.75, 1, 1, 5.5, 6.25)}',
                        'M2.5 12.5 H7.75', 'M11.25 12.5 H13.5',
                        f'M9.5 10.75 {_arc(1.75, 1, 1, 9.5, 14.25)} {_arc(1.75, 1, 1, 9.5, 10.75)}'],
               []),
    'image': (0xE012, ['M3.5 2.75 H12.5 A1.5 1.5 0 0 1 14 4.25 V11.75 A1.5 1.5 0 0 1 '
                       '12.5 13.25 H3.5 A1.5 1.5 0 0 1 2 11.75 V4.25 A1.5 1.5 0 0 1 '
                       '3.5 2.75 Z',
                       'M2.75 12 L6.25 8.5 L9 11.25 L10.75 9.5 L13.25 12',
                       f'M10.5 4.75 {_arc(1.25, 1, 1, 10.5, 7.25)} {_arc(1.25, 1, 1, 10.5, 4.75)}'],
              []),
    'lock': (0xE013, ['M4.5 7 H11.5 A1.5 1.5 0 0 1 13 8.5 V12.75 A1.5 1.5 0 0 1 11.5 '
                      '14.25 H4.5 A1.5 1.5 0 0 1 3 12.75 V8.5 A1.5 1.5 0 0 1 4.5 7 Z',
                      'M5.5 7 V5 A2.5 2.5 0 0 1 10.5 5 V7', 'M8 10 V11.25'], []),
    'git': (0xE014, [f'M5 2 {_arc(1.75, 1, 1, 5, 5.5)} {_arc(1.75, 1, 1, 5, 2)}',
                     f'M5 10.5 {_arc(1.75, 1, 1, 5, 14)} {_arc(1.75, 1, 1, 5, 10.5)}',
                     f'M11 3.5 {_arc(1.75, 1, 1, 11, 7)} {_arc(1.75, 1, 1, 11, 3.5)}',
                     'M5 5.5 V10.5', 'M11 7 C11 9.25 5 8.25 5 10.5'], []),
}


def _skia(paths, stroke):
    result = pathops.Path()
    for d in paths:
        path = pathops.Path()
        pen = path.getPen()
        if isinstance(d, RecordingPen):
            d.replay(pen)
        else:
            parse_path(d, pen)
        if stroke:
            path.stroke(STROKE, pathops.LineCap.ROUND_CAP,
                        pathops.LineJoin.ROUND_JOIN, 4)
            # Round caps and joins come out as conics, which neither the
            # boolean operations nor TrueType take. 0.25 % of the grid.
            path.convertConicsToQuads(0.004)
        result = pathops.op(result, path, pathops.PathOp.UNION)
    return result


def _glyph(stroked, filled):
    outline = pathops.op(_skia(stroked, True), _skia(filled, False),
                         pathops.PathOp.UNION)
    pen = TTGlyphPen(None)
    # Grid y runs down; font y runs up, with the em box from 0 to 1600.
    flip = TransformPen(Cu2QuPen(ReverseContourPen(pen), 1.0, reverse_direction=False),
                        (UNIT, 0, 0, -UNIT, 0, GRID * UNIT))
    outline.draw(flip)
    return pen.glyph()


def build():
    names = ['.notdef'] + list(GLYPHS)
    glyphs = {'.notdef': TTGlyphPen(None).glyph()}
    for name, (_, stroked, filled) in GLYPHS.items():
        glyphs[name] = _glyph(stroked, filled)
    fb = FontBuilder(GRID * UNIT, isTTF=True)
    fb.setupGlyphOrder(names)
    fb.setupCharacterMap({cp: name for name, (cp, _, _) in GLYPHS.items()})
    fb.setupGlyf(glyphs)
    metrics = {}
    for name in names:
        g = glyphs[name]
        g.recalcBounds(fb.font['glyf'])
        metrics[name] = (GRID * UNIT, getattr(g, 'xMin', 0))
    fb.setupHorizontalMetrics(metrics)
    # The same proportions as Material Symbols (ascent 1.1 em, descent
    # 0.1 em): Flutter's Icon then centres the 0..1 em box in its square.
    fb.setupHorizontalHeader(ascent=1760, descent=-160)
    fb.setupNameTable({'familyName': FAMILY, 'styleName': 'Regular',
                       'uniqueFontIdentifier': f'{FAMILY}-Regular',
                       'fullName': f'{FAMILY} Regular', 'psName': f'{FAMILY}-Regular',
                       'version': 'Version 1.000'})
    fb.setupOS2(sTypoAscender=1760, sTypoDescender=-160, sTypoLineGap=0,
                usWinAscent=1760, usWinDescent=160, achVendID='NONE')
    fb.setupPost()
    fb.font['head'].created = fb.font['head'].modified = timestampFromString(
        'Thu Nov 12 00:00:00 2026')
    fb.font.recalcTimestamp = False
    fb.save(OUTPUT)
    print(f'{OUTPUT}: {len(GLYPHS)} glyphs, {OUTPUT.stat().st_size} bytes')


def preview(target):
    from PIL import Image, ImageDraw, ImageFont
    sizes = [16, 42, 96]
    names = list(GLYPHS)
    cell = 110
    img = Image.new('RGB', (cell * len(names) // 2 + 40, 2 * (sum(sizes) + 60)),
                    (15, 17, 21))
    draw = ImageDraw.Draw(img)
    label = ImageFont.load_default()
    for i, name in enumerate(names):
        col, row = i % ((len(names) + 1) // 2), i // ((len(names) + 1) // 2)
        x, y = 20 + col * (cell - 6), 10 + row * (sum(sizes) + 60)
        draw.text((x, y), name, fill=(154, 161, 176), font=label)
        y += 14
        for s in sizes:
            font = ImageFont.truetype(str(OUTPUT), s)
            draw.text((x, y), chr(GLYPHS[name][0]), fill=(232, 234, 240), font=font)
            y += s + 4
    img.save(target)
    print('preview', target)


if __name__ == '__main__':
    build()
    if '--preview' in sys.argv:
        preview(sys.argv[sys.argv.index('--preview') + 1])
