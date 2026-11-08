#!/bin/bash
# End-to-end tests for the ghost-traefik-letsencrypt-docker-compose backup + restore flow.
#
# Requires: docker, docker compose. Assumes the stack is already up with
# short backup intervals in .env (CI uses INIT_SLEEP=15s, INTERVAL=60s).
#
# Run from the repository root:
#   ./tests/e2e-backup-restore.sh
#
# CI runs the same script on every push inside the deploy-and-test job.
#
# Tests and helpers are dispatched indirectly via run_test "$name"; shellcheck
# cannot trace that and flags every function as unused (SC2329).
# shellcheck disable=SC2329

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-ghost}"
DOCKER_COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-ghost-traefik-letsencrypt-docker-compose.yml}"

if [[ -f .env ]]; then
  set -o allexport
  # shellcheck disable=SC1091
  source .env
  set +o allexport
else
  echo "error: .env not found at $REPO_ROOT/.env" >&2
  exit 1
fi

# Variables the compose file defaults are defaulted the same way here;
# secrets must come from .env.
: "${MYSQL_BACKUPS_PATH:=/srv/ghost-mysql/backups}"
: "${MYSQL_BACKUP_NAME:=ghost-mysql-backup}"
: "${BACKUP_INTERVAL:=24h}"
: "${GHOST_DB_USER:=ghostdbbuser}"
: "${GHOST_DB_PASSWORD:?set in .env}"
: "${GHOST_DB_NAME:=ghostdb}"
: "${DATA_BACKUPS_PATH:=/srv/ghost-application-data/backups}"
: "${DATA_BACKUP_NAME:=ghost-application-data-backup}"

BACKUPS_PATH="${MYSQL_BACKUPS_PATH%/}"
BACKUP_PREFIX="${MYSQL_BACKUP_NAME}"
BACKUP_EXT=".gz"
INTERVAL="${BACKUP_INTERVAL}"
DB_USER="${GHOST_DB_USER}"
DB_PASS="${GHOST_DB_PASSWORD}"
export MYSQL_PWD="$DB_PASS"   # every client below reads it from here, never from -p
DB_NAME="${GHOST_DB_NAME}"
DB_HOST="mysql"

# Resolve containers through compose, not by name: a container_name
# override in the compose file would defeat a docker ps name filter.
BACKUPS_CONTAINER="$(docker compose -f "$DOCKER_COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" ps -aq backups | head -n 1)"
DB_CONTAINER="$(docker compose -f "$DOCKER_COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" ps -aq mysql | head -n 1)"
[[ -n "$BACKUPS_CONTAINER" ]] || { echo "error: backups container not found" >&2; exit 1; }
[[ -n "$DB_CONTAINER" ]] || { echo "error: database container not found" >&2; exit 1; }

# seconds to wait for one full backup cycle: INTERVAL plus dump or connection-timeout time
interval_seconds() {
  local v="$INTERVAL"
  case "$v" in
    *h) echo $(( ${v%h} * 3600 )) ;;
    *m) echo $(( ${v%m} * 60 )) ;;
    *s) echo "${v%s}" ;;
    *) echo "$v" ;;
  esac
}
CYCLE_WAIT=$(( $(interval_seconds) + 60 ))

# --- Test runner ---

PASSED=0
FAILED=0
FAILURES=()

run_test() {
  local name="$1"
  echo
  echo "=== $name ==="
  if "$name"; then
    echo "  PASS: $name"
    PASSED=$((PASSED + 1))
  else
    echo "  FAIL: $name" >&2
    FAILED=$((FAILED + 1))
    FAILURES+=("$name")
  fi
}

fail() {
  echo "  ASSERT: $*" >&2
  return 1
}

# Note: never `grep -q` on a docker logs pipe here - with pipefail, grep
# exiting early sends docker logs a SIGPIPE and the whole pipeline fails.

# --- Container helpers ---

backups_sh() {
  docker exec "$BACKUPS_CONTAINER" sh -c "$1"
}

