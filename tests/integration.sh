#!/bin/sh
# Every mise/Herdr subprocess is launched by Python with a fresh environment.
set -eu
exec python3 "$(dirname "$0")/integration.py" "$@"
