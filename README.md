# abhiksWholesomeBlog


to get going install docker



# a reminder of how to run
docker compose up -d
docker compose down -v
docker stop $(docker ps -q)
docker container prune



## show fully resolved compose on system
docker compose config

## use a different env file
docker compose --env-file .env.staging up -d

##one-off overrides
HOST_HTTP_PORT=9090 docker compose up -d


docker inspect --format '{{json .State.Health}}' wpblog_db | jq
docker logs containerName

docker inspect containerName

backup command example
./scripts/backup.sh


restore command example
./scripts/restore.sh backup/...



to point my domain at my ec2 instance