# Use a multi-arch base image, platform is dynamically selected by Buildx
FROM --platform=$BUILDPLATFORM ruby:3.4.2

LABEL org.opencontainers.image.source=https://github.com/temannin/devcontainers

ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update -y && \
    apt-get install -y build-essential curl git sudo bash zlib1g-dev tzdata libsqlite3-dev && \
    useradd -m -s /bin/bash devuser && \
    echo "devuser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Switch to devuser
USER devuser
WORKDIR /home/devuser

# Conditionally install Homebrew and rbenv (only for non-ARM platforms)
RUN if [ "$(uname -m)" != "aarch64" ]; then \
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" && \
    echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> ~/.bashrc && \
    echo 'bash -c "source ~/.bashrc"' >> ~/.profile && \
    /home/linuxbrew/.linuxbrew/bin/brew install rbenv && \
    echo 'eval "$(rbenv init -)"' >> ~/.bashrc && \
    bash -c "source ~/.bashrc"; \
    fi

# Default command
CMD ["/bin/bash"]
