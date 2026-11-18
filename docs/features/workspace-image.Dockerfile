# BelloCode workspace image with the Docker CLI and Compose (docs/features/containers.md): the CLI talks only to
# BelloCode's filtered endpoint (DOCKER_HOST is set per command). No daemon, no buildx (BuildKit's gRPC is not proxied).
FROM node:22-bookworm-slim
COPY --from=docker:29-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker:29-cli /usr/local/libexec/docker/cli-plugins/docker-compose /usr/local/libexec/docker/cli-plugins/docker-compose
