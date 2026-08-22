#!/bin/sh
set -eu

SOURCE_DIR=/source
WORK_ROOT=/tmp/karakeep-backup
SSH_KEY_FILE=/run/secrets/ssh_key
SSH_KNOWN_HOSTS_FILE=/run/secrets/known_hosts

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

fail() {
  log "ERROR: $*"
  return 1
}

validate_settings() {
  case "${BACKUP_INTERVAL:-}" in
    ''|*[!0-9smhd]*) fail "BACKUP_INTERVAL must look like 30m, 6h, or 1d"; return 1 ;;
  esac
  case "${BACKUP_RETENTION_DAYS:-}" in
    ''|*[!0-9]*) fail "BACKUP_RETENTION_DAYS must be a positive integer"; return 1 ;;
  esac
  [ "$BACKUP_RETENTION_DAYS" -gt 0 ] || { fail "BACKUP_RETENTION_DAYS must be greater than zero"; return 1; }
  case "${REMOTE_BACKUP_PATH:-}" in
    /mnt/user/bu/docker-apps/karakeep) ;;
    *) fail "REMOTE_BACKUP_PATH must be /mnt/user/bu/docker-apps/karakeep"; return 1 ;;
  esac
  [ -s "$SOURCE_DIR/db.db" ] || { fail "Karakeep db.db is missing"; return 1; }
  [ -s "$SOURCE_DIR/queue.db" ] || { fail "Karakeep queue.db is missing"; return 1; }
  [ -d "$SOURCE_DIR/assets" ] || { fail "Karakeep assets directory is missing"; return 1; }
  [ -r "$SSH_KEY_FILE" ] || { fail "SSH key is not readable"; return 1; }
  [ -r "$SSH_KNOWN_HOSTS_FILE" ] || { fail "SSH known_hosts file is not readable"; return 1; }
}

ssh_receiver() {
  ssh \
    -i "$SSH_KEY_FILE" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$SSH_KNOWN_HOSTS_FILE" \
    "$REMOTE_USER@$REMOTE_HOST" "$1"
}

run_backup() {
  timestamp="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
  filename="karakeep-${timestamp}.tar.gz"
  stage="$WORK_ROOT/stage"
  archive="$WORK_ROOT/$filename"

  rm -rf -- "$WORK_ROOT" || { fail "Could not clear the temporary workspace"; return 1; }
  mkdir -p "$stage/assets" || { fail "Could not create the staging directory"; return 1; }

  log "Creating online SQLite snapshots"
  sqlite3 "$SOURCE_DIR/db.db" ".timeout 30000" ".backup '$stage/db.db'" || { fail "db.db snapshot failed"; return 1; }
  sqlite3 "$SOURCE_DIR/queue.db" ".timeout 30000" ".backup '$stage/queue.db'" || { fail "queue.db snapshot failed"; return 1; }

  [ "$(sqlite3 "$stage/db.db" 'PRAGMA integrity_check;')" = "ok" ] || { fail "db.db integrity check failed"; return 1; }
  [ "$(sqlite3 "$stage/queue.db" 'PRAGMA integrity_check;')" = "ok" ] || { fail "queue.db integrity check failed"; return 1; }

  log "Copying Karakeep assets"
  tar -C "$SOURCE_DIR" -cf "$WORK_ROOT/assets.tar" assets || { fail "Asset packaging failed"; return 1; }
  tar -C "$stage" -xf "$WORK_ROOT/assets.tar" || { fail "Asset copy failed"; return 1; }
  rm -f -- "$WORK_ROOT/assets.tar" || { fail "Temporary asset archive cleanup failed"; return 1; }

  {
    printf 'created_utc=%s\n' "$timestamp"
    printf 'source=karakeep_data\n'
    printf 'asset_files=%s\n' "$(find "$stage/assets" -type f | wc -l | tr -d ' ')"
    sha256sum "$stage/db.db" "$stage/queue.db"
  } > "$stage/manifest.txt" || { fail "Manifest creation failed"; return 1; }

  tar -C "$stage" -czf "$archive" . || { fail "Archive creation failed"; return 1; }
  tar -tzf "$archive" >/dev/null || { fail "Local archive validation failed"; return 1; }
  checksum="$(sha256sum "$archive" | cut -d' ' -f1)" || { fail "Archive checksum failed"; return 1; }

  log "Uploading validated archive to Unraid"
  receiver_result="$(ssh_receiver "upload:${REMOTE_BACKUP_PATH}:${filename}:${checksum}" < "$archive")" || {
    fail "Unraid upload or remote validation failed"
    return 1
  }
  log "$receiver_result"

  retention_weeks=$(( (BACKUP_RETENTION_DAYS + 6) / 7 ))
  ssh_receiver "prune-tiered:${REMOTE_BACKUP_PATH}:${BACKUP_RETENTION_DAYS}:${BACKUP_RETENTION_DAYS}:${retention_weeks}" >/dev/null || {
    fail "Unraid retention pruning failed"
    return 1
  }

  rm -rf -- "$WORK_ROOT" || log "WARNING: temporary workspace cleanup failed"
  log "Backup completed successfully: $filename"
}

main() {
  validate_settings
  ssh_receiver "probe:${REMOTE_BACKUP_PATH}" >/dev/null || {
    fail "Unraid backup receiver probe failed for ${REMOTE_BACKUP_PATH}"
    exit 1
  }

  if [ "${BACKUP_RUN_ON_START:-true}" != "true" ]; then
    log "Initial backup disabled; waiting ${BACKUP_INTERVAL}"
    sleep "$BACKUP_INTERVAL"
  fi

  while true; do
    run_backup || true
    log "Next backup attempt in ${BACKUP_INTERVAL}"
    sleep "$BACKUP_INTERVAL"
  done
}

main
