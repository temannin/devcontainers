# Base devcontainer image based on Ubuntu LTS
FROM ubuntu:22.04

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
    nano \
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
    # SSH client
    openssh-client \
    # CA certificates
    ca-certificates \
    # Clean up
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Create a non-root user for development
ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=$USER_UID

# Create the user
RUN groupadd --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID -m $USERNAME \
    && apt-get update \
    && apt-get install -y sudo \
    && echo $USERNAME ALL=\(root\) NOPASSWD:ALL > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Switch to the non-root user
USER $USERNAME

# Set working directory
WORKDIR /home/$USERNAME

# Install oh-my-zsh
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

# Install latest GitHub CLI
RUN GH_VERSION=$(curl -s https://api.github.com/repos/cli/cli/releases/latest | grep '"tag_name"' | cut -d'"' -f4) \
  && wget https://github.com/cli/cli/releases/download/${GH_VERSION}/gh_${GH_VERSION#v}_linux_amd64.deb \
  && sudo dpkg -i gh_${GH_VERSION#v}_linux_amd64.deb \
  && rm gh_${GH_VERSION#v}_linux_amd64.deb

ENV GITHUB_TOKEN=""
# RUN gh auth login if GITHUB_TOKEN is not empty
RUN <<EOF
    if [ ! -z "$GITHUB_TOKEN" ]; then
        gh auth login --with-token
    fi
EOF

# Default command
CMD ["/bin/zsh"]
