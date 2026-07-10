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
}

validate_delivery_options() {
  if [[ "$EDITION" == community ]]; then
    [[ -z "$IMAGE_FILE" ]] || die "--image-file is only valid for enterprise"
  else
    [[ -n "$IMAGE_FILE" ]] || die "--image-file is required for enterprise"
    [[ -r "$IMAGE_FILE" && -f "$IMAGE_FILE" ]] || die "Enterprise image archive is not readable: ${IMAGE_FILE}"
  fi
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

  current_identity=$(volume_identity eramba /var/www/eramba)
  current_name=${current_identity%%|*}
  [[ "$current_name" == "$APP_VOLUME_NAME" ]] || \
    die "Application volume changed after preflight; refusing deletion."
  docker volume rm -- "$APP_VOLUME_NAME" || die "Unable to remove application volume: ${APP_VOLUME_NAME}"
}

recover_before_migration() {
  local recovered=1

  restore_image_tag || recovered=0
  compose up -d eramba cron triggers_caddy || recovered=0
  if ((recovered)); then
    log "Pre-migration recovery succeeded; the previous image tag and application services were restored."
  else
    log "Pre-migration recovery failed; operator intervention is required."
  fi
  return 0
}
