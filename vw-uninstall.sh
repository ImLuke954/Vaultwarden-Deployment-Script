#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

APP_DIR=/opt/vaultwarden
ETC_DIR=/etc/vaultwarden
VAR_LIB_DIR=/var/lib/vaultwarden
LOCK_FILE=/run/lock/vaultwarden-operation.lock
COMPOSE_FILE=$APP_DIR/compose.yml
NGINX_SITE=/etc/nginx/sites-available/vaultwarden.conf
NGINX_LINK=/etc/nginx/sites-enabled/vaultwarden.conf
CERTBOT_HOOK=/etc/letsencrypt/renewal-hooks/deploy/vaultwarden-nginx-reload
FAIL2BAN_JAIL=/etc/fail2ban/jail.d/vaultwarden.local
FAIL2BAN_FILTER=/etc/fail2ban/filter.d/vaultwarden.conf
FAIL2BAN_ADMIN_FILTER=/etc/fail2ban/filter.d/vaultwarden-admin.conf
FAIL2BAN_TOTP_FILTER=/etc/fail2ban/filter.d/vaultwarden-totp.conf
FAIL2BAN_ACTION=/etc/fail2ban/action.d/cloudflare-token.conf
LOGROTATE_FILE=/etc/logrotate.d/vaultwarden

PURGE_DATA=0
ASSUME_YES=0
DRY_RUN=0

usage() {
    cat <<'USAGE'
Usage: sudo ./vw-uninstall.sh [options]

Remove the Vaultwarden service and host configuration installed by
vw-deploy.sh. By default, persistent data, rclone credentials, certificates,
installed packages, and remote backups are preserved.

Options:
  --purge-data  Also remove local Vaultwarden data and rclone credentials
  --yes         Do not request interactive confirmation
  --dry-run     Print the selected action and exit without changes
  -h, --help    Show this help

Remote rclone backups, Let's Encrypt certificates, and apt packages are never
removed by this script.
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

parse_args() {
    while (($#)); do
        case "$1" in
            --purge-data)
                PURGE_DATA=1
                shift
                ;;
            --yes)
                ASSUME_YES=1
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
}

print_summary() {
    printf '\nThis will remove the Vaultwarden container, backup timer, and managed Nginx, Fail2Ban, logrotate, and Certbot-hook configuration.\n'
    if [[ "$PURGE_DATA" == 1 ]]; then
        printf 'It will also permanently remove local Vaultwarden data and rclone credentials.\n'
    else
        printf 'It will preserve local data at %s and rclone credentials at %s/rclone/.\n' \
            "$APP_DIR/data" "$ETC_DIR"
    fi
    printf "Remote backups, Let's Encrypt certificates, and installed packages are always preserved.\n\n"
}

confirm_removal() {
    local answer phrase
    [[ "$ASSUME_YES" == 1 ]] && return 0
    [[ -t 0 ]] || die 'use --yes when standard input is not a terminal'
    read -r -p 'Remove the Vaultwarden deployment from this host [y/N]: ' answer
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]] || die 'uninstall cancelled'
    if [[ "$PURGE_DATA" == 1 ]]; then
        read -r -p 'Type DELETE VAULTWARDEN DATA to permanently remove local data: ' phrase
        [[ "$phrase" == 'DELETE VAULTWARDEN DATA' ]] || die 'local data purge cancelled'
    fi
}

preflight() {
    [[ "$EUID" -eq 0 ]] || die "run this script as root, for example: sudo $0"
    command -v systemctl >/dev/null || die 'systemctl is required'
    command -v flock >/dev/null || die 'flock is required; install util-linux first'
    mkdir -p /run/lock
    exec 9>"$LOCK_FILE"
    flock -n 9 || die 'another Vaultwarden operation is already running; wait for it to finish first'
}

disable_backup() {
    systemctl disable --now vw-backup.timer >/dev/null 2>&1 || true
    systemctl stop vw-backup.service >/dev/null 2>&1 || true
    rm -f -- /etc/systemd/system/vw-backup.service /etc/systemd/system/vw-backup.timer \
        /usr/local/sbin/vw-backup.sh
    systemctl daemon-reload
    systemctl reset-failed vw-backup.service vw-backup.timer >/dev/null 2>&1 || true
}

remove_container() {
    local image
    command -v docker >/dev/null || {
        warn 'Docker is not installed; no Vaultwarden container was removed'
        return 0
    }

    if [[ -f "$COMPOSE_FILE" ]] && docker compose version >/dev/null 2>&1; then
        docker compose --project-directory "$APP_DIR" -f "$COMPOSE_FILE" down --remove-orphans
        return 0
    fi
    if [[ -f "$COMPOSE_FILE" ]] && command -v docker-compose >/dev/null; then
        docker-compose --project-directory "$APP_DIR" -f "$COMPOSE_FILE" down --remove-orphans
        return 0
    fi
    if docker inspect vaultwarden >/dev/null 2>&1; then
        image=$(docker inspect -f '{{.Config.Image}}' vaultwarden)
        [[ "$image" == vaultwarden/server:* ]] || \
            die "refusing to remove container 'vaultwarden' with unexpected image: $image"
        docker rm -f vaultwarden >/dev/null
    fi
}

remove_nginx_config() {
    rm -f -- "$NGINX_LINK" "$NGINX_SITE" "$CERTBOT_HOOK"
    if command -v nginx >/dev/null && nginx -t >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 || warn 'Nginx configuration was removed but could not be reloaded'
    elif command -v nginx >/dev/null; then
        warn 'Nginx configuration was removed, but nginx -t failed; inspect the remaining Nginx configuration before reloading'
    fi
}

remove_fail2ban_config() {
    rm -f -- "$FAIL2BAN_JAIL" "$FAIL2BAN_FILTER" "$FAIL2BAN_ADMIN_FILTER" \
        "$FAIL2BAN_TOTP_FILTER" "$FAIL2BAN_ACTION" "$LOGROTATE_FILE"
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        fail2ban-client reload >/dev/null 2>&1 || \
            warn 'Fail2Ban configuration was removed but could not be reloaded'
    fi
}

remove_local_configuration() {
    rm -f -- "$APP_DIR/compose.yml" "$APP_DIR/.env" \
        "$ETC_DIR/install.env" "$ETC_DIR/vaultwarden.env" "$ETC_DIR/cloudflare.env" \
        "$VAR_LIB_DIR/deploy.state"
    rm -rf -- "$VAR_LIB_DIR/restore" "$VAR_LIB_DIR/backup-staging"
    rmdir -- "$VAR_LIB_DIR" 2>/dev/null || true
}

purge_local_data() {
    rm -rf -- "$APP_DIR/data" "$ETC_DIR/rclone"
    if [[ -d "$APP_DIR" ]]; then
        find "$APP_DIR" -maxdepth 1 -type d \( -name 'data.pre-restore.*' -o \
            -name 'data.failed-restore.*' \) -exec rm -rf -- {} +
    fi
    rmdir -- "$APP_DIR" "$ETC_DIR" 2>/dev/null || true
}

run_uninstall() {
    print_summary
    if [[ "$DRY_RUN" == 1 ]]; then
        log 'dry run requested; no changes were made'
        return 0
    fi
    confirm_removal
    preflight
    disable_backup
    remove_container
    remove_nginx_config
    remove_fail2ban_config
    remove_local_configuration
    if [[ "$PURGE_DATA" == 1 ]]; then
        purge_local_data
    fi
    log 'Vaultwarden deployment removal completed'
    if [[ "$PURGE_DATA" == 0 ]]; then
        log "local data remains at $APP_DIR/data and rclone credentials remain at $ETC_DIR/rclone/"
    fi
}

parse_args "$@"
run_uninstall
