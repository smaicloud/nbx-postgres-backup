#!/usr/bin/env bash
#
# pg_backup.sh
#
# Simple, modern PostgreSQL backup script.
# - Loads configuration from pg_backup.config (or via -c <file>)
# - Creates a dated backup directory
# - Optionally dumps globals, schema-only DBs and full DBs
# - Supports plain (SQL) and custom (-Fc) backups
#
# Usage:
#   ./pg_backup.sh              # uses default config search
#   ./pg_backup.sh -c /path/to/pg_backup.config
#

set -euo pipefail
IFS=$'\n\t'

#######################################
# Helper functions
#######################################

log() {
  # Simple timestamped logger
  # Usage: log "message"
  printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  # Print error and exit non-zero
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

# Enforce backup user if configured
if [[ -n "${BACKUP_USER}" ]]; then
  CURRENT_USER="$(id -un)"
  if [[ "${CURRENT_USER}" != "${BACKUP_USER}" ]]; then
    die "Script must be run as '${BACKUP_USER}', current user is '${CURRENT_USER}'"
  fi
fi

# Prepare backup directory
if [[ ! -d "${BACKUP_DIR}" ]]; then
  log "Creating backup directory: ${BACKUP_DIR}"
  mkdir -p "${BACKUP_DIR}"
fi

DATE_STAMP="$(date +%Y-%m-%d_%H%M%S)"
FINAL_BACKUP_DIR="${BACKUP_DIR}/${DATE_STAMP}"

mkdir -p "${FINAL_BACKUP_DIR}"

log "Starting PostgreSQL backup into: ${FINAL_BACKUP_DIR}"

#######################################
# Globals backup
#######################################

if [[ "${ENABLE_GLOBALS_BACKUPS}" == "yes" ]]; then
  log "Backing up global objects (roles, privileges, tablespaces)"
  if ! pg_dumpall -g -h "${HOSTNAME}" -U "${USERNAME}" \
    | gzip > "${FINAL_BACKUP_DIR}/globals.sql.gz".in_progress; then
    die "Failed to dump global objects"
  fi
  mv "${FINAL_BACKUP_DIR}/globals.sql.gz".in_progress "${FINAL_BACKUP_DIR}/globals.sql.gz"
else
  log "Skipping globals backup (ENABLE_GLOBALS_BACKUPS != yes)"
fi

#######################################
# Schema-only backups
#######################################

SCHEMA_ONLY_CLAUSE=""
if [[ -n "${SCHEMA_ONLY_LIST}" ]]; then
  # Build WHERE clause for schema-only databases
  for SCHEMA_ONLY_DB in ${SCHEMA_ONLY_LIST//,/ }; do
    SCHEMA_ONLY_CLAUSE="${SCHEMA_ONLY_CLAUSE} OR datname = '${SCHEMA_ONLY_DB}'"
  done
fi

SCHEMA_ONLY_DB_LIST=""
if [[ -n "${SCHEMA_ONLY_CLAUSE}" ]]; then
  SCHEMA_ONLY_QUERY="SELECT datname
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

#######################################
# Full backups (excluding schema-only DBs)
#######################################

EXCLUDE_SCHEMA_ONLY_CLAUSE=""
if [[ -n "${SCHEMA_ONLY_LIST}" ]]; then
  for SCHEMA_ONLY_DB in ${SCHEMA_ONLY_LIST//,/ }; do
    EXCLUDE_SCHEMA_ONLY_CLAUSE="${EXCLUDE_SCHEMA_ONLY_CLAUSE} AND datname <> '${SCHEMA_ONLY_DB}'"
  done
fi

FULL_BACKUP_QUERY="SELECT datname
                   FROM pg_database
                   WHERE datallowconn
                     AND NOT datistemplate
                     ${EXCLUDE_SCHEMA_ONLY_CLAUSE}
                   ORDER BY datname;"

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

log "All database backups completed successfully."

