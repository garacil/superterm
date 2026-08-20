#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
if [ ! -f "$PROJECT_DIR/Makefile" ]; then
  "$PROJECT_DIR/configure"
fi
exec make -C "$PROJECT_DIR" "$@"
