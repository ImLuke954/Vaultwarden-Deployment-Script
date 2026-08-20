# Vaultwarden Deployment and Restore Automation

This repository provisions Vaultwarden on a new Ubuntu or Debian VPS and restores an existing Vaultwarden data directory from an encrypted rclone Crypt remote backed by Google Drive.

The deployment is intentionally conservative:

- Vaultwarden runs in Docker and is bound only to `127.0.0.1:8080`.
- Nginx terminates HTTPS on ports 80 and 443.
- The Vaultwarden image is always pinned to an explicit tag.
- Backups are created while Vaultwarden is stopped briefly, so SQLite and its files are consistent.
- New backups include a SHA-256 checksum and JSON manifest.
- Restores are staged, inspected, integrity-checked, and protected by a local rollback copy.
- The selected rclone remote must have type `crypt`; the script refuses to upload to an unencrypted remote.

## Contents

- `vw-deploy.sh`: interactive fresh-install and restore provisioner
- `vw-backup.sh`: encrypted backup helper installed as `/usr/local/sbin/vw-backup.sh`
- `vw-uninstall.sh`: conservative removal helper for a deployed server
- `templates/compose.yml`: Docker Compose service definition
- `templates/nginx.conf`: Cloudflare-aware Nginx HTTP to HTTPS redirect and reverse proxy
- `templates/fail2ban/`: Vaultwarden filters and Cloudflare API action
- `templates/logrotate-vaultwarden`: Vaultwarden log rotation policy
- `systemd/vw-backup.service`: backup service unit
- `systemd/vw-backup.timer`: daily backup timer
- `VAULTWARDEN_AUTOMATION_PLAN.md`: architecture and implementation plan

## Requirements

The target must be a real Ubuntu or Debian VPS with:

- Root access or an account that can run the script with `sudo`
- A public DNS record for the Vaultwarden domain pointing to the VPS
- TCP ports 80 and 443 available for Nginx and Let's Encrypt validation
- Outbound HTTPS access to `check-host.net` if external HTTPS probing is desired
- If Cloudflare proxying is enabled, a Cloudflare Zone ID and a custom API token with `Zone -> Firewall Services -> Edit` for only that zone
- At least 5 GiB of free root filesystem space recommended
- A Google Drive rclone configuration containing the original Crypt remote, or permission to authenticate interactively

The script installs Docker, Docker Compose, Nginx, Certbot, rclone, SQLite, Fail2Ban, logrotate, jq, and supporting packages through `apt`.

Do not run the provisioner on the existing production server unless you intend to modify that server. It is designed to configure a target VPS.

## Quick Start

Copy this repository to the target VPS, then run:

```bash
sudo chmod 700 vw-deploy.sh vw-backup.sh
sudo ./vw-deploy.sh
```

The script presents this menu:

```text
1. Install a new empty Vaultwarden server
2. Install a new server and restore existing Vaultwarden data
```

The interactive wizard labels each answer as belonging to the new VPS, the
old server/backup, or an optional security feature. It also shows a final
summary before making deployment changes.

Before running the script, make sure the DNS record already resolves to this VPS. The script also checks DNS immediately before requesting the certificate.

## Beginner Migration Guide

Use **Restore** when you are moving an existing Vaultwarden installation to a
new VPS. Use **Fresh installation** only when you want an empty Vaultwarden
database.

### Values from the old server

For a restore, copy the complete old `rclone.conf`. It must include the
Google Drive remote and the encrypted Crypt remote. In this example:

Run `rclone config file` on the old server to find the file, then copy that
complete file to the new VPS. Do not copy only the Crypt section.

```ini
[gdrive]
type = drive
...

[grive-crypt]
type = crypt
remote = gdrive:backup-chilika
```

The remote name is `grive-crypt`. The `gdrive:backup-chilika` value is the
underlying Google Drive location and must not be entered as the Crypt remote.
The old Crypt `password` and `password2` must remain unchanged or existing
backups cannot be decrypted.

