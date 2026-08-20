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
CLOUDFLARE_ENV=$ETC_DIR/cloudflare.env
FAIL2BAN_JAIL=/etc/fail2ban/jail.d/vaultwarden.local
FAIL2BAN_FILTER=/etc/fail2ban/filter.d/vaultwarden.conf
FAIL2BAN_ADMIN_FILTER=/etc/fail2ban/filter.d/vaultwarden-admin.conf
FAIL2BAN_TOTP_FILTER=/etc/fail2ban/filter.d/vaultwarden-totp.conf
FAIL2BAN_ACTION=/etc/fail2ban/action.d/cloudflare-token.conf
LOGROTATE_FILE=/etc/logrotate.d/vaultwarden

MODE=
DOMAIN=
LETSENCRYPT_EMAIL=
IMAGE_TAG=
VAULTWARDEN_IMAGE=
ADMIN_TOKEN_HASH=
RCLONE_REMOTE=
RCLONE_CRYPT_REMOTES=()
BACKUP_PREFIX=
BACKUP_PREFIX_RESUMED=0
BACKUP_RETENTION=30
BACKUP_INSTANCE_ID=
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
RESTORE_SECURITY_ROLLBACK_DIR=
RESTORE_FAIL2BAN_WAS_ACTIVE=0
RESTORE_FAIL2BAN_WAS_ENABLED=0
RESTORE_FAIL2BAN_STATE_CAPTURED=0
RESTORE_COMMITTED=0
CLOUDFLARE_ZONE_ID=
# Preserve a token supplied through the environment; the interactive prompt
# remains the fallback for normal terminal use.
CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN-}
CLOUDFLARE_CONFIG_RESUMED=0

