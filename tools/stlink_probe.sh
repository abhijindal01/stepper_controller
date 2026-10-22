#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
CFG="${ROOT}/openocd_fixture.cfg"
exec openocd -f "$CFG" -c "init; targets; echo PROBE_OK; exit"
