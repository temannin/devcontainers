# syntax=docker/dockerfile:1
#
# packwiz (https://github.com/packwiz/packwiz), the Minecraft modpack editor,
# on the Microsoft devcontainers Debian base image.
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

COPY --from=build /usr/local/bin/packwiz /usr/local/bin/packwiz