db_query() {
  docker exec -e MYSQL_PWD "$BACKUPS_CONTAINER" mysql -h "$DB_HOST" -u "$DB_USER" -N -s -e "$1" "$DB_NAME" 2>/dev/null
}
db_ready() {
  docker exec -e MYSQL_PWD "$BACKUPS_CONTAINER" mysqladmin -h "$DB_HOST" -u "$DB_USER" ping > /dev/null 2>&1
}
marker_create() { db_query "CREATE TABLE IF NOT EXISTS e2e_marker (id int PRIMARY KEY);" > /dev/null; }
marker_insert() { db_query "CREATE TABLE IF NOT EXISTS restore_test (id int); INSERT INTO restore_test VALUES (1);" > /dev/null; }
marker_count() { db_query "SELECT count(*) FROM restore_test;" | tr -d '[:space:]'; }
marker_gone() {
  [[ "$(db_query "SELECT count(*) FROM information_schema.tables WHERE table_schema='$DB_NAME' AND table_name='restore_test';" | tr -d '[:space:]')" == "0" ]]
}
DUMP_HEADER="MySQL dump|MariaDB dump"
DUMP_CONTENT="CREATE TABLE"

list_backups() {
  backups_sh "ls -1 ${BACKUPS_PATH}/${BACKUP_PREFIX}-*${BACKUP_EXT} 2>/dev/null" | grep -v '\.failed$' | sort || true
}

# First backup taken after the marker existed; waits up to one cycle for it.
post_marker_backup() {
  local f elapsed=0
  while :; do
    f=$(backups_sh "find ${BACKUPS_PATH} -name '${BACKUP_PREFIX}-*${BACKUP_EXT}' -newer ${BACKUPS_PATH}/.e2e-marker-stamp 2>/dev/null | sort | head -1")
    # a file that exists is not yet a backup: the loop may still be writing it,
    # so wait for the "backup OK" log line that names it
    if [[ -n "$f" ]] && docker logs "$BACKUPS_CONTAINER" 2>&1 | grep -qF "backup OK: $f"; then echo "$f"; return 0; fi
    [[ $elapsed -lt $CYCLE_WAIT ]] || return 1
    sleep 5; elapsed=$((elapsed + 5))
  done
}

wait_for_first_backup() {
  local timeout="${1:-180}" elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    [[ -n "$(list_backups)" ]] && return 0
    sleep 3; elapsed=$((elapsed + 3))
  done
  return 1
}

wait_for_db_ready() {
  local timeout="${1:-90}" elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    db_ready && return 0
    sleep 3; elapsed=$((elapsed + 3))
  done
  return 1
}

# --- Test cases ---

test_env_required() {
  # The compose file guards required variables with ${VAR:?...}; without
  # .env and with an empty environment `docker compose config` must refuse.
  mv .env .env.bak
  local out
  out=$(env -i PATH="$PATH" HOME="$HOME" docker compose -f "$DOCKER_COMPOSE_FILE" config 2>&1 || true)
  mv .env.bak .env
  echo "$out" | grep -qiE "set in \.env|required|is not set" && return 0
  fail "expected a required-variable error from docker compose config"
}

test_backup_created() {
  echo "  waiting up to 180s for the first backup..."
  wait_for_first_backup 180 || { fail "no backup appeared within 180s"; return 1; }
  local first size
  first=$(list_backups | head -1)
  size=$(backups_sh "stat -c %s $first" | tr -d '[:space:]')
  [[ -n "$size" && "$size" -gt 0 ]] || { fail "backup $first has size '$size'"; return 1; }
  echo "  first backup: $first ($size bytes)"
}

test_backup_gunzip_ok() {
  local newest
  newest=$(list_backups | tail -1)
  backups_sh "gunzip -t $newest" || { fail "gunzip -t failed on $newest"; return 1; }
}

