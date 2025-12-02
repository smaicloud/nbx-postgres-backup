#!/usr/bin/env bash
#
# pg_backup_rotated.sh
#
# Wrapper around pg_dump logic with simple rotation.
# - Loads configuration from pg_backup.config (or via -c <file>)
# - Creates either a *daily* or *weekly* backup directory
# - Deletes old backup directories based on DAYS_TO_KEEP and WEEKS_TO_KEEP
#
# Usage:
#   ./pg_backup_rotated.sh              # uses default config search
#   ./pg_backup_rotated.sh -c /path/to/pg_backup.config
#

set -euo pipefail
IFS=$'\n\t'

#######################################
# Helper functions
#######################################

log() {
  printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  printf '[%s] [ERROR] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2
  exit 1
}

#######################################
# Load configuration
#######################################

CONFIG_FILE_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c)
      CONFIG_FILE_PATH="$2"
      shift 2
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      die "Unexpected argument: $1"
      ;;
  esac
done

# Search for config file if not provided explicitly
if [[ -z "${CONFIG_FILE_PATH}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for candidate in \
    "./pg_backup.config" \
    "${SCRIPT_DIR}/pg_backup.config" \
    "/etc/pg_backup.config"
  do
    if [[ -r "${candidate}" ]]; then
      CONFIG_FILE_PATH="${candidate}"
      break
    fi
  done
fi

[[ -n "${CONFIG_FILE_PATH}" ]] || die "No readable pg_backup.config found"
[[ -r "${CONFIG_FILE_PATH}" ]] || die "Config file '${CONFIG_FILE_PATH}' not readable"

log "Using config file: ${CONFIG_FILE_PATH}"
# shellcheck disable=SC1090
source "${CONFIG_FILE_PATH}"

#######################################
# Validate environment & defaults
#######################################

BACKUP_USER="${BACKUP_USER:-}"
HOSTNAME="${HOSTNAME:-localhost}"
USERNAME="${USERNAME:-postgres}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/postgresql}"
SCHEMA_ONLY_LIST="${SCHEMA_ONLY_LIST:-}"
ENABLE_PLAIN_BACKUPS="${ENABLE_PLAIN_BACKUPS:-yes}"
ENABLE_CUSTOM_BACKUPS="${ENABLE_CUSTOM_BACKUPS:-no}"
ENABLE_GLOBALS_BACKUPS="${ENABLE_GLOBALS_BACKUPS:-no}"
DAY_OF_WEEK_TO_KEEP="${DAY_OF_WEEK_TO_KEEP:-7}"
DAYS_TO_KEEP="${DAYS_TO_KEEP:-14}"
WEEKS_TO_KEEP="${WEEKS_TO_KEEP:-8}"

# Enforce backup user if configured
if [[ -n "${BACKUP_USER}" ]]; then
  CURRENT_USER="$(id -un)"
  if [[ "${CURRENT_USER}" != "${BACKUP_USER}" ]]; then
    die "Script must be run as '${BACKUP_USER}', current user is '${CURRENT_USER}'"
  fi
fi

if [[ ! -d "${BACKUP_DIR}" ]]; then
  log "Creating backup directory: ${BACKUP_DIR}"
  mkdir -p "${BACKUP_DIR}"
fi

#######################################
# Core backup function
#######################################

perform_backups() {
  local SUFFIX="$1"

  local DATE_STAMP
  DATE_STAMP="$(date +%Y-%m-%d)"
  local FINAL_BACKUP_DIR="${BACKUP_DIR}/${DATE_STAMP}${SUFFIX}"

  mkdir -p "${FINAL_BACKUP_DIR}"
  log "Writing backups into: ${FINAL_BACKUP_DIR}"

  # Globals
  if [[ "${ENABLE_GLOBALS_BACKUPS}" == "yes" ]]; then
    log "Backing up global objects (roles, privileges, tablespaces)"
    if ! pg_dumpall -g -h "${HOSTNAME}" -U "${USERNAME}" \
      | gzip > "${FINAL_BACKUP_DIR}/globals.sql.gz".in_progress; then
      die "Failed to dump global objects"
    fi
    mv "${FINAL_BACKUP_DIR}/globals.sql.gz".in_progress \
       "${FINAL_BACKUP_DIR}/globals.sql.gz"
  else
    log "Skipping globals backup (ENABLE_GLOBALS_BACKUPS != yes)"
  fi

  # Schema-only backups
  local SCHEMA_ONLY_CLAUSE=""
  if [[ -n "${SCHEMA_ONLY_LIST}" ]]; then
    for SCHEMA_ONLY_DB in ${SCHEMA_ONLY_LIST//,/ }; do
      SCHEMA_ONLY_CLAUSE="${SCHEMA_ONLY_CLAUSE} OR datname = '${SCHEMA_ONLY_DB}'"
    done
  fi

  local SCHEMA_ONLY_DB_LIST=""
  if [[ -n "${SCHEMA_ONLY_CLAUSE}" ]]; then
    local SCHEMA_ONLY_QUERY="SELECT datname
                             FROM pg_database
                             WHERE datallowconn
                               AND NOT datistemplate
                               AND (false ${SCHEMA_ONLY_CLAUSE})
                             ORDER BY datname;"
    SCHEMA_ONLY_DB_LIST="$(psql -h "${HOSTNAME}" -U "${USERNAME}" -At -c "${SCHEMA_ONLY_QUERY}" postgres || true)"
  fi

  if [[ -n "${SCHEMA_ONLY_DB_LIST}" ]]; then
    log "Schema-only backups for databases:"
    printf '%s\n' "${SCHEMA_ONLY_DB_LIST}"
  else
    log "No databases matched for schema-only backup"
  fi

  local DATABASE
  for DATABASE in ${SCHEMA_ONLY_DB_LIST}; do
    log "Schema-only backup for database: ${DATABASE}"

    if [[ "${ENABLE_PLAIN_BACKUPS}" == "yes" ]]; then
      if ! pg_dump -Fp -s -h "${HOSTNAME}" -U "${USERNAME}" "${DATABASE}" \
        | gzip > "${FINAL_BACKUP_DIR}/${DATABASE}_schema.sql.gz".in_progress; then
        die "Failed to produce schema-only plain backup of ${DATABASE}"
      fi
      mv "${FINAL_BACKUP_DIR}/${DATABASE}_schema.sql.gz".in_progress \
         "${FINAL_BACKUP_DIR}/${DATABASE}_schema.sql.gz"
    fi

    if [[ "${ENABLE_CUSTOM_BACKUPS}" == "yes" ]]; then
      if ! pg_dump -Fc -s -h "${HOSTNAME}" -U "${USERNAME}" "${DATABASE}" \
        -f "${FINAL_BACKUP_DIR}/${DATABASE}_schema.custom".in_progress; then
        die "Failed to produce schema-only custom backup of ${DATABASE}"
      fi
      mv "${FINAL_BACKUP_DIR}/${DATABASE}_schema.custom".in_progress \
         "${FINAL_BACKUP_DIR}/${DATABASE}_schema.custom"
    fi
  done

  # Full backups (excluding schema-only)
  local EXCLUDE_SCHEMA_ONLY_CLAUSE=""
  if [[ -n "${SCHEMA_ONLY_LIST}" ]]; then
    for SCHEMA_ONLY_DB in ${SCHEMA_ONLY_LIST//,/ }; do
      EXCLUDE_SCHEMA_ONLY_CLAUSE="${EXCLUDE_SCHEMA_ONLY_CLAUSE} AND datname <> '${SCHEMA_ONLY_DB}'"
    done
  fi

  local FULL_BACKUP_QUERY="SELECT datname
                           FROM pg_database
                           WHERE datallowconn
                             AND NOT datistemplate
                             ${EXCLUDE_SCHEMA_ONLY_CLAUSE}
                           ORDER BY datname;"

  local FULL_DB_LIST
  FULL_DB_LIST="$(psql -h "${HOSTNAME}" -U "${USERNAME}" -At -c "${FULL_BACKUP_QUERY}" postgres || true)"

  if [[ -n "${FULL_DB_LIST}" ]]; then
    log "Full backups for databases:"
    printf '%s\n' "${FULL_DB_LIST}"
  else
    log "No databases matched for full backup"
  fi

  for DATABASE in ${FULL_DB_LIST}; do
    log "Full backup for database: ${DATABASE}"

    if [[ "${ENABLE_PLAIN_BACKUPS}" == "yes" ]]; then
      if ! pg_dump -Fp -h "${HOSTNAME}" -U "${USERNAME}" "${DATABASE}" \
        | gzip > "${FINAL_BACKUP_DIR}/${DATABASE}.sql.gz".in_progress; then
        die "Failed to produce plain backup of ${DATABASE}"
      fi
      mv "${FINAL_BACKUP_DIR}/${DATABASE}.sql.gz".in_progress \
         "${FINAL_BACKUP_DIR}/${DATABASE}.sql.gz"
    fi

    if [[ "${ENABLE_CUSTOM_BACKUPS}" == "yes" ]]; then
      if ! pg_dump -Fc -h "${HOSTNAME}" -U "${USERNAME}" "${DATABASE}" \
        -f "${FINAL_BACKUP_DIR}/${DATABASE}.custom".in_progress; then
        die "Failed to produce custom backup of ${DATABASE}"
      fi
      mv "${FINAL_BACKUP_DIR}/${DATABASE}.custom".in_progress \
         "${FINAL_BACKUP_DIR}/${DATABASE}.custom"
    fi
  done

  log "Backup run for suffix '${SUFFIX}' completed."
}

#######################################
# Rotation logic
#######################################

DAY_OF_WEEK="$(date +%u)"

# Weekly backup (if today matches configured weekday)
if [[ "${DAY_OF_WEEK}" == "${DAY_OF_WEEK_TO_KEEP}" ]]; then
  log "Weekly backup day (weekday ${DAY_OF_WEEK})."

  # Calculate expiry for weekly backups in days
  EXPIRED_DAYS=$(( WEEKS_TO_KEEP * 7 ))

  log "Pruning weekly backups older than ${EXPIRED_DAYS} days."
  find "${BACKUP_DIR}" -maxdepth 1 -type d -name "*-weekly" -mtime +"${EXPIRED_DAYS}" -print -exec rm -rf {} \;

  perform_backups "-weekly"
  exit 0
fi

# Daily backup (default path)
log "Running daily backup."

log "Pruning daily backups older than ${DAYS_TO_KEEP} days."
find "${BACKUP_DIR}" -maxdepth 1 -type d -name "*-daily" -mtime +"${DAYS_TO_KEEP}" -print -exec rm -rf {} \;

perform_backups "-daily"

log "Rotated backup script completed successfully."
