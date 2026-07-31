#!/usr/bin/env bash

compose() {
  docker compose "${COMPOSE_ARGS[@]}" "$@"
}

configure_compose() {
  COMPOSE_ARGS=(-f "${ROOT_DIR}/docker-compose.simple-install.yml")
  if [[ "$EDITION" == enterprise ]]; then
    COMPOSE_ARGS+=(-f "${ROOT_DIR}/docker-compose.simple-install.enterprise.yml")
  fi
}

detect_installation() {
  local detected_edition
  local running

  running=$(docker inspect --format '{{.State.Running}}' eramba 2>/dev/null) || \
    die "An existing running eramba container is required."
  [[ "$running" == true ]] || die "An existing running eramba container is required."

  CURRENT_IMAGE=$(docker inspect --format '{{.Config.Image}}' eramba) || \
    die "Unable to inspect the running eramba image."

  if [[ "$CURRENT_IMAGE" =~ ^ghcr\.io/eramba/eramba:([^:@]+)$ ]]; then
    detected_edition=community
    CURRENT_IMAGE_REPOSITORY=ghcr.io/eramba/eramba
  elif [[ "$CURRENT_IMAGE" =~ ^ghcr\.io/eramba/eramba-enterprise:([^:@]+)$ ]]; then
    detected_edition=enterprise
    CURRENT_IMAGE_REPOSITORY=ghcr.io/eramba/eramba-enterprise
  else
    die "Unable to detect edition from running image: ${CURRENT_IMAGE}"
  fi
  CURRENT_IMAGE_TAG=${BASH_REMATCH[1]}

  if [[ -n "$EDITION" && "$EDITION" != "$detected_edition" ]]; then
    die "Requested edition conflicts with the running image."
  fi
  EDITION=$detected_edition
  configure_compose

  CURRENT_APP_VERSION=$(docker exec -w /var/www/eramba/app/upgrade -u www-data \
    eramba cat /var/www/eramba/app/upgrade/VERSION) || \
    die "Unable to read the current application version."
  CURRENT_APP_VERSION=${CURRENT_APP_VERSION//$'\r'/}
  CURRENT_APP_VERSION=${CURRENT_APP_VERSION//$'\n'/}
  [[ -n "$CURRENT_APP_VERSION" ]] || die "Current application version is empty."

  CURRENT_IMAGE_ID=$(docker image inspect --format '{{.Id}}' "$CURRENT_IMAGE") || \
    die "Unable to inspect the current application image ID."
  [[ -n "$CURRENT_IMAGE_ID" ]] || die "Current application image ID is empty."
}

validate_delivery_options() {
  if [[ "$EDITION" == community ]]; then
    [[ -z "$IMAGE_FILE" ]] || die "--image-file is only valid for enterprise"
  else
    [[ -n "$IMAGE_FILE" ]] || die "--image-file is required for enterprise"
    [[ -r "$IMAGE_FILE" && -f "$IMAGE_FILE" ]] || die "Enterprise image archive is not readable: ${IMAGE_FILE}"
  fi
}

check_current_deployment() {
  application_exec eramba curl -kfsS -o /dev/null https://localhost:443 || \
    die "Current application HTTP readiness check failed."
  application_exec eramba bin/cake current_config validate >/dev/null 2>&1 || \
    die "Current configuration validation failed."
  application_exec eramba bin/cake system_health check || \
    die "Current system health check failed."
  application_exec cron bin/cake migrations status || \
    die "Current migrations status check failed."
}

acquire_target_image() {
  if [[ "$EDITION" == community ]]; then
    docker pull "$TARGET_IMAGE" || die "Unable to pull target image: ${TARGET_IMAGE}"
  else
    docker load --input "$IMAGE_FILE" || die "Unable to load Enterprise image archive."
    docker image inspect "$TARGET_IMAGE" >/dev/null 2>&1 || \
      die "Enterprise archive did not provide the planned image: ${TARGET_IMAGE}"
  fi
}

normalize_architecture() {
  case "$1" in
    x86_64 | amd64) printf '%s\n' amd64 ;;
    aarch64 | arm64) printf '%s\n' arm64 ;;
    *) printf '%s\n' "$1" ;;
  esac
}