usage() {
    cat <<'USAGE'
Usage: sudo ./vw-deploy.sh [options]

Interactive mode presents the two supported operations and explains which
values belong to the new server and which values come from the old server.
Options can be used for unattended values. Secrets are read from standard input
unless supplied through their documented environment variables.

For unattended Cloudflare setup, pass the token through the environment rather
than putting it in a command-line option:

  sudo CLOUDFLARE_API_TOKEN='token-value' ./vw-deploy.sh --cloudflare-zone-id ID

Options:
  --mode fresh|restore       Select the operation without the menu
  --domain DOMAIN            Public Vaultwarden DNS name
  --email ADDRESS            Let's Encrypt notification address
  --image-tag TAG            Pinned vaultwarden/server image tag
  --rclone-remote NAME       rclone Crypt remote (auto-detected when possible)
  --backup-prefix PATH       Path below the Crypt remote (default: detected)
  --retention COUNT          Number of remote archives to keep (default: 30)
  --backup NAME|latest       Archive to restore
  --cloudflare-zone-id ID    Cloudflare zone for Fail2Ban bans
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
        restore_previous_security || true
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
            --cloudflare-zone-id)
                (($# >= 2)) || die "--cloudflare-zone-id requires a value"
                CLOUDFLARE_ZONE_ID=$2
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

ensure_backup_instance_id() {
    if [[ -z "$BACKUP_INSTANCE_ID" ]]; then
        [[ -r /proc/sys/kernel/random/uuid ]] || die 'cannot generate a backup instance ID'
        BACKUP_INSTANCE_ID=$(tr -d '-' < /proc/sys/kernel/random/uuid)
    fi
    [[ "$BACKUP_INSTANCE_ID" =~ ^[a-f0-9]{32}$ ]] || die 'backup instance ID is invalid'
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

prompt_secret() {
    local variable=$1 prompt=$2 value
    read -r -s -p "$prompt: " value
    printf '\n'
    [[ -n "$value" ]] || die "$variable is required"
    printf -v "$variable" '%s' "$value"
}

confirm() {
    local answer
    read -r -p "$1 [y/N]: " answer
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

print_migration_help() {
    if [[ "$MODE" == restore ]]; then
        cat <<'EOF'

This will configure a NEW VPS and restore your existing Vaultwarden data.

Values marked [NEW VPS] are chosen for this new installation.
Values marked [OLD SERVER] must come from the existing server or its backup.
The old server will not be changed by this script, but do not run this
restore on the old production server by mistake.

Before continuing, make sure:
  - The new domain's DNS record points to this VPS.
  - You have the complete rclone.conf from the old server.
  - You know the original rclone Crypt password and password2 if the config
    must be recreated. They cannot be recovered from the backup files.
  - Ports 80 and 443 are open to the internet.

EOF
    else
        cat <<'EOF'

This will configure a NEW, empty Vaultwarden installation on this VPS.

All settings below are for the new server, except an existing rclone
configuration if you choose to reuse an encrypted backup destination.
Do not choose Restore unless you already have a Vaultwarden backup to use.

Before continuing, make sure:
  - The domain's DNS record points to this VPS.
  - Ports 80 and 443 are open to the internet.

EOF
    fi
}

rclone_remote_type() {
    local remote=$1
    rclone --config "$RCLONE_CONFIG" config show "$remote" 2>/dev/null | \
        awk -F= '$1 ~ /^[[:space:]]*type[[:space:]]*$/ { value = $2; gsub(/[[:space:]]/, "", value); print value; exit }'
}

find_crypt_remotes() {
    local remotes remote
    RCLONE_CRYPT_REMOTES=()
    remotes=$(rclone --config "$RCLONE_CONFIG" listremotes 2>/dev/null) || \
        die 'rclone could not read the configuration file'
    while IFS= read -r remote; do
        [[ -n "$remote" ]] || continue
        remote=${remote%:}
        [[ "$(rclone_remote_type "$remote")" == crypt ]] || continue
        RCLONE_CRYPT_REMOTES+=("$remote")
    done <<< "$remotes"
}

print_rclone_setup_help() {
    if [[ "$MODE" == restore ]]; then
        cat <<'EOF'


The restore needs the complete rclone.conf from the old server. It must
contain both the Google Drive remote and the Crypt remote. Do not paste only
the [crypt] section: the underlying Google Drive remote is needed too.

On the old server, run `rclone config file` to find the config path. Copy that
complete file to this new VPS, then enter its local path when asked.

For example, an old configuration may contain:

  [gdrive]
  type = drive
  ...

  [grive-crypt]
  type = crypt
  remote = gdrive:backup-chilika

The value to select later is grive-crypt. The value gdrive:backup-chilika is
the storage underneath it and is not the Crypt remote name.

The Crypt password and password2 must be the original values. Creating a new
Crypt remote with different passwords will not decrypt existing backups.

EOF
    else
        cat <<'EOF'


You may reuse an existing rclone.conf from another Vaultwarden server, or
create a new Google Drive plus Crypt configuration. A Crypt remote encrypts
file names and contents before they leave this server. This script refuses
to use an unencrypted Google Drive remote.

If you reuse an old configuration, copy the complete file. If you create a
new Crypt remote, record its password and password2 somewhere safe because
they are required to read future backups.

EOF
    fi
}

select_rclone_remote() {
    local index choice
    [[ -n "$RCLONE_REMOTE" ]] && return 0
    find_crypt_remotes
    case "${#RCLONE_CRYPT_REMOTES[@]}" in
        0)
            die 'no rclone Crypt remote was found; the config must contain a remote with type = crypt'
            ;;
        1)
            RCLONE_REMOTE=${RCLONE_CRYPT_REMOTES[0]}
            printf 'Detected the only encrypted rclone remote: %s\n' "$RCLONE_REMOTE"
            ;;
        *)
            printf '\n[OLD SERVER] Choose the encrypted remote containing the Vaultwarden backups.\n'
            index=1
            for choice in "${RCLONE_CRYPT_REMOTES[@]}"; do
                printf '  %s. %s\n' "$index" "$choice"
                index=$((index + 1))
            done
            [[ -t 0 ]] || die 'multiple Crypt remotes were found; rerun with --rclone-remote NAME'
            read -r -p 'Enter the number of the backup remote: ' choice
            [[ "$choice" =~ ^[1-9][0-9]*$ ]] && \
                ((choice <= ${#RCLONE_CRYPT_REMOTES[@]})) || \
                die 'choose one of the listed Crypt remotes'
            RCLONE_REMOTE=${RCLONE_CRYPT_REMOTES[choice - 1]}
            ;;
    esac
}

print_cloudflare_help() {
    cat <<'EOF'


Choose Cloudflare only when this domain uses the orange-cloud proxy in the
Cloudflare DNS page. It lets Fail2Ban block abusive visitor IPs at Cloudflare.
If the domain is DNS-only, the local firewall is the correct choice.

To create the required API token:
  1. Open https://dash.cloudflare.com/profile/api-tokens
  2. Select Create Token, then Create Custom Token.
  3. Name it something like vaultwarden-fail2ban.
  4. Add exactly: Zone -> Firewall Services -> Edit.
  5. Under Zone Resources, choose Include -> Specific zone and select this
     domain. Do not grant access to all zones.
  6. Create the token and copy it immediately; Cloudflare shows it once.

Do not use the Global API Key. The token is entered without being displayed
and is stored only in root-readable files on this VPS.

The Zone ID is not the API token. Find it at the domain dashboard under
Overview -> API -> Zone ID. It is a 32-character hexadecimal value.

EOF
}

select_mode() {
    if [[ -n "$MODE" ]]; then
        print_migration_help
        return
    fi
    [[ -t 0 ]] || die "--mode is required when standard input is not a terminal"
    printf '\nWhat do you want to do?\n'
    printf '  1. Install a new empty Vaultwarden server\n'
    printf '  2. Install a new server and restore existing Vaultwarden data\n\n'
    local choice
    read -r -p 'Choose 1 for new or 2 for restore: ' choice
    case "$choice" in
        1) MODE=fresh ;;
        2) MODE=restore ;;
        *) die 'choose 1 for a new server or 2 to restore existing data' ;;
    esac
    print_migration_help
}

load_resume_settings() {
    [[ "$RESUME" == 1 && -r "$INSTALL_ENV" ]] || return 0

    local cli_domain=$DOMAIN cli_email=$LETSENCRYPT_EMAIL cli_tag=$IMAGE_TAG
    local cli_remote=$RCLONE_REMOTE cli_prefix=$BACKUP_PREFIX cli_retention=$BACKUP_RETENTION
    local cli_cloudflare_zone=$CLOUDFLARE_ZONE_ID cli_cloudflare_token=$CLOUDFLARE_API_TOKEN
    local cli_retention_set=$RETENTION_SET
    # This file is created by this script and is root-only. It contains no
    # shell metacharacters because all values are validated before writing.
    # shellcheck disable=SC1090
    source "$INSTALL_ENV"
    BACKUP_PREFIX_RESUMED=1
    if [[ -r "$CLOUDFLARE_ENV" ]]; then
        # This file is created by this script and is root-only.
        # shellcheck disable=SC1090
        source "$CLOUDFLARE_ENV"
        CLOUDFLARE_CONFIG_RESUMED=1
    fi
    [[ -n "$cli_domain" ]] && DOMAIN=$cli_domain
    [[ -n "$cli_email" ]] && LETSENCRYPT_EMAIL=$cli_email
    [[ -n "$cli_tag" ]] && IMAGE_TAG=$cli_tag
    [[ -n "$cli_remote" ]] && RCLONE_REMOTE=$cli_remote
    [[ -n "$cli_prefix" ]] && BACKUP_PREFIX=$cli_prefix
    [[ -n "$cli_cloudflare_zone" ]] && CLOUDFLARE_ZONE_ID=$cli_cloudflare_zone
    [[ -n "$cli_cloudflare_token" ]] && CLOUDFLARE_API_TOKEN=$cli_cloudflare_token
    if [[ "$cli_retention_set" == 1 ]]; then
        BACKUP_RETENTION=$cli_retention
        RETENTION_SET=1
    fi
    log "loaded deployment settings from $INSTALL_ENV"
}

collect_settings() {
    normalize_domain
    if [[ -z "$DOMAIN" ]]; then
        printf '\n[NEW VPS] Public domain\n'
        printf 'Enter the hostname users will type to open Vaultwarden.\n'
        printf 'Example: vault.example.com (do not include https://).\n'
        printf 'Its DNS A/AAAA record must point to this VPS.\n'
        prompt_value DOMAIN 'Vaultwarden domain'
        normalize_domain
    fi
    validate_domain "$DOMAIN"

    if [[ -z "$LETSENCRYPT_EMAIL" ]]; then
        printf "\n[NEW VPS] Let's Encrypt email\n"
        printf 'Use an email address you monitor for certificate expiration notices.\n'
        prompt_value LETSENCRYPT_EMAIL 'Certificate notification email'
    fi
    validate_email "$LETSENCRYPT_EMAIL"

    configure_rclone

    if [[ -z "$BACKUP_PREFIX" && "$BACKUP_PREFIX_RESUMED" == 0 ]]; then
        local suggested_prefix
        suggested_prefix=$(backup_prefix_suggestion)
        printf '\n[BACKUP STORAGE] Backup folder inside %s:\n' "$RCLONE_REMOTE"
        printf 'This is the folder containing the encrypted .tar.gz backup files.\n'
        printf 'It is not the Google Drive path from the rclone config.\n'
        printf 'Enter . only when the backup files are directly at the Crypt root.\n'
        prompt_value BACKUP_PREFIX 'Backup folder' "$suggested_prefix"
    fi
    [[ "$BACKUP_PREFIX" == . ]] && BACKUP_PREFIX=
    BACKUP_PREFIX=${BACKUP_PREFIX#/}
    BACKUP_PREFIX=${BACKUP_PREFIX%/}
    validate_prefix "$BACKUP_PREFIX"
    verify_rclone_backup_path

    if [[ "$RETENTION_SET" == 1 || ! -t 0 ]]; then
        :
    else
        printf '\n[NEW BACKUP POLICY] Retention count\n'
        printf 'The daily backup job keeps this many verified archives on the encrypted remote.\n'
        printf 'The default of 30 keeps about one month of daily backups.\n'
        prompt_value BACKUP_RETENTION 'Number of backups to keep' "$BACKUP_RETENTION"
    fi
    [[ "$BACKUP_RETENTION" =~ ^[1-9][0-9]*$ ]] || die "retention must be a positive integer"
}

collect_security_settings() {
    local zone choice
    if [[ "$CLOUDFLARE_CONFIG_RESUMED" == 0 && -z "$CLOUDFLARE_ZONE_ID" && -t 0 ]]; then
        print_cloudflare_help
        printf 'Choose how Fail2Ban should block abusive visitor IPs:\n'
        printf '  1. Local firewall (recommended for DNS-only domains)\n'
        printf '  2. Cloudflare firewall (required when the domain is orange-cloud proxied)\n\n'
        read -r -p 'Choose 1 or 2 [1]: ' choice
        choice=${choice:-1}
        case "$choice" in
            1) CLOUDFLARE_ZONE_ID= ;;
            2)
                prompt_value zone 'Cloudflare Zone ID'
                CLOUDFLARE_ZONE_ID=$zone
                ;;
            *) die 'choose 1 for the local firewall or 2 for Cloudflare' ;;
        esac
    fi
    if [[ -z "$CLOUDFLARE_ZONE_ID" ]]; then
        [[ -z "$CLOUDFLARE_API_TOKEN" ]] || die 'Cloudflare API token requires a zone ID'
        return 0
    fi
    [[ "$CLOUDFLARE_ZONE_ID" =~ ^[A-Fa-f0-9]{32}$ ]] || \
        die 'Cloudflare Zone ID must be exactly 32 hexadecimal characters; find it on the domain Overview page'
    if [[ -z "$CLOUDFLARE_API_TOKEN" ]]; then
        [[ -t 0 ]] || die 'a Cloudflare API token is required when --cloudflare-zone-id is used'
        printf '\n[NEW VPS] Cloudflare API token\n'
        printf 'The token must have Zone -> Firewall Services -> Edit for this domain only.\n'
        prompt_secret CLOUDFLARE_API_TOKEN 'Cloudflare API token'
    fi
    [[ "$CLOUDFLARE_API_TOKEN" =~ ^[A-Za-z0-9._-]{20,256}$ ]] || \
        die 'Cloudflare API token format is invalid; create a token, then paste the complete token value'
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
    if [[ "$MODE" == restore ]]; then
        if systemctl is-active --quiet fail2ban 2>/dev/null; then
            RESTORE_FAIL2BAN_WAS_ACTIVE=1
        fi
        if systemctl is-enabled --quiet fail2ban 2>/dev/null; then
            RESTORE_FAIL2BAN_WAS_ENABLED=1
        fi
        RESTORE_FAIL2BAN_STATE_CAPTURED=1
    fi
    local free_kb
    free_kb=$(df -Pk / | awk 'NR == 2 { print $4 }')
    [[ "$free_kb" =~ ^[0-9]+$ && "$free_kb" -ge 5242880 ]] || \
        warn 'less than 5 GiB is available on the root filesystem'

    mkdir -p /run/lock
    exec 9>"$LOCK_FILE"
    flock -n 9 || die 'another Vaultwarden operation is already running'
}

install_packages() {
    local required_packages=(
        ca-certificates curl docker.io nginx certbot fail2ban logrotate
        python3-certbot-nginx python3-pyinotify rclone sqlite3 jq tar gzip coreutils util-linux
    )
    local missing_packages=()
    local package
    local apt_updated=0

    for package in "${required_packages[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -qx 'install ok installed'; then
            missing_packages+=("$package")
        fi
    done

    export DEBIAN_FRONTEND=noninteractive
    if ((${#missing_packages[@]} > 0)); then
        log 'installing missing packages'
        apt-get update
        apt_updated=1
        apt-get install -y "${missing_packages[@]}"
    else
        log 'required packages are already installed'
    fi

    if ! systemctl is-enabled --quiet docker 2>/dev/null ||
        ! systemctl is-active --quiet docker 2>/dev/null; then
        systemctl enable --now docker
    fi
    if ! systemctl is-enabled --quiet nginx 2>/dev/null ||
        ! systemctl is-active --quiet nginx 2>/dev/null; then
        systemctl enable --now nginx
    fi

    if ! docker compose version >/dev/null 2>&1; then
        if ((apt_updated == 0)); then
            apt-get update
            apt_updated=1
        fi
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
        print_rclone_setup_help
        printf 'No rclone configuration was found at:\n  %s\n\n' "$RCLONE_CONFIG"
        printf 'You can provide a copy from this computer, or let rclone start its setup wizard.\n'
        local source_path
        read -r -p 'Local path to the complete rclone.conf (blank to create/configure one here): ' source_path
        if [[ -n "$source_path" ]]; then
            [[ -f "$source_path" ]] || die "rclone config not found: $source_path"
            install -m 0600 "$source_path" "$RCLONE_CONFIG"
        else
            [[ -t 0 ]] || die 'interactive rclone configuration requires a terminal'
            cat <<'EOF'

The rclone setup wizard will now open. For an existing restore:
  - Reuse the old Google Drive remote and its authorization.
  - Create or reuse a Crypt remote with the original password and password2.
  - Do not make a new Crypt password for old backups.

For a new backup destination:
  - Create a Google Drive remote first.
  - Create a Crypt remote pointing to that Google Drive remote.
  - Write down both Crypt passwords somewhere safe.

EOF
            rclone config --config "$RCLONE_CONFIG"
        fi
    fi
    chmod 0700 "$RCLONE_DIR"
    chmod 0600 "$RCLONE_CONFIG"
    select_rclone_remote
    validate_remote_name "$RCLONE_REMOTE"
    has_rclone_remote || {
        printf '\nThe configured rclone remotes are:\n'
        rclone --config "$RCLONE_CONFIG" listremotes
        die "rclone remote '$RCLONE_REMOTE' was not found; check the name in brackets in rclone.conf"
    }
    local remote_type
    remote_type=$(rclone_remote_type "$RCLONE_REMOTE")
    [[ "$remote_type" == crypt ]] || \
        die "rclone remote '$RCLONE_REMOTE' is not encrypted; choose a remote whose type is crypt"
    log "verified encrypted rclone remote $RCLONE_REMOTE"
}

backup_prefix_suggestion() {
    local directories root_files suggestion=vaultwarden-backups
    directories=$(rclone --config "$RCLONE_CONFIG" lsf --dirs-only --max-depth 1 \
        "$RCLONE_REMOTE:" 2>/dev/null || true)
    root_files=$(rclone --config "$RCLONE_CONFIG" lsf --files-only --max-depth 1 \
        "$RCLONE_REMOTE:" 2>/dev/null || true)

    if [[ "$directories" == *$'vaultwarden-backups/\n'* || "$directories" == 'vaultwarden-backups/' ]]; then
        suggestion=vaultwarden-backups
    elif grep -Eq '\.tar\.gz$' <<< "$root_files"; then
        suggestion=.
    fi

    if [[ -n "$directories" ]]; then
        printf '\nFound top-level folders in the encrypted remote:\n%s\n' "$directories" >&2
    fi
    if [[ -n "$root_files" ]]; then
        printf 'Found top-level files in the encrypted remote:\n%s\n' "$root_files" >&2
    fi
    printf 'Suggested backup folder: %s\n' "$suggestion" >&2
    printf '%s' "$suggestion"
}

verify_rclone_backup_path() {
    local remote_root
    remote_root=$(remote_root_path)
    if ! rclone --config "$RCLONE_CONFIG" lsf --max-depth 1 --files-only "$remote_root" >/dev/null 2>&1; then
        [[ "$MODE" == fresh ]] || die "cannot access backup path: $remote_root"
        rclone --config "$RCLONE_CONFIG" mkdir "$remote_root"
    fi
    log "verified encrypted backup path $remote_root"
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
IP_HEADER=X-Real-IP
IP_HEADER_TRUSTED_PROXIES=local
EXTENDED_LOGGING=true
LOG_FILE=/data/vaultwarden.log
LOG_LEVEL=info
EOF
    chmod 0600 "$VAULTWARDEN_ENV"
}

write_cloudflare_env() {
    if [[ -z "$CLOUDFLARE_ZONE_ID" ]]; then
        [[ "$CLOUDFLARE_CONFIG_RESUMED" == 1 ]] || rm -f -- "$CLOUDFLARE_ENV"
        return 0
    fi
    {
        printf 'CLOUDFLARE_ZONE_ID=%q\n' "$CLOUDFLARE_ZONE_ID"
        printf 'CLOUDFLARE_API_TOKEN=%q\n' "$CLOUDFLARE_API_TOKEN"
    } > "$CLOUDFLARE_ENV"
    chmod 0600 "$CLOUDFLARE_ENV"
}

ensure_vaultwarden_log() {
    local log_file=$APP_DIR/data/vaultwarden.log
    [[ ! -L "$log_file" ]] || die 'Vaultwarden log path must not be a symlink'
    if [[ -e "$log_file" ]]; then
        [[ -f "$log_file" ]] || die 'Vaultwarden log path must be a regular file'
    else
        install -m 0600 /dev/null "$log_file"
    fi
}

validate_cloudflare_credentials() {
    local response curl_config
    [[ -n "$CLOUDFLARE_ZONE_ID" ]] || return 0
    curl_config=$(mktemp "$STAGE_DIR/cloudflare-curl.XXXXXX")
    printf 'header = "Authorization: Bearer %s"\n' "$CLOUDFLARE_API_TOKEN" > "$curl_config"
    printf 'header = "Content-Type: application/json"\n' >> "$curl_config"
    response=$(curl --noproxy '*' -fsS --max-time 20 --config "$curl_config" \
        "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/firewall/access_rules/rules?per_page=1") || {
        rm -f -- "$curl_config"
        die 'could not validate the Cloudflare API token or zone ID'
    }
    rm -f -- "$curl_config"
    jq -e '.success == true' <<< "$response" >/dev/null || \
        die 'Cloudflare API token cannot access zone firewall rules'
}

write_fail2ban_jail() {
    local temporary action
    temporary=$(mktemp "$STAGE_DIR/fail2ban-jail.XXXXXX")
    if [[ -n "$CLOUDFLARE_ZONE_ID" ]]; then
        action=cloudflare-token
    else
        action='%(action_)s'
    fi
    cat > "$temporary" <<EOF
[DEFAULT]
bantime = 4h
findtime = 10m
maxretry = 3
backend = pyinotify
action = $action
EOF
    if [[ -n "$CLOUDFLARE_ZONE_ID" ]]; then
        printf 'cfzone = %s\n' "$CLOUDFLARE_ZONE_ID" >> "$temporary"
    fi
    cat >> "$temporary" <<'EOF'

[vaultwarden]
enabled = true
port = 80,443
filter = vaultwarden
logpath = /opt/vaultwarden/data/vaultwarden.log

[vaultwarden-admin]
enabled = true
port = 80,443
filter = vaultwarden-admin
logpath = /opt/vaultwarden/data/vaultwarden.log

[vaultwarden-totp]
enabled = true
port = 80,443
filter = vaultwarden-totp
logpath = /opt/vaultwarden/data/vaultwarden.log
EOF
    install -d -m 0755 /etc/fail2ban/jail.d
    if [[ -n "$CLOUDFLARE_ZONE_ID" ]]; then
        install -m 0600 "$temporary" "$FAIL2BAN_JAIL"
    else
        install -m 0644 "$temporary" "$FAIL2BAN_JAIL"
    fi
    rm -f -- "$temporary"
}

install_fail2ban() {
    [[ -f "$SCRIPT_DIR/templates/fail2ban/filter.d/vaultwarden.conf" ]] || \
        die 'Vaultwarden Fail2Ban filter is missing'
    [[ -f "$SCRIPT_DIR/templates/fail2ban/filter.d/vaultwarden-admin.conf" ]] || \
        die 'Vaultwarden admin Fail2Ban filter is missing'
    [[ -f "$SCRIPT_DIR/templates/fail2ban/filter.d/vaultwarden-totp.conf" ]] || \
        die 'Vaultwarden TOTP Fail2Ban filter is missing'
    [[ -f "$SCRIPT_DIR/templates/fail2ban/action.d/cloudflare-token.conf" ]] || \
        die 'Cloudflare Fail2Ban action is missing'

    validate_cloudflare_credentials
    install -d -m 0755 /etc/fail2ban/filter.d /etc/fail2ban/action.d /etc/fail2ban/jail.d
    install -m 0644 "$SCRIPT_DIR/templates/fail2ban/filter.d/vaultwarden.conf" "$FAIL2BAN_FILTER"
    install -m 0644 "$SCRIPT_DIR/templates/fail2ban/filter.d/vaultwarden-admin.conf" "$FAIL2BAN_ADMIN_FILTER"
    install -m 0644 "$SCRIPT_DIR/templates/fail2ban/filter.d/vaultwarden-totp.conf" "$FAIL2BAN_TOTP_FILTER"
    install -m 0644 "$SCRIPT_DIR/templates/fail2ban/action.d/cloudflare-token.conf" "$FAIL2BAN_ACTION"
    [[ -f "$SCRIPT_DIR/templates/logrotate-vaultwarden" ]] || die 'Vaultwarden logrotate configuration is missing'
    install -m 0644 "$SCRIPT_DIR/templates/logrotate-vaultwarden" "$LOGROTATE_FILE"
    write_fail2ban_jail
    fail2ban-client -t >/dev/null || die 'Fail2Ban configuration validation failed'
    systemctl enable --now fail2ban
    fail2ban-client reload >/dev/null
    fail2ban-client status vaultwarden >/dev/null || die 'Vaultwarden Fail2Ban jail is not available'
    fail2ban-client status vaultwarden-admin >/dev/null || die 'Vaultwarden admin Fail2Ban jail is not available'
    fail2ban-client status vaultwarden-totp >/dev/null || die 'Vaultwarden TOTP Fail2Ban jail is not available'
    if [[ -n "$CLOUDFLARE_ZONE_ID" ]]; then
        log 'Fail2Ban is configured to ban visitor IPs through Cloudflare'
    else
        warn 'Fail2Ban is using the local firewall; Cloudflare-proxied visitor bans require --cloudflare-zone-id'
    fi
}

write_deployment_env() {
    {
        printf 'DOMAIN=%q\n' "$DOMAIN"
        printf 'LETSENCRYPT_EMAIL=%q\n' "$LETSENCRYPT_EMAIL"
        printf 'VAULTWARDEN_IMAGE=%q\n' "$VAULTWARDEN_IMAGE"
        printf 'RCLONE_REMOTE=%q\n' "$RCLONE_REMOTE"
        printf 'BACKUP_PREFIX=%q\n' "$BACKUP_PREFIX"
        printf 'BACKUP_RETENTION=%q\n' "$BACKUP_RETENTION"
        printf 'BACKUP_INSTANCE_ID=%q\n' "$BACKUP_INSTANCE_ID"
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
    RESTORE_SECURITY_ROLLBACK_DIR=$STAGE_DIR/previous-security
    install -d -m 0700 "$RESTORE_CONFIG_ROLLBACK_DIR" "$RESTORE_NGINX_ROLLBACK_DIR" \
        "$RESTORE_SECURITY_ROLLBACK_DIR"

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

    RESTORE_CONFIG_ROLLBACK_DIR=$RESTORE_SECURITY_ROLLBACK_DIR
    snapshot_restore_path "$CLOUDFLARE_ENV" cloudflare-env
    snapshot_restore_path "$FAIL2BAN_JAIL" fail2ban-jail
    snapshot_restore_path "$FAIL2BAN_FILTER" fail2ban-filter
    snapshot_restore_path "$FAIL2BAN_ADMIN_FILTER" fail2ban-admin-filter
    snapshot_restore_path "$FAIL2BAN_TOTP_FILTER" fail2ban-totp-filter
    snapshot_restore_path "$FAIL2BAN_ACTION" fail2ban-action
    snapshot_restore_path "$LOGROTATE_FILE" logrotate
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

restore_previous_security() {
    if [[ -n "$RESTORE_SECURITY_ROLLBACK_DIR" && -d "$RESTORE_SECURITY_ROLLBACK_DIR" ]]; then
        RESTORE_CONFIG_ROLLBACK_DIR=$RESTORE_SECURITY_ROLLBACK_DIR
        restore_snapshot_path "$CLOUDFLARE_ENV" cloudflare-env
        restore_snapshot_path "$FAIL2BAN_JAIL" fail2ban-jail
        restore_snapshot_path "$FAIL2BAN_FILTER" fail2ban-filter
        restore_snapshot_path "$FAIL2BAN_ADMIN_FILTER" fail2ban-admin-filter
        restore_snapshot_path "$FAIL2BAN_TOTP_FILTER" fail2ban-totp-filter
        restore_snapshot_path "$FAIL2BAN_ACTION" fail2ban-action
        restore_snapshot_path "$LOGROTATE_FILE" logrotate
        RESTORE_CONFIG_ROLLBACK_DIR=$STAGE_DIR/previous-config
    fi
    [[ "$RESTORE_FAIL2BAN_STATE_CAPTURED" == 1 ]] || return 0

    if [[ "$RESTORE_FAIL2BAN_WAS_ACTIVE" == 1 ]]; then
        systemctl enable --now fail2ban >/dev/null 2>&1 || true
        fail2ban-client reload >/dev/null 2>&1 || true
    elif [[ "$RESTORE_FAIL2BAN_WAS_ENABLED" == 1 ]]; then
        systemctl stop fail2ban >/dev/null 2>&1 || true
        systemctl enable fail2ban >/dev/null 2>&1 || true
    else
        systemctl disable --now fail2ban >/dev/null 2>&1 || true
    fi
}

write_nginx_bootstrap() {
    local temporary
    temporary=$(mktemp /etc/nginx/vaultwarden-bootstrap.XXXXXX)
    cat > "$temporary" <<'NGINX'
    set_real_ip_from 103.21.244.0/22;
    set_real_ip_from 103.22.200.0/22;
    set_real_ip_from 103.31.4.0/22;
    set_real_ip_from 104.16.0.0/13;
    set_real_ip_from 104.24.0.0/14;
    set_real_ip_from 108.162.192.0/18;
    set_real_ip_from 131.0.72.0/22;
    set_real_ip_from 141.101.64.0/18;
    set_real_ip_from 162.158.0.0/15;
    set_real_ip_from 172.64.0.0/13;
    set_real_ip_from 173.245.48.0/20;
    set_real_ip_from 188.114.96.0/20;
    set_real_ip_from 190.93.240.0/20;
    set_real_ip_from 197.234.240.0/22;
    set_real_ip_from 198.41.128.0/17;
    set_real_ip_from 2400:cb00::/32;
    set_real_ip_from 2606:4700::/32;
    set_real_ip_from 2803:f800::/32;
    set_real_ip_from 2405:b500::/32;
    set_real_ip_from 2405:8100::/32;
    set_real_ip_from 2a06:98c0::/29;
    set_real_ip_from 2c0f:f248::/32;
    real_ip_header CF-Connecting-IP;
    real_ip_recursive on;

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

prompt_pinned_image_tag() {
    local context=$1
    printf '\n%s\n' "$context"
    printf 'Vaultwarden requires a specific version so an unexpected update cannot happen during setup.\n'
    printf 'Use a release tag such as 1.34.3, not the word latest.\n'
    printf 'Available releases: https://github.com/dani-garcia/vaultwarden/releases\n'
    prompt_value IMAGE_TAG 'Vaultwarden image tag'
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
    local output hash
    local -a script_args=(-q -e)
    command -v script >/dev/null || die 'script is required to create the admin token'
    # util-linux 2.34 lacks --echo; Vaultwarden still disables terminal echo itself.
    if script --help 2>&1 | grep -F -- '--echo' >/dev/null; then
        script_args+=(-E never)
    fi
    printf '\n[NEW VPS] Vaultwarden admin-panel password\n'
    printf 'This is only for the /admin page. Existing users keep their current email addresses and master passwords.\n'
    printf 'Vaultwarden will ask for the password twice without echoing it.\n'
    output=$(script "${script_args[@]}" -c \
        "docker run --rm -it --entrypoint /vaultwarden $VAULTWARDEN_IMAGE hash" \
        /dev/null | tee /dev/tty)
    hash=$(printf '%s\n' "$output" | awk -F "'" '
        {
            value = $2
            sub(/\r$/, "", value)
            if ($1 == "ADMIN_TOKEN=" && value ~ /^\$argon2(id|i|d)\$/) {
                print value
                exit
            }
            value = $0
            sub(/\r$/, "", value)
            if (value ~ /^\$argon2(id|i|d)\$/) {
                print value
                exit
            }
        }
    ')
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
    mapfile -t CANONICAL_REMOTE_ARCHIVES < <(
        while IFS= read -r archive; do
            [[ "$archive" =~ ^vaultwarden-([a-f0-9]{32}-)?([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z)\.tar\.gz$ ]] || continue
            printf '%s\t%s\n' "${BASH_REMATCH[2]}" "$archive"
        done < "$listing" | sort -r | cut -f2-
    )
    mapfile -t REMOTE_ARCHIVES < <(
        if ((${#CANONICAL_REMOTE_ARCHIVES[@]} > 0)); then
            printf '%s\n' "${CANONICAL_REMOTE_ARCHIVES[@]}"
        fi
        while IFS= read -r archive; do
            [[ "$archive" =~ ^vaultwarden-([a-f0-9]{32}-)?[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z\.tar\.gz$ ]] && continue
            [[ "$archive" == *.tar.gz ]] || continue
            printf '%s\n' "$archive"
        done < "$listing" | sort -r
    )
    ((${#REMOTE_ARCHIVES[@]} > 0)) || die 'no .tar.gz backups were found in the configured remote path'
}

choose_backup() {
    local selected choice index latest= archive
    local -a backup_instances=()
    list_remote_archives
    if [[ -n "$BACKUP_INSTANCE_ID" ]]; then
        for archive in "${CANONICAL_REMOTE_ARCHIVES[@]}"; do
            if [[ "$archive" == "vaultwarden-$BACKUP_INSTANCE_ID-"* ]]; then
                latest=$archive
                break
            fi
        done
    else
        mapfile -t backup_instances < <(
            for archive in "${CANONICAL_REMOTE_ARCHIVES[@]}"; do
                if [[ "$archive" =~ ^vaultwarden-([a-f0-9]{32})- ]]; then
                    printf '%s\n' "${BASH_REMATCH[1]}"
                else
                    printf 'legacy\n'
                fi
            done | sort -u
        )
        if ((${#backup_instances[@]} == 1)); then
            latest=${CANONICAL_REMOTE_ARCHIVES[0]}
        fi
    fi
    if [[ -n "$BACKUP_SELECTION" ]]; then
        if [[ "$BACKUP_SELECTION" == latest ]]; then
            [[ -n "$latest" ]] || \
                die 'latest is unavailable because no unambiguous canonical backup instance was found; select an archive by number or exact name'
            selected=$latest
        else
            selected=$BACKUP_SELECTION
            printf '%s\n' "${REMOTE_ARCHIVES[@]}" | grep -Fx "$selected" >/dev/null || \
                die "backup was not found: $selected"
        fi
        RESTORED_ARCHIVE=$selected
        return
    fi

    printf '\n[OLD SERVER] Choose the Vaultwarden backup to restore.\n'
    printf 'The default latest option is available only when the backup instance is unambiguous.\n'
    printf 'Older backups may be listed as legacy archives and require the old image version later.\n\n'
    printf 'Available backups (canonical backups newest first):\n'
    if [[ -n "$latest" ]]; then
        printf '  latest -> %s\n' "$latest"
    fi
    index=1
    for choice in "${REMOTE_ARCHIVES[@]}"; do
        printf '  %s. %s\n' "$index" "$choice"
        index=$((index + 1))
    done
    if [[ -n "$latest" ]]; then
        read -r -p 'Enter latest, a number, or an exact archive name [latest]: ' choice
        choice=${choice:-latest}
    else
        read -r -p 'Enter a number or an exact archive name: ' choice
    fi
    if [[ "$choice" == latest ]]; then
        [[ -n "$latest" ]] || die 'latest is unavailable because no unambiguous canonical backup instance was found'
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
        cat <<'EOF'

[OLD SERVER] Vaultwarden version used to create this legacy backup

This older backup does not record its Vaultwarden version. Restore it first
with the same version that ran on the old server. On the old server, try:

  docker inspect vaultwarden --format '{{.Config.Image}}'

The result may look like vaultwarden/server:1.34.3. Enter only the part after
the colon, for example 1.34.3. Do not enter latest.

EOF
        prompt_pinned_image_tag '[OLD SERVER] Source image version'
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
    awk 'substr($0, 1, 1) !~ /^[-d]$/ { found = 1 } END { exit found }' "$details" && return 0
    die 'archive contains links or special filesystem entries, which are not accepted'
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
    local attempt health_status
    for attempt in {1..45}; do
        health_status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' \
            vaultwarden 2>/dev/null || true)
        if [[ "$health_status" == unhealthy ]]; then
            die 'Vaultwarden Docker healthcheck failed; inspect docker logs vaultwarden'
        fi
        if [[ "$health_status" == healthy ]] && \
           curl -fsS --max-time 5 http://127.0.0.1:8080/alive >/dev/null; then
            log 'Vaultwarden internal and Docker health checks passed'
            break
        fi
        [[ "$attempt" -eq 45 ]] && die 'Vaultwarden did not become healthy; inspect docker logs vaultwarden'
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

print_configuration_summary() {
    printf '\n========================================\n'
    printf 'Review the deployment settings\n'
    printf '========================================\n'
    printf 'Operation:             %s\n' "$([[ "$MODE" == restore ]] && printf 'restore existing data' || printf 'new empty installation')"
    printf 'New VPS domain:        %s\n' "$DOMAIN"
    printf 'Certificate email:     %s\n' "$LETSENCRYPT_EMAIL"
    printf 'Vaultwarden image:     %s\n' "$VAULTWARDEN_IMAGE"
    printf 'Encrypted rclone:      %s\n' "$RCLONE_REMOTE"
    printf 'Backup path:           %s\n' "$(remote_root_path)"
    printf 'Backups retained:      %s\n' "$BACKUP_RETENTION"
    if [[ "$MODE" == restore ]]; then
        printf 'Archive to restore:    %s\n' "$RESTORED_ARCHIVE"
    fi
    if [[ -n "$CLOUDFLARE_ZONE_ID" ]]; then
        printf 'Fail2Ban bans:         Cloudflare firewall for zone %s\n' "$CLOUDFLARE_ZONE_ID"
    else
        printf 'Fail2Ban bans:         local firewall\n'
    fi
    printf '\nPasswords and API tokens are not shown above.\n'
    printf 'The script will now install packages and configure this VPS.\n\n'
    if [[ -t 0 ]]; then
        confirm 'Are these settings correct; continue' || die 'deployment cancelled'
    fi
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
        printf 'mode=%s\ndomain=%s\nimage_tag=%s\nrclone_remote=%s\nbackup_prefix=%s\ncloudflare_zone_id=%s\n' \
            "${MODE:-not-selected}" "$DOMAIN" "$IMAGE_TAG" "$RCLONE_REMOTE" "$BACKUP_PREFIX" "$CLOUDFLARE_ZONE_ID"
        return 0
    fi
    preflight
    install_packages
    ensure_directories
    STAGE_DIR=$(mktemp -d "$RESTORE_ROOT/deploy.XXXXXX")
    collect_settings
    collect_security_settings

    if [[ "$MODE" == restore ]]; then
        choose_backup
        download_restore
        select_restore_image
        validate_and_extract_restore
    else
        if [[ -z "$IMAGE_TAG" ]]; then
            prompt_pinned_image_tag '[NEW VPS] Vaultwarden version'
        fi
        set_image_from_tag "$IMAGE_TAG"
        ensure_fresh_data_is_empty
    fi

    ensure_backup_instance_id
    print_configuration_summary
    write_state settings-collected
    log "pulling $VAULTWARDEN_IMAGE"
    docker pull "$VAULTWARDEN_IMAGE"
    generate_admin_hash
    capture_restore_state
    write_compose_env
    write_cloudflare_env
    write_deployment_env
    write_compose
    configure_tls

    if [[ "$MODE" == restore ]]; then
        install_restore_data
    fi
    ensure_vaultwarden_log
    set_data_permissions
    write_state vaultwarden-started
    start_and_verify
    install_fail2ban
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
