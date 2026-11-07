# syntax=docker/dockerfile:1
#
# packwiz (https://github.com/packwiz/packwiz), the Minecraft modpack editor,
# on the Microsoft devcontainers Debian base image.
#
# Besides being a devcontainer, the image is used as a Gitea Actions job
# container (`container: image: ghcr.io/temannin/devcontainers-packwiz:latest`)
# for modpack release jobs, so it also carries:
#   - node:    the runner executes JavaScript actions (e.g. actions/checkout)
#              with the container's node
#   - python3: runs the release script
#   - tea:     the Gitea CLI, to create releases and upload assets
# It runs as root, which job containers expect.
#
# packwiz has no release binaries, so it is compiled from source with
# `go install`. The build runs natively on the build machine and cross-compiles
# for each target platform (no QEMU), and only the binary is copied into the
# final image.

FROM --platform=$BUILDPLATFORM golang:1.26 AS build

ARG TARGETOS
ARG TARGETARCH

# Cross-compiled installs land in /go/bin/<os>_<arch>/, native ones in /go/bin/.
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
      go install github.com/packwiz/packwiz@latest && \
    find /go/bin -type f -name packwiz -exec cp {} /usr/local/bin/packwiz \;

FROM mcr.microsoft.com/devcontainers/base:debian

LABEL org.opencontainers.image.source=https://github.com/temannin/devcontainers

RUN apt-get update && \
    apt-get install -y --no-install-recommends nodejs python3 && \
    rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local/bin/packwiz /usr/local/bin/packwiz

# Pinned to a release: gitea/tea:latest points at a dev build. The binary is
# built against glibc (Wolfi) and runs on Debian.
COPY --from=gitea/tea:0.16.0 /usr/bin/tea /usr/local/bin/tea
