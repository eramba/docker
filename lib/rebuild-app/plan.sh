#!/usr/bin/env bash

plan_field() {
  local field=$1
  printf '%s' "$PLAN_JSON" | docker exec -i eramba php -r '
    $data = json_decode(stream_get_contents(STDIN), true, 512, JSON_THROW_ON_ERROR);
    $field = $argv[1];
    if (!array_key_exists($field, $data) || (!is_string($data[$field]) && !is_bool($data[$field]))) {
        exit(2);
    }
    echo is_bool($data[$field]) ? ($data[$field] ? "true" : "false") : $data[$field];
  ' "$field"
}

require_plan_field() {
  local field=$1
  local value
  value=$(plan_field "$field") || die "Invalid image switch plan: missing or invalid ${field}."
  [[ -n "$value" ]] || die "Invalid image switch plan: empty ${field}."
  printf '%s\n' "$value"
}

resolve_plan() {
  PLAN_JSON=$(docker exec -w /var/www/eramba/app/upgrade -u www-data eramba \
    bin/cake image_switch_plan --current-image-tag "$CURRENT_IMAGE_TAG" --format json) || \
    die "Unable to resolve the canonical image switch plan."

  PLAN_REQUIRED=$(plan_field required) || die "Invalid image switch plan: missing or invalid required."
  if [[ "$PLAN_REQUIRED" == false ]]; then
    return 0
  fi
  [[ "$PLAN_REQUIRED" == true ]] || die "Invalid image switch plan: required must be boolean."

  SOURCE_APP_VERSION=$(require_plan_field source_app_version)
  TARGET_APP_VERSION=$(require_plan_field target_app_version)
  PLAN_CURRENT_IMAGE_TAG=$(require_plan_field current_image_tag)
  TARGET_IMAGE_TAG=$(require_plan_field target_image_tag)
  PLAN_EDITION=$(require_plan_field edition)
  DISTRIBUTION=$(require_plan_field distribution)

  [[ "$SOURCE_APP_VERSION" == "$CURRENT_APP_VERSION" ]] || \
    die "Plan source application version does not match the running deployment."
  [[ "$PLAN_CURRENT_IMAGE_TAG" == "$CURRENT_IMAGE_TAG" ]] || \
    die "Plan current image tag does not match the running deployment."
  [[ "$PLAN_EDITION" == "$EDITION" ]] || die "Plan edition does not match the running deployment."
  [[ "$TARGET_IMAGE_TAG" != latest && "$TARGET_IMAGE_TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || \
    die "Invalid image switch plan: target image tag must be immutable."

  if [[ "$EDITION" == community ]]; then
    [[ "$DISTRIBUTION" == registry ]] || die "Community plans require registry distribution."
    TARGET_IMAGE_REPOSITORY=ghcr.io/eramba/eramba
  else
    [[ "$DISTRIBUTION" == archive ]] || die "Enterprise plans require archive distribution."
    TARGET_IMAGE_REPOSITORY=ghcr.io/eramba/eramba-enterprise
  fi
  TARGET_IMAGE="${TARGET_IMAGE_REPOSITORY}:${TARGET_IMAGE_TAG}"
}
