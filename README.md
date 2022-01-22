netbox postgres backup
================

Comfortable shell script to backup your netbox postgres db (works for all other pg db's too)

### Scheduling

    # Backup postgresql database
    #0 2 * * * /data/pg_backup.sh >> /dev/null 2>&1
    # backup postgresql database backups with cleanup
    0 2 * * * /data/pg_backup_rotated.sh >> /dev/null 2>&1

### Restore:

    su postgres
    psql -c 'drop database netbox'
    psql -c 'create database netbox'
    psql netbox < netbox.sql
	