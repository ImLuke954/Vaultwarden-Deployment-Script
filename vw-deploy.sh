#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(builtin cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_DIR=/opt/vaultwarden
ETC_DIR=/etc/vaultwarden
INSTALL_ENV=$ETC_DIR/install.env
VAULTWARDEN_ENV=$ETC_DIR/vaultwarden.env
RCLONE_DIR=$ETC_DIR/rclone
RCLONE_CONFIG=$RCLONE_DIR/rclone.conf
RESTORE_ROOT=/var/lib/vaultwarden/restore
LOCK_FILE=/run/lock/vaultwarden-operation.lock
STATE_FILE=/var/lib/vaultwarden/deploy.state
COMPOSE_FILE=$APP_DIR/compose.yml
NGINX_SITE=/etc/nginx/sites-available/vaultwarden.conf
NGINX_LINK=/etc/nginx/sites-enabled/vaultwarden.conf
CERTBOT_HOOK=/etc/letsencrypt/renewal-hooks/deploy/vaultwarden-nginx-reload
PUBLIC_CHECK_API=https://check-host.net

MODE=
DOMAIN=
LETSENCRYPT_EMAIL=
IMAGE_TAG=
VAULTWARDEN_IMAGE=
ADMIN_TOKEN_HASH=
RCLONE_REMOTE=
BACKUP_PREFIX=
BACKUP_PREFIX_RESUMED=0
BACKUP_RETENTION=30
RETENTION_SET=0
BACKUP_SELECTION=
DRY_RUN=0
RESUME=0
COMPOSE_KIND=
STAGE_DIR=
RESTORE_DATA_SOURCE=
RESTORED_ARCHIVE=
RESTORE_OLD_RUNNING=0
RESTORE_OLD_PRESENT=0
RESTORE_OLD_CONTAINER_ID=
RESTORE_NEW_CONTAINER_ATTEMPTED=0
RESTORE_ROLLBACK_DIR=
RESTORE_CONFIG_ROLLBACK_DIR=
RESTORE_NGINX_ROLLBACK_DIR=
RESTORE_COMMITTED=0

usage() {
    cat <<'USAGE'
Usage: sudo ./vw-deploy.sh [options]

Interactive mode presents the two supported operations. Options can be used
for unattended values, but secrets are always read from standard input.

Options:
  --mode fresh|restore       Select the operation without the menu
  --domain DOMAIN            Public Vaultwarden DNS name
  --email ADDRESS            Let's Encrypt notification address
  --image-tag TAG            Pinned vaultwarden/server image tag
  --rclone-remote NAME       rclone Crypt remote (default: gcrypt)
  --backup-prefix PATH       Path below the Crypt remote
  --retention COUNT          Number of remote archives to keep (default: 30)
  --backup NAME|latest       Archive to restore
  --resume                   Reuse existing deployment settings where possible
  --dry-run                  Print the selected operation and exit
  -h, --help                 Show this help

Examples:
  sudo ./vw-deploy.sh
  sudo ./vw-deploy.sh --mode restore --domain vault.example.com \
      --backup latest --image-tag 1.34.3
USAGE
}

log() {
    printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"
}

warn() {
    printf '[%s] WARNING: %s\n' "$(date -u +%FT%TZ)" "$*" >&2
}

die() {
    printf '[%s] ERROR: %s\n' "$(date -u +%FT%TZ)" "$*" >&2
    exit 1
}

on_error() {
    local rc=$?
    printf '[%s] ERROR: deployment failed near line %s (exit %s)\n' \
        "$(date -u +%FT%TZ)" "$1" "$rc" >&2
    exit "$rc"
}

cleanup() {
    local current_container_id
    if [[ "$MODE" == restore && "$RESTORE_COMMITTED" == 0 ]]; then
        if [[ "$RESTORE_NEW_CONTAINER_ATTEMPTED" == 1 ]] && \
           container_present vaultwarden; then
            current_container_id=$(docker inspect -f '{{.Id}}' vaultwarden 2>/dev/null || true)
            if [[ "$RESTORE_OLD_PRESENT" == 0 ]]; then
                docker rm -f vaultwarden >/dev/null 2>&1 || true
            elif [[ -n "$RESTORE_OLD_CONTAINER_ID" && \
                    "$current_container_id" != "$RESTORE_OLD_CONTAINER_ID" ]]; then
                docker rm -f vaultwarden >/dev/null 2>&1 || true
            fi
        fi
        if [[ -n "$RESTORE_ROLLBACK_DIR" && ( -e "$RESTORE_ROLLBACK_DIR" || -L "$RESTORE_ROLLBACK_DIR" ) ]]; then
            if existing_container_running; then
                docker stop vaultwarden >/dev/null 2>&1 || true
            fi
            if [[ -e "$APP_DIR/data" || -L "$APP_DIR/data" ]]; then
                mv "$APP_DIR/data" "$APP_DIR/data.failed-restore.$(date -u +%Y%m%dT%H%M%SZ)" || true
            fi
            mv "$RESTORE_ROLLBACK_DIR" "$APP_DIR/data" || true
            log 'restore failed; previous Vaultwarden data was put back'
        fi
        restore_previous_files || true
        restore_previous_nginx || true
        current_container_id=$(docker inspect -f '{{.Id}}' vaultwarden 2>/dev/null || true)
        if [[ "$RESTORE_OLD_PRESENT" == 1 && -n "$current_container_id" && \
              ( -z "$RESTORE_OLD_CONTAINER_ID" || \
                "$current_container_id" == "$RESTORE_OLD_CONTAINER_ID" ) ]]; then
            if [[ "$RESTORE_OLD_RUNNING" == 1 ]]; then
                docker start "$current_container_id" >/dev/null 2>&1 || true
            fi
        elif [[ "$RESTORE_OLD_RUNNING" == 1 ]]; then
            compose -f "$COMPOSE_FILE" up -d vaultwarden >/dev/null 2>&1 || true
        elif [[ "$RESTORE_OLD_PRESENT" == 1 ]]; then
            compose -f "$COMPOSE_FILE" create vaultwarden >/dev/null 2>&1 || true
        fi
    fi
    if [[ -n "$STAGE_DIR" && -d "$STAGE_DIR" ]]; then
        rm -rf -- "$STAGE_DIR"
    fi
}

