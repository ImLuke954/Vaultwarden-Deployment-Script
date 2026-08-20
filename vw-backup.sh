#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

CONFIG=/etc/vaultwarden/install.env
LOCK_FILE=/run/lock/vaultwarden-operation.lock
STAGE_ROOT=/var/lib/vaultwarden/backup-staging

log() {
    printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"
}

die() {
    printf '[%s] ERROR: %s\n' "$(date -u +%FT%TZ)" "$*" >&2
    exit 1
}

on_error() {
    local rc=$?
    printf '[%s] ERROR: backup failed near line %s (exit %s)\n' \
        "$(date -u +%FT%TZ)" "$1" "$rc" >&2
    exit "$rc"
}

trap 'on_error "$LINENO"' ERR

[[ "$EUID" -eq 0 ]] || die 'backup helper must run as root'
[[ -r "$CONFIG" ]] || die "missing $CONFIG; run vw-deploy.sh first"
[[ -r /etc/os-release ]] || die 'cannot identify operating system'
command -v flock >/dev/null || die 'flock is required'
command -v rclone >/dev/null || die 'rclone is required'
command -v sqlite3 >/dev/null || die 'sqlite3 is required'
command -v sha256sum >/dev/null || die 'sha256sum is required'

# This file is generated from validated values by vw-deploy.sh.
# shellcheck disable=SC1090,SC1091
source "$CONFIG"
: "${APP_DIR:?APP_DIR is missing from install.env}"
: "${DATA_DIR:?DATA_DIR is missing from install.env}"
: "${COMPOSE_FILE:?COMPOSE_FILE is missing from install.env}"
: "${VAULTWARDEN_IMAGE:?VAULTWARDEN_IMAGE is missing from install.env}"
: "${RCLONE_REMOTE:?RCLONE_REMOTE is missing from install.env}"
: "${BACKUP_PREFIX:=}"
: "${BACKUP_RETENTION:?BACKUP_RETENTION is missing from install.env}"
: "${BACKUP_INSTANCE_ID:=}"
[[ "$BACKUP_RETENTION" =~ ^[1-9][0-9]*$ ]] || die 'BACKUP_RETENTION is invalid'
if [[ -z "$BACKUP_INSTANCE_ID" ]]; then
    [[ -r /etc/machine-id ]] || die 'BACKUP_INSTANCE_ID is missing and /etc/machine-id is unavailable'
    BACKUP_INSTANCE_ID=$(sha256sum /etc/machine-id | awk '{print substr($1, 1, 32)}')
fi
[[ "$BACKUP_INSTANCE_ID" =~ ^[a-f0-9]{32}$ ]] || die 'BACKUP_INSTANCE_ID is invalid'

RCLONE_CONFIG=/etc/vaultwarden/rclone/rclone.conf
[[ -r "$RCLONE_CONFIG" ]] || die "missing $RCLONE_CONFIG"
remote_type=$(rclone --config "$RCLONE_CONFIG" config show "$RCLONE_REMOTE" 2>/dev/null | \
    awk -F= '$1 ~ /^[[:space:]]*type[[:space:]]*$/ && !found { value = $2; gsub(/[[:space:]]/, "", value); print value; found = 1 }')
[[ "$remote_type" == crypt ]] || die "rclone remote '$RCLONE_REMOTE' is not a Crypt remote"
remote_target=$(rclone --config "$RCLONE_CONFIG" config show "$RCLONE_REMOTE" 2>/dev/null | \
    awk -F= '$1 ~ /^[[:space:]]*remote[[:space:]]*$/ && !found { value = $2; sub(/^[[:space:]]*/, "", value); sub(/[[:space:]]*$/, "", value); print value; found = 1 }')
[[ -n "$remote_target" ]] || die "rclone Crypt remote '$RCLONE_REMOTE' has no underlying remote"
remote_target_name=${remote_target%%:*}
[[ "$remote_target_name" != "$RCLONE_REMOTE" ]] || \
    die "rclone Crypt remote '$RCLONE_REMOTE' points to itself; set its remote = value to a different storage remote"

if docker compose version >/dev/null 2>&1; then
    COMPOSE_KIND=plugin
elif command -v docker-compose >/dev/null; then
    COMPOSE_KIND=standalone
else
    die 'Docker Compose is not available'
fi

compose() {
    if [[ "$COMPOSE_KIND" == plugin ]]; then
        docker compose --project-directory "$APP_DIR" "$@"
    else
        docker-compose --project-directory "$APP_DIR" "$@"
    fi
}

