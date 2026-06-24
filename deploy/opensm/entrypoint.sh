#!/bin/sh
set -eu

set -- opensm "$@"

if [ -n "${OPENSM_GUID:-}" ]; then
  set -- "$@" -g "$OPENSM_GUID"
fi

if [ -n "${OPENSM_PRIORITY:-}" ]; then
  set -- "$@" -p "$OPENSM_PRIORITY"
fi

if [ -n "${OPENSM_EXTRA_ARGS:-}" ]; then
  # shellcheck disable=SC2086
  set -- "$@" $OPENSM_EXTRA_ARGS
fi

echo "Starting: $*"
exec "$@"
