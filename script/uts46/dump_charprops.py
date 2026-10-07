#!/usr/bin/env python3
"""Dump Unicode character properties needed by the UTS 46 implementation.

The Ruby table generator (script/uts46/generate_tables.rb) consumes this
JSON and intersects it with the set of code points assigned in Unicode 15.1
(computed from Ruby's Onigmo age data), so the exact Unicode version of the
"regex" module does not matter as long as it is >= 15.1: character
properties of already-assigned code points are frozen by Unicode stability
policy.

Usage:
    python3 script/uts46/dump_charprops.py /path/to/charprops.json
"""

import json
import sys

import regex


def all_codepoints():
    # Surrogates are kept so that string indices match code points
    # exactly; they match no property and thus never appear in ranges.
    return "".join(chr(cp) for cp in range(0x110000))


def ranges_for(pattern, text):
    """Return [[lo, hi], ...] ranges of code points matching pattern."""
    rx = regex.compile("(?:" + pattern + ")+")
    return [[m.start(), m.end() - 1] for m in rx.finditer(text, overlapped=False)]


def main():
    out_path = sys.argv[1]
    text = all_codepoints()

    bidi_classes = [
        "R", "AL", "EN", "ES", "ET", "AN", "CS", "NSM", "BN",
        "B", "S", "WS", "ON",
        "LRE", "LRO", "RLE", "RLO", "PDF", "LRI", "RLI", "FSI", "PDI",
    ]
    # "L" is the default and is omitted to keep the table small.
    bidi = {cls: ranges_for(r"\p{bc=%s}" % cls, text) for cls in bidi_classes}

    joining_types = ["L", "R", "D", "T"]
    # "U" (non-joining) is the default and is omitted.
    joining = {jt: ranges_for(r"\p{jt=%s}" % jt, text) for jt in joining_types}

    scripts = ["Greek", "Hebrew", "Hiragana", "Katakana", "Han"]
    script_map = {sc: ranges_for(r"\p{sc=%s}" % sc, text) for sc in scripts}

    data = {
        "bidi": bidi,
        "joining": joining,
        "scripts": script_map,
        # Canonical_Combining_Class = 9 (Virama), for ContextJ.
        "virama": ranges_for(r"\p{ccc=9}", text),
        # General_Category = Mark (Mn/Mc/Me), for the leading-mark check.
        "mark": ranges_for(r"\p{gc=M}", text),
    }

    with open(out_path, "w") as f:
        json.dump(data, f)
    total = sum(len(v) for v in bidi.values()) + sum(len(v) for v in joining.values())
    total += sum(len(v) for v in script_map.values())
    total += len(data["virama"]) + len(data["mark"])
    print("wrote %s (%d ranges)" % (out_path, total))


if __name__ == "__main__":
    main()