read_target_version() {
  local container_id
  local version_file
  local version

  version_file=$(mktemp "${TMPDIR:-/tmp}/rebuild-app-version.XXXXXX") || \
    die "Unable to create target inspection file."
  if ! container_id=$(docker create --entrypoint /bin/true "$TARGET_IMAGE"); then
    rm -f "$version_file"
    die "Unable to create target image inspection container."
  fi

  if ! docker cp "${container_id}:/var/www/eramba/app/upgrade/VERSION" "$version_file"; then
    docker rm -f "$container_id" >/dev/null 2>&1 || true
    rm -f "$version_file"
    die "Unable to read VERSION from target image."
  fi
  version=$(tr -d '\r\n' <"$version_file")
  docker rm -f "$container_id" >/dev/null 2>&1 || true
  rm -f "$version_file"
  printf '%s\n' "$version"
}

validate_target_image() {
  local host_arch
  local image_arch
  local repo_tags
  local target_version

  repo_tags=$(docker image inspect --format '{{json .RepoTags}}' "$TARGET_IMAGE") || \
    die "Unable to inspect target image tags."
  [[ "$repo_tags" == *"\"${TARGET_IMAGE}\""* ]] || \
    die "Target image repository or tag does not match the plan."

  image_arch=$(docker image inspect --format '{{.Architecture}}' "$TARGET_IMAGE") || \
    die "Unable to inspect target image architecture."
  host_arch=$(docker info --format '{{.Architecture}}') || \
    die "Unable to inspect Docker host architecture."
  [[ "$(normalize_architecture "$image_arch")" == "$(normalize_architecture "$host_arch")" ]] || \
    die "Target image architecture does not match the Docker host."

  target_version=$(read_target_version)
  [[ "$target_version" == "$TARGET_APP_VERSION" ]] || \
    die "Target application version does not match the plan."

  TARGET_IMAGE_ID=$(docker image inspect --format '{{.Id}}' "$TARGET_IMAGE") || \
    die "Unable to inspect target image ID."
  [[ -n "$TARGET_IMAGE_ID" ]] || die "Target image ID is empty."
}