trap 'on_error "$LINENO"' ERR
trap cleanup EXIT

parse_args() {
    while (($#)); do
        case "$1" in
            --mode)
                (($# >= 2)) || die "--mode requires fresh or restore"
                MODE=$2
                shift 2
                ;;
            --domain)
                (($# >= 2)) || die "--domain requires a value"
                DOMAIN=$2
                shift 2
                ;;
            --email)
                (($# >= 2)) || die "--email requires a value"
                LETSENCRYPT_EMAIL=$2
                shift 2
                ;;
            --image-tag)
                (($# >= 2)) || die "--image-tag requires a value"
                IMAGE_TAG=$2
                shift 2
                ;;
            --rclone-remote)
                (($# >= 2)) || die "--rclone-remote requires a value"
                RCLONE_REMOTE=$2
                shift 2
                ;;
            --backup-prefix)
                (($# >= 2)) || die "--backup-prefix requires a value"
                BACKUP_PREFIX=$2
                shift 2
                ;;
            --retention)
                (($# >= 2)) || die "--retention requires a value"
                BACKUP_RETENTION=$2
                RETENTION_SET=1
                shift 2
                ;;
            --backup)
                (($# >= 2)) || die "--backup requires a name or latest"
                BACKUP_SELECTION=$2
                shift 2
                ;;
            --resume)
                RESUME=1
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown option: $1"
                ;;
        esac
    done

    case "$MODE" in
        ''|fresh|restore) ;;
        *) die "--mode must be fresh or restore" ;;
    esac
}

normalize_domain() {
    DOMAIN=${DOMAIN#https://}
    DOMAIN=${DOMAIN#http://}
    DOMAIN=${DOMAIN%/}
}

validate_domain() {
    local domain=$1 label
    [[ ${#domain} -le 253 ]] || die "domain is too long"
    [[ "$domain" != *[!A-Za-z0-9.-]* ]] || die "invalid domain: $domain"
    [[ "$domain" != .* && "$domain" != *. ]] || die "invalid domain: $domain"
    [[ "$domain" != *..* ]] || die "invalid domain: $domain"
    IFS=. read -r -a labels <<< "$domain"
    ((${#labels[@]} >= 2)) || die "a public fully-qualified domain is required"
    for label in "${labels[@]}"; do
        [[ -n "$label" && ${#label} -le 63 ]] || die "invalid domain label"
        [[ "$label" != -* && "$label" != *- ]] || die "invalid domain label"
    done
}

validate_email() {
    [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || \
        die "invalid email address"
}

validate_remote_name() {
    [[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid rclone remote name"
}

validate_prefix() {
    local prefix=$1
    [[ "$prefix" != /* ]] || die "backup prefix must be relative"
    [[ "$prefix" != *..* ]] || die "backup prefix must not contain '..'"
    [[ "$prefix" != *$'\n'* && "$prefix" != *$'\r'* ]] || die "invalid backup prefix"
}

validate_image_tag() {
    local tag=$1
    [[ -n "$tag" ]] || die "a pinned Vaultwarden image tag is required"
    [[ "$tag" != latest ]] || die "latest is not permitted; use a pinned image tag"
    [[ "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid image tag"
}

set_image_from_tag() {
    IMAGE_TAG=$1
    validate_image_tag "$IMAGE_TAG"
    VAULTWARDEN_IMAGE="vaultwarden/server:$IMAGE_TAG"
}

set_image_from_ref() {
    local ref=$1 tag
    [[ "$ref" == vaultwarden/server:* ]] || die "manifest image must use vaultwarden/server"
    tag=${ref#vaultwarden/server:}
    set_image_from_tag "$tag"
}

prompt_value() {
    local variable=$1 prompt=$2 default=${3-} value
    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " value
        value=${value:-$default}
    else
        read -r -p "$prompt: " value
    fi
    [[ -n "$value" ]] || die "$variable is required"
    printf -v "$variable" '%s' "$value"
}

confirm() {
    local answer
    read -r -p "$1 [y/N]: " answer
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

select_mode() {
    [[ -n "$MODE" ]] && return
    [[ -t 0 ]] || die "--mode is required when standard input is not a terminal"
    printf '\nVaultwarden deployment mode:\n'
    printf '  1. Fresh installation\n'
    printf '  2. Restore from encrypted Google Drive backup\n\n'
    local choice
    read -r -p 'Choose 1 or 2: ' choice
    case "$choice" in
        1) MODE=fresh ;;
        2) MODE=restore ;;
        *) die "choose 1 or 2" ;;
    esac
}

load_resume_settings() {
    [[ "$RESUME" == 1 && -r "$INSTALL_ENV" ]] || return 0

    local cli_domain=$DOMAIN cli_email=$LETSENCRYPT_EMAIL cli_tag=$IMAGE_TAG
    local cli_remote=$RCLONE_REMOTE cli_prefix=$BACKUP_PREFIX cli_retention=$BACKUP_RETENTION
    local cli_retention_set=$RETENTION_SET
    # This file is created by this script and is root-only. It contains no
    # shell metacharacters because all values are validated before writing.
    # shellcheck disable=SC1090
    source "$INSTALL_ENV"
    BACKUP_PREFIX_RESUMED=1
    [[ -n "$cli_domain" ]] && DOMAIN=$cli_domain
    [[ -n "$cli_email" ]] && LETSENCRYPT_EMAIL=$cli_email
    [[ -n "$cli_tag" ]] && IMAGE_TAG=$cli_tag
    [[ -n "$cli_remote" ]] && RCLONE_REMOTE=$cli_remote
    [[ -n "$cli_prefix" ]] && BACKUP_PREFIX=$cli_prefix
    if [[ "$cli_retention_set" == 1 ]]; then
        BACKUP_RETENTION=$cli_retention
        RETENTION_SET=1
    fi
    log "loaded deployment settings from $INSTALL_ENV"
}

collect_settings() {
    normalize_domain
    if [[ -z "$DOMAIN" ]]; then
        prompt_value DOMAIN 'Public domain'
        normalize_domain
    fi
    validate_domain "$DOMAIN"

    if [[ -z "$LETSENCRYPT_EMAIL" ]]; then
        prompt_value LETSENCRYPT_EMAIL "Let's Encrypt email"
    fi
    validate_email "$LETSENCRYPT_EMAIL"

    if [[ -z "$RCLONE_REMOTE" ]]; then
        prompt_value RCLONE_REMOTE 'rclone Crypt remote' 'gcrypt'
    fi
    validate_remote_name "$RCLONE_REMOTE"

    if [[ -z "$BACKUP_PREFIX" && "$BACKUP_PREFIX_RESUMED" == 0 ]]; then
        prompt_value BACKUP_PREFIX 'Backup path below the Crypt remote' 'vaultwarden-backups'
    fi
    [[ "$BACKUP_PREFIX" == . ]] && BACKUP_PREFIX=
    BACKUP_PREFIX=${BACKUP_PREFIX#/}
    BACKUP_PREFIX=${BACKUP_PREFIX%/}
    validate_prefix "$BACKUP_PREFIX"

    if [[ "$RETENTION_SET" == 1 || ! -t 0 ]]; then
        :
    else
        prompt_value BACKUP_RETENTION 'Remote backup retention count' "$BACKUP_RETENTION"
    fi
    [[ "$BACKUP_RETENTION" =~ ^[1-9][0-9]*$ ]] || die "retention must be a positive integer"
}

preflight() {
    [[ "$EUID" -eq 0 ]] || die "run this script as root, for example: sudo $0"
    [[ -r /etc/os-release ]] || die 'cannot identify operating system'
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}" in
        ubuntu|debian) ;;
        *)
            [[ "${ID_LIKE:-}" == *debian* ]] || die "Ubuntu or Debian is required"
            ;;
    esac
    command -v apt-get >/dev/null || die 'apt-get is required'
    command -v flock >/dev/null || die 'flock is required; install util-linux first'
    local free_kb
    free_kb=$(df -Pk / | awk 'NR == 2 { print $4 }')
    [[ "$free_kb" =~ ^[0-9]+$ && "$free_kb" -ge 5242880 ]] || \
        warn 'less than 5 GiB is available on the root filesystem'

    mkdir -p /run/lock
    exec 9>"$LOCK_FILE"
    flock -n 9 || die 'another Vaultwarden operation is already running'
}

install_packages() {
    log 'installing required packages'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl docker.io nginx certbot \
        python3-certbot-nginx rclone sqlite3 jq tar gzip coreutils util-linux

    systemctl enable --now docker
    systemctl enable --now nginx

    if ! docker compose version >/dev/null 2>&1; then
        if ! apt-get install -y docker-compose-plugin; then
            if ! apt-get install -y docker-compose-v2; then
                apt-get install -y docker-compose
            fi
        fi
    fi
    if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null; then
        die 'Docker Compose v2 is not available after package installation'
    fi
    if docker compose version >/dev/null 2>&1; then
        COMPOSE_KIND=plugin
    else
        COMPOSE_KIND=standalone
    fi
}

compose() {
    if [[ "$COMPOSE_KIND" == plugin ]]; then
        docker compose --project-directory "$APP_DIR" "$@"
    else
        docker-compose --project-directory "$APP_DIR" "$@"
    fi
}

ensure_directories() {
    install -d -m 0700 "$ETC_DIR" "$RCLONE_DIR" "$RESTORE_ROOT" /var/lib/vaultwarden
    install -d -m 0755 "$APP_DIR"
    if [[ ! -d "$APP_DIR/data" ]]; then
        install -d -m 0700 "$APP_DIR/data"
    fi
}

has_rclone_remote() {
    local remotes
    remotes=$(rclone --config "$RCLONE_CONFIG" listremotes 2>/dev/null)
    grep -Fxq "$RCLONE_REMOTE:" <<< "$remotes"
}

configure_rclone() {
    if [[ ! -s "$RCLONE_CONFIG" ]]; then
        printf '\nNo rclone configuration was found.\n'
        printf 'Place an existing config at:\n  %s\n' "$RCLONE_CONFIG"
        printf 'Required permissions: directory 0700, file 0600.\n'
        printf 'You may instead provide a local config path or configure Google Drive interactively.\n\n'
        local source_path
        read -r -p 'Path to an existing rclone.conf (blank for interactive OAuth): ' source_path
        if [[ -n "$source_path" ]]; then
            [[ -f "$source_path" ]] || die "rclone config not found: $source_path"
            install -m 0600 "$source_path" "$RCLONE_CONFIG"
        else
            [[ -t 0 ]] || die 'interactive rclone configuration requires a terminal'
            rclone config --config "$RCLONE_CONFIG"
        fi
    fi
    chmod 0700 "$RCLONE_DIR"
    chmod 0600 "$RCLONE_CONFIG"
    has_rclone_remote || {
        printf '\nThe configured rclone remotes are:\n'
        rclone --config "$RCLONE_CONFIG" listremotes
        die "rclone remote '$RCLONE_REMOTE' was not found"
    }
    local remote_type
    remote_type=$(rclone --config "$RCLONE_CONFIG" config show "$RCLONE_REMOTE" 2>/dev/null | \
        awk -F= '$1 ~ /^[[:space:]]*type[[:space:]]*$/ { value = $2; gsub(/[[:space:]]/, "", value); print value; exit }')
    [[ "$remote_type" == crypt ]] || die "rclone remote '$RCLONE_REMOTE' is not a Crypt remote"
    local remote_root
    remote_root=$(remote_root_path)
    if ! rclone --config "$RCLONE_CONFIG" lsf --max-depth 1 --files-only "$remote_root" >/dev/null 2>&1; then
        [[ "$MODE" == fresh ]] || die "cannot access backup path: $remote_root"
        rclone --config "$RCLONE_CONFIG" mkdir "$remote_root"
    fi
    log "verified rclone remote $RCLONE_REMOTE"
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

write_compose_env() {
    local domain_url="https://$DOMAIN"
    cat > "$VAULTWARDEN_ENV" <<EOF
DOMAIN=$domain_url
ADMIN_TOKEN='$ADMIN_TOKEN_HASH'
SIGNUPS_ALLOWED=false
SHOW_PASSWORD_HINT=false
WEBSOCKET_ENABLED=true
ROCKET_ADDRESS=0.0.0.0
LOG_LEVEL=warn
EOF
    chmod 0600 "$VAULTWARDEN_ENV"
}

write_deployment_env() {
    {
        printf 'DOMAIN=%q\n' "$DOMAIN"
        printf 'LETSENCRYPT_EMAIL=%q\n' "$LETSENCRYPT_EMAIL"
        printf 'VAULTWARDEN_IMAGE=%q\n' "$VAULTWARDEN_IMAGE"
        printf 'RCLONE_REMOTE=%q\n' "$RCLONE_REMOTE"
        printf 'BACKUP_PREFIX=%q\n' "$BACKUP_PREFIX"
        printf 'BACKUP_RETENTION=%q\n' "$BACKUP_RETENTION"
        printf 'APP_DIR=%q\n' "$APP_DIR"
        printf 'DATA_DIR=%q\n' "$APP_DIR/data"
        printf 'COMPOSE_FILE=%q\n' "$COMPOSE_FILE"
    } > "$INSTALL_ENV"
    chmod 0600 "$INSTALL_ENV"
    printf 'VAULTWARDEN_IMAGE=%s\n' "$VAULTWARDEN_IMAGE" > "$APP_DIR/.env"
    chmod 0600 "$APP_DIR/.env"
}

write_compose() {
    [[ -f "$SCRIPT_DIR/templates/compose.yml" ]] || die 'templates/compose.yml is missing'
    install -m 0644 "$SCRIPT_DIR/templates/compose.yml" "$COMPOSE_FILE"
    compose -f "$COMPOSE_FILE" config -q
}

container_present() {
    docker inspect "$1" >/dev/null 2>&1
}

snapshot_restore_path() {
    local path=$1 name=$2
    if [[ -e "$path" || -L "$path" ]]; then
        cp -a -- "$path" "$RESTORE_CONFIG_ROLLBACK_DIR/$name"
        printf 'present\n' > "$RESTORE_CONFIG_ROLLBACK_DIR/$name.state"
    else
        printf 'absent\n' > "$RESTORE_CONFIG_ROLLBACK_DIR/$name.state"
    fi
}

restore_snapshot_path() {
    local path=$1 name=$2 state
    state=$RESTORE_CONFIG_ROLLBACK_DIR/$name.state
    [[ -f "$state" ]] || return 0
    rm -f -- "$path"
    if [[ "$(<"$state")" == present ]]; then
        cp -a -- "$RESTORE_CONFIG_ROLLBACK_DIR/$name" "$path"
    fi
}

capture_restore_state() {
    local old_container_id
    [[ "$MODE" == restore ]] || return 0
    RESTORE_CONFIG_ROLLBACK_DIR=$STAGE_DIR/previous-config
    RESTORE_NGINX_ROLLBACK_DIR=$STAGE_DIR/previous-nginx
    install -d -m 0700 "$RESTORE_CONFIG_ROLLBACK_DIR" "$RESTORE_NGINX_ROLLBACK_DIR"

    snapshot_restore_path "$APP_DIR/.env" app-env
    snapshot_restore_path "$COMPOSE_FILE" compose
    snapshot_restore_path "$VAULTWARDEN_ENV" vaultwarden-env
    snapshot_restore_path "$INSTALL_ENV" install-env
    RESTORE_CONFIG_ROLLBACK_DIR=$RESTORE_NGINX_ROLLBACK_DIR
    snapshot_restore_path "$NGINX_SITE" nginx-site
    snapshot_restore_path "$NGINX_LINK" nginx-link
    snapshot_restore_path /etc/nginx/sites-enabled/default nginx-default
    snapshot_restore_path "$CERTBOT_HOOK" certbot-hook
    RESTORE_CONFIG_ROLLBACK_DIR=$STAGE_DIR/previous-config

    if container_present vaultwarden; then
        RESTORE_OLD_PRESENT=1
        old_container_id=$(docker inspect -f '{{.Id}}' vaultwarden 2>/dev/null || true)
        RESTORE_OLD_CONTAINER_ID=$old_container_id
        if existing_container_running; then
            RESTORE_OLD_RUNNING=1
        fi
    fi
}

restore_previous_files() {
    [[ -n "$RESTORE_CONFIG_ROLLBACK_DIR" && -d "$RESTORE_CONFIG_ROLLBACK_DIR" ]] || return 0
    restore_snapshot_path "$APP_DIR/.env" app-env
    restore_snapshot_path "$COMPOSE_FILE" compose
    restore_snapshot_path "$VAULTWARDEN_ENV" vaultwarden-env
    restore_snapshot_path "$INSTALL_ENV" install-env
}

restore_previous_nginx() {
    [[ -n "$RESTORE_NGINX_ROLLBACK_DIR" && -d "$RESTORE_NGINX_ROLLBACK_DIR" ]] || return 0
    RESTORE_CONFIG_ROLLBACK_DIR=$RESTORE_NGINX_ROLLBACK_DIR
    restore_snapshot_path "$NGINX_SITE" nginx-site
    restore_snapshot_path "$NGINX_LINK" nginx-link
    restore_snapshot_path /etc/nginx/sites-enabled/default nginx-default
    restore_snapshot_path "$CERTBOT_HOOK" certbot-hook
    RESTORE_CONFIG_ROLLBACK_DIR=$STAGE_DIR/previous-config
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 || true
    else
        warn "previous Nginx configuration could not be reloaded from $RESTORE_NGINX_ROLLBACK_DIR"
    fi
}

write_nginx_bootstrap() {
    local temporary
    temporary=$(mktemp /etc/nginx/vaultwarden-bootstrap.XXXXXX)
    cat > "$temporary" <<'NGINX'
server {
    listen 80;
    listen [::]:80;
    server_name __DOMAIN__;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 404;
    }
}
NGINX
    sed "s/__DOMAIN__/$DOMAIN/g" "$temporary" > "$NGINX_SITE"
    rm -f -- "$temporary"
    chmod 0644 "$NGINX_SITE"
    ln -sfn "$NGINX_SITE" "$NGINX_LINK"
    rm -f /etc/nginx/sites-enabled/default
    install -d -m 0755 /var/www/certbot
    nginx -t
    systemctl reload nginx
}

configure_tls() {
    getent hosts "$DOMAIN" >/dev/null || die "domain does not resolve: $DOMAIN"
    write_nginx_bootstrap
    if [[ ! -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" || \
          ! -s "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]]; then
        log "requesting Let's Encrypt certificate for $DOMAIN"
        certbot certonly --webroot -w /var/www/certbot -d "$DOMAIN" \
            --email "$LETSENCRYPT_EMAIL" --agree-tos --no-eff-email --non-interactive
    fi
    [[ -f "$SCRIPT_DIR/templates/nginx.conf" ]] || die 'templates/nginx.conf is missing'
    sed "s/__DOMAIN__/$DOMAIN/g" "$SCRIPT_DIR/templates/nginx.conf" > "$NGINX_SITE"
    chmod 0644 "$NGINX_SITE"
    nginx -t
    systemctl reload nginx

    install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
    cat > "$CERTBOT_HOOK" <<'HOOK'
#!/usr/bin/env bash
set -Eeuo pipefail
systemctl reload nginx
HOOK
    chmod 0755 "$CERTBOT_HOOK"
    systemctl enable --now certbot.timer >/dev/null 2>&1 || true
}

existing_container_running() {
    [[ "$(docker inspect -f '{{.State.Running}}' vaultwarden 2>/dev/null || true)" == true ]]
}

generate_admin_hash() {
    if [[ "$RESUME" == 1 && -s "$VAULTWARDEN_ENV" ]]; then
        local existing
        existing=$(sed -n "s/^ADMIN_TOKEN='\(.*\)'$/\1/p" "$VAULTWARDEN_ENV")
        if [[ "$existing" =~ ^\$argon2(id|i|d)\$ ]]; then
            ADMIN_TOKEN_HASH=$existing
            log 'reusing existing Argon2 admin token hash'
            return
        fi
    fi

    [[ -t 0 ]] || die 'an interactive terminal is required to create the admin token'
    local password confirmation output hash
    read -r -s -p 'New Vaultwarden admin password: ' password
    printf '\n'
    read -r -s -p 'Repeat Vaultwarden admin password: ' confirmation
    printf '\n'
    [[ -n "$password" && "$password" == "$confirmation" ]] || die 'admin passwords do not match'
    output=$(printf '%s\n%s\n' "$password" "$confirmation" | \
        docker run --rm -i --entrypoint /vaultwarden "$VAULTWARDEN_IMAGE" hash 2>/dev/null)
    unset password confirmation
    hash=$(printf '%s\n' "$output" | awk '/^\$argon2(id|i|d)\$/ { print; exit }')
    [[ "$hash" =~ ^\$argon2(id|i|d)\$ ]] || die 'Vaultwarden did not produce an Argon2 hash'
    ADMIN_TOKEN_HASH=$hash
}

ensure_fresh_data_is_empty() {
    if [[ -n "$(find "$APP_DIR/data" -mindepth 1 -print -quit)" ]]; then
        [[ "$RESUME" == 1 ]] || die "$APP_DIR/data is not empty; use restore or --resume"
    fi
    existing_container_running && [[ "$RESUME" == 1 ]] || {
        existing_container_running && die 'a Vaultwarden container already exists; use --resume or stop it first'
        return 0
    }
}

list_remote_archives() {
    local listing=$STAGE_DIR/remote-list
    rclone --config "$RCLONE_CONFIG" lsf --files-only --recursive "$(remote_root_path)" > "$listing"
    mapfile -t REMOTE_ARCHIVES < <(awk '/\.tar\.gz$/ { print }' "$listing" | sort -r)
    mapfile -t CANONICAL_REMOTE_ARCHIVES < <(
        awk '$0 ~ /^vaultwarden-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z\.tar\.gz$/ { print }' \
            "$listing" | sort -r
    )
    ((${#REMOTE_ARCHIVES[@]} > 0)) || die 'no .tar.gz backups were found in the configured remote path'
}

choose_backup() {
    local selected choice index latest=
    list_remote_archives
    if ((${#CANONICAL_REMOTE_ARCHIVES[@]} > 0)); then
        latest=${CANONICAL_REMOTE_ARCHIVES[0]}
    fi
    if [[ -n "$BACKUP_SELECTION" ]]; then
        if [[ "$BACKUP_SELECTION" == latest ]]; then
            [[ -n "$latest" ]] || \
                die 'no canonical Vaultwarden backups were found; select a legacy archive by exact name'
            selected=$latest
        else
            selected=$BACKUP_SELECTION
            printf '%s\n' "${REMOTE_ARCHIVES[@]}" | grep -Fx "$selected" >/dev/null || \
                die "backup was not found: $selected"
        fi
        RESTORED_ARCHIVE=$selected
        return
    fi

    printf '\nAvailable backups (newest first):\n'
    if [[ -n "$latest" ]]; then
        printf '  latest -> %s\n' "$latest"
    fi
    index=1
    for choice in "${REMOTE_ARCHIVES[@]}"; do
        printf '  %s. %s\n' "$index" "$choice"
        index=$((index + 1))
    done
    if [[ -n "$latest" ]]; then
        read -r -p 'Choose latest, a number, or an exact archive name [latest]: ' choice
        choice=${choice:-latest}
    else
        read -r -p 'Choose a number or an exact legacy archive name: ' choice
    fi
    if [[ "$choice" == latest ]]; then
        [[ -n "$latest" ]] || die 'no canonical Vaultwarden backups were found'
        RESTORED_ARCHIVE=$latest
    elif [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#REMOTE_ARCHIVES[@]})); then
        RESTORED_ARCHIVE=${REMOTE_ARCHIVES[choice - 1]}
    else
        printf '%s\n' "${REMOTE_ARCHIVES[@]}" | grep -Fx "$choice" >/dev/null || die 'invalid backup selection'
        RESTORED_ARCHIVE=$choice
    fi
}

download_optional_sidecar() {
    local relative=$1 destination=$2
    if rclone --config "$RCLONE_CONFIG" copyto "$(remote_object_path "$relative")" "$destination" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

download_restore() {
    local archive_basename archive_path checksum_path manifest_path sidecar_base
    archive_basename=${RESTORED_ARCHIVE##*/}
    [[ "$archive_basename" == *.tar.gz ]] || die 'selected backup is not a gzip tar archive'
    [[ "$RESTORED_ARCHIVE" != /* && "$RESTORED_ARCHIVE" != *..* ]] || die 'invalid remote backup path'
    archive_path=$STAGE_DIR/$archive_basename
    checksum_path=$STAGE_DIR/$archive_basename.sha256
    manifest_path=$STAGE_DIR/${archive_basename%.tar.gz}.manifest.json
    sidecar_base=$RESTORED_ARCHIVE

    log "downloading $RESTORED_ARCHIVE"
    rclone --config "$RCLONE_CONFIG" copyto "$(remote_object_path "$RESTORED_ARCHIVE")" "$archive_path"
    if ! download_optional_sidecar "${sidecar_base}.sha256" "$checksum_path"; then
        warn 'selected archive has no checksum sidecar; treating it as a legacy backup'
        rm -f -- "$checksum_path"
    fi
    if ! download_optional_sidecar "${sidecar_base%.tar.gz}.manifest.json" "$manifest_path"; then
        rm -f -- "$manifest_path"
    fi

    if [[ -f "$checksum_path" ]]; then
        local expected actual
        expected=$(awk 'NF { print $1; exit }' "$checksum_path")
        [[ "$expected" =~ ^[A-Fa-f0-9]{64}$ ]] || die 'checksum sidecar is invalid'
        actual=$(sha256sum "$archive_path" | awk '{print $1}')
        [[ "$actual" == "$expected" ]] || die 'backup checksum verification failed'
        log 'backup checksum verified'
    fi
}

select_restore_image() {
    local manifest_image manifest_archive manifest_sha checksum_sha
    local archive_basename=${RESTORED_ARCHIVE##*/}
    local manifest_path=$STAGE_DIR/${archive_basename%.tar.gz}.manifest.json
    if [[ -f "$manifest_path" ]]; then
        jq -e 'type == "object" and .archive_format == 1' "$manifest_path" >/dev/null || \
            die 'backup manifest is invalid'
        manifest_archive=$(jq -r '.archive // empty' "$manifest_path")
        [[ "$manifest_archive" == "$archive_basename" ]] || die 'manifest archive name does not match backup'
        manifest_sha=$(jq -r '.sha256 // empty' "$manifest_path")
        [[ "$manifest_sha" =~ ^[A-Fa-f0-9]{64}$ ]] || die 'backup manifest checksum is invalid'
        [[ -f "$STAGE_DIR/$archive_basename.sha256" ]] || die 'manifest backup is missing its checksum sidecar'
        checksum_sha=$(awk 'NF { print $1; exit }' "$STAGE_DIR/$archive_basename.sha256")
        [[ "$manifest_sha" == "$checksum_sha" ]] || die 'manifest and checksum do not agree'
        manifest_image=$(jq -r '.vaultwarden_image // empty' "$manifest_path")
        [[ -n "$manifest_image" ]] || die 'backup manifest does not contain a Vaultwarden image'
        set_image_from_ref "$manifest_image"
        log "using Vaultwarden image from manifest: $VAULTWARDEN_IMAGE"
    elif [[ -z "$IMAGE_TAG" ]]; then
        warn 'legacy backup has no recorded Vaultwarden version'
        prompt_value IMAGE_TAG 'Source Vaultwarden image tag (required for legacy restore)'
        set_image_from_tag "$IMAGE_TAG"
    else
        set_image_from_tag "$IMAGE_TAG"
    fi
}

validate_archive_paths() {
    local archive=$1 names=$STAGE_DIR/archive-names details=$STAGE_DIR/archive-details path
    tar -tzf "$archive" > "$names"
    while IFS= read -r path; do
        path=${path%/}
        [[ -z "$path" ]] && continue
        [[ "$path" != /* ]] || die 'archive contains an absolute path'
        [[ "/$path/" != */../* ]] || die 'archive contains parent-directory traversal'
    done < "$names"
    tar -tvzf "$archive" > "$details"
    awk 'substr($0, 1, 1) ~ /^[lh]$/ { found = 1 } END { exit found }' "$details" && return 0
    die 'archive contains symlinks or hardlinks, which are not accepted'
}

validate_and_extract_restore() {
    local archive=$STAGE_DIR/${RESTORED_ARCHIVE##*/}
    local extract=$STAGE_DIR/extracted
    local database candidate_count
    validate_archive_paths "$archive"
    mkdir -p "$extract"
    tar -xzf "$archive" --no-same-owner --no-same-permissions -C "$extract"
    mapfile -t databases < <(find -P "$extract" -type f -name db.sqlite3 -print)
    ((${#databases[@]} == 1)) || die "expected exactly one db.sqlite3, found ${#databases[@]}"
    database=${databases[0]}
    RESTORE_DATA_SOURCE=$(dirname "$database")
    local integrity
    integrity=$(sqlite3 "$database" 'PRAGMA integrity_check;')
    [[ "$integrity" == ok ]] || die 'SQLite integrity check failed'
    candidate_count=$(find -P "$RESTORE_DATA_SOURCE" -type f -name db.sqlite3 | wc -l)
    [[ "$candidate_count" -eq 1 ]] || die 'restore data root is ambiguous'
    [[ ! -L "$RESTORE_DATA_SOURCE" ]] || die 'restore data root is a symlink'
    log "validated restore data at $RESTORE_DATA_SOURCE"
}

stop_existing_container() {
    if existing_container_running; then
        log 'stopping existing Vaultwarden container before data replacement'
        docker stop vaultwarden >/dev/null
    fi
}

install_restore_data() {
    local rollback data_dir=$APP_DIR/data
    RESTORE_ROLLBACK_DIR=
    if [[ "$RESTORE_OLD_PRESENT" == 1 ]] && existing_container_running; then
        RESTORE_OLD_RUNNING=1
    fi
    if [[ -n "$(find "$data_dir" -mindepth 1 -print -quit)" ]]; then
        confirm "Replace existing Vaultwarden data in $data_dir" || die 'restore cancelled'
    fi
    stop_existing_container
    rollback=$APP_DIR/data.pre-restore.$(date -u +%Y%m%dT%H%M%SZ)
    mv "$data_dir" "$rollback"
    RESTORE_ROLLBACK_DIR=$rollback
    log "existing data preserved at $rollback"
    install -d -m 0700 "$data_dir"
    cp -a "$RESTORE_DATA_SOURCE"/. "$data_dir"/
}

set_data_permissions() {
    local image_user uid gid detected_user
    image_user=$(docker image inspect --format '{{.Config.User}}' "$VAULTWARDEN_IMAGE" 2>/dev/null || true)
    if [[ "$image_user" =~ ^([0-9]+)(:([0-9]+))?$ ]]; then
        uid=${BASH_REMATCH[1]}
        gid=${BASH_REMATCH[3]:-$uid}
        chown -R "$uid:$gid" "$APP_DIR/data"
    else
        # Some image versions record a named user instead of numeric IDs.
        # Resolve that user inside the pulled image before restricting data.
        detected_user=$(docker run --rm --entrypoint /bin/sh "$VAULTWARDEN_IMAGE" \
            -c 'printf "%s:%s\n" "$(id -u)" "$(id -g)"' 2>/dev/null || true)
        if [[ "$detected_user" =~ ^([0-9]+):([0-9]+)$ ]]; then
            uid=${BASH_REMATCH[1]}
            gid=${BASH_REMATCH[2]}
            chown -R "$uid:$gid" "$APP_DIR/data"
        else
            chown -R root:root "$APP_DIR/data"
        fi
    fi
    chmod -R u+rwX,go-rwx "$APP_DIR/data"
}

start_and_verify() {
    compose -f "$COMPOSE_FILE" config -q
    if [[ "$MODE" == restore ]]; then
        RESTORE_NEW_CONTAINER_ATTEMPTED=1
    fi
    compose -f "$COMPOSE_FILE" up -d
    local attempt
    for attempt in {1..30}; do
        if curl -fsS --max-time 5 http://127.0.0.1:8080/alive >/dev/null; then
            log 'Vaultwarden internal health check passed'
            break
        fi
        [[ "$attempt" -eq 30 ]] && die 'Vaultwarden did not become healthy; inspect docker logs vaultwarden'
        sleep 2
    done
    curl --noproxy '*' -fsS --max-time 20 \
        "https://$DOMAIN/alive" >/dev/null
    log "HTTPS health check passed through normal DNS for https://$DOMAIN/alive"
    external_https_check
}

external_https_check() {
    local response request_id result attempt
    response=$(curl --noproxy '*' -fsS --max-time 20 \
        -H 'Accept: application/json' \
        --get \
        --data-urlencode "host=https://$DOMAIN/alive" \
        --data-urlencode 'max_nodes=3' \
        "$PUBLIC_CHECK_API/check-http") || \
        die 'could not start the external HTTPS reachability check'
    request_id=$(jq -r '.request_id // empty' <<< "$response") || \
        die 'external HTTPS reachability service returned invalid JSON'
    [[ "$request_id" =~ ^[A-Za-z0-9_-]+$ ]] || \
        die 'external HTTPS reachability service returned no request ID'

    for attempt in {1..15}; do
        result=$(curl --noproxy '*' -fsS --max-time 20 \
            -H 'Accept: application/json' \
            "$PUBLIC_CHECK_API/check-result/$request_id") || \
            die 'could not read the external HTTPS reachability result'
        if jq -e '
            [ .[]? | .[]?
              | select(
                    type == "array"
                    and (.[0] // 0) == 1
                    and ((.[3] // "") | tostring | test("^2[0-9][0-9]$"))
                )
            ] | length > 0
        ' <<< "$result" >/dev/null; then
            log "external HTTPS health check passed for https://$DOMAIN/alive"
            return 0
        fi
        [[ "$attempt" -eq 15 ]] || sleep 2
    done

    die "external HTTPS health check failed for https://$DOMAIN/alive"
}

install_backup_units() {
    [[ -f "$SCRIPT_DIR/systemd/vw-backup.service" ]] || die 'systemd/vw-backup.service is missing'
    [[ -f "$SCRIPT_DIR/systemd/vw-backup.timer" ]] || die 'systemd/vw-backup.timer is missing'
    install -m 0750 "$SCRIPT_DIR/vw-backup.sh" /usr/local/sbin/vw-backup.sh
    install -m 0644 "$SCRIPT_DIR/systemd/vw-backup.service" /etc/systemd/system/vw-backup.service
    install -m 0644 "$SCRIPT_DIR/systemd/vw-backup.timer" /etc/systemd/system/vw-backup.timer
    systemctl daemon-reload
    systemctl enable --now vw-backup.timer
}

write_state() {
    install -d -m 0700 /var/lib/vaultwarden
    printf '%s\n' "$1" > "$STATE_FILE"
    chmod 0600 "$STATE_FILE"
}

run_deployment() {
    select_mode
    load_resume_settings
    if [[ "$DRY_RUN" == 1 ]]; then
        printf 'mode=%s\ndomain=%s\nimage_tag=%s\nrclone_remote=%s\nbackup_prefix=%s\n' \
            "${MODE:-not-selected}" "$DOMAIN" "$IMAGE_TAG" "$RCLONE_REMOTE" "$BACKUP_PREFIX"
        return 0
    fi
    preflight
    install_packages
    ensure_directories
    STAGE_DIR=$(mktemp -d "$RESTORE_ROOT/deploy.XXXXXX")
    collect_settings
    configure_rclone

    if [[ "$MODE" == restore ]]; then
        choose_backup
        download_restore
        select_restore_image
        validate_and_extract_restore
    else
        if [[ -z "$IMAGE_TAG" ]]; then
            prompt_value IMAGE_TAG 'Pinned Vaultwarden image tag'
        fi
        set_image_from_tag "$IMAGE_TAG"
        ensure_fresh_data_is_empty
    fi

    write_state settings-collected
    log "pulling $VAULTWARDEN_IMAGE"
    docker pull "$VAULTWARDEN_IMAGE"
    generate_admin_hash
    capture_restore_state
    write_compose_env
    write_deployment_env
    write_compose
    configure_tls

    if [[ "$MODE" == restore ]]; then
        install_restore_data
    fi
    set_data_permissions
    write_state vaultwarden-started
    start_and_verify
    install_backup_units
    write_state complete
    RESTORE_COMMITTED=1
    log 'Vaultwarden deployment completed successfully'
    if [[ "$MODE" == restore ]]; then
        warn "review Admin Panel -> General Settings and set the domain URL to https://$DOMAIN"
        warn 'Passkeys/WebAuthn registered for the old domain may need to be registered again.'
    fi
    log 'backup timer is scheduled for 03:00 UTC; run systemctl status vw-backup.timer to inspect it'
}

parse_args "$@"
run_deployment
