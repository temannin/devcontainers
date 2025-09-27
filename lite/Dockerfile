# Base devcontainer image based on Ubuntu LTS
FROM ubuntu:latest

LABEL org.opencontainers.image.source=https://github.com/temannin/devcontainers

# Avoid prompts from apt
ENV DEBIAN_FRONTEND=noninteractive

# Set timezone
ENV TZ=UTC
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Update package lists and install essential tools
RUN apt-get update && apt-get install -y \
    # Basic utilities
    curl \
    wget \
    git \
    vim \
    htop \
    tree \
    unzip \
    zip \
    tar \
    gzip \
    zsh \
    # Build tools
    build-essential \
    cmake \
    make \
    gcc \
    g++ \
    # Network tools
    net-tools \
    iputils-ping \
    dnsutils \
    # Process management
    procps \
    # Text processing
    jq \
    # CA certificates
    ca-certificates \
    # Clean up
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Create a non-root user for development
ENV USERNAME=vscode
ENV USER_UID=1001
ENV USER_GID=$USER_UID

# Create the user
RUN groupadd --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID -m $USERNAME \
    && apt-get update \
    && apt-get install -y sudo \
    && echo $USERNAME ALL=\(root\) NOPASSWD:ALL > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

#  Give user sudo access
RUN echo $USERNAME ALL=\(root\) NOPASSWD:ALL > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME

# Switch to the non-root user
USER $USERNAME

# Set working directory
WORKDIR /home/$USERNAME

# Default command - start SSH server and shell
CMD ["/bin/bash"]