test_backup_content_valid() {
  [[ -n "$DUMP_HEADER" ]] || { echo "  (binary archive format, header check not applicable)"; return 0; }
  # Judge a backup taken after the marker existed: some applications create
  # their schema only after the setup wizard, so an early dump is legitimately
  # empty apart from the marker table.
  local newest
  newest=$(post_marker_backup) || { fail "no backup taken after the marker within ${CYCLE_WAIT}s"; return 1; }
  backups_sh "gunzip -c $newest | head -5" | grep -qE "$DUMP_HEADER" || { fail "expected dump header ($DUMP_HEADER) at the top of $newest"; return 1; }
  # the preamble (types, functions, SET lines) can run long - search the whole dump
  backups_sh "gunzip -c $newest | grep -m1 -qE '$DUMP_CONTENT'" || { fail "expected $DUMP_CONTENT somewhere in $newest"; return 1; }
}

test_data_backup_valid() {
  # Log-driven: the archive named in a 'Data backup OK' line is complete,
  # so this never races an archive that is still being written.
  local f elapsed=0
  # the data archive is written after the dump and can take a while on a
  # large tree; wait for the loop to report it before judging
  until docker logs "$BACKUPS_CONTAINER" 2>&1 | grep -E "Data backup (OK|FAILED)" > /dev/null; do
    [[ $elapsed -lt 180 ]] || { fail "no data backup result within 180s"; return 1; }
    sleep 3; elapsed=$((elapsed + 3))
  done
  f=$(docker logs "$BACKUPS_CONTAINER" 2>&1 | grep "Data backup OK" | tail -1 | sed -E 's/.*Data backup OK: ([^ ]+) .*/\1/')
  [[ -n "$f" ]] || { fail "no 'Data backup OK' line in the backups log"; return 1; }
  backups_sh "tar -tzf $f > /dev/null" || { fail "tar -tzf failed on $f"; return 1; }
  echo "  data archive readable: $f"
}

test_backup_failure_detected() {
  # Stop the database so the next dump attempt fails; the loop must log
  # FAILED and keep the partial file as .failed. The data archive of a
  # large tree can take longer than the interval, so wait for an actual
  # failed attempt during the outage instead of a fixed cycle time.
  local failed_before deadline failed_files
  failed_before=$(docker logs "$BACKUPS_CONTAINER" 2>&1 | grep -ci "backup FAILED" || true)
  echo "  stopping the database to force a failed cycle"
  docker stop "$DB_CONTAINER" > /dev/null
  deadline=$(( $(date +%s) + CYCLE_WAIT * 2 + 120 ))
  echo "  waiting up to $(( CYCLE_WAIT * 2 + 120 ))s for a failed dump during the outage..."
  while [[ $(docker logs "$BACKUPS_CONTAINER" 2>&1 | grep -ci "backup FAILED" || true) -le $failed_before ]]; do
    if [[ $(date +%s) -ge $deadline ]]; then break; fi
    sleep 5
  done
  failed_files=$(backups_sh "ls ${BACKUPS_PATH}/*.failed 2>/dev/null" || true)
  echo "  restarting the database"
  docker start "$DB_CONTAINER" > /dev/null
  wait_for_db_ready 90 || { fail "database did not become ready within 90s after restart"; return 1; }
  [[ $(docker logs "$BACKUPS_CONTAINER" 2>&1 | grep -ci "backup FAILED" || true) -gt $failed_before ]] || { fail "no 'backup FAILED' log line during the outage"; return 1; }
  [[ -n "$failed_files" ]] || { fail "no *.failed file produced during the outage"; return 1; }
  echo "  observed failed file: $failed_files"
}