volume_name_at_destination() {
  local container=$1
  local destination=$2
  local template
  local name

  [[ "$destination" == /* && "$destination" != *'"'* ]] || \
    die "Invalid mount destination: ${destination}"
  template="{{range .Mounts}}{{if eq .Destination \"${destination}\"}}{{println .Name}}{{end}}{{end}}"
  name=$(docker inspect --format "$template" "$container") || \
    die "Unable to inspect ${container} mount at ${destination}."
  name=${name%$'\n'}
  [[ -n "$name" && "$name" != *$'\n'* ]] || \
    die "Expected exactly one named volume for ${container}:${destination}."
  printf '%s\n' "$name"
}

volume_identity() {
  local container=$1
  local destination=$2
  local name
  local created_at

  name=$(volume_name_at_destination "$container" "$destination")
  created_at=$(docker volume inspect --format '{{.CreatedAt}}' "$name") || \
    die "Unable to inspect Docker volume: ${name}"
  [[ -n "$created_at" ]] || die "Docker volume has no creation identity: ${name}"
  printf '%s|%s\n' "$name" "$created_at"
}

snapshot_volume_identities() {
  APP_VOLUME_IDENTITY=$(volume_identity eramba /var/www/eramba)
  DATA_VOLUME_IDENTITY=$(volume_identity eramba /var/www/eramba/app/upgrade/data)
  LOGS_VOLUME_IDENTITY=$(volume_identity eramba /var/www/eramba/app/upgrade/logs)
  DB_VOLUME_IDENTITY=$(volume_identity mysql /var/lib/mysql)
  TRIGGER_STORAGE_VOLUME_IDENTITY=$(volume_identity triggers_caddy /data/eramba_trigger_storage)
  APP_VOLUME_NAME=${APP_VOLUME_IDENTITY%%|*}
}

stop_application_services() {
  local service
  for service in triggers_caddy cron eramba; do
    compose stop "$service"
    compose rm -f "$service"
  done
}

remove_verified_app_volume() {
  local current_identity
  local current_name

  compose create eramba
  if ! current_identity=$(volume_identity eramba /var/www/eramba); then
    compose rm -f eramba >/dev/null 2>&1 || true
    die "Unable to re-verify the application volume."
  fi
  compose rm -f eramba
  current_name=${current_identity%%|*}
  [[ "$current_name" == "$APP_VOLUME_NAME" ]] || \
    die "Application volume changed after preflight; refusing deletion."
  docker volume rm -- "$APP_VOLUME_NAME" || die "Unable to remove application volume: ${APP_VOLUME_NAME}"
}

recover_before_migration() {
  local recovered=1

  if restore_image_tag; then
    compose up -d eramba cron triggers_caddy || recovered=0
  else
    recovered=0
  fi
  if ((recovered)); then
    log "Pre-migration recovery succeeded; the previous image tag and application services were restored."
  else
    log "Pre-migration recovery failed; operator intervention is required."
  fi
  return 0
}

application_exec() {
  docker exec -w /var/www/eramba/app/upgrade -u www-data "$@"
}

wait_for_application_http() {
  local timeout=${REBUILD_APP_START_TIMEOUT_SECONDS:-300}
  local interval=${REBUILD_APP_POLL_INTERVAL_SECONDS:-2}
  local deadline=$((SECONDS + timeout))

  while true; do
    if application_exec eramba curl -kfsS -o /dev/null https://localhost:443; then
      return 0
    fi
    ((SECONDS >= deadline)) && die "Timed out waiting for the target eramba HTTP endpoint."
    sleep "$interval"
  done
}

start_and_verify_eramba() {
  local running_version

  PHASE=migration-boundary
  FAILED_STEP=start-target-eramba
  compose up -d eramba

  FAILED_STEP=wait-for-target-http
  wait_for_application_http

  FAILED_STEP=verify-target-version
  running_version=$(application_exec eramba cat /var/www/eramba/app/upgrade/VERSION) || \
    die "Unable to read the running target application version."
  running_version=${running_version//$'\r'/}
  running_version=${running_version//$'\n'/}
  [[ "$running_version" == "$TARGET_APP_VERSION" ]] || \
    die "Running application version does not match the plan."

  FAILED_STEP=validate-target-config
  application_exec eramba bin/cake current_config validate >/dev/null 2>&1 || \
    die "Target configuration validation failed."
  FAILED_STEP=check-target-health
  application_exec eramba bin/cake system_health check
  ERAMBA_VERIFIED=1
}

start_and_verify_cron() {
  FAILED_STEP=start-target-cron
  compose up -d cron
  FAILED_STEP=check-target-migrations
  application_exec cron bin/cake migrations status
  CRON_VERIFIED=1
}

wait_for_trigger_health() {
  local timeout=${REBUILD_APP_START_TIMEOUT_SECONDS:-300}
  local interval=${REBUILD_APP_POLL_INTERVAL_SECONDS:-2}
  local deadline=$((SECONDS + timeout))
  local health

  while true; do
    health=$(docker inspect --format '{{.State.Health.Status}}' triggers_caddy 2>/dev/null || true)
    [[ "$health" == healthy ]] && return 0
    ((SECONDS >= deadline)) && die "Timed out waiting for triggers_caddy health."
    sleep "$interval"
  done
}

start_and_verify_triggers() {
  FAILED_STEP=start-target-triggers
  compose up -d triggers_caddy
  FAILED_STEP=check-target-triggers-health
  wait_for_trigger_health
  TRIGGERS_VERIFIED=1
}

verify_final_deployment() {
  local eramba_image
  local cron_image

  FAILED_STEP=verify-final-images
  eramba_image=$(docker inspect --format '{{.Config.Image}}' eramba) || \
    die "Unable to inspect final eramba image."
  cron_image=$(docker inspect --format '{{.Config.Image}}' cron) || \
    die "Unable to inspect final cron image."
  [[ "$eramba_image" == "$TARGET_IMAGE" && "$cron_image" == "$TARGET_IMAGE" ]] || \
    die "Final application services do not use the planned image."

  FAILED_STEP=verify-final-volumes
  FINAL_APP_VOLUME_IDENTITY=$(volume_identity eramba /var/www/eramba)
  FINAL_DATA_VOLUME_IDENTITY=$(volume_identity eramba /var/www/eramba/app/upgrade/data)
  FINAL_LOGS_VOLUME_IDENTITY=$(volume_identity eramba /var/www/eramba/app/upgrade/logs)
  FINAL_DB_VOLUME_IDENTITY=$(volume_identity mysql /var/lib/mysql)
  FINAL_TRIGGER_STORAGE_VOLUME_IDENTITY=$(volume_identity triggers_caddy /data/eramba_trigger_storage)

  [[ "$FINAL_APP_VOLUME_IDENTITY" != "$APP_VOLUME_IDENTITY" ]] || \
    die "Application volume identity did not change."
  [[ "$FINAL_DATA_VOLUME_IDENTITY" == "$DATA_VOLUME_IDENTITY" ]] || \
    die "Preserved volume identity changed: application data."
  [[ "$FINAL_LOGS_VOLUME_IDENTITY" == "$LOGS_VOLUME_IDENTITY" ]] || \
    die "Preserved volume identity changed: application logs."
  [[ "$FINAL_DB_VOLUME_IDENTITY" == "$DB_VOLUME_IDENTITY" ]] || \
    die "Preserved volume identity changed: MySQL data."
  [[ "$FINAL_TRIGGER_STORAGE_VOLUME_IDENTITY" == "$TRIGGER_STORAGE_VOLUME_IDENTITY" ]] || \
    die "Preserved volume identity changed: trigger storage."
}

quiesce_unverified_dependents() {
  if [[ "${TRIGGERS_VERIFIED:-0}" != 1 ]]; then
    compose stop triggers_caddy >/dev/null 2>&1 || true
  fi
  if [[ "${CRON_VERIFIED:-0}" != 1 ]]; then
    compose stop cron >/dev/null 2>&1 || true
  fi
}

capture_diagnostics() {
  local exit_status=$1
  local service
  local inspect_template

  [[ -n "${RUN_DIR:-}" ]] || return 0
  write_run_state failed "$exit_status" "${FAILED_STEP:-unknown}" || true

  compose ps >"${RUN_DIR}/compose-ps.txt" 2>&1 || true
  chmod 600 "${RUN_DIR}/compose-ps.txt" 2>/dev/null || true

  inspect_template='{"name":{{json .Name}},"image":{{json .Config.Image}},"image_id":{{json .Image}},"state":{{json .State}},"mounts":{{json .Mounts}}}'
  for service in eramba cron mysql redis triggers_caddy; do
    docker inspect --format "$inspect_template" "$service" \
      >"${RUN_DIR}/${service}-inspect.json" 2>&1 || true
    chmod 600 "${RUN_DIR}/${service}-inspect.json" 2>/dev/null || true
    docker logs --tail 500 "$service" >"${RUN_DIR}/${service}.log" 2>&1 || true
    chmod 600 "${RUN_DIR}/${service}.log" 2>/dev/null || true
  done
}
