# Vaultwarden Automated Deployment and Restore Plan

## Goal

Provide one Bash-based interactive provisioner for Ubuntu/Debian VPS hosts with two modes:

1. Fresh Vaultwarden installation
2. Restore Vaultwarden from encrypted Google Drive backups

The provisioner will install and configure Docker, Vaultwarden, Nginx, Let's Encrypt TLS, rclone, and recurring encrypted backups.

## Architecture

The implementation should use a single strict Bash entry point, supported by a small set of templates and installed helper scripts.

```text
project/
├── vw-deploy.sh                 # Interactive fresh/restore provisioner
├── vw-backup.sh                 # Consistent backup helper
├── templates/
│   ├── compose.yml
│   └── nginx.conf
└── systemd/
    ├── vw-backup.service
    └── vw-backup.timer
```

The installer creates these files on the VPS:

```text
/etc/vaultwarden/
├── install.env                  # Root-only non-secret deployment settings
└── rclone/rclone.conf           # Root-only Google Drive and Crypt configuration

/opt/vaultwarden/
├── compose.yml
└── data/                        # Vaultwarden persistent data mounted at /data

/var/lib/vaultwarden/restore/    # Root-only temporary restore staging area
```

The script must use `set -Eeuo pipefail`, `umask 077`, an execution lock, cleanup traps, and redacted logs. Secrets must not be written to logs or passed as command-line arguments.

## Runtime Configuration

The provisioner prompts for or obtains:

- Vaultwarden domain name
- Email address for Let's Encrypt
- Pinned Vaultwarden image tag
- Admin token, stored only as an Argon2 hash
- rclone Crypt remote and backup prefix
- Backup retention count

`/etc/vaultwarden/install.env` must be mode `0600`. The rclone directory must be mode `0700` and `rclone.conf` mode `0600`.

The script invokes rclone with `--config /etc/vaultwarden/rclone/rclone.conf` so it never depends on the invoking user's home directory.

## Mode 1: Fresh Installation

1. Verify root or sudo access, Ubuntu/Debian support, free storage, and that ports 80 and 443 are available.
2. Verify DNS for the requested domain before requesting a TLS certificate.
3. Install Docker Engine and Docker Compose plugin, rclone, Nginx, Certbot, SQLite tools, and required utilities.
4. Check for `/etc/vaultwarden/rclone/rclone.conf`.
5. If an existing rclone configuration is available, instruct the operator to place it in that location with the required permissions.
6. If no configuration is available, run interactive `rclone config` to authorize Google Drive and configure the Crypt remote.
7. Verify that the configured Crypt remote can list the backup prefix.
8. Generate the Docker Compose configuration, Nginx site configuration, systemd backup service, and timer.
9. Request the Let's Encrypt certificate, start Vaultwarden, and verify its `/alive` endpoint locally and through external HTTPS probe nodes.
10. Enable the recurring backup timer.

## Mode 2: Restore From Google Drive

1. Complete the same server, Docker, Nginx, TLS, and rclone preparation as a fresh installation.
2. List decrypted backups from the configured `gcrypt:` remote and let the operator select one. `latest` must be an explicit selectable option.
3. Download only the selected archive, checksum, and manifest to `/var/lib/vaultwarden/restore/`.
4. For the new archive format, verify the SHA-256 checksum and manifest before extraction.
5. Inspect the archive paths before extraction and reject absolute paths, parent-directory traversal, and unexpected symbolic links.
6. Extract safely to a staging directory and locate exactly one valid Vaultwarden data root.
7. Validate expected data, including `db.sqlite3`, attachment and send directories, and RSA key files when present.
8. Run SQLite `PRAGMA integrity_check` before installing the data.
9. Refuse to overwrite populated data unless the operator explicitly confirms. Preserve existing data as a timestamped local rollback directory.
10. Move the validated data into `/opt/vaultwarden/data`, apply restrictive permissions, and start the selected pinned Vaultwarden image.
11. Verify the container status, logs, SQLite integrity, and local plus externally probed HTTPS `/alive` endpoints.
12. Apply the requested `DOMAIN` configuration and warn that passkeys/WebAuthn registered for the old domain must be re-registered.

## Existing Backup Compatibility

The restore path must support both the current archives described in the existing guide and the new canonical archive format.

Current archives may contain different top-level paths, such as `vw-data/`, `data/`, or an archived absolute source path ending in `data/`. The restore script must locate a single directory containing `db.sqlite3` rather than assuming one fixed archive path.

Existing archives may not include a checksum or Vaultwarden version. The script must perform archive structure and SQLite validation, display a warning, and require the operator to provide the old server's Vaultwarden image tag. It must not default to `latest` during restoration.

## Backup Format and Process

New backups must use a canonical timestamped format:

```text
vaultwarden-backups/
├── vaultwarden-2026-08-19T030000Z.tar.gz
├── vaultwarden-2026-08-19T030000Z.tar.gz.sha256
└── vaultwarden-2026-08-19T030000Z.manifest.json
```

The manifest records the backup timestamp, archive format version, pinned Vaultwarden image tag, and verification metadata.

The backup helper must:

1. Acquire a lock to prevent concurrent backups or restores.
2. Stop Vaultwarden briefly before creating the archive, ensuring a consistent SQLite database and filesystem snapshot.
3. Always restart Vaultwarden through a cleanup trap, including when the archive or upload fails.
4. Create the archive and its SHA-256 checksum in a root-only staging directory.
5. Upload through the encrypted `gcrypt:vaultwarden-backups/` remote using `rclone copy`.
6. Verify that the remote upload succeeded before deleting local staging files.
7. Apply retention only after a successful verified backup.

`rclone sync` must not be used because a local failure or deletion could remove valid remote backups.

## Security and Reliability Requirements

- Pin the Vaultwarden image tag. Do not use `latest` for a restore.
- Restore the same image version as the source server first, then upgrade Vaultwarden deliberately after successful validation.
- Keep rclone configuration and Crypt keys outside the repository and out of all logs.
- Do not expose the Vaultwarden container directly to the internet; Nginx handles public TLS traffic.
- Use a root-only staging path, never a world-readable temporary directory.
- Include `--dry-run`, `--mode fresh|restore`, `--backup latest|NAME`, and `--resume` options.
- Require interactive confirmation before destructive actions, including overwriting data and deleting expired backups.
- Validate DNS, certificate issuance, and external HTTPS reachability before declaring the deployment successful.

## Implementation Order

1. Create the strict Bash framework, CLI parsing, protected configuration handling, logging, locking, and preflight checks.
2. Add Docker, Vaultwarden Compose, Nginx, and Certbot deployment functions.
3. Add rclone configuration detection, import guidance, interactive OAuth fallback, and remote verification.
4. Implement the fresh-install workflow and health checks.
5. Implement canonical backup creation, upload verification, retention, and systemd scheduling.
6. Implement restore selection, legacy archive support, validation, rollback protection, and post-restore checks.
7. Test fresh installation, restore from a valid current backup, checksum failure, invalid archive paths, interrupted backup restart behavior, and attempted overwrite of an existing data directory.
