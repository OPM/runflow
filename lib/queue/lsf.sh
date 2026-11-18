#!/usr/bin/env bash
# LSF backend: planned. This skeleton lists the interface to implement (see
# docs/BACKENDS.md); flowrun does not load it while lsf is in
# _FLOWRUN_PLANNED_SCHEDULERS (lib/config.sh).

flowrun::backend_submit_job() {     # QUEUE NP OUTPUT DEPENDS_ON OPTIONS COMMAND...
  flowrun::error "LSF backend not implemented"
  return 1
}

flowrun::backend_job_status() {     # ID
  flowrun::error "LSF backend not implemented"
  return 1
}

flowrun::backend_cancel_job() {     # ID
  flowrun::error "LSF backend not implemented"
  return 1
}

flowrun::backend_list_jobs() {      # [active|all]
  flowrun::error "LSF backend not implemented"
  return 1
}