resolve_deployment_image() {
    local compose_image container_image
    [[ -r "$APP_DIR/.env" ]] || die "missing $APP_DIR/.env"
    compose_image=$(awk -F= '$1 == "VAULTWARDEN_IMAGE" { print substr($0, index($0, "=") + 1); exit }' \
        "$APP_DIR/.env")
    [[ "$compose_image" =~ ^vaultwarden/server:[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
        die 'active Compose image is invalid or not pinned'
    VAULTWARDEN_IMAGE=$compose_image
    container_image=$(docker inspect -f '{{.Config.Image}}' vaultwarden 2>/dev/null || true)
    if [[ -n "$container_image" ]]; then
        [[ "$container_image" =~ ^vaultwarden/server:[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
            die 'configured Vaultwarden container image is invalid or not pinned'
        VAULTWARDEN_IMAGE=$container_image
    fi
}

remote_root_path() {
    if [[ -n "$BACKUP_PREFIX" ]]; then
        printf '%s:%s' "$RCLONE_REMOTE" "$BACKUP_PREFIX"
    else
        printf '%s:' "$RCLONE_REMOTE"
    fi
}

remote_object_path() {
    local relative=$1 root
    root=$(remote_root_path)
    if [[ -n "$BACKUP_PREFIX" ]]; then
        printf '%s/%s' "$root" "$relative"
    else
        printf '%s%s' "$root" "$relative"
    fi
}

mkdir -p "$STAGE_ROOT" /run/lock
chmod 0700 "$STAGE_ROOT"
exec 9>"$LOCK_FILE"
flock -n 9 || die 'another Vaultwarden operation is already running'
resolve_deployment_image

[[ -d "$DATA_DIR" ]] || die "missing Vaultwarden data directory: $DATA_DIR"
[[ -f "$DATA_DIR/db.sqlite3" ]] || die 'db.sqlite3 is missing; refusing to create an incomplete backup'
if find -P "$DATA_DIR" \( -type l -o \( -type f -links +1 \) -o \( ! -type d -a ! -type f \) \) -print -quit | grep -q .; then
    die 'data directory contains links or special filesystem entries, which are not supported by restore'
fi

RUN_STAGE=$(mktemp -d "$STAGE_ROOT/run.XXXXXX")
RUNNING=0
cleanup() {
    local rc=$?
    if [[ "$RUNNING" == 1 ]]; then
        log 'restarting Vaultwarden after backup'
        if ! compose -f "$COMPOSE_FILE" up -d vaultwarden >/dev/null; then
            printf '[%s] ERROR: Vaultwarden could not be restarted\n' "$(date -u +%FT%TZ)" >&2
            rc=1
        fi
    fi
    rm -rf -- "$RUN_STAGE"
    exit "$rc"
}
trap cleanup EXIT

if [[ "$(docker inspect -f '{{.State.Running}}' vaultwarden 2>/dev/null || true)" == true ]]; then
    RUNNING=1
    log 'stopping Vaultwarden for a consistent SQLite/filesystem backup'
    compose -f "$COMPOSE_FILE" stop vaultwarden >/dev/null
fi

timestamp=$(date -u +%Y-%m-%dT%H%M%SZ)
archive_name="vaultwarden-$BACKUP_INSTANCE_ID-$timestamp.tar.gz"
archive="$RUN_STAGE/$archive_name"
checksum="$RUN_STAGE/$archive_name.sha256"
manifest="$RUN_STAGE/${archive_name%.tar.gz}.manifest.json"

tar -czf "$archive" -C "$(dirname "$DATA_DIR")" "$(basename "$DATA_DIR")"
archive_hash=$(sha256sum "$archive" | awk '{print $1}')
printf '%s  %s\n' "$archive_hash" "$archive_name" > "$checksum"
jq -n \
    --arg archive "$archive_name" \
    --arg timestamp "$timestamp" \
    --arg image "$VAULTWARDEN_IMAGE" \
    --arg sha256 "$archive_hash" \
    --arg backup_instance_id "$BACKUP_INSTANCE_ID" \
    '{archive_format: 1, archive: $archive, created_at: $timestamp, vaultwarden_image: $image, sha256: $sha256, backup_instance_id: $backup_instance_id}' \
    > "$manifest"

remote_archive=$(remote_object_path "$archive_name")
remote_checksum=$(remote_object_path "$archive_name.sha256")
remote_manifest=$(remote_object_path "${archive_name%.tar.gz}.manifest.json")
log "uploading encrypted backup to $RCLONE_REMOTE"
rclone --config "$RCLONE_CONFIG" copyto "$archive" "$remote_archive"
rclone --config "$RCLONE_CONFIG" copyto "$checksum" "$remote_checksum"
rclone --config "$RCLONE_CONFIG" copyto "$manifest" "$remote_manifest"

remote_verify="$RUN_STAGE/remote-verify.tar.gz"
rclone --config "$RCLONE_CONFIG" cat "$remote_archive" > "$remote_verify"
local_hash=$archive_hash
remote_hash=$(sha256sum "$remote_verify" | awk '{print $1}')
[[ "$local_hash" == "$remote_hash" ]] || die 'remote backup verification failed'
log "verified $archive_name ($local_hash)"

remote_listing="$RUN_STAGE/remote-list"
rclone --config "$RCLONE_CONFIG" lsf --files-only --recursive "$(remote_root_path)" > "$remote_listing"
mapfile -t archives < <(
    while IFS= read -r archive_candidate; do
        [[ "$archive_candidate" =~ ^vaultwarden-${BACKUP_INSTANCE_ID}-[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z\.tar\.gz$ ]] || continue
        printf '%s\n' "$archive_candidate"
    done < "$remote_listing" | sort -r
)
if ((${#archives[@]} > BACKUP_RETENTION)); then
    for ((index=BACKUP_RETENTION; index<${#archives[@]}; index++)); do
        old=${archives[index]}
        [[ "$old" == *.tar.gz && "$old" != /* && "$old" != *..* ]] || die "unsafe remote archive name: $old"
        log "removing expired remote backup $old"
        rclone --config "$RCLONE_CONFIG" deletefile "$(remote_object_path "$old")"
        rclone --config "$RCLONE_CONFIG" deletefile "$(remote_object_path "$old.sha256")" >/dev/null 2>&1 || true
        old_manifest=${old%.tar.gz}.manifest.json
        rclone --config "$RCLONE_CONFIG" deletefile "$(remote_object_path "$old_manifest")" >/dev/null 2>&1 || true
    done
fi

log 'encrypted backup completed successfully'
