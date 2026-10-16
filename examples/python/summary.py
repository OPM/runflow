"""Print a summary vector of one or more runs: its last value and, for a rate,
its total over the run. Relative changes are against the first run.
With --compare TOL: PASS if every run agrees with the first within TOL
(largest difference over time, relative to the first run's largest value),
FAIL and exit status 1 otherwise.

Usage: summary.py [--compare TOL] VECTOR CASE..."""

import os
import sys

import numpy as np
from opm.io.ecl import ESmry

args = sys.argv[1:]
tolerance = None
if args[:1] == ["--compare"]:
    tolerance, args = float(args[1]), args[2:]
if len(args) < 2:
    sys.exit(__doc__)
vector, cases = args[0], args[1:]


def load(case):
    """The summary of CASE (a deck, a summary file, or their base name);
    Flow writes its output in upper case: case.DATA gives CASE.SMSPEC."""
    base = os.path.splitext(case)[0] if case.upper().endswith((".DATA", ".SMSPEC")) else case
    for name in (base, os.path.join(os.path.dirname(base), os.path.basename(base).upper())):
        if os.path.exists(name + ".SMSPEC"):
            return ESmry(name + ".SMSPEC")
    sys.exit(f"No summary for {case}")


def number(value):
    return f"{value:,.0f}" if abs(value) >= 1e4 else f"{value:,.4g}"


first = None
failed = False
for case in cases:
    smry = load(case)
    time, values = np.asarray(smry["TIME"]), np.asarray(smry[vector])
    unit = smry.units(vector)
    line = f"{os.path.relpath(case)}: {vector} last {number(values[-1])} {unit}"
    result = values[-1]
    if unit.endswith("/DAY"):  # a rate: its total over the run, in days
        result = getattr(np, "trapezoid", getattr(np, "trapz", None))(values, time)  # numpy < 2: trapz
        line += f", total {number(result)} {unit[:-4]}"
    if first is None:
        first = (time, values, result)
    else:
        line += f" ({100 * (result / first[2] - 1):+.1f}%)" if first[2] else ""
        if tolerance is not None:
            difference = np.max(np.abs(np.interp(first[0], time, values) - first[1]))
            relative = difference / max(np.max(np.abs(first[1])), 1e-12)
            failed |= relative > tolerance
            line += f"  difference {relative:.1e}: {'FAIL' if relative > tolerance else 'ok'}"
    print(line)

if tolerance is not None:
    print("FAIL" if failed else "PASS", f"(tolerance {tolerance:g})")
    sys.exit(1 if failed else 0)
