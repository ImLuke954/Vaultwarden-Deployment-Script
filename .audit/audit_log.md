# Initial Audit
2026-08-19

## Findings

### AUD-001: Restore failure or cancellation leaves live Nginx configuration replaced
- Severity: High
- Status: OPEN
- Files: `vw-deploy.sh:88-103,488-529,837-843`
- Lines: 88-103, 488-529, 837-843
- Description: Restore installs and reloads a bootstrap or new-domain Nginx configuration before validation and destructive confirmation, with no configuration rollback.
- Root Cause: Cleanup restores data only; it does not preserve or restore `NGINX_SITE`.
- Impact: Existing Vaultwarden public access can be lost after a failed or cancelled restore.
- Reproduction: Restore an existing deployment with an unresolvable target domain, or decline data replacement after TLS setup.
- Evidence: Bootstrap installation/reload is at lines 488-514 before DNS validation at 517-518; cleanup at 88-103 has no Nginx restoration.
- Confidence: 100%

### AUD-002: Restore rollback starts replacement container instead of previous container
- Severity: High
- Status: OPEN
- Files: `vw-deploy.sh:88-103,451-480,721-747,772-848`; `README.md:193`
- Lines: 88-103, 451-480, 721-747, 772-848; README 193
- Description: A post-start restore failure starts the container currently named `vaultwarden`, even after Compose has replaced the prior container.
- Root Cause: No prior container ID, image, or configuration is retained before configuration replacement.
- Impact: Rollback can start old data under the new image/environment or leave the prior service unavailable.
- Reproduction: Restore a backup with a different image into an existing script-managed deployment and cause the post-start health check to fail.
- Evidence: `compose up -d` is line 774; cleanup only calls `docker start vaultwarden` at line 101.
- Confidence: 99%

### AUD-003: Documented upgrades create manifests with stale restore image
- Severity: High
- Status: OPEN
- Files: `README.md:327-335`; `vw-deploy.sh:465-480,660-684`; `vw-backup.sh:36-45,127-133`
- Lines: README 327-335; vw-deploy.sh 465-480, 660-684; vw-backup.sh 36-45, 127-133
- Description: The upgrade changes `.env`, but manifests source the unchanged image in `install.env` and restore trusts that stale manifest value.
- Root Cause: Upgrade and backup use different authoritative image state.
- Impact: Post-upgrade backups restore the old application version and may fail after database migrations.
- Reproduction: Upgrade from image A to B with the documented commands, back up, then restore and observe image A selected.
- Evidence: README line 328 changes only `.env`; backup manifest uses sourced `install.env` image at lines 36-45 and 127-133; restore selects manifest image at lines 660-677.
- Confidence: 100%

### AUD-004: Retention deletes unrelated archives and can delete the new backup
- Severity: Medium
- Status: OPEN
- Files: `vw-backup.sh:150-163`; `README.md:99-115`
- Lines: vw-backup.sh 150-163; README 99-115
- Description: Retention treats every `.tar.gz` object beneath the selected prefix as a Vaultwarden backup.
- Root Cause: Suffix-only filtering and lexical ordering without canonical name validation.
- Impact: Unrelated remote data, including the newly verified archive, can be deleted.
- Reproduction: Use the documented root prefix with retention 1 and add a lexically later unrelated `.tar.gz` object.
- Evidence: Recursive suffix-only listing is at lines 151-152; deletion begins at line 153; root-prefix use is documented at README lines 109-115.
- Confidence: 100%

### AUD-005: Backup accepts archives its restore path rejects for links
- Severity: Medium
- Status: OPEN
- Files: `vw-backup.sh:118-124`; `vw-deploy.sh:687-718`; `README.md:185,246-255`
- Lines: vw-backup.sh 118-124; vw-deploy.sh 687-718; README 185, 246-255
- Description: The helper archives links but restore unconditionally refuses archives containing them.
- Root Cause: Backup and restore enforce incompatible archive policies.
- Impact: A verified backup can be unusable for recovery.
- Reproduction: Place a symbolic link in the data directory, take a backup, then attempt restore.
- Evidence: Archive creation is line 124; link rejection is lines 696-698.
- Confidence: 98%

### AUD-006: HTTPS health check is local rather than public
- Severity: Medium
- Status: OPEN
- Files: `vw-deploy.sh:772-786`; `README.md:145`
- Lines: vw-deploy.sh 772-786; README 145
- Description: Success is reported after a loopback-forced HTTPS request, not a public reachability test.
- Root Cause: `curl --resolve` maps port 443 to `127.0.0.1`.
- Impact: Deployment can be declared healthy while cloud firewall or routing prevents all public HTTPS access.
- Reproduction: Permit HTTP-01 on port 80 but block external port 443.
- Evidence: The forced loopback request is line 784 and success log is line 786; README claims a public endpoint test at line 145.
- Confidence: 100%

## Summary

Critical: 0
High: 3
Medium: 3
Low: 0

# Fix Verification
2026-08-19

## Verified Fixes
- AUD-001: Status: FIXED. DNS is checked before Nginx bootstrap changes, and prior Nginx configuration is restored and reloaded on uncommitted restore failure or cancellation.
- AUD-002: Status: FIXED. Prior deployment files and container state are captured; attempted replacement containers are removed before the previous configuration is recreated or started.
- AUD-003: Status: FIXED. Documented upgrades update both image state files, and backup manifests record the active Compose/container image.
- AUD-004: Status: FIXED. Retention filters to exact direct canonical Vaultwarden archive names before deletion.
- AUD-005: Status: FIXED. Backup rejects symlinks and hard-linked files before archiving, matching restore policy.

## Remaining Open Findings
- AUD-006: Status: OPEN. The HTTPS probe uses normal DNS but still originates from the VPS, so it does not prove external public TCP/443 reachability.

# Fix Verification
2026-08-19

## Verified Fixes
- AUD-006: Status: FIXED. Deployment now requires a successful external Check-Host HTTPS probe in addition to local and normal-DNS checks. The check fails closed when the API cannot start, results cannot be read, polling expires, or no external node reports a 2xx response.

## Remaining Open Findings
- None.

# Regression Audit
2026-08-19

## Regressions Found

### R-001: Restore rollback can remove the original container before replacement
- Severity: High
- Status: OPEN
- Files: `vw-deploy.sh:96-99,112-115,857-860`; `README.md:194,241`
- Expected behavior: A failed restore preserves the original container unless a distinct replacement was created, then restores the prior data/configuration and restarts that original container.
- Actual behavior: The restore marks a replacement as attempted before Compose runs. Cleanup removes any `vaultwarden` container by name, including the original if Compose failed before replacing it, and then relies on the restored Compose file to recreate it.
- Evidence: `RESTORE_NEW_CONTAINER_ATTEMPTED=1` is assigned immediately before `compose up -d`; cleanup calls `docker rm -f vaultwarden` based only on container name; rollback calls `compose up/create` instead of restarting a recorded original container. The README documents restarting/continuing an existing container.
- Reproduction path: Use an existing running container, start a restore with `--resume`, and make Compose fail before replacement, such as a non-Compose container name conflict or a port conflict introduced after the old container is stopped. Cleanup removes the original container; if the previous Compose file is absent or the conflict remains, the rollback restart fails and the prior service stays down.
- Confidence: 94%
- Self-review: A normal Compose-managed deployment may recreate the service successfully after this removal, so the finding is limited to failure-before-replacement cases where that recreation is unavailable or fails.

## Regression Summary
- New regressions found: 1
- High: 1
- Medium: 0
- Low: 0
- Previously fixed findings were not reopened.

# Regression Fix Verification
2026-08-19

## Verified Fixes
- R-001: Status: FIXED. The restore records the previous container ID, removes only a distinct replacement container, directly restarts the original container when it remains present, and uses Compose recreation only when the original was removed.

## Remaining Open Regressions
- None.

# Release Audit
2026-08-19

## Remaining Open Findings

### AUD-007: `latest` restore selection includes unrelated `.tar.gz` objects
- Severity: Medium
- Status: OPEN
- Files: `vw-deploy.sh:685-703`; `README.md:110-116,181-182`
- Root cause: Restore lists every recursively returned object with a `.tar.gz` suffix, sorts all matches lexically, and uses the first result for `latest`.
- Impact: A normal restore using `latest` can select an unrelated archive and fail instead of restoring the available Vaultwarden backup, or install the wrong data if the unrelated archive contains a valid database.
- Evidence: `list_remote_archives` filters only by suffix at `vw-deploy.sh:688`; `choose_backup` selects index zero for `latest` at `vw-deploy.sh:696-697` and `716-717`. Root-prefix use and `latest` are documented in `README.md:110-116` and `181-182`.
- Reproduction: In a Crypt root prefix, place `vaultwarden-2026-08-19T030000Z.tar.gz` and lexically newer `zz-unrelated.tar.gz`; run restore with `--backup latest` and a legacy image tag. Sorting selects `zz-unrelated.tar.gz`.
- Confidence: 100%
- Self-review: Exact archive selection is unaffected, but the supported `latest` path remains incorrect. This is separate from the fixed retention logic.

### AUD-008: `--resume` loses a persisted Crypt-root backup prefix
- Severity: Medium
- Status: OPEN
- Files: `vw-deploy.sh:298-317,338-344,494-505`; `README.md:110-116,238-241`
- Root cause: `.` is normalized to an empty prefix and persisted as empty; resume reloads that empty value, then treats it as unset and applies the default `vaultwarden-backups`.
- Impact: A resumed deployment configured for root-level backups searches a different remote path or fails to find valid backups; non-interactive resume stops at the prompt.
- Evidence: Root-prefix normalization is at `vw-deploy.sh:341`, persistence at `vw-deploy.sh:494-505`, reload at `vw-deploy.sh:307-312`, and defaulting at `vw-deploy.sh:338-340`. The supported root prefix and resume promise are documented in `README.md:110-116` and `238-241`.
- Reproduction: Deploy with `--backup-prefix .`, then run `--mode restore --resume` without a prefix and accept the displayed default. The operation uses `vaultwarden-backups` instead of the saved Crypt root.
- Confidence: 100%
- Self-review: Repeating `--backup-prefix .` avoids the defect, but that workaround does not implement the documented resume behavior.

## Release Decision

NOT READY FOR RELEASE

# Release Fix Verification
2026-08-19

## Verified Fixes
- AUD-007: Status: FIXED. Restore retains legacy archives for exact-name or numbered selection, but `latest` now selects only a direct canonical `vaultwarden-YYYY-MM-DDTHHMMSSZ.tar.gz` archive. If none exists, `latest` fails rather than selecting an unrelated object.
- AUD-008: Status: FIXED. Resume marks loaded backup settings separately from their value, so an intentionally empty persisted prefix remains the Crypt root and is not replaced by the default prefix.

## Remaining Open Findings
- None.

## Release Decision

READY FOR RELEASE
