#!/usr/bin/env bash
set -euo pipefail

# Defaults (override by exporting before running, e.g. DB_VOL=mydb_data WP_VOL=mywp_data ./scripts/restore.sh ...)
DB_VOL="${DB_VOL:-db_data}"
WP_VOL="${WP_VOL:-wordpress_data}"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [BACKUP_DIR] [--wpfiles /path/to/wpfiles.tar(.gz)] [--db /path/to/{db.sql(.gz)|db_data.tar(.gz)}] [--yes|-y]

Examples:
  $(basename "$0") backup/20250818T063015Z
  $(basename "$0") --dir backup/20250818T063015Z
  $(basename "$0") --wpfiles backup/20250818T063015Z/wpfiles.tar.gz --db backup/20250818T063015Z/db.sql.gz

Notes:
  If BACKUP_DIR (or --dir) is provided, the script auto-detects:
    - WordPress files: wpfiles*.tar(.gz)
    - Database: prefers db*.sql(.gz), falls back to db*_data*.tar(.gz)

  --db can be either:
    - SQL dump  (.sql or .sql.gz) -> imported into fresh MariaDB
    - Raw volume tar (.tar or .tar.gz) -> extracted directly into ${DB_VOL} (only safe if taken while DB was stopped)

Env overrides:
  DB_VOL=${DB_VOL}   WP_VOL=${WP_VOL}
EOF
  exit 1
}

DB_FILE=""
WP_FILE=""
YES=0
BACKUP_DIR=""

# Backwards & new flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --db=*) DB_FILE="${1#*=}";;
    --db) shift; DB_FILE="${1-}";;
    --wpfiles=*) WP_FILE="${1#*=}";;
    --wpfiles) shift; WP_FILE="${1-}";;
    --dir=*) BACKUP_DIR="${1#*=}";;
    --dir) shift; BACKUP_DIR="${1-}";;
    --yes|-y) YES=1;;
    -h|--help) usage;;
    -*)
      echo "Unknown arg: $1"; usage;;
    *)
      # first non-flag positional treated as BACKUP_DIR
      if [[ -z "$BACKUP_DIR" && -d "$1" ]]; then
        BACKUP_DIR="$1"
      else
        echo "Unknown arg or not a directory: $1"; usage
      fi
      ;;
  esac
  shift
done

# If a backup dir was provided, auto-detect files (unless explicitly set)
if [[ -n "${BACKUP_DIR}" ]]; then
  [[ -d "${BACKUP_DIR}" ]] || { echo "Backup dir not found: ${BACKUP_DIR}"; exit 1; }

  # Autodetect WP tar
  if [[ -z "${WP_FILE}" ]]; then
    for c in "wpfiles.tar.gz" "wpfiles-*.tar.gz" "wpfiles.tar" "wpfiles-*.tar"; do
      found=( "${BACKUP_DIR}"/$c )
      [[ -e "${found[0]}" ]] && { WP_FILE="${found[0]}"; break; }
    done
  fi

  # Autodetect DB file: prefer SQL, then raw tar
  if [[ -z "${DB_FILE}" ]]; then
    # prefer SQL
    for c in "db.sql.gz" "db.sql" "db-*.sql.gz" "db-*.sql" "*.sql.gz" "*.sql"; do
      found=( "${BACKUP_DIR}"/$c )
      [[ -e "${found[0]}" ]] && { DB_FILE="${found[0]}"; break; }
    done
    # fallback to tar if still empty
    if [[ -z "${DB_FILE}" ]]; then
      for c in "db_data.tar.gz" "db_data-*.tar.gz" "db_data.tar" "db_data-*.tar" "db*.tar.gz" "db*.tar"; do
        found=( "${BACKUP_DIR}"/$c )
        [[ -e "${found[0]}" ]] && { DB_FILE="${found[0]}"; break; }
      done
    fi
  fi
fi

[[ -n "${DB_FILE}" && -n "${WP_FILE}" ]] || usage
[[ -f "${DB_FILE}" ]] || { echo "DB file not found: ${DB_FILE}"; exit 1; }
[[ -f "${WP_FILE}" ]] || { echo "WP files tar not found: ${WP_FILE}"; exit 1; }

# Decide DB restore mode
DB_MODE=""
case "${DB_FILE}" in
  *.sql|*.sql.gz) DB_MODE="sql" ;;
  *.tar|*.tar.gz) DB_MODE="volume" ;;
  *) echo "Cannot infer DB file type. Use .sql/.sql.gz for SQL or .tar(.gz) for raw volume."; exit 1 ;;
esac

# Pick compose command
if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  DC=(docker-compose)
else
  echo "Neither 'docker compose' nor 'docker-compose' found." >&2
  exit 1
fi

echo "==> Plan:"
echo "   - Restore WordPress files tar -> volume '${WP_VOL}'"
echo "   - Restore DB (${DB_MODE}) -> volume '${DB_VOL}'"
echo "   - WP files: ${WP_FILE}"
echo "   - DB file : ${DB_FILE}"
if [[ $YES -ne 1 ]]; then
  read -rp "Proceed? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

untar_into_volume() {
  local vol="$1"
  local file="$2"
  local dir; dir="$(cd "$(dirname "$file")" && pwd)"
  local base; base="$(basename "$file")"
  local flags="xf"
  [[ "$base" =~ \.tar\.gz$ || "$base" =~ \.tgz$ ]] && flags="xzf"
  docker run --rm -v "${vol}":/volume -v "${dir}":/backup alpine \
    sh -lc 'set -e; rm -rf /volume/*; tar '"$flags"' "/backup/'"$base"'" -C /volume'
}

wait_for_db() {
  echo -n "==> Waiting for DB to accept connections"
  until "${DC[@]}" exec -T db sh -lc '
    set -e
    ping_cmd=""
    if command -v mariadb-admin >/dev/null 2>&1; then
      ping_cmd="mariadb-admin"
    elif command -v mysqladmin >/dev/null 2>&1; then
      ping_cmd="mysqladmin"
    fi
    [ -n "$ping_cmd" ] && (
      "$ping_cmd" ping -h 127.0.0.1 -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" --silent ||
      "$ping_cmd" ping -h 127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD" --silent
    )
  '; do
    printf '.'
    sleep 2
  done
  echo
}

# Bring stack down to avoid writes during restore
"${DC[@]}" down

# Ensure volumes exist
docker volume inspect "${WP_VOL}" >/dev/null 2>&1 || docker volume create "${WP_VOL}" >/dev/null
docker volume inspect "${DB_VOL}" >/dev/null 2>&1 || docker volume create "${DB_VOL}" >/dev/null

echo "==> Restoring WordPress files to volume '${WP_VOL}'"
untar_into_volume "${WP_VOL}" "${WP_FILE}"

if [[ "${DB_MODE}" == "volume" ]]; then
  echo "==> Restoring DB volume '${DB_VOL}' from raw tar (assumed cold/clean backup)"
  untar_into_volume "${DB_VOL}" "${DB_FILE}"

  echo "==> Starting DB + WordPress"
  "${DC[@]}" up -d db
  wait_for_db
  "${DC[@]}" up -d wordpress

else
  echo "==> Starting DB container to import SQL"
  "${DC[@]}" up -d db
  wait_for_db

  echo "==> Importing SQL into database '\$MYSQL_DATABASE'"
  if [[ "${DB_FILE}" == *.gz ]]; then
    gunzip -c "${DB_FILE}" | "${DC[@]}" exec -T db sh -lc '
      set -e
      client="mariadb"
      command -v mariadb >/dev/null 2>&1 || client="mysql"
      "$client" -h 127.0.0.1 -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"
    '
  else
    cat "${DB_FILE}" | "${DC[@]}" exec -T db sh -lc '
      set -e
      client="mariadb"
      command -v mariadb >/dev/null 2>&1 || client="mysql"
      "$client" -h 127.0.0.1 -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"
    '
  fi

  echo "==> Starting WordPress"
  "${DC[@]}" up -d wordpress
fi

echo "==> Restore complete."
"${DC[@]}" ps
