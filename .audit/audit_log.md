# Initial Audit
2026-08-20

## Findings

### AUD-001
- Severity: High
- Status: OPEN
- Files: `vw-deploy.sh`; `README.md`
- Lines: `vw-deploy.sh`: 1182-1207, 1577-1579; `README.md`: 29-39
- Description: Fresh and restore deployments that need a new admin-token hash abort on Ubuntu 20.04 because the script invokes an unsupported `script` option.
- Root Cause: `generate_admin_hash` unconditionally passes `-E never` to `script`, but Ubuntu 20.04's util-linux 2.34 `script` does not implement `-E`. The repository supports Ubuntu without a minimum release or a compatibility check.
- Impact: The deployment exits after pulling the Vaultwarden image and before it writes the deployment configuration, so supported Ubuntu 20.04 hosts cannot complete a fresh install or restore requiring a new admin password.
- Reproduction: On Ubuntu 20.04, run `script -q -e -E never -c true /dev/null`, then run the fresh deployment path without an existing valid `ADMIN_TOKEN` hash. `script` rejects `-E`; `pipefail` propagates that failure from `generate_admin_hash`.
- Evidence: `run_deployment` always pulls the image and calls `generate_admin_hash` at lines 1577-1579. That function requires a TTY, then executes `script -q -e -E never` at lines 1182-1190 without testing option support. The Ubuntu 20.04 util-linux 2.34 `script(1)` option list contains no `-E` option.
- Confidence: 99%

### AUD-002
- Severity: High
- Status: OPEN
- Files: `vw-deploy.sh`; `templates/fail2ban/action.d/cloudflare-token.conf`; `VAULTWARDEN_AUTOMATION_PLAN.md`
- Lines: `vw-deploy.sh`: 851-860, 879-882; `templates/fail2ban/action.d/cloudflare-token.conf`: 7-21; `VAULTWARDEN_AUTOMATION_PLAN.md`: 53, 68
- Description: Cloudflare API bearer tokens are passed to `curl` as command-line arguments during credential validation and every Fail2Ban ban/unban action.
- Root Cause: The validation call interpolates the token into `curl -H`, and the Fail2Ban action expands `<cftoken>` into the same `curl -H` argument.
- Impact: On the default Linux `/proc` configuration, a different local user can read a running process command line and obtain the scoped token. The token authorizes Cloudflare firewall-rule changes for the configured zone.
- Reproduction: Configure Cloudflare bans, then while deployment validation or a Fail2Ban ban/unban is running, inspect process arguments as an unprivileged local user: `tr '\0' ' ' </proc/PID/cmdline`. The `Authorization: Bearer TOKEN` argument is visible for the invoked `curl` process on a default `hidepid=0` `/proc` mount.
- Evidence: Lines 854-858 create `curl` with `-H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"`. Lines 880-881 place the token into Fail2Ban's `cftoken` setting, and template line 21 expands that setting in a `curl` header argument for the commands at lines 7-18. The project plan explicitly requires that secrets not be passed as command-line arguments.
- Confidence: 98%

### AUD-003
- Severity: Medium
- Status: OPEN
- Files: `vw-backup.sh`; `vw-deploy.sh`
- Lines: `vw-backup.sh`: 104-107, 138-181; `vw-deploy.sh`: 785-810, 944-955
- Description: Installations sharing a Crypt remote and backup prefix delete each other's canonical backups during retention, and can overwrite each other's backup objects when they run in the same second.
- Root Cause: Backup object names contain only a UTC timestamp with one-second resolution, while retention treats every canonical archive in the configured remote/prefix as the local installation's history. The lock is only a local host lock and no per-installation namespace is recorded or enforced.
- Impact: A valid backup belonging to another installation can be removed. Simultaneous hosts can also upload different archives to the same remote object name, leaving sidecars and archive contents inconsistent.
- Reproduction: Configure two installations with the same `RCLONE_REMOTE`, `BACKUP_PREFIX`, and retention `1`. Create a backup on host A, then run host B's backup. Host B lists both canonical archives, sorts them together, and deletes A's older archive as expired. If both jobs run in the same second, both use the identical `vaultwarden-TIMESTAMP` names.
- Evidence: Lines 138-157 derive archive, checksum, and manifest names solely from `date -u +%Y-%m-%dT%H%M%SZ`. Lines 171-181 enumerate and delete all canonical names under the shared path. Lines 104-107 use `flock` only on `/run/lock`, which is not shared by hosts. Deployment settings persist only remote and prefix at `vw-deploy.sh` lines 944-955.
- Confidence: 99%

