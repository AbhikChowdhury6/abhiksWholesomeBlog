#!/usr/bin/env bash
set -euo pipefail

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUTDIR="${1:-backup}"
mkdir -p "$OUTDIR"

# load .env if present (for DB creds)
set -a; [ -f .env ] && . ./.env; set +a

echo "==> Dumping database to $OUTDIR/db-$STAMP.sql.gz"
docker compose exec -T db sh -lc '
  mariadb-dump -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" \
  --single-transaction --quick --routines --events "$MYSQL_DATABASE"
' | gzip > "$OUTDIR/db-$STAMP.sql.gz"

echo "==> Archiving WordPress files to $OUTDIR/wpfiles-$STAMP.tar.gz"
docker run --rm -v wordpress_data:/volume -v "$PWD/$OUTDIR":/backup alpine \
  tar czf "/backup/wpfiles-$STAMP.tar.gz" -C /volume .

# snapshot the config used to run this version
cp docker-compose.yml "$OUTDIR/compose-$STAMP.yml"
[ -f .env ] && cp .env "$OUTDIR/env-$STAMP"

echo "==> Done."
du -h "$OUTDIR/db-$STAMP.sql.gz" "$OUTDIR/wpfiles-$STAMP.tar.gz" | sed 's/^/   /'
