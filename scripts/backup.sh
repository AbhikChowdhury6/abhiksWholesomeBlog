#!/usr/bin/env bash
set -euo pipefail

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUTDIR_BASE="${1:-backup}"
OUTDIR="$OUTDIR_BASE/$STAMP"
mkdir -p "$OUTDIR"

# load .env if present (for DB creds)
set -a; [ -f .env ] && . ./.env; set +a

echo "==> Dumping database to $OUTDIR/db.sql.gz"
docker compose exec -T db sh -lc '
  mariadb-dump -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" \
  --single-transaction --quick --routines --events "$MYSQL_DATABASE"
' | gzip > "$OUTDIR/db.sql.gz"

echo "==> Archiving WordPress files to $OUTDIR/wpfiles.tar.gz"
docker run --rm -v wordpress_data:/volume -v "$OUTDIR":/backup alpine \
  tar czf "/backup/wpfiles.tar.gz" -C /volume .

# snapshot the config used to run this version
cp docker-compose.yml "$OUTDIR/compose.yml"
[ -f .env ] && cp .env "$OUTDIR/env"

echo "==> Done. Backup stored in $OUTDIR"
du -h "$OUTDIR"/* | sed 's/^/   /'
