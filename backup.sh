#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Robust incremental backup script for MySQL, web roots and mailboxes
#  Author: <your-name>
#  Version: 1.1 – 2025-04-24
# ---------------------------------------------------------------------------
#  - Incremental backups Mon‑Sat, full backup on Sunday
#  - Rsync with on‑the‑fly compression (‑z)
#  - Requires: bash (4+), mysqldump, mysql client, tar, gzip, rsync, ssh
#  - Recommended execution: daily via cron or a systemd‑timer as root
# ---------------------------------------------------------------------------

set -Eeuo pipefail
shopt -s lastpipe

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION (edit only this block)
# ─────────────────────────────────────────────────────────────────────────────
MYSQL_CNF="/root/.my.cnf"          # file containing user & password (600 perms!)
MYSQL_HOST="localhost"            # MySQL host (overridden by .my.cnf)

SRC_WEB="/var/www/virtual"         # web roots
SRC_MAIL="/var/mail/virtual"        # maildirs
DEST_ROOT="/directory_backup"       # local staging directory
REMOTE_USER="root"                 # remote user for push
REMOTE_HOST="123.456.789"          # remote host/IP
REMOTE_DEST="/directory_backup"    # remote base dir

EXCLUDE_DBS=(information_schema performance_schema mysql sys test)  # skip list
KEEP_DAYS=14                      # how long to keep local copies
# ─────────────────────────────────────────────────────────────────────────────

# DERIVED PATHS / COMMANDS
DATESTAMP="$(date '+%Y-%m-%d')"
DAY_OF_WEEK="$(date '+%u')"   # 1‑7 (Mon=1 … Sun=7)
HOSTNAME="$(hostname -s)"
LOCAL_DEST="${DEST_ROOT}/${DATESTAMP}"

MYSQLDUMP=$(command -v mysqldump)
MYSQL=$(command -v mysql)
TAR=$(command -v tar)
GZIP=$(command -v gzip)
RSYNC=$(command -v rsync)
SSH=$(command -v ssh)

# SNAPSHOT FILES FOR INCREMENTALS
WEB_SNAPSHOT="${DEST_ROOT}/.web.snar"
MAIL_SNAPSHOT="${DEST_ROOT}/.mail.snar"

# LOGGING + ERROR HANDLING
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
error_exit() { log "ERROR: $1"; exit 1; }
trap 'error_exit "line $LINENO: command \`$BASH_COMMAND\` exited with status $?"' ERR

# ─────────────────────────────────────────────────────────────────────────────
# PREP: DIRECTORY STRUCTURE & WEEKLY FULL‑BACKUP HANDLING
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p "${LOCAL_DEST}"/{mysql,web,mail}

if [[ "${DAY_OF_WEEK}" -eq 7 ]]; then
  log "Sunday detected → performing FULL backup and resetting snapshot files."
  rm -f "${WEB_SNAPSHOT}" "${MAIL_SNAPSHOT}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 1. MySQL DUMP
# ─────────────────────────────────────────────────────────────────────────────
log "Dumping MySQL databases …"
mapfile -t DBS < <("${MYSQL}" --defaults-file="${MYSQL_CNF}" -NBe "SHOW DATABASES;")
for db in "${DBS[@]}"; do
  if printf '%s\n' "${EXCLUDE_DBS[@]}" | grep -qx "${db}"; then
    log "  › Skipping ${db} (excluded)"
    continue
  fi
  OUT_FILE="${LOCAL_DEST}/mysql/${db}_${HOSTNAME}_${DATESTAMP}.sql.gz"
  log "  › Dumping ${db} → $(basename "${OUT_FILE}")"
  "${MYSQLDUMP}" --defaults-file="${MYSQL_CNF}" \
                --host="${MYSQL_HOST}" \
                --single-transaction --quick --skip-lock-tables --routines --events \
                "${db}" | "${GZIP}" > "${OUT_FILE}"
done

# ─────────────────────────────────────────────────────────────────────────────
# 2. WEB ROOT ARCHIVE (incremental ‑‑listed‑incremental)
# ─────────────────────────────────────────────────────────────────────────────
log "Archiving web roots …"
"${TAR}" --listed-incremental="${WEB_SNAPSHOT}" \
          -czf "${LOCAL_DEST}/web/web_${HOSTNAME}_${DATESTAMP}.tar.gz" \
          -C "${SRC_WEB}" .

# ─────────────────────────────────────────────────────────────────────────────
# 3. MAILDIR ARCHIVE (incremental ‑‑listed‑incremental)
# ─────────────────────────────────────────────────────────────────────────────
log "Archiving mailboxes …"
"${TAR}" --listed-incremental="${MAIL_SNAPSHOT}" \
          -czf "${LOCAL_DEST}/mail/mail_${HOSTNAME}_${DATESTAMP}.tar.gz" \
          -C "${SRC_MAIL}" .

# ─────────────────────────────────────────────────────────────────────────────
# 4. PUSH TO REMOTE (rsync over SSH with compression)
# ─────────────────────────────────────────────────────────────────────────────
log "Syncing backups to ${REMOTE_HOST} with rsync ‑z (compressed) …"
"${RSYNC}" -az --delete "${LOCAL_DEST}/" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DEST}/${DATESTAMP}/"

# ─────────────────────────────────────────────────────────────────────────────
# 5. RETENTION (local)
# ─────────────────────────────────────────────────────────────────────────────
log "Pruning local backups older than ${KEEP_DAYS} days …"
find "${DEST_ROOT}" -maxdepth 1 -type d -mtime "+${KEEP_DAYS}" -exec rm -rf {} +

log "Backup completed successfully ✔"
