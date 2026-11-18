#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# LSF backend: planned. This skeleton lists the interface to implement (see
# docs/BACKENDS.md); runflow does not load it while lsf is in
# _RUNFLOW_PLANNED_SCHEDULERS (lib/config.sh).

runflow::backend_submit_job() {     # QUEUE NP OUTPUT DEPENDS_ON OPTIONS COMMAND...
  runflow::error "LSF backend not implemented"
  return 1
}

runflow::backend_job_status() {     # ID
  runflow::error "LSF backend not implemented"
  return 1
}

runflow::backend_cancel_job() {     # ID
  runflow::error "LSF backend not implemented"
  return 1
}

runflow::backend_list_jobs() {      # [active|all]
  runflow::error "LSF backend not implemented"
  return 1
}
