#!/usr/bin/env bash
# backup.sh - Automated Backup System
# Requires: bash, tar, date, sha256sum or md5sum, mktemp, df, find, sort, awk, stat
# Use: ./backup.sh [--dry-run] /path/to/source
# Extras:
#   --list                       List backups
#   --restore <file> --to <dir>  Restore backup to directory
#   --help

set -o errexit
set -o pipefail
set -o nounset

# -----------------------
# Helper functions
# -----------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config_file="${script_dir}/backup.config"
log_file="${script_dir}/backup.log"

log() {
  local level="$1"; shift
  local msg="$*"
  local now
  now="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$now] $level: $msg" | tee -a "$log_file"
}

die() {
  log "ERROR" "$*"
  cleanup_lock
  exit 1
}

# -----------------------
# Read config (if exists)
# -----------------------
# Set defaults
BACKUP_DESTINATION="${script_dir}/backups"
EXCLUDE_PATTERNS=".git,node_modules,.cache"
DAILY_KEEP=7
WEEKLY_KEEP=4
MONTHLY_KEEP=3
CHECKSUM_ALGO="sha256"
NOTIFY_EMAIL=""
MIN_FREE_MB=100
LOCKFILE="/tmp/backup_system.lock"

if [[ -f "$config_file" ]]; then
  # shellcheck disable=SC1091
  source "$config_file"
  log "INFO" "Loaded config from $config_file"
else
  log "WARN" "Config file not found at $config_file — using defaults"
fi

# -----------------------
# Globals
# -----------------------
DRY_RUN=false
# argument parsing done later
timestamp() { date '+%Y-%m-%d-%H%M%S'; }
now_ts=$(timestamp)
backup_prefix="backup"
# backup filename: backup-YYYY-MM-DD-HHMMSS.tar.gz
ext=".tar.gz"

# -----------------------
# Lockfile handling
# -----------------------
create_lock() {
  if [[ -n "${LOCKFILE:-}" && -e "$LOCKFILE" ]]; then
    local pid
    pid="$(cat "$LOCKFILE" 2>/dev/null || echo "")"
    if [[ -n "$pid" && -d "/proc/$pid" ]]; then
      die "Lockfile $LOCKFILE exists and process $pid is running. Exiting."
    else
      log "WARN" "Removing stale lockfile $LOCKFILE"
      rm -f "$LOCKFILE"
    fi
  fi

  if $DRY_RUN; then
    log "INFO" "Dry-run: would create lockfile $LOCKFILE"
  else
    echo "$$" > "$LOCKFILE"
    log "INFO" "Created lockfile $LOCKFILE (pid $$)"
  fi
}

cleanup_lock() {
  if [[ -n "${LOCKFILE:-}" && -e "$LOCKFILE" ]]; then
    local owner
    owner="$(cat "$LOCKFILE" 2>/dev/null || echo "")"
    if [[ "$owner" == "$$" ]]; then
      rm -f "$LOCKFILE" || true
      log "INFO" "Removed lockfile $LOCKFILE"
    fi
  fi
}

trap 'cleanup_lock; exit' INT TERM EXIT

# -----------------------
# Utility: compute checksum
# -----------------------
checksum_file() {
  local file="$1"
  if [[ "$CHECKSUM_ALGO" == "md5" ]]; then
    md5sum "$file" | awk '{print $1}'
  else
    # default sha256
    sha256sum "$file" | awk '{print $1}'
  fi
}

checksum_cmd_name() {
  if [[ "$CHECKSUM_ALGO" == "md5" ]]; then
    echo "md5sum"
  else
    echo "sha256sum"
  fi
}

# -----------------------
# Ensure backup destination exists
# -----------------------
ensure_dest() {
  if [[ ! -d "$BACKUP_DESTINATION" ]]; then
    if $DRY_RUN; then
      log "INFO" "Dry-run: would create backup destination $BACKUP_DESTINATION"
    else
      mkdir -p "$BACKUP_DESTINATION" || die "Cannot create $BACKUP_DESTINATION"
      log "INFO" "Created backup destination $BACKUP_DESTINATION"
    fi
  fi
}

# -----------------------
# Space check
# -----------------------
check_free_space_mb() {
  local dest="$1"
  local min_mb="$2"
  # use df --output=avail -m
  local avail
  avail=$(df --output=avail -m "$dest" 2>/dev/null | tail -n1 | tr -d ' ')
  if [[ -z "$avail" ]]; then
    log "WARN" "Unable to determine free space for $dest"
    return 0
  fi
  if (( avail < min_mb )); then
    return 1
  fi
  return 0
}

