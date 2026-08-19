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
- `templates/compose.yml`: Docker Compose service definition
- `templates/nginx.conf`: Nginx HTTP to HTTPS redirect and reverse proxy
- `systemd/vw-backup.service`: backup service unit
- `systemd/vw-backup.timer`: daily backup timer
- `VAULTWARDEN_AUTOMATION_PLAN.md`: architecture and implementation plan

## Requirements

The target must be a real Ubuntu or Debian VPS with:

- Root access or an account that can run the script with `sudo`
- A public DNS record for the Vaultwarden domain pointing to the VPS
- TCP ports 80 and 443 available for Nginx and Let's Encrypt validation
- At least 5 GiB of free root filesystem space recommended
- A Google Drive rclone configuration containing the original Crypt remote, or permission to authenticate interactively

The script installs Docker, Docker Compose, Nginx, Certbot, rclone, SQLite, jq, and supporting packages through `apt`.

Do not run the provisioner on the existing production server unless you intend to modify that server. It is designed to configure a target VPS.

## Quick Start

Copy this repository to the target VPS, then run:

```bash
sudo chmod 700 vw-deploy.sh vw-backup.sh
sudo ./vw-deploy.sh
```

The script presents this menu:

```text
1. Fresh installation
2. Restore from encrypted Google Drive backup
```

The script asks for the public domain, Let's Encrypt email, pinned Vaultwarden image tag when needed, rclone Crypt remote, backup prefix, retention count, and a new admin password.

Before running the script, make sure the DNS record already resolves to this VPS. The script also checks DNS immediately before requesting the certificate.

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

The configuration should contain the same Crypt remote used by the original server. The default remote name expected by the script is `gcrypt`.

The script verifies both the remote name and its configured type:

```text
type = crypt
```

It will not use a plain Google Drive remote for backups or restores.

### Interactive configuration

If the file is absent, the script asks for a local configuration path. Leave that answer blank to start:

```bash
rclone config
```

Complete Google Drive OAuth and configure the Crypt remote using the same Crypt password and salt as the original server. The Crypt password and salt cannot be recovered by this project if they are lost.

The rclone configuration contains Google credentials and encryption metadata. Keep it outside this repository and never paste it into logs or source control.

### Backup prefix

The backup prefix is the path below the selected Crypt remote.

New backups use this default:

```text
vaultwarden-backups
```

The older manual guide copied archives directly to the Crypt remote root. To restore those archives, enter a single period (`.`) when asked for the prefix, or pass:

```bash
--backup-prefix .
```

The script normalizes `.` to an empty root prefix.

## Fresh Installation

Run the interactive command and select `1`, or use `--mode fresh`.

Example:

```bash
sudo ./vw-deploy.sh \
  --mode fresh \
  --domain vault.example.com \
  --email admin@example.com \
  --image-tag 1.34.3 \
  --rclone-remote gcrypt \
  --backup-prefix vaultwarden-backups \
  --retention 30
```

The admin password is entered twice without echoing. The script passes it through standard input to the selected Vaultwarden image's hash command and stores only the resulting Argon2 hash. The plaintext password is not written to a file or passed as a command-line argument.

The fresh-install flow:

1. Validates the operating system, free space, lock state, DNS, and prerequisites.
2. Installs and starts Docker, Nginx, rclone, Certbot, SQLite, jq, and required packages.
3. Imports or creates the rclone configuration and verifies the Crypt remote.
4. Refuses to overwrite an existing data directory unless `--resume` is used.
5. Pulls the pinned Vaultwarden image.
6. Creates the Compose and Vaultwarden environment files.
7. Obtains or reuses a Let's Encrypt certificate.
8. Starts Vaultwarden and tests both the local and public `/alive` endpoints.
9. Installs and enables the daily encrypted backup timer.

## Restore From Google Drive

Run the interactive command and select `2`, or use `--mode restore`.

Example for a new-format backup:

```bash
sudo ./vw-deploy.sh \
  --mode restore \
  --domain new-vault.example.com \
  --email admin@example.com \
  --backup latest \
  --rclone-remote gcrypt \
  --backup-prefix vaultwarden-backups \
  --retention 30
```

For an archive from the older guide, use the root prefix and explicitly provide the image version used by the old server:

