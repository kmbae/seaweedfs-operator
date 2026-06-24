#!/bin/sh
set -eu

config_file="${OPENSM_CONFIG_FILE:-/tmp/opensm.conf}"
set -- opensm "$@"

if [ -n "${OPENSM_SM_ASSIGNED_GUID:-}" ]; then
  opensm --create-config "$config_file" >/dev/null 2>&1
  sed -i "s/^sm_assigned_guid .*/sm_assigned_guid ${OPENSM_SM_ASSIGNED_GUID}/" "$config_file"
  set -- "$@" -F "$config_file"
fi

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
