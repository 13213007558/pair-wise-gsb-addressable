#!/usr/bin/env python3
"""Extract IDNA2008/UTS 46 reference data from the Python idna package.

The idna package (https://github.com/kjd/idna) ships machine-generated
tables derived from the Unicode Character Database. This script dumps them
to JSON so that generate_uts46_data.rb can pin them to a specific Unicode
version. Everything runs offline; no data is downloaded.

Usage:
    python3 tasks/uts46/extract_idna_package_data.py [output.json]
"""

import json
import sys

from idna.idnadata import codepoint_classes, joining_types
from idna.intranges import intranges_contain
from idna.uts46data import uts46data

MAXCP = 0x110000


def main():
    output = sys.argv[1] if len(sys.argv) > 1 else "tmp/uts46/py_dump.json"

    def cp_class(cp):
        for name, ranges in codepoint_classes.items():
            if intranges_contain(cp, ranges):
                return name
        return None

    out_class = {}
    for cp in range(MAXCP):
        cls = cp_class(cp)
        if cls:
            out_class[cp] = cls

    out_jt = {cp: chr(value) for cp, value in joining_types().items()}

    out_uts46 = {}
    for entry in uts46data:
        out_uts46[entry[0]] = [entry[1], entry[2] if len(entry) > 2 else None]

    with open(output, "w") as fh:
        json.dump(
            {"classes": out_class, "joining": out_jt, "uts46": out_uts46}, fh
        )
    print(
        "wrote %s (classes=%d joining=%d uts46=%d)"
        % (output, len(out_class), len(out_jt), len(out_uts46))
    )


if __name__ == "__main__":
    main()

