#!/bin/sh
set -eu

if [ "${RELEASE_DISTRIBUTION:-none}" = "name" ] && [ -z "${RELEASE_NODE:-}" ]; then
  address=$(hostname -i | cut -d ' ' -f 1)
  [ -n "$address" ] || { echo "Unable to determine container address" >&2; exit 1; }
  export RELEASE_NODE="${ARENA_NODE_BASENAME:-arena}@$address"
fi

exec /app/bin/arena "$@"
