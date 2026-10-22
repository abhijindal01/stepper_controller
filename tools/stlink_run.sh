#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
CFG="${ROOT}/openocd_fixture.cfg"
exec openocd -f "$CFG" -c "init; reset run; echo RUN_OK; exit"
