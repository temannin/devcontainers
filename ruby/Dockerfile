# Use a multi-arch base image, platform is dynamically selected by Buildx
FROM --platform=$BUILDPLATFORM ruby:3.4.2

LABEL org.opencontainers.image.source=https://github.com/temannin/devcontainers

ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update -y && \
    apt-get install -y build-essential curl git sudo bash zlib1g-dev tzdata libsqlite3-dev libvips-dev && \
    useradd -m -s /bin/bash devuser && \
    echo "devuser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Switch to devuser
USER devuser
WORKDIR /home/devuser

# Default command
CMD ["/bin/bash"]
