# abhiksWholesomeBlog

# a reminder of how to run
docker compose up -d

## show fully resolved compose on system
docker compose config

## use a different env file
docker compose --env-file .env.staging up -d

##one-off overrides
HOST_HTTP_PORT=9090 docker compose up -d




backup command example
./scripts/backup.sh


restore command example
./scripts/restore.sh --wpfiles backup/wpfiles-20250817T010203Z.tar.gz --db backup/db_data-20250817T010203Z.tar.gz
