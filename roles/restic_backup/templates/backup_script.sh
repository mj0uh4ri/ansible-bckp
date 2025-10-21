#!/bin/bash
set -euo pipefail

# Configuration
HOSTNAME="{{ inventory_hostname }}"
RESTIC_REPO="{{ restic_repo }}"
RESTIC_PASSWORD_FILE="{{ backup_config_dir }}/${HOSTNAME}_password"
BACKUP_PATHS_FILE="{{ backup_config_dir }}/backup_paths.txt"
{% if backup_excludes is defined %}
EXCLUDE_FILE="{{ backup_config_dir }}/exclude_patterns.txt"
{% endif %}
LOG_FILE="{{ backup_log_dir }}/backup-$(date +%Y%m%d-%H%M%S).log"
LOCK_FILE="/var/run/restic-backup.lock"

# SSH configuration
export RESTIC_SSH_COMMAND="ssh -i {{ backup_ssh_dir }}/restic_backup_key -o StrictHostKeyChecking=no"
export RESTIC_PASSWORD_FILE

# Logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Cleanup function
cleanup() {
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT

# Check for existing backup process
if [ -f "$LOCK_FILE" ]; then
    log "ERROR: Backup already running (lock file exists)"
    exit 1
fi
touch "$LOCK_FILE"

log "Starting backup for $HOSTNAME"

{% if backup_pre_script is defined %}
# Run pre-backup script
log "Running pre-backup script"
{{ backup_pre_script }} >> "$LOG_FILE" 2>&1 || {
    log "ERROR: Pre-backup script failed"
    exit 1
}
{% endif %}

# Perform backup
log "Starting restic backup"
restic -r "$RESTIC_REPO" backup \
    --files-from="$BACKUP_PATHS_FILE" \
{% if backup_excludes is defined %}
    --exclude-file="$EXCLUDE_FILE" \
{% endif %}
    --tag "hostname:$HOSTNAME" \
    --tag "automated" \
    --verbose >> "$LOG_FILE" 2>&1 || {
    log "ERROR: Backup failed"
    exit 1
}

# Forget old snapshots and prune
log "Applying retention policy"
restic -r "$RESTIC_REPO" forget \
    --tag "hostname:$HOSTNAME" \
    --keep-daily {{ retention_daily | default(7) }} \
    --keep-weekly {{ retention_weekly | default(4) }} \
    --keep-monthly {{ retention_monthly | default(6) }} \
    --keep-yearly {{ retention_yearly | default(2) }} \
    --prune \
    --verbose >> "$LOG_FILE" 2>&1

# Check repository health
log "Checking repository integrity"
restic -r "$RESTIC_REPO" check \
    --read-data-subset=5% >> "$LOG_FILE" 2>&1

log "Backup completed successfully"

# Keep only last 30 days of logs
find /var/log/restic/ -name "backup-*.log" -mtime +30 -delete

exit 0