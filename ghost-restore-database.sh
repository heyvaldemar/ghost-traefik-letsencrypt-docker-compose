#!/bin/bash

# # ghost-restore-database.sh Description
# This script facilitates the restoration of a database backup.
# 1. **Identify Containers**: It first identifies the service and backups containers by name, finding the appropriate container IDs.
# 2. **List Backups**: Displays all available database backups located at the specified backup path.
# 3. **Select Backup**: Prompts the user to copy and paste the desired backup name from the list to restore the database.
# 4. **Stop Service**: Temporarily stops the service to ensure data consistency during restoration.
# 5. **Restore Database**: Executes a sequence of commands to drop the current database, create a new one, and restore it from the selected compressed backup file.
# 6. **Start Service**: Restarts the service after the restoration is completed.
# To make the `ghost-restore-database.shh` script executable, run the following command:
# `chmod +x ghost-restore-database.sh`
# Usage of this script ensures a controlled and guided process to restore the database from an existing backup.

GHOST_CONTAINER=$(docker ps -aqf "name=ghost-ghost")
GHOST_BACKUPS_CONTAINER=$(docker ps -aqf "name=ghost-backups")
GHOST_DB_NAME="ghostdb"
GHOST_DB_USER=$(docker exec $GHOST_BACKUPS_CONTAINER printenv GHOST_DB_USER)
MYSQL_PASSWORD=$(docker exec $GHOST_BACKUPS_CONTAINER printenv GHOST_DB_PASSWORD)
BACKUP_PATH="/srv/ghost-mysql/backups/"

echo "--> All available database backups:"

for entry in $(docker container exec "$GHOST_BACKUPS_CONTAINER" sh -c "ls $BACKUP_PATH")
do
  echo "$entry"
done

echo "--> Copy and paste the backup name from the list above to restore database and press [ENTER]"
echo "--> Example: ghost-mysql-backup-YYYY-MM-DD_hh-mm.gz"
echo -n "--> "

read SELECTED_DATABASE_BACKUP

echo "--> $SELECTED_DATABASE_BACKUP was selected"

echo "--> Stopping service..."
docker stop "$GHOST_CONTAINER"

echo "--> Restoring database..."
docker exec "$GHOST_BACKUPS_CONTAINER" sh -c "mysql -h mysql -u $GHOST_DB_USER --password=$MYSQL_PASSWORD -e 'DROP DATABASE $GHOST_DB_NAME; CREATE DATABASE $GHOST_DB_NAME;' \
&& gunzip -c ${BACKUP_PATH}${SELECTED_DATABASE_BACKUP} | mysql -h mysql -u $GHOST_DB_USER --password=$MYSQL_PASSWORD $GHOST_DB_NAME"
echo "--> Database recovery completed..."

echo "--> Starting service..."
docker start "$GHOST_CONTAINER"
