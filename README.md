# NetBox PostgreSQL Backup Toolkit

A clean and reliable set of shell scripts to back up your **NetBox** PostgreSQL database.  
(Works perfectly for any other PostgreSQL database as well.)

---

## 📦 Included Files

| File | Description |
|------|-------------|
| **pg_backup.config** | Main configuration file |
| **pg_backup.sh** | Basic PostgreSQL backup script |
| **pg_backup_rotated.sh** | Backup with rotation and automatic cleanup |
| **README.md** | Documentation (this file) |

---

## 🚀 Features

- Automated PostgreSQL backups
- Optional weekly/monthly rotation
- Configurable retention periods
- Supports plain and custom-format dumps
- Safe permission model for secure operation
- Fully compatible with NetBox installations

---

## ⚙️ Requirements

- A running **PostgreSQL** server  
- Scripts executed as the **postgres** user  
- A writable backup directory  

---

## 🔧 Configuration (`pg_backup.config`)

Below is a clean and optimized example configuration for NetBox installations:

```bash
##############################
## POSTGRESQL BACKUP CONFIG ##
##############################

# Script should always run as postgres
BACKUP_USER=postgres

# PostgreSQL host (usually local)
HOSTNAME=localhost

# DB user performing the backup
USERNAME=postgres

# Backup directory (created if missing)
BACKUP_DIR=/data/pgbackup/

# Empty for typical NetBox deployments
SCHEMA_ONLY_LIST=""

# Backup formats
ENABLE_CUSTOM_BACKUPS=no
ENABLE_PLAIN_BACKUPS=yes

# Include roles/permissions?
ENABLE_GLOBALS_BACKUPS=no

######### ROTATION SETTINGS #########

# Weekly backup day (1–7 = Mon–Sun)
DAY_OF_WEEK_TO_KEEP=7

# Retention periods
DAYS_TO_KEEP=14
WEEKS_TO_KEEP=8

#####################################
```

### ✏️ Adjust these values to match your environment:

- `USERNAME` — PostgreSQL user (NetBox-specific user or `postgres`)
- `BACKUP_DIR` — location where backups should be saved  
- `ENABLE_GLOBALS_BACKUPS` — set to `yes` to include roles & privileges  

---

## 🔐 Secure File Permissions

Ensure only the `postgres` user can access and execute the scripts:

```bash
chown postgres:postgres /data/pg_backup.config /data/pg_backup.sh /data/pg_backup_rotated.sh
chmod 700 /data/pg_backup.sh /data/pg_backup_rotated.sh
chmod 600 /data/pg_backup.config

mkdir -p /data/pgbackup
chown postgres:postgres /data/pgbackup
chmod 700 /data/pgbackup
```

---

## ⏱️ Scheduling via Cron

Open the crontab of the `postgres` user:

```bash
crontab -u postgres -e
```

Add the following entry:

```bash
# NetBox/PostgreSQL backup with rotation
0 2 * * * /data/pg_backup_rotated.sh -c /data/pg_backup.config >> /var/log/pg_backup.log 2>&1
```

🔸 Runs every day at **02:00**  
🔸 Uses the config file  
🔸 Writes output to `/var/log/pg_backup.log`  

If log files grow too large, configure logrotate.

---

## 🧪 Manual Test Before Scheduling

```bash
sudo -u postgres /data/pg_backup_rotated.sh -c /data/pg_backup.config
```

A successful run should create a directory in your `BACKUP_DIR` containing:

```
netbox.sql.gz
```

---

## 🔄 Restore Procedure

⚠️ **Warning:** Restoring the production database overwrites ALL current data.

### Restore into production NetBox:

```bash
su postgres
psql -c 'drop database netbox'
psql -c 'create database netbox'

# For gzip-compressed dumps:
zcat /path/to/backup/netbox.sql.gz | psql netbox

# For uncompressed dumps:
psql netbox < netbox.sql
```

### Recommended: Test Restore into a Separate DB

```bash
su postgres
psql -c 'drop database if exists netbox_test'
psql -c 'create database netbox_test'

zcat /path/to/backup/netbox.sql.gz | psql netbox_test
```

If everything loads correctly and NetBox functions normally, your backup strategy is validated.

---

## 📘 Notes

- These scripts are **generic** and work for any PostgreSQL database.  
- For non‑NetBox environments, simply adjust DB name, user, and paths in `pg_backup.config`.

---

## ✅ You're All Set!

Your backups are now safe, rotated, and easy to restore.  
If you need further enhancements (systemd timers, email alerts, encryption, S3 uploads), just let me know!

