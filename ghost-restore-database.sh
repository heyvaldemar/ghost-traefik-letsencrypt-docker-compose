#!/usr/bin/env bash
# ghost-restore-database.sh [backup-file-name]
#
# Replaces the Ghost database with one of the dumps the backups service wrote.
#
#   ./ghost-restore-database.sh               list and ask
#   ./ghost-restore-database.sh <file-name>   restore that one
#
# EVERY PATH, NAME AND CREDENTIAL COMES FROM THE RUNNING BACKUPS CONTAINER.
# The previous version carried the database name, user and backup directory
# as literals, wrong for any .env that sets them differently, and found its
# containers with a name filter that misses them under any -p but the default.
# The backup loop reads its own environment, so this reads the same one, and
# the two cannot disagree.
#
# CI runs this exact file against a marker written after the backup it
# restores, and requires the marker to be gone.
#
# Set COMPOSE_PROJECT_NAME if the stack was started with a -p other than ghost.
set -Eeuo pipefail

PROJECT="${COMPOSE_PROJECT_NAME:-ghost}"
APP_SERVICE="ghost"

cid() {  # the container of one compose service in this project
  docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" \
    --filter "label=com.docker.compose.service=$1" | head -n 1
}
APP="$(cid "$APP_SERVICE")"; BKP="$(cid backups)"
[ -n "$BKP" ] || { echo "error: no backups container in compose project '$PROJECT' (set COMPOSE_PROJECT_NAME)" >&2; exit 1; }
[ -n "$APP" ] || { echo "error: no $APP_SERVICE container in compose project '$PROJECT'" >&2; exit 1; }
[ "$(docker inspect -f '{{.State.Running}}' "$BKP")" = true ] || { echo "error: the backups container is not running" >&2; exit 1; }

env_of() { docker exec "$BKP" printenv "$1"; }
DIR="$(env_of MYSQL_BACKUPS_PATH)"; NAME="$(env_of MYSQL_BACKUP_NAME)"
DB_NAME="$(env_of GHOST_DB_NAME)"; DB_USER="$(env_of GHOST_DB_USER)"; DB_PASS="$(env_of GHOST_DB_PASSWORD)"

SELECTED="${1:-}"
if [ -z "$SELECTED" ]; then
  echo "Database backups in $DIR:"
  docker exec "$BKP" sh -c "ls -1 '$DIR' | grep -E '^$NAME-.*\\.gz\$'" || { echo "  none found" >&2; exit 1; }
  read -r -p "File name to restore: " SELECTED
fi
case "$SELECTED" in ""|*/*) echo "error: give a file name from the list, not a path" >&2; exit 1 ;; esac
docker exec "$BKP" gunzip -t "$DIR/$SELECTED" >/dev/null \
  || { echo "error: $DIR/$SELECTED is missing or does not open; nothing was changed" >&2; exit 1; }

echo "Stopping $APP_SERVICE so nothing writes while the database is replaced"
docker stop "$APP" >/dev/null
restart() { docker start "$APP" >/dev/null && echo "Started $APP_SERVICE"; }
trap 'restart' EXIT
echo "Restoring $SELECTED"
if ! docker exec -e MYSQL_PWD="$DB_PASS" "$BKP" sh -c "(set -o pipefail) 2>/dev/null && set -o pipefail; set -eu
    mysql -h mysql -u '$DB_USER' -e 'DROP DATABASE IF EXISTS \`$DB_NAME\`; CREATE DATABASE \`$DB_NAME\`;'
    gunzip -c '$DIR/$SELECTED' | mysql -h mysql -u '$DB_USER' '$DB_NAME'"; then
  echo "error: the restore failed part-way. The database may now be empty: restore another backup before using Ghost." >&2
  exit 1
fi
echo "Restored $SELECTED into $DB_NAME"
