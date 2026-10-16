#!/usr/bin/env bash
# LSF backend: planned. This skeleton lists the interface to implement (see
# docs/BACKENDS.md); opmexec does not load it while lsf is in
# _OPMEXEC_PLANNED_SCHEDULERS (lib/config.sh).

opmexec::backend_submit_job() {     # QUEUE NP OUTPUT DEPENDS_ON OPTIONS COMMAND...
  opmexec::error "LSF backend not implemented"
  return 1
}

opmexec::backend_job_status() {     # ID
  opmexec::error "LSF backend not implemented"
  return 1
}

opmexec::backend_cancel_job() {     # ID
  opmexec::error "LSF backend not implemented"
  return 1
}

opmexec::backend_list_jobs() {      # [active|all]
  opmexec::error "LSF backend not implemented"
  return 1
}