For a legacy backup without a manifest, find the old Vaultwarden image tag on
the old server with:

```bash
docker inspect vaultwarden --format '{{.Config.Image}}'
```

If the result is `vaultwarden/server:1.34.3`, enter `1.34.3` when the wizard
asks for the old image version. Never use `latest` for a restore.

### Values for the new VPS

Enter the new public domain, an email address you monitor for Let's Encrypt
notices, a new Vaultwarden admin-panel password, and the number of backup
archives to retain. Existing users keep their existing email addresses and
master passwords after a restore.

The new domain must have an `A` or `AAAA` DNS record pointing to the new VPS.
Ports 80 and 443 must be reachable from the internet.

## rclone Configuration

### Preferred configuration path

Place an existing rclone configuration at this exact path on the target VPS:

```text
/etc/vaultwarden/rclone/rclone.conf
```

The provisioner creates the parent directory when needed. To install an existing configuration before starting:

```bash
sudo install -d -m 700 /etc/vaultwarden/rclone
sudo install -m 600 /path/to/rclone.conf \
  /etc/vaultwarden/rclone/rclone.conf
```

The configuration should contain the same Crypt remote used by the original server. The wizard automatically detects a single Crypt remote. If multiple Crypt remotes exist, it displays their names and asks you to choose one.

The script verifies both the remote name and its configured type:

```text
type = crypt
```

It will not use a plain Google Drive remote for backups or restores.

The Crypt remote must point to a different underlying storage remote. For
example, `[new-gdrive-crypt]` should contain `remote = new-gdrive:backups`,
not `remote = new-gdrive-crypt:`. A Crypt remote pointing to itself cannot be
opened by rclone and will be rejected before Vaultwarden is stopped.

### Interactive configuration

If the file is absent, the script asks for a local configuration path. Enter
the path to the complete file if you have copied it to the new VPS. Leave the
answer blank to start:

```bash
rclone config
```

Complete Google Drive OAuth and configure the Crypt remote. During a restore,
use the same Crypt password and salt as the original server. The Crypt
password and salt cannot be recovered by this project if they are lost.

The rclone configuration contains Google credentials and encryption metadata. Keep it outside this repository and never paste it into logs or source control.

### Backup prefix

The backup prefix is the path below the selected Crypt remote. The wizard
lists top-level folders and files and suggests the correct value when it can.

New backups use this default:

```text
vaultwarden-backups
```

The older manual guide copied archives directly to the Crypt remote root. To restore those archives, enter a single period (`.`) when asked for the prefix, or pass:

```bash
--backup-prefix .
```

The script normalizes `.` to an empty root prefix and preserves that root
prefix when `--resume` reloads prior settings. Each installation also receives
a stable backup instance ID, so backups sharing a remote path do not overwrite
or expire one another.

## Cloudflare API Token

Cloudflare is optional. Choose the local firewall when the domain is DNS-only.
Choose Cloudflare when the domain uses the orange-cloud proxy; local firewall
bans cannot block visitors arriving through Cloudflare's edge network.

Create a scoped custom token as follows:

1. Open <https://dash.cloudflare.com/profile/api-tokens>.
2. Select **Create Token**, then **Create Custom Token**.
3. Name it `vaultwarden-fail2ban`.
4. Add the permission `Zone -> Firewall Services -> Edit`.
5. Under **Zone Resources**, choose **Include -> Specific zone** and select only this domain.
6. Create the token and copy it immediately; Cloudflare displays it only once.

Do not use the Global API Key. Find the 32-character Zone ID in the domain
dashboard under **Overview -> API -> Zone ID**. The wizard asks for the Zone
ID and then reads the API token without displaying it. It validates that the
token can access the zone firewall rules before enabling Cloudflare bans.

## Fresh Installation

Run the interactive command and select `1`, or use `--mode fresh`.

Example:

```bash
sudo ./vw-deploy.sh \
  --mode fresh \
  --domain vault.example.com \
  --email admin@example.com \
  --image-tag 1.34.3 \
  --rclone-remote grive-crypt \
  --backup-prefix vaultwarden-backups \
  --retention 30
```

The admin password is entered twice without echoing by the selected Vaultwarden image's TTY-backed hash command. The script stores only the resulting Argon2 hash. The plaintext password is not written to a file, piped through standard input, or passed as a command-line argument.

The fresh-install flow:

1. Validates the operating system, free space, lock state, DNS, and prerequisites.
2. Installs and starts Docker, Nginx, rclone, Certbot, SQLite, jq, and required packages.
3. Imports or creates the rclone configuration and verifies the Crypt remote.
4. Refuses to overwrite an existing data directory unless `--resume` is used.
5. Pulls the pinned Vaultwarden image.
6. Creates the Compose and Vaultwarden environment files.
7. Obtains or reuses a Let's Encrypt certificate.
8. Starts Vaultwarden and verifies its Docker healthcheck plus local, normal-DNS, and externally probed HTTPS `/alive` endpoints.
9. Installs and enables Fail2Ban, Vaultwarden authentication jails, and daily log rotation.
10. Installs and enables the daily encrypted backup timer.

## Restore From Google Drive

Run the interactive command and select `2`, or use `--mode restore`.

Example for a new-format backup:

```bash
sudo ./vw-deploy.sh \
  --mode restore \
  --domain new-vault.example.com \
   --email admin@example.com \
   --backup latest \
   --rclone-remote grive-crypt \
  --backup-prefix vaultwarden-backups \
  --retention 30
```

For an archive from the older guide, use the root prefix and explicitly provide the image version used by the old server:

```bash
sudo ./vw-deploy.sh \
  --mode restore \
  --domain new-vault.example.com \
   --email admin@example.com \
   --backup LEGACY_ARCHIVE.tar.gz \
  --image-tag 1.34.3 \
   --rclone-remote grive-crypt \
  --backup-prefix .
```

The restore flow:

1. Lists `.tar.gz` archives in the selected Crypt prefix.
2. Lets the operator choose `latest`, a number, or an exact archive path.
   `latest` selects only a canonical script-created `vaultwarden-INSTANCE_ID-TIMESTAMP.tar.gz`
   archive when the backup instance is unambiguous; otherwise select an archive
   by number or exact name.
3. Downloads only the selected archive and any checksum or manifest sidecars.
4. Verifies the SHA-256 checksum when present.
5. Validates new-format manifests and their image/checksum metadata.
6. Rejects absolute paths, parent-directory traversal, links, and special filesystem entries.
7. Extracts to a root-only staging directory.
8. Locates exactly one `db.sqlite3` and runs SQLite `PRAGMA integrity_check`.
9. Stops an existing Vaultwarden container only when data replacement is ready.
10. Requires confirmation before replacing non-empty data.
11. Preserves old data under `/opt/vaultwarden/data.pre-restore.TIMESTAMP`.
12. Installs the validated data, starts the pinned image, and checks Docker, local, and externally probed HTTPS health.

If the restore fails after old data has been moved but before the new deployment is committed, the script attempts to restore the previous data and restart the previous container. A failed restore copy is retained under a `data.failed-restore.TIMESTAMP` path for investigation.

### Legacy archives

Archives created by the original manual guide may have no checksum, manifest, or recorded image version. The script supports them, but displays a warning and requires the source image tag through `--image-tag` or an interactive prompt. Never restore a legacy archive using `latest`.

The archive may contain `vw-data/`, `data/`, or an archived absolute source path. The script locates the data root by finding the one valid `db.sqlite3` rather than relying on a fixed top-level directory.

### After a restore

Open the admin panel at:

```text
https://YOUR_NEW_DOMAIN/admin
```

Review General Settings and set the domain URL to the new domain. The script sets the `DOMAIN` environment variable, but the restored database can contain the old domain configuration.

