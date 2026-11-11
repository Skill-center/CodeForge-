#!/usr/bin/env python3
"""Finds a node in a `uiautomator dump` (Phase 3 W2, the gate's folder
picker driver in emulator_gate.sh).

    ui_node.py <dump.xml> <regex> [any]

Prints the centre "x y" of the first enabled node whose text or
content-desc matches <regex> in full, case ignored, and exits 0; exits 1
when no node matches, 2 when the dump can't be read. With "any", disabled
nodes count too (the folder picker shows files, disabled, inside the
folder it offers).
"""

import re
import sys
import xml.etree.ElementTree as ElementTree


def main() -> int:
    dump, pattern = sys.argv[1], re.compile(sys.argv[2], re.IGNORECASE)
    enabled_only = len(sys.argv) < 4 or sys.argv[3] != "any"
    try:
        root = ElementTree.parse(dump).getroot()
    except (OSError, ElementTree.ParseError) as error:
        print(f"unreadable dump: {error}", file=sys.stderr)
        return 2
    for node in root.iter("node"):
        if enabled_only and node.get("enabled", "true") != "true":
            continue
        for attribute in ("text", "content-desc"):
            if pattern.fullmatch(node.get(attribute) or ""):
                bounds = re.fullmatch(
                    r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.get("bounds", "")
                )
                if bounds:
                    x1, y1, x2, y2 = map(int, bounds.groups())
                    print((x1 + x2) // 2, (y1 + y2) // 2)
                    return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
