# Use a multi-arch base image, platform is dynamically selected by Buildx
FROM --platform=$BUILDPLATFORM ubuntu:24.04

LABEL org.opencontainers.image.source=https://github.com/temannin/devcontainers

ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update -y && \
    apt-get install -y build-essential curl wget make git sudo bash zlib1g-dev tzdata libsqlite3-dev libvips-dev && \
    useradd -m -s /bin/bash devuser && \
    echo "devuser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Switch to devuser
USER devuser
WORKDIR /home/devuser

# Download and install ruby-install
RUN wget https://github.com/postmodern/ruby-install/releases/download/v0.10.1/ruby-install-0.10.1.tar.gz && \
    tar -xzvf ruby-install-0.10.1.tar.gz && \
    cd ruby-install-0.10.1 && \
    sudo make install

# Cleanup
RUN rm -rf ruby-install-0.10.1.tar.gz ruby-install-0.10.1

RUN /bin/bash -c "sudo ruby-install --system ruby 3.4.2"

# Default command
CMD ["/bin/bash"]