Passkeys and WebAuthn credentials are domain-bound. Credentials registered for the old domain may need to be registered again on the new instance.

Users keep their existing email addresses and master passwords. The master password is not stored by Vaultwarden and is not changed by this process.

## Command-Line Options

```text
--mode fresh|restore       Select the operation without the menu
--domain DOMAIN            Public Vaultwarden DNS name
--email ADDRESS            Let's Encrypt notification address
--image-tag TAG            Pinned vaultwarden/server image tag
--rclone-remote NAME       rclone Crypt remote, auto-detected when possible
--backup-prefix PATH       Path below the Crypt remote
--retention COUNT          Number of remote archives to retain, default 30
--backup NAME|latest       Archive to restore
--cloudflare-zone-id ID    Cloudflare zone used for API-backed bans
--resume                   Reuse existing deployment settings where possible
--dry-run                  Print selected values and exit without changes
```

The image tag must not be `latest`. The admin password remains interactive even when other options are supplied.

Examples:

```bash
sudo ./vw-deploy.sh --help
sudo ./vw-deploy.sh --mode fresh --dry-run
sudo ./vw-deploy.sh --mode restore --backup latest --resume
```

`--resume` reuses settings from `/etc/vaultwarden/install.env` where possible and allows an existing data directory or container to be continued. It does not bypass the restore confirmation prompt.

For unattended Cloudflare setup, the token can be supplied through the
environment. Do not put it in a command-line option because command-line
arguments may be visible to other users on the VPS:

```bash
sudo CLOUDFLARE_API_TOKEN='your-token' ./vw-deploy.sh \
  --mode fresh \
  --cloudflare-zone-id YOUR_32_CHARACTER_ZONE_ID
```

The token is still validated and written only to the root-readable
`/etc/vaultwarden/cloudflare.env` file. Supplying a token this way with
`--resume` replaces the persisted token, which supports token rotation.

## Backup Operation

The installer enables `vw-backup.timer`. It runs daily around 03:00 UTC with a randomized delay of up to 15 minutes.

The helper:

1. Acquires the same operation lock used by the provisioner.
2. Stops Vaultwarden briefly when it is running.
3. Archives the complete `/opt/vaultwarden/data` directory.
4. Writes a SHA-256 sidecar and JSON manifest.
5. Uploads all objects through the configured Crypt remote with `rclone copyto`.
6. Downloads the uploaded archive back and compares its SHA-256 hash.
7. Removes older archives only after the new upload is verified.
8. Refuses links and special filesystem entries because the restore path does not accept them.
9. Restarts Vaultwarden even when an earlier backup step fails.

The helper deliberately does not use `rclone sync`. A local failure must not delete valid remote backups.

### Backup object format

New backups are stored as:

```text
vaultwarden-INSTANCE_ID-TIMESTAMP.tar.gz
vaultwarden-INSTANCE_ID-TIMESTAMP.tar.gz.sha256
vaultwarden-INSTANCE_ID-TIMESTAMP.manifest.json
```

`INSTANCE_ID` is a generated per-installation identifier. Retention deletes
only archives with the current installation's ID. The manifest records the
archive format version, UTC creation time, instance ID, image reference, and
SHA-256 value.

### Inspect and run backups

```bash
sudo systemctl status vw-backup.timer
sudo systemctl list-timers vw-backup.timer
sudo systemctl start vw-backup.service
sudo journalctl -u vw-backup.service --no-pager
```

The first scheduled backup is not forced immediately by installation. Run `sudo systemctl start vw-backup.service` after verifying the deployment if you want an immediate backup.

## VPS File Layout

