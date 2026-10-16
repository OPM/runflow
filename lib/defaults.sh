#!/usr/bin/env bash
# Built-in defaults of every setting. Configuration files, the environment
# and options override them (see opmexec(1), CONFIGURATION). Do not edit:
# copy etc/opmexec.conf.example to a configuration file instead.

# Schedulers
OPMEXEC_SCHEDULER=auto                 # auto: localq (LSF, SLURM, PBS: planned)
OPMEXEC_DEFAULT_QUEUE_LSF=''           # empty: the scheduler's own default queue
OPMEXEC_DEFAULT_QUEUE_SLURM=''
OPMEXEC_DEFAULT_QUEUE_PBS=''
OPMEXEC_DEFAULT_QUEUE_LOCALQ=normal    # a label only
OPMEXEC_LSF_OPTIONS=''                 # native options for every job
OPMEXEC_SLURM_OPTIONS=''
OPMEXEC_PBS_OPTIONS=''
OPMEXEC_LOCALQ_OPTIONS=''              # --time, --nice, --job-name, --exclusive
OPMEXEC_LOCALQ_SLOTS=''                # empty: the number of CPUs

# Flow
OPMEXEC_FLOW_BIN_PATHS=(PATH)          # PATH: the directories of $PATH when Flow is looked up
OPMEXEC_FLOW_VERSION=flow
OPMEXEC_FLOWPY_VERSION=''              # @flowpy's default version; empty: OPMEXEC_FLOW_VERSION
OPMEXEC_FLOW_VERSIONS=()               # named versions, e.g. ('2025.04=/opt/opm/2025.04/bin/flow' 'dev=~/opm/build')
OPMEXEC_FLOW_OPTIONS=''
OPMEXEC_FLOW_PYTHONPATH=auto           # opm bindings: auto (found next to Flow), a template, or '' (none)
OPMEXEC_FLOW_PYTHON_MAP=()             # Python per version pattern, e.g. ('flow2024*:3.12'); wins over detection

# MPI launchers; {np} is replaced by the number of ranks; empty: LOCAL
OPMEXEC_MPI_LAUNCHER_LOCAL='mpirun -np {np}'
OPMEXEC_MPI_LAUNCHER_LOCALQ=''
OPMEXEC_MPI_LAUNCHER_LSF='mpirun -np {np}'
OPMEXEC_MPI_LAUNCHER_SLURM='srun --ntasks={np}'
OPMEXEC_MPI_LAUNCHER_PBS='mpirun -np {np}'
OPMEXEC_MPI_OPTIONS=''

# Jobs
OPMEXEC_JOB_SETUP=''                   # shell commands run at the start of every job

# Waiting for jobs
OPMEXEC_WAIT_TIMEOUT=0                 # seconds @wait waits at most; 0: no limit
OPMEXEC_POLL=1                         # seconds between status checks of polled schedulers
OPMEXEC_LOCALQ_POLL=1                  # seconds between localq's scheduling checks
OPMEXEC_LOCALQ_REAP_INTERVAL=5         # seconds between localq's checks for dead runners

# Interactive shells (opmexec --shell, or source opmexec.bash at a prompt)
OPMEXEC_PROMPT=true                    # (opmexec SCHEDULER FLOW_VERSION) before the prompt
OPMEXEC_NOTIFY=true                    # report finished jobs before the prompt
OPMEXEC_NOTIFY_INTERVAL=5              # at most every so many seconds

# Files
OPMEXEC_DIRECTIVE_PATH="${XDG_CONFIG_HOME:-$HOME/.config}/opmexec/directives"
OPMEXEC_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/opmexec"
OPMEXEC_LOG_DIR=''                     # empty: $OPMEXEC_STATE_DIR/logs

OPMEXEC_DEBUG=false