# -----------------------
# Build tar exclude args from EXCLUDE_PATTERNS
# -----------------------
build_exclude_args() {
  local IFS=','
  local arr=($EXCLUDE_PATTERNS)
  local args=()
  for pat in "${arr[@]}"; do
    pat="${pat#"${pat%%[![:space:]]*}"}"
    pat="${pat%"${pat##*[![:space:]]}"}"
    [[ -z "$pat" ]] && continue
    args+=(--exclude="$pat")
  done
  echo "${args[@]}"
}

# -----------------------
# Create backup
# -----------------------
create_backup() {
  local src="$1"
  local dest="$2"
  local created_name="${backup_prefix}-$(date '+%Y-%m-%d-%H%M%S')${ext}"
  local created_path="${dest}/${created_name}"
  local checksum_path="${created_path}.${CHECKSUM_ALGO}"

  log "INFO" "Starting backup of $src -> $created_path"

  if [[ ! -d "$src" ]]; then
    die "Error: Source folder not found: $src"
  fi
  if [[ ! -r "$src" ]]; then
    die "Error: Cannot read folder (permission denied): $src"
  fi

  if (( MIN_FREE_MB > 0 )); then
    if ! check_free_space_mb "$dest" "$MIN_FREE_MB"; then
      die "Error: Not enough disk space in $dest (need ${MIN_FREE_MB} MB)"
    fi
  fi

  local exclude_args
  exclude_args="$(build_exclude_args)"

  if $DRY_RUN; then
    log "INFO" "Dry-run: would run: tar -czf $created_path $exclude_args -C $(dirname "$src") $(basename "$src")"
    log "INFO" "Dry-run: would write checksum to $checksum_path using $(checksum_cmd_name)"
    echo "$created_name"
    return 0
  fi

  # create archive
  tar -czf "$created_path" $exclude_args -C "$(dirname "$src")" "$(basename "$src")" \
    || die "Tar failed while creating $created_path"

  # checksum
  local chksum
  chksum="$(checksum_file "$created_path")"
  echo "$chksum  $(basename "$created_path")" > "$checksum_path"
  log "SUCCESS" "Backup created: $(basename "$created_path")"
  log "INFO" "Checksum ($CHECKSUM_ALGO) saved to $(basename "$checksum_path")"

  # verify backup
  verify_backup "$created_path" "$checksum_path"
  echo "$(basename "$created_path")"
}

# -----------------------
# Verify backup
# -----------------------
verify_backup() {
  local created_path="$1"
  local checksum_path="$2"
  log "INFO" "Verifying $created_path"

  if [[ ! -f "$checksum_path" ]]; then
    log "ERROR" "Checksum file not found: $checksum_path"
    return 1
  fi

  local saved_sum
  saved_sum=$(awk '{print $1}' "$checksum_path")
  local current_sum
  current_sum=$(checksum_file "$created_path")

  if [[ "$saved_sum" != "$current_sum" ]]; then
    log "FAILED" "Checksum mismatch for $(basename "$created_path")"
    return 1
  fi

  # try to extract one file to temp dir
  local tempd
  tempd="$(mktemp -d)"
  if ! tar -xzf "$created_path" -C "$tempd" --wildcards --no-anchored --no-overwrite-dir --strip-components=0 2>/dev/null; then
    # fall back: try list only
    if ! tar -tzf "$created_path" >/dev/null 2>&1; then
      rm -rf "$tempd"
      log "FAILED" "Archive appears corrupted: $(basename "$created_path")"
      return 1
    fi
  fi
  rm -rf "$tempd"
  log "SUCCESS" "Verification successful for $(basename "$created_path")"
  return 0
}

# -----------------------
# Rotation algorithm
# -----------------------
# find all backups in dest (matching prefix and ext), parse timestamps from filename
# keep last DAILY_KEEP distinct dates, last WEEKLY_KEEP distinct weeks, last MONTHLY_KEEP distinct months
rotate_backups() {
  local dest="$1"
  log "INFO" "Starting rotation in $dest (daily=$DAILY_KEEP weekly=$WEEKLY_KEEP monthly=$MONTHLY_KEEP)"

  # collect backup files (tar.gz only)
  mapfile -t backups < <(find "$dest" -maxdepth 1 -type f -name "${backup_prefix}-*${ext}" | sort -r)

  declare -A keep_map
  declare -A seen_day
  declare -A seen_week
  declare -A seen_month

  local kept_count=0
  local f ts day week month key

  # helper: convert filename to timestamp string accepted by date -d
  parse_ts() {
    local fname="$1"
    # example: backup-2024-11-03-143015.tar.gz -> 2024-11-03-143015
    echo "$fname" | sed -E "s/^.*${backup_prefix}-([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}).*$/\1/"
  }

  for f in "${backups[@]}"; do
    # skip empty
    [[ -z "$f" ]] && continue
    local base
    base="$(basename "$f")"
    ts="$(parse_ts "$base")"
    # if parse failed, skip
    if ! date -d "${ts:0:10} ${ts:11:2}:${ts:13:2}:${ts:15:2}" >/dev/null 2>&1; then
      # try alternative parse: date -d 'YYYY-MM-DD-HHMMSS' might not be accepted with hyphen
      log "WARN" "Unable to parse timestamp from $base; skipping rotation logic for this file"
      keep_map["$base"]=1
      continue
    fi

    # derive day/week/month keys
    # day: YYYY-MM-DD
    day="$(date -d "${ts:0:10} ${ts:11:2}:${ts:13:2}:${ts:15:2}" '+%Y-%m-%d')"
    week="$(date -d "${ts:0:10}" '+%Y-W%V')" # ISO week
    month="$(date -d "${ts:0:10}" '+%Y-%m')"

    if [[ -z "${seen_day[$day]:-}" && "${#seen_day[@]}" -lt "$DAILY_KEEP" ]]; then
      seen_day["$day"]=1
      keep_map["$base"]=1
      ((kept_count++))
      continue
    fi

    if [[ -z "${seen_week[$week]:-}" && "${#seen_week[@]}" -lt "$WEEKLY_KEEP" ]]; then
      seen_week["$week"]=1
      keep_map["$base"]=1
      ((kept_count++))
      continue
    fi

    if [[ -z "${seen_month[$month]:-}" && "${#seen_month[@]}" -lt "$MONTHLY_KEEP" ]]; then
      seen_month["$month"]=1
      keep_map["$base"]=1
      ((kept_count++))
      continue
    fi

    # else candidate for deletion
    if [[ -z "${keep_map[$base]:-}" ]]; then
      if $DRY_RUN; then
        log "INFO" "Dry-run: would delete $base"
      else
        # delete archive and checksum file
        rm -f "$dest/$base" "$dest/$base.${CHECKSUM_ALGO}"
        log "INFO" "Deleted old backup: $base"
      fi
    fi
  done

  log "INFO" "Rotation complete"
}

# -----------------------
# List backups
# -----------------------
list_backups() {
  local dest="$1"
  printf "Available backups in %s:\n" "$dest"
  ls -lh "$dest"/*"${ext}" 2>/dev/null || echo "(none)"
}

# -----------------------
# Restore
# -----------------------
restore_backup() {
  local backupfile="$1"
  local todir="$2"

  if [[ ! -f "$backupfile" ]]; then
    die "Restore file not found: $backupfile"
  fi

  if [[ ! -d "$todir" ]]; then
    if $DRY_RUN; then
      log "INFO" "Dry-run: would create restore target $todir"
    else
      mkdir -p "$todir" || die "Cannot create restore target $todir"
    fi
  fi

  if $DRY_RUN; then
    log "INFO" "Dry-run: would extract $backupfile to $todir"
    return 0
  fi

  tar -xzf "$backupfile" -C "$todir" || die "Failed to extract $backupfile to $todir"
  log "SUCCESS" "Restored $backupfile -> $todir"
}

# -----------------------
# Argument parsing
# -----------------------
show_help() {
  cat <<EOF
Usage:
  $0 [--dry-run] /path/to/source
  $0 --list
  $0 --restore <backup-file> --to <dir>
  $0 --help

Options:
  --dry-run       Do not perform actions, only print what would happen
  --list          List backups in destination
  --restore       Restore given backup (specify --to <dir>)
  --help          Show this help
EOF
}

# parse args
if [[ $# -eq 0 ]]; then
  show_help
  exit 0
fi

# small parser
POSITIONAL=()
MODE="backup"
RESTORE_FILE=""
RESTORE_TO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --list) MODE="list"; shift ;;
    --restore) MODE="restore"; RESTORE_FILE="$2"; shift 2 ;;
    --to) RESTORE_TO="$2"; shift 2 ;;
    --help|-h) show_help; exit 0 ;;
    --config) config_file="$2"; shift 2 ;;
    --*) die "Unknown option $1" ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

set -- "${POSITIONAL[@]}"

# -----------------------
# Main flows
# -----------------------
if [[ "$MODE" == "list" ]]; then
  ensure_dest
  list_backups "$BACKUP_DESTINATION"
  exit 0
fi

if [[ "$MODE" == "restore" ]]; then
  if [[ -z "$RESTORE_FILE" || -z "$RESTORE_TO" ]]; then
    die "Usage: --restore <backup-file> --to <dir>"
  fi
  create_lock
  ensure_dest
  restore_backup "$RESTORE_FILE" "$RESTORE_TO"
  cleanup_lock
  exit 0
fi

# backup mode (default)
SOURCE_DIR="${POSITIONAL[0]:-}"

if [[ -z "$SOURCE_DIR" ]]; then
  show_help
  die "No source directory provided"
fi

# expand SOURCE_DIR to absolute
SOURCE_DIR="$(cd "$SOURCE_DIR" 2>/dev/null && pwd || echo "$SOURCE_DIR")"

create_lock
ensure_dest

# create
created_basename="$(create_backup "$SOURCE_DIR" "$BACKUP_DESTINATION")"

# rotate
rotate_backups "$BACKUP_DESTINATION"

cleanup_lock

log "INFO" "Done."
exit 0
