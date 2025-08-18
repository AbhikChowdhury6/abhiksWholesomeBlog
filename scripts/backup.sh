#!/usr/bin/env bash
set -euo pipefail

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUTDIR_BASE="${1:-backup}"
OUTDIR="$OUTDIR_BASE/$STAMP"
mkdir -p "$OUTDIR"
# make the host path absolute for Docker bind mount
ABS_OUTDIR="$(cd "$OUTDIR" && pwd)"

# load .env if present (for DB creds)
set -a; [ -f .env ] && . ./.env; set +a

echo "==> Dumping database to $ABS_OUTDIR/db.sql.gz"
docker compose exec -T db sh -lc '
  set -e
  DUMP=mysqldump
  command -v mariadb-dump >/dev/null 2>&1 && DUMP=mariadb-dump
  "$DUMP" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" \
    --single-transaction --quick --routines --events "$MYSQL_DATABASE"
' | gzip > "$ABS_OUTDIR/db.sql.gz"

echo "==> Archiving WordPress files to $ABS_OUTDIR/wpfiles.tar.gz"
docker run --rm \
  -v wordpress_data:/volume \
  -v "$ABS_OUTDIR":/backup \
  alpine tar czf "/backup/wpfiles.tar.gz" -C /volume .

# snapshot the config used to run this version
cp docker-compose.yml "$ABS_OUTDIR/compose.yml"
[ -f .env ] && cp .env "$ABS_OUTDIR/env"

echo "==> Done. Backup stored in $ABS_OUTDIR"
du -h "$ABS_OUTDIR"/* | sed 's/^/   /'
