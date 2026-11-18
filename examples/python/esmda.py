# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
"""The update of an ensemble history match (ES-MDA, Emerick and Reynolds
2013), for examples/6_history_match.sh. Parameters: one line per member, its
log10 multipliers. Data: the producer's bottom-hole pressure, GOR and oil
rate, every 3 months over the history.

Usage:
  esmda.py prior N SEED PARAMS              random members around 0 (x1)
  esmda.py observe TRUTH SEED OBS           the truth run's data plus noise
  esmda.py update OBS PARAMS ALPHA NEW CASE...  the members after one step
  esmda.py misfit OBS CASE...               how well the runs fit"""

import sys

import numpy as np
from opm.io.ecl import ESmry

VECTORS = [("WBHP:PROD", 20.0, 0.0), ("WGOR:PROD", 0.1, 0.05), ("WOPR:PROD", 50.0, 0.02)]
TIMES = np.arange(91.0, 1826.0, 91.0)  # every 3 months of the 5 years of history


def data(case):
    """The run's data, or None if it has no results."""
    try:
        smry = ESmry(case + ".SMSPEC")
    except Exception:
        return None
    return np.concatenate([np.interp(TIMES, smry["TIME"], smry[key]) for key, _, _ in VECTORS])


def ensemble(cases):
    runs = [data(case) for case in cases]
    ok = np.array([run is not None for run in runs])
    return np.array([run for run in runs if run is not None]), ok


def misfit(simulated, obs, std):
    """Mean squared misfit in noise units: about 1 fits within the noise."""
    return np.mean(((simulated - obs) / std) ** 2, axis=1)


command, args = sys.argv[1], sys.argv[2:]
if command == "prior":
    rng = np.random.default_rng(int(args[1]))
    np.savetxt(args[2], rng.normal(0.0, 0.4, (int(args[0]), 3)), fmt="%.6f")
elif command == "observe":
    truth = data(args[0])
    std = np.concatenate([a + r * np.abs(p) for (_, a, r), p in zip(VECTORS, np.split(truth, len(VECTORS)))])
    obs = truth + np.random.default_rng(int(args[1])).normal(0.0, std)
    np.savetxt(args[2], np.column_stack([obs, std]), fmt="%.6g")
elif command == "update":
    obs, std = np.loadtxt(args[0], unpack=True)
    params, alpha = np.loadtxt(args[1], ndmin=2), float(args[2])
    simulated, ok = ensemble(args[4:])
    m = params[ok]
    # Kalman-like update from the ensemble's covariances, with the noise
    # inflated by alpha (ES-MDA spreads the data over its iterations)
    dm, dd = m - m.mean(axis=0), simulated - simulated.mean(axis=0)
    c_md, c_dd = dm.T @ dd / (len(m) - 1), dd.T @ dd / (len(m) - 1)
    perturbed = obs + np.sqrt(alpha) * std * np.random.default_rng(len(m)).normal(size=simulated.shape)
    gain = np.linalg.solve(c_dd + alpha * np.diag(std ** 2), c_md.T).T
    params[ok] = m + (perturbed - simulated) @ gain.T
    params[~ok] = params[ok].mean(axis=0)  # failed members restart from the mean
    np.savetxt(args[3], params, fmt="%.6f")
    print(f"misfit {np.median(misfit(simulated, obs, std)):.1f} ({ok.sum()} runs); "
          f"multipliers now {' '.join(f'{10 ** x:.2f}' for x in params.mean(axis=0))}")
elif command == "misfit":
    obs, std = np.loadtxt(args[0], unpack=True)
    simulated, ok = ensemble(args[1:])
    print(f"misfit {np.median(misfit(simulated, obs, std)):.1f} ({ok.sum()} runs)")
else:
    sys.exit(__doc__)