test_restore_roundtrip() {
  # Proof that restore replaces database state rather than being a no-op:
  # take the earliest backup, add a marker, restore, assert the marker is gone.
  # The baseline must postdate the marker collection/table: CI takes its first
  # backup long before this script runs, and a restore of a pre-marker archive
  # cannot prove anything about it.
  local baseline before
  baseline=$(post_marker_backup) || { fail "no backup taken after the marker within ${CYCLE_WAIT}s"; return 1; }
  echo "  baseline: $baseline"
  marker_insert
  before=$(marker_count)
  [[ "$before" -ge 1 ]] || { fail "marker insert failed: count=$before"; return 1; }
  # THE SHIPPED SCRIPT, NOT A COPY OF ITS COMMANDS. This used to run its own
  # copy of the restore commands, so the script a person runs on their worst
  # day was never run here, and it had drifted from the stack it restores.
  echo "  restoring the baseline with ./ghost-restore-database.sh"
  COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" ./ghost-restore-database.sh "$(basename "$baseline")" \
    || { fail "the shipped restore script failed"; return 1; }
  marker_gone || { fail "marker still present after restore - restore was a no-op"; return 1; }
  echo "  marker absent after restore - the backup is restorable"
}

test_data_restore_roundtrip() {
  # The same proof for application data, through the shipped script: a marker
  # written after every existing archive must be gone once one is restored.
  # The newest archive, not the earliest: the upgrade drill leaves archives from
  # the previous release on these volumes, and a restore that rolls the data back
  # past this run would leave the stack unlike the one being tested.
  local data dir name newest
  data="$(backups_sh 'printenv DATA_PATH' | tr -d '[:space:]')"
  dir="$(backups_sh 'printenv DATA_BACKUPS_PATH' | tr -d '[:space:]')"
  name="$(backups_sh 'printenv DATA_BACKUP_NAME' | tr -d '[:space:]')"
  newest="$(backups_sh "ls -1 '${dir%/}'/'$name'-*.tar.gz 2>/dev/null" | sort | tail -n 1)"
  [[ -n "$newest" ]] || { fail "no application data archive to restore"; return 1; }
  backups_sh "touch '$data/e2e-restore-marker'" || { fail "could not write the marker into $data"; return 1; }
  echo "  restoring $(basename "$newest") with ./ghost-restore-application-data.sh"
  COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" ./ghost-restore-application-data.sh "$(basename "$newest")" \
    || { fail "the shipped restore script failed"; return 1; }
  if backups_sh "test -e '$data/e2e-restore-marker'"; then
    fail "marker still present after the data restore - it did not replace the data"; return 1
  fi
  echo "  marker absent after the data restore - the archive is restorable"
}

test_prune_removes_old() {
  local fake_old="${BACKUPS_PATH}/${BACKUP_PREFIX}-0000-00-00_00-00${BACKUP_EXT}"
  echo "  placing a fake file dated 2020 at $fake_old"
  # touch -t works in GNU and BusyBox alike; -d 'N days ago' is GNU-only
  backups_sh "echo fake > $fake_old && touch -t 202001010000 $fake_old" || { fail "could not create the fake file"; return 1; }
  # A cycle is a database dump, a data backup that takes as long as the data
  # does, the prune, then the interval. Nextcloud 35.0.1's data backup took
  # 98 s on 2026-09-25 and a fixed wait of interval + 60 s asked before the
  # prune had run. Wait for the prune itself, with a ceiling of two cycles.
  local ceiling=$(( $(interval_seconds) * 2 + 300 )) waited=0
  echo "  waiting up to ${ceiling}s for a prune cycle to remove it..."
  while backups_sh "ls $fake_old 2>/dev/null" > /dev/null 2>&1; do
    if [ "$waited" -ge "$ceiling" ]; then fail "fake old file survived ${ceiling}s, longer than two backup cycles"; return 1; fi
    sleep 5; waited=$(( waited + 5 ))
  done
  echo "  pruned after ${waited}s"
  [[ -n "$(list_backups)" ]] || { fail "prune removed everything, including recent backups"; return 1; }
}