### AUD-004
- Severity: Low
- Status: OPEN
- Files: `vw-deploy.sh`; `vw-backup.sh`
- Lines: `vw-deploy.sh`: 843-849, 1359-1389, 1414-1415; `vw-backup.sh`: 110-114, 144
- Description: Restore accepts FIFO and device-file archive members even though the data directory is expected to contain regular Vaultwarden files. A FIFO at the configured log path is retained and can block Vaultwarden's log initialization.
- Root Cause: Archive validation rejects only symbolic and hard links. It accepts tar member types such as FIFO (`p`), block device (`b`), and character device (`c`), extracts them as root, and preserves them with `cp -a`. The backup helper also does not reject these special file types.
- Impact: A selected archive containing a valid SQLite database and a FIFO at `data/vaultwarden.log` passes validation but installs the FIFO into the live data directory. `ensure_vaultwarden_log` leaves it in place, and opening the configured `LOG_FILE` for writing can block without a reader, preventing service startup.
- Reproduction: Create an archive with a valid `data/db.sqlite3` and `mkfifo data/vaultwarden.log`, upload it to the configured Crypt remote, and restore it. The archive has no links, passes `PRAGMA integrity_check`, and the FIFO remains at `/opt/vaultwarden/data/vaultwarden.log` after the restore.
- Evidence: The check at lines 1368-1370 rejects only `l` and `h` entries. Lines 1379 and 1415 extract and copy permitted members with metadata preserved. Lines 844-848 reject only symlinks and create the log file only when no filesystem entry exists. The configured log path is `/data/vaultwarden.log` at line 825.
- Confidence: 96%

### AUD-005
- Severity: Low
- Status: OPEN
- Files: `vw-deploy.sh`
- Lines: 61-64, 498-524, 593-606, 831-860
- Description: An explicitly supplied `CLOUDFLARE_API_TOKEN` is discarded by `--resume`; the persisted token silently replaces it.
- Root Cause: `load_resume_settings` sources `cloudflare.env` after the environment token is initialized, but preserves CLI values only for non-secret settings. It never saves and reapplies the caller-supplied token.
- Impact: An operator cannot rotate a revoked Cloudflare token through the documented environment-variable interface when resuming a deployment. The deployment validates and rewrites the obsolete persisted token, or fails when that token has been revoked.
- Reproduction: Create `/etc/vaultwarden/cloudflare.env` with token A. Run `CLOUDFLARE_API_TOKEN=tokenB ./vw-deploy.sh --mode restore --resume` with Cloudflare enabled. `source "$CLOUDFLARE_ENV"` replaces token B with token A, and subsequent validation uses token A.
- Evidence: Lines 61-64 retain an environment-provided token and state that it should be preserved. Lines 509-513 source the persisted Cloudflare file. Unlike domain, email, image, remote, prefix, retention, and zone values, no saved environment token is restored after this source operation. Lines 851-860 validate the overwritten value and lines 836-840 persist it again.
- Confidence: 99%

## Summary

Critical: 0
High: 2
Medium: 1
Low: 2

# Remediation Verification
2026-08-20

## Fixed Findings

### AUD-001
- Status: FIXED
- Evidence: `generate_admin_hash` detects `script --echo` support before adding `-E never`, retaining the compatible `-q -e -c` invocation for util-linux 2.34.

### AUD-002
- Status: FIXED
- Evidence: Cloudflare validation writes headers to a root-only temporary curl config, and the Fail2Ban action pipes headers to `curl --config -`; bearer tokens are not command-line arguments.

### AUD-003
- Status: FIXED
- Evidence: New deployments persist a random `BACKUP_INSTANCE_ID`; backup archive names and retention filtering include that ID, preventing shared-prefix collisions and cross-installation deletion.

### AUD-004
- Status: FIXED
- Evidence: Backup rejects all non-directory/non-regular entries, restore rejects all tar member types except regular files and directories, and the log path must be a regular file.

### AUD-005
- Status: FIXED
- Evidence: `load_resume_settings` saves and restores a caller-supplied `CLOUDFLARE_API_TOKEN` after sourcing persisted Cloudflare settings.

## Summary

Critical: 0
High: 0
Medium: 0
Low: 0