```bash
sudo ./vw-deploy.sh \
  --mode restore \
  --domain new-vault.example.com \
  --email admin@example.com \
  --backup latest \
  --image-tag 1.34.3 \
  --rclone-remote gcrypt \
  --backup-prefix .
```

The restore flow:

1. Lists `.tar.gz` archives in the selected Crypt prefix.
2. Lets the operator choose `latest`, a number, or an exact archive path.
3. Downloads only the selected archive and any checksum or manifest sidecars.
4. Verifies the SHA-256 checksum when present.
5. Validates new-format manifests and their image/checksum metadata.
6. Rejects absolute paths, parent-directory traversal, symlinks, and hardlinks.
7. Extracts to a root-only staging directory.
8. Locates exactly one `db.sqlite3` and runs SQLite `PRAGMA integrity_check`.
9. Stops an existing Vaultwarden container only when data replacement is ready.
10. Requires confirmation before replacing non-empty data.
11. Preserves old data under `/opt/vaultwarden/data.pre-restore.TIMESTAMP`.
12. Installs the validated data, starts the pinned image, and checks health over HTTPS.

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
--rclone-remote NAME       rclone Crypt remote, default gcrypt
--backup-prefix PATH       Path below the Crypt remote
--retention COUNT          Number of remote archives to retain, default 30
--backup NAME|latest       Archive to restore
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
8. Restarts Vaultwarden even when an earlier backup step fails.

The helper deliberately does not use `rclone sync`. A local failure must not delete valid remote backups.

### Backup object format

New backups are stored as:

```text
vaultwarden-TIMESTAMP.tar.gz
vaultwarden-TIMESTAMP.tar.gz.sha256
vaultwarden-TIMESTAMP.manifest.json
```

The manifest records the archive format version, UTC creation time, image reference, and SHA-256 value.

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
```

The provisioner uses `/run/lock/vaultwarden-operation.lock` to prevent backup, restore, and deployment operations from running concurrently.

## Security Notes

- Keep `/etc/vaultwarden/rclone/rclone.conf` out of Git and restrict it to mode `0600`.
- Keep `/etc/vaultwarden/vaultwarden.env` root-only because it contains the admin token hash.
- Do not place Crypt passwords, Google OAuth tokens, admin passwords, or backup archives in this repository.
- The Vaultwarden container is not exposed directly to the internet.
- The image tag is pinned to avoid an unexpected application/database migration during restore.
- Restoring a backup does not decrypt vault contents. Users still need their own master passwords.
- Anyone who obtains the rclone configuration and Crypt password may be able to access the encrypted backup files. Protect both independently.
- Test restoring a backup on a separate VPS before relying on it for disaster recovery.

## Updating Vaultwarden

Do not update the image by changing it to `latest`. Use a deliberate, pinned upgrade:

```bash
sudo cp /opt/vaultwarden/compose.yml /opt/vaultwarden/compose.yml.before-upgrade
sudo sed -i 's/vaultwarden\/server:[^ ]*/vaultwarden\/server:NEW_TAG/' /opt/vaultwarden/.env
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
  lsf --recursive gcrypt:vaultwarden-backups
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

### HTTPS or certificate issuance fails

Verify DNS and port availability:

```bash
getent hosts vault.example.com
sudo ss -ltnp | grep -E ':(80|443)'
sudo nginx -t
sudo journalctl -u nginx --no-pager -n 100
```

Let's Encrypt must be able to reach the VPS on port 80. A pre-existing web server, incorrect DNS, or a cloud firewall can prevent validation.

### Backup service fails

```bash
sudo systemctl status vw-backup.service
sudo journalctl -u vw-backup.service --no-pager -n 200
sudo systemctl start vw-backup.service
```

Confirm that Docker is running, the rclone remote is still type `crypt`, the Crypt password is correct, and sufficient local and Google Drive space is available.

## Removal

There is no automatic uninstall command because deleting Vaultwarden data or backups is destructive. To remove the running service while preserving data, stop and disable the containers and timer manually:

```bash
sudo systemctl disable --now vw-backup.timer
sudo docker compose --project-directory /opt/vaultwarden \
  -f /opt/vaultwarden/compose.yml down
```

Review and remove `/opt/vaultwarden`, `/etc/vaultwarden`, the Nginx site, and systemd units only after exporting any required data and confirming that backups are readable.