# --- No password on any command line ---
#
# A process's arguments are /proc/<pid>/cmdline, mode 0444: every user on the
# host reads them with ps, and the host sees every container's processes. Its
# environment is /proc/<pid>/environ, readable by its owner alone. So the
# password reaches each client as MYSQL_PWD, never as -p. Two proofs, both
# matched against a file holding the value, so the value is never printed and
# never becomes an argument of the comparison itself:
#   - a sampler reads every command line on this machine several times a second
#     for the whole suite;
#   - one backup is held open by a table lock, and its dump process is read
#     while it runs, on the host and inside the backups container.
PW_FILE="$(mktemp)"; PS_COUNTS="$(mktemp)"; PS_SAMPLER=""
trap 'rm -f "$PW_FILE" "$PS_COUNTS"; [[ -z "$PS_SAMPLER" ]] || kill "$PS_SAMPLER" 2>/dev/null || true' EXIT
chmod 600 "$PW_FILE"; printf '%s\n' "$DB_PASS" > "$PW_FILE"
PW_SUM="sha256:$(printf '%s' "$DB_PASS" | sha256sum | cut -c1-12)"   # names the value in this log without showing it

argv_hits() { grep -cF -f "$PW_FILE" || true; }                 # lines on stdin that contain the value
cmdlines_in() {                                                   # every command line inside one container
  docker exec "$1" sh -c 'for f in /proc/[0-9]*/cmdline; do tr "\000" " " < "$f" 2>/dev/null; echo; done'
}
seconds_of() {
  case "$1" in
    *h) echo $(( ${1%h} * 3600 )) ;;
    *m) echo $(( ${1%m} * 60 )) ;;
    *s) echo "${1%s}" ;;
    *) echo "$1" ;;
  esac
}
ps_sampler_start() {
  ( while :; do ps -eo args= 2>/dev/null | argv_hits >> "$PS_COUNTS"; sleep 0.2; done ) &
  PS_SAMPLER=$!
}
ps_sampler_stop() {
  [[ -n "$PS_SAMPLER" ]] || return 0
  kill "$PS_SAMPLER" 2>/dev/null || true; wait "$PS_SAMPLER" 2>/dev/null || true; PS_SAMPLER=""
}

test_dump_runs_without_password_in_argv() {
  # A write lock on a table the dump has to read keeps the dump waiting, so
  # its process can be read while the backup runs rather than guessed at.
  local init hold locker since dump="" i ok="" hits_host hits_bkp id="" net img
  init=$(seconds_of "${BACKUP_INIT_SLEEP:-30m}")
  [[ "$init" -le 120 ]] || { fail "BACKUP_INIT_SLEEP is ${BACKUP_INIT_SLEEP:-30m}; this test needs a short one (CI uses 15s)"; return 1; }
  hold=$(( init + 75 ))
  db_query "CREATE TABLE IF NOT EXISTS zz_argv_probe (id int); INSERT INTO zz_argv_probe VALUES (1);" > /dev/null \
    || { fail "could not create the probe table"; return 1; }
  # The lock is held from a throwaway container of the backups image on the
  # stack's network, the same way in as the dump: the backups container itself
  # restarts below, and would take the session with it.
  net="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "$BACKUPS_CONTAINER" | head -n 1)"
  img="$(docker inspect -f '{{.Config.Image}}' "$BACKUPS_CONTAINER")"
  docker run --rm --network "$net" --entrypoint mysql -e MYSQL_PWD "$img" -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" \
    -e "LOCK TABLES zz_argv_probe WRITE; SELECT SLEEP($hold); UNLOCK TABLES;" > /dev/null 2>&1 &
  locker=$!
  for (( i = 0; i < 30; i++ )); do
    id="$(db_query "SELECT id FROM information_schema.processlist WHERE info LIKE 'SELECT SLEEP(%' LIMIT 1;" | tr -d '[:space:]')"
    [[ -n "$id" ]] && break
    sleep 1
  done
  [[ -n "$id" ]] || { fail "the session holding the lock never started"; return 1; }
  since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "  restarting the backups service; its first dump waits on the lock"
  docker restart "$BACKUPS_CONTAINER" > /dev/null
  for (( i = 0; i < init + 50; i++ )); do
    dump="$(ps -eo comm=,args= | awk '$1 == "mariadb-dump" || $1 == "mysqldump" { $1 = ""; sub(/^ /, ""); print; exit }')"
    [[ -n "$dump" ]] && break
    sleep 1
  done
  hits_host=$(ps -eo args= | argv_hits)
  hits_bkp=$(cmdlines_in "$BACKUPS_CONTAINER" | argv_hits)
  db_query "KILL $id;" > /dev/null 2>&1 || true
  wait "$locker" 2>/dev/null || true
  for (( i = 0; i < 120; i += 3 )); do
    ok="$(docker logs --since "$since" "$BACKUPS_CONTAINER" 2>&1 | grep -E "Database backup (OK|FAILED)" | head -n 1 || true)"
    [[ -n "$ok" ]] && break
    sleep 3
  done
  db_query "DROP TABLE IF EXISTS zz_argv_probe;" > /dev/null 2>&1 || true
  [[ -n "$dump" ]] || { fail "no dump process appeared within $(( init + 50 ))s of the restart"; return 1; }
  echo "  the dump, read while it ran: $(sed -E 's/(^| )(-p|--password=?)[^ ]*/\1\2<hidden>/g' <<< "$dump")"
  [[ "$hits_host" == 0 ]] || { fail "$hits_host command line(s) on the host carried the password ($PW_SUM) while the dump ran"; return 1; }
  [[ "$hits_bkp" == 0 ]] || { fail "$hits_bkp command line(s) in the backups container carried the password ($PW_SUM) while the dump ran"; return 1; }
  if grep -qE '(^| )(-p[^ ]*|--password[^ ]*)( |$)' <<< "$dump"; then
    fail "the dump was given its password as an argument; the client blanks its copy only after it was readable"; return 1
  fi
  [[ "$ok" == *"backup OK"* ]] || { fail "the held backup did not finish OK: ${ok:-no result within 120s}"; return 1; }
  echo "  0 command lines on the host and 0 in the backups container carried the password ($PW_SUM); the backup finished OK"
}

