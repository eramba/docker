### Setup

Docker is a stand-alone plugin that is "composed" within eramba and used for docker image building and docker workflows but can be used to run docker versions of eramba software very easily.
Clone or download our docker source files:
```shell
git clone https://github.com/eramba/docker
cd docker
```

### Community 

For the community, it should be very easy to run this type of software as there is no authentication or any other procedures required.
You can just use the public [ghcr.io](https://ghcr.io/eramba/eramba) image
```shell
## Run Community version of the software
docker compose -f docker-compose.simple-install.yml up -d --always-recreate-deps --force-recreate --remove-orphans --renew-anon-volumes
```

### Enterprise

Enterprise version of the software requires either ghcr.io authentication with access to our Enterprise package:
```shell
## Docker Authentication
docker login -u your_github_username ghcr.io
```

Or download the exported image from our [Downloads](https://downloads.eramba.org) page and import it into you docker registry and tag the image as `ghcr.io/eramba/eramba-enterprise:latest` for the simple-install script to work without modifications:
```shell
## Import docker image into your registry
docker load -i /path/to/the/docker/image.tar

## Tag the image you imported as ghcr.io/eramba/eramba-enterprise:latest
docker tag downloaded_image ghcr.io/eramba/eramba-enterprise:latest
```

Finally run simple install script to run enterprise version:
```shell
## Run Enterprise version of the software
docker compose -f docker-compose.simple-install.yml -f docker-compose.simple-install.enterprise.yml up -d  --always-recreate-deps --force-recreate --remove-orphans --renew-anon-volumes
```

### Note

Running both Enterprise and Community installations at the same time within a single docker engine is not supported.