```text
/etc/vaultwarden/
├── install.env                  # Root-only deployment settings
├── vaultwarden.env              # Root-only container environment, includes hash
├── cloudflare.env               # Root-only Cloudflare API credentials
└── rclone/
    └── rclone.conf              # Root-only Google Drive/Crypt credentials

/opt/vaultwarden/
├── .env                         # Pinned image reference
├── compose.yml                  # Docker Compose definition
├── data/                        # Persistent Vaultwarden data
├── data.pre-restore.TIMESTAMP/  # Restore rollback copy when applicable
└── data.failed-restore.TIMESTAMP/

/var/lib/vaultwarden/
├── deploy.state                 # Root-only last deployment phase
├── restore/                     # Root-only restore staging
└── backup-staging/              # Root-only backup staging

/usr/local/sbin/vw-backup.sh
/etc/systemd/system/vw-backup.service
/etc/systemd/system/vw-backup.timer
/etc/nginx/sites-available/vaultwarden.conf
/etc/fail2ban/jail.d/vaultwarden.local
/etc/fail2ban/filter.d/vaultwarden*.conf
/etc/fail2ban/action.d/cloudflare-token.conf
/etc/logrotate.d/vaultwarden
```

The provisioner uses `/run/lock/vaultwarden-operation.lock` to prevent backup, restore, and deployment operations from running concurrently.

## Security Notes

- Keep `/etc/vaultwarden/rclone/rclone.conf` out of Git and restrict it to mode `0600`.
- Keep `/etc/vaultwarden/vaultwarden.env` root-only because it contains the admin token hash.
- Keep `/etc/vaultwarden/cloudflare.env` root-only because it contains the Cloudflare API token.
- Keep `/etc/fail2ban/jail.d/vaultwarden.local` root-only when Cloudflare bans are enabled because it contains the same token for the Fail2Ban action.
- Do not place Crypt passwords, Google OAuth tokens, admin passwords, or backup archives in this repository.
- The Vaultwarden container is not exposed directly to the internet.
- The image tag is pinned to avoid an unexpected application/database migration during restore.
- Restoring a backup does not decrypt vault contents. Users still need their own master passwords.
- Anyone who obtains the rclone configuration and Crypt password may be able to access the encrypted backup files. Protect both independently.
- Cloudflare-proxied bans require the Cloudflare API action; local firewall bans do not block packets arriving from Cloudflare edge IPs.
- The script trusts `CF-Connecting-IP` only from Cloudflare's published IP ranges and forwards the resulting address through `X-Real-IP`.
- Vaultwarden uses `IP_HEADER=X-Real-IP` and `IP_HEADER_TRUSTED_PROXIES=local`; `ROCKET_TRUSTED_PROXIES` is a legacy setting and is not used by current Vaultwarden releases.
- Test restoring a backup on a separate VPS before relying on it for disaster recovery.

## Updating Vaultwarden

Do not update the image by changing it to `latest`. Use a deliberate, pinned upgrade:

```bash
sudo cp /opt/vaultwarden/compose.yml /opt/vaultwarden/compose.yml.before-upgrade
sudo sed -i 's/vaultwarden\/server:[^ ]*/vaultwarden\/server:NEW_TAG/' /opt/vaultwarden/.env
sudo sed -i 's|^VAULTWARDEN_IMAGE=.*$|VAULTWARDEN_IMAGE=vaultwarden/server:NEW_TAG|' \
  /etc/vaultwarden/install.env
sudo docker compose --project-directory /opt/vaultwarden \
  -f /opt/vaultwarden/compose.yml pull
sudo docker compose --project-directory /opt/vaultwarden \
  -f /opt/vaultwarden/compose.yml up -d
```

Create and verify a backup before upgrading. Check the Vaultwarden release notes and database migration requirements first. If a migration fails, stop the service and restore the pre-upgrade backup rather than repeatedly starting different versions.

## Troubleshooting

### No backups are listed

Check the Crypt remote, prefix, and remote contents:

```bash
sudo rclone --config /etc/vaultwarden/rclone/rclone.conf listremotes
sudo rclone --config /etc/vaultwarden/rclone/rclone.conf \
  lsf --recursive grive-crypt:vaultwarden-backups
```

For archives from the old guide, use `--backup-prefix .`.

### Vaultwarden is unhealthy

Inspect the container and recent logs:

```bash
sudo docker ps -a
sudo docker logs --tail 200 vaultwarden
sudo curl -fsS http://127.0.0.1:8080/alive
```

Check that the data directory is readable by the user configured in the pulled image and that `/opt/vaultwarden/data/db.sqlite3` exists after a restore.

The Compose healthcheck runs `/healthcheck.sh`. Check its state with:

```bash
sudo docker inspect --format '{{.State.Health.Status}}' vaultwarden
```

### Fail2Ban or visitor IP detection fails

Vaultwarden writes extended authentication logs to `/opt/vaultwarden/data/vaultwarden.log`. Inspect the jails and recent events with:

```bash
sudo fail2ban-client status
sudo fail2ban-client status vaultwarden
sudo fail2ban-client status vaultwarden-admin
sudo journalctl -u fail2ban --no-pager -n 100
sudo tail -n 50 /opt/vaultwarden/data/vaultwarden.log
```

When Cloudflare proxying is enabled, the deployment requires `--cloudflare-zone-id` or the interactive Zone ID prompt and a scoped API token. Fail2Ban then creates and removes Cloudflare firewall access rules. Without Cloudflare credentials, local firewall bans are used and do not block Cloudflare-proxied traffic.

### HTTPS or certificate issuance fails

Verify DNS and port availability:

```bash
getent hosts vault.example.com
sudo ss -ltnp | grep -E ':(80|443)'
sudo nginx -t
sudo journalctl -u nginx --no-pager -n 100
```

Let's Encrypt must be able to reach the VPS on port 80. The deployment also
attempts to use Check-Host nodes to verify external HTTPS access on port 443.
That probe is best-effort because geo-blocking, an allowlist, or a temporary
probe-service failure can prevent those nodes from reaching an otherwise
working installation. Local and normal-DNS HTTPS checks remain required.

HTTP 526 during the public HTTPS check is returned by Cloudflare when it cannot
validate the certificate presented by the origin. Check that the domain's A and
AAAA records point to this VPS, the Cloudflare SSL mode is **Full (strict)**,
and the certificate served by Nginx covers the requested domain and has not
expired:

```bash
sudo openssl x509 -in /etc/letsencrypt/live/vault.example.com/fullchain.pem \
  -noout -subject -issuer -dates -ext subjectAltName
sudo curl --noproxy '*' -k --resolve vault.example.com:443:127.0.0.1 \
  https://vault.example.com/alive
sudo curl --noproxy '*' -I https://vault.example.com/alive
```

The `--resolve` curl command checks Nginx on the VPS while the `openssl`
command checks the certificate. The final curl checks the public DNS and
Cloudflare path. A local success with public 526 usually means Cloudflare is
pointed at a different origin or has a stale AAAA record.

### Backup service fails

```bash
sudo systemctl status vw-backup.service
sudo journalctl -u vw-backup.service --no-pager -n 200
sudo systemctl start vw-backup.service
```

Confirm that Docker is running, the rclone remote is still type `crypt`, the Crypt password is correct, and sufficient local and Google Drive space is available.

## Removal

Use the uninstall helper to remove the running service and configuration while preserving local data, rclone credentials, remote backups, Let's Encrypt certificates, and installed packages:

```bash
sudo chmod 700 vw-uninstall.sh
sudo ./vw-uninstall.sh
```

The script removes the Vaultwarden container, backup units, Nginx site, Fail2Ban files, logrotate policy, Certbot renewal hook, and deployment configuration. It leaves `/opt/vaultwarden/data` and `/etc/vaultwarden/rclone/` intact so the server can be restored later.

To also permanently remove all local Vaultwarden data, restore rollback copies, and rclone credentials, use the separately confirmed purge mode:

```bash
sudo ./vw-uninstall.sh --purge-data
```

`--purge-data` never removes encrypted remote backups, Let's Encrypt certificates, or packages installed through `apt`. Verify remote backups are readable before purging local data.
