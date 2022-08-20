Docker is a stand-alone plugin that is "composed" within eramba and used for docker image building and docker workflows and stuff but you can easily do (or anybody when we open eramba repository public, this repository will become public as well https://github.com/eramba/docker):

```shell
git clone https://github.com/eramba/docker
cd docker

## method 1
composer simple-install-enterprise

## or
composer simple-install-community

## method2
docker compose -f docker-compose.simple-install.yml up -d  --always-recreate-deps --force-recreate --remove-orphans --renew-anon-volumes

## or 
docker compose -f docker-compose.simple-install.yml -f docker-compose.simple-install.community.yml up -d  --always-recreate-deps --force-recreate --remove-orphans --renew-anon-volumes
```
