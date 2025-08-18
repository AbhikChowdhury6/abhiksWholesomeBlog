#!/usr/bin/env bash
set -euo pipefail

# Defaults (override by exporting before running, e.g. DB_VOL=mydb_data WP_VOL=mywp_data ./scripts/restore.sh ...)
DB_VOL="${DB_VOL:-db_data}"
WP_VOL="${WP_VOL:-wordpress_data}"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") --wpfiles /path/to/wpfiles-YYYYmmddTHHMMSSZ.tar.gz --db /path/to/{db-YYYYmmddTHHMMSSZ.sql.gz|db_data-YYYYmmddTHHMMSSZ.tar.gz} [--yes|-y]

Notes:
  --db can be either:
    - SQL dump  (.sql or .sql.gz)  -> imported into fresh MariaDB
    - Raw volume tar (.tar or .tar.gz) -> extracted directly into ${DB_VOL} (only safe if taken while DB was stopped)

Env overrides:
  DB_VOL=${DB_VOL}   WP_VOL=${WP_VOL}
EOF
  exit 1
}

DB_FILE=""
WP_FILE=""
YES=0

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --db=*) DB_FILE="${1#*=}";;
    --wpfiles=*) WP_FILE="${1#*=}";;
    --yes|-y) YES=1;;
    -h|--help) usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
  shift
done

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

# Helper: untar a .tar.gz (or .tar) into a named volume, after clearing it
untar_into_volume() {
  local vol="$1"
  local file="$2"
  local dir; dir="$(dirname "$file")"
  local base; base="$(basename "$file")"
  # Decide tar flags based on extension
  local flags="xf"
  [[ "$base" =~ \.tar\.gz$ || "$base" =~ \.tgz$ ]] && flags="xzf"

  docker run --rm -v "${vol}":/volume -v "${dir}":/backup alpine \
    sh -lc 'set -e; rm -rf /volume/*; tar '"$flags"' "/backup/'"$base"'" -C /volume'
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
  "${DC[@]}" up -d wordpress

else
  echo "==> Starting DB container to import SQL"
  "${DC[@]}" up -d db

  # Wait for DB to be ready
  echo -n "==> Waiting for DB to accept connections"
  until "${DC[@]}" exec -T db sh -lc 'mysqladmin ping -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" --silent'; do
    printf '.'
    sleep 2
  done
  echo

  echo "==> Importing SQL into database '$MYSQL_DATABASE'"
  if [[ "${DB_FILE}" == *.gz ]]; then
    gunzip -c "${DB_FILE}" | "${DC[@]}" exec -T db sh -lc 'mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"'
  else
    cat "${DB_FILE}" | "${DC[@]}" exec -T db sh -lc 'mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"'
  fi

  echo "==> Starting WordPress"
  "${DC[@]}" up -d wordpress
fi

echo "==> Restore complete."
"${DC[@]}" ps