test_no_password_on_any_command_line() {
  ps_sampler_stop
  local samples hits
  samples=$(wc -l < "$PS_COUNTS" | tr -d '[:space:]')
  hits=$(awk '$1 > 0 { n++ } END { print n + 0 }' "$PS_COUNTS")
  [[ "$samples" -ge 100 ]] || { fail "only $samples samples of the host's command lines were taken"; return 1; }
  [[ "$hits" == 0 ]] || { fail "$hits of $samples samples of the host's command lines carried the password ($PW_SUM)"; return 1; }
  echo "  $samples samples of every command line on the host during this suite, none with the password ($PW_SUM)"
}

# --- Main ---

echo "=== Deployment Verification: backup/restore E2E tests ==="
echo "  project=${COMPOSE_PROJECT_NAME} backups=${BACKUPS_CONTAINER} db=${DB_CONTAINER}"
echo "  path=${BACKUPS_PATH} prefix=${BACKUP_PREFIX} interval=${INTERVAL}"

wait_for_db_ready 120 || { echo "error: database not ready" >&2; exit 1; }
# Pin known content into the database before the first backup cycle. Some
# images answer the readiness ping from a temporary init server before the
# application database exists, so this retries instead of trusting one ping.
marker_ok=0
for _ in $(seq 1 40); do
  if marker_create 2>/dev/null; then marker_ok=1; break; fi
  sleep 3
done
[[ "$marker_ok" == 1 ]] || { echo "error: could not create the marker in the database within 120s" >&2; exit 1; }
# stamp the moment the marker exists; the restore test picks the first backup newer than this
backups_sh "touch ${BACKUPS_PATH}/.e2e-marker-stamp"

ps_sampler_start
run_test test_env_required
run_test test_backup_created
run_test test_backup_gunzip_ok
run_test test_backup_content_valid
run_test test_data_backup_valid
run_test test_backup_failure_detected
run_test test_restore_roundtrip
run_test test_data_restore_roundtrip
run_test test_prune_removes_old
run_test test_dump_runs_without_password_in_argv
run_test test_no_password_on_any_command_line

echo
echo "==============================="
echo "Passed: $PASSED  Failed: $FAILED"
if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo "Failures:"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
fi
[[ $FAILED -eq 0 ]]
