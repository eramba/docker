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

file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

rewrite_env_key() {
  local key=$1
  local operation=$2
  local value=${3:-}
  local mode
  local temporary

  mode=$(file_mode "$ENV_FILE") || return 1
  temporary=$(mktemp "${ENV_FILE}.rebuild-app.XXXXXX") || return 1
  chmod "$mode" "$temporary" || {
    rm -f "$temporary"
    return 1
  }

  if [[ "$operation" == set ]]; then
    awk -v key="$key" -v value="$value" '
      BEGIN { replaced = 0 }
      $0 ~ "^" key "=" {
        if (!replaced) print key "=" value
        replaced = 1
        next
      }
      { print }
      END { if (!replaced) print key "=" value }
    ' "$ENV_FILE" >"$temporary" || {
      rm -f "$temporary"
      return 1
    }
  else
    awk -v key="$key" '$0 !~ "^" key "=" { print }' "$ENV_FILE" >"$temporary" || {
      rm -f "$temporary"
      return 1
    }
  fi

  mv -f -- "$temporary" "$ENV_FILE"
}

atomic_set_env() {
  local key=$1
  local value=$2
  local count

  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "Invalid environment key: ${key}"
  count=$(awk -v key="$key" '$0 ~ "^" key "=" { count++ } END { print count + 0 }' "$ENV_FILE") || \
    die "Unable to inspect ${ENV_FILE}."
  ((count <= 1)) || die "Duplicate ${key} definitions in ${ENV_FILE}."

  PREVIOUS_ENV_KEY=$key
  if ((count == 1)); then
    PREVIOUS_ENV_PRESENT=1
    PREVIOUS_ENV_VALUE=$(awk -v key="$key" '$0 ~ "^" key "=" { print substr($0, index($0, "=") + 1) }' "$ENV_FILE")
  else
    PREVIOUS_ENV_PRESENT=0
    PREVIOUS_ENV_VALUE=""
  fi

  rewrite_env_key "$key" set "$value" || die "Unable to atomically update ${ENV_FILE}."
  ENV_MUTATED=1
}

restore_image_tag() {
  [[ "${ENV_MUTATED:-0}" == 1 ]] || return 0
  if ((PREVIOUS_ENV_PRESENT)); then
    rewrite_env_key "$PREVIOUS_ENV_KEY" set "$PREVIOUS_ENV_VALUE" || return 1
  else
    rewrite_env_key "$PREVIOUS_ENV_KEY" remove || return 1
  fi
  ENV_MUTATED=0
}

create_run_directory() {
  local state_dir=${REBUILD_APP_STATE_DIR:-${ROOT_DIR}/.rebuild-app}
  local timestamp
  timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
  RUN_DIR="${state_dir}/runs/${timestamp}"
  if [[ -e "$RUN_DIR" ]]; then
    RUN_DIR="${RUN_DIR}.$$"
  fi
  mkdir -p "$(dirname "$RUN_DIR")"
  mkdir -m 700 "$RUN_DIR" || die "Unable to create rebuild run directory."
  chmod 700 "$RUN_DIR"
}

write_run_state() {
  local outcome=$1
  local exit_status=$2
  local failed_step=${3:-none}
  local state_file

  [[ -n "${RUN_DIR:-}" ]] || return 0
  state_file="${RUN_DIR}/state.txt"
  {
    printf 'outcome=%s\n' "$outcome"
    printf 'phase=%s\n' "${PHASE:-unknown}"
    printf 'failed_step=%s\n' "$failed_step"
    printf 'exit_status=%s\n' "$exit_status"
    printf 'current_image=%s\n' "${CURRENT_IMAGE:-unknown}"
    printf 'current_image_id=%s\n' "${CURRENT_IMAGE_ID:-unknown}"
    printf 'current_app_version=%s\n' "${CURRENT_APP_VERSION:-unknown}"
    printf 'target_image=%s\n' "${TARGET_IMAGE:-unknown}"
    printf 'target_image_id=%s\n' "${TARGET_IMAGE_ID:-unknown}"
    printf 'target_app_version=%s\n' "${TARGET_APP_VERSION:-unknown}"
    printf 'app_volume_before=%s\n' "${APP_VOLUME_IDENTITY:-unknown}"
    printf 'data_volume_before=%s\n' "${DATA_VOLUME_IDENTITY:-unknown}"
    printf 'logs_volume_before=%s\n' "${LOGS_VOLUME_IDENTITY:-unknown}"
    printf 'db_volume_before=%s\n' "${DB_VOLUME_IDENTITY:-unknown}"
    printf 'trigger_storage_before=%s\n' "${TRIGGER_STORAGE_VOLUME_IDENTITY:-unknown}"
    printf 'app_volume_after=%s\n' "${FINAL_APP_VOLUME_IDENTITY:-unknown}"
    printf 'data_volume_after=%s\n' "${FINAL_DATA_VOLUME_IDENTITY:-unknown}"
    printf 'logs_volume_after=%s\n' "${FINAL_LOGS_VOLUME_IDENTITY:-unknown}"
    printf 'db_volume_after=%s\n' "${FINAL_DB_VOLUME_IDENTITY:-unknown}"
    printf 'trigger_storage_after=%s\n' "${FINAL_TRIGGER_STORAGE_VOLUME_IDENTITY:-unknown}"
  } >"$state_file"
  chmod 600 "$state_file"
}
