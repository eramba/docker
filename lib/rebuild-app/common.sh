#!/usr/bin/env bash

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

acquire_lock() {
  LOCK_DIR="${REBUILD_APP_LOCK_DIR:-${ROOT_DIR}/.rebuild-app/lock}"
  mkdir -p "$(dirname "$LOCK_DIR")"
  mkdir "$LOCK_DIR" 2>/dev/null || die "Another rebuild-app process is running."
}

release_lock() {
  [[ -n "${LOCK_DIR:-}" ]] && rmdir "$LOCK_DIR" 2>/dev/null || true
}
