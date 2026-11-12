#!/usr/bin/env python3
"""Joins a JSON report a test printed in parts (Phase 3 W6).

A test prints its report as lines `<MARKER> <part>/<parts> <text>`, each
short enough for any log; this finds them in the test's output, joins the
parts in order, and writes the report, indented, to <out>. Fails when a part
is missing or the joined text is not JSON.

Usage: join_report.py <MARKER> <test output> <out.json>
"""

import json
import re
import sys


def join(marker, lines):
    """The report from `lines`, or a reason it can't be had."""
    pattern = re.compile(re.escape(marker) + r' (\d+)/(\d+) (.*)$')
    parts = {}
    total = 0
    for line in lines:
        match = pattern.search(line.rstrip('\n'))
        if match:
            parts[int(match.group(1))] = match.group(3)
            total = int(match.group(2))
    if not total:
        return None, f'no {marker} lines'
    missing = [i for i in range(1, total + 1) if i not in parts]
    if missing:
        return None, f'{marker}: parts {missing} of {total} missing'
    try:
        return json.loads(''.join(parts[i] for i in range(1, total + 1))), None
    except ValueError as error:
        return None, f'{marker}: not JSON ({error})'


def main(argv):
    if len(argv) != 4:
        print(__doc__)
        return 2
    marker, source, out = argv[1:]
    with open(source, encoding='utf-8', errors='replace') as f:
        report, problem = join(marker, f)
    if problem:
        print(problem)
        return 1
    with open(out, 'w', encoding='utf-8') as f:
        json.dump(report, f, indent=2)
        f.write('\n')
    print(f'{out}: {len(report)} keys')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
