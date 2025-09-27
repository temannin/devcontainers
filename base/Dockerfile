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
    # SSH client and server
    openssh-client \
    openssh-server \
    # CA certificates
    ca-certificates \
    # Clean up
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Create a non-root user for development
ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=$USER_UID
ARG SSH_PUBLIC_KEY=

# Create the user
RUN groupadd --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID -m $USERNAME \
    && apt-get update \
    && apt-get install -y sudo \
    && echo $USERNAME ALL=\(root\) NOPASSWD:ALL > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Create .ssh directory and add the SSH public key if SSH_PUBLIC_KEY is not empty
RUN if [ ! -z "$SSH_PUBLIC_KEY" ]; then \
    mkdir -p /home/$USERNAME/.ssh \
    && echo "$SSH_PUBLIC_KEY" > /home/$USERNAME/.ssh/authorized_keys \
    && chmod 700 /home/$USERNAME/.ssh \
    && chmod 600 /home/$USERNAME/.ssh/authorized_keys \
    && chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh; \
fi

# Configure SSH server
RUN sudo mkdir /var/run/sshd \
  && echo 'PermitRootLogin no' | sudo tee -a /etc/ssh/sshd_config \
  && echo 'PasswordAuthentication no' | sudo tee -a /etc/ssh/sshd_config \
  && echo 'PubkeyAuthentication yes' | sudo tee -a /etc/ssh/sshd_config \
  && echo 'X11Forwarding yes' | sudo tee -a /etc/ssh/sshd_config \
  && echo "AllowUsers $USERNAME" | sudo tee -a /etc/ssh/sshd_config

  # Create startup script to run SSH server and shell
RUN echo '#!/bin/bash' | sudo tee /usr/local/bin/start-devcontainer.sh \
  && echo 'sudo service ssh start' | sudo tee -a /usr/local/bin/start-devcontainer.sh \
  && echo 'exec "$@"' | sudo tee -a /usr/local/bin/start-devcontainer.sh \
  && sudo chmod +x /usr/local/bin/start-devcontainer.sh

EXPOSE 22

# Switch to the non-root user
USER $USERNAME

# Set working directory
WORKDIR /home/$USERNAME

# Install oh-my-zsh
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

# Install latest GitHub CLI (architecture-aware)
RUN ARCH=$(dpkg --print-architecture) \
  && GH_VERSION=$(curl -s https://api.github.com/repos/cli/cli/releases/latest | grep '"tag_name"' | cut -d'"' -f4) \
  && wget https://github.com/cli/cli/releases/download/${GH_VERSION}/gh_${GH_VERSION#v}_linux_${ARCH}.deb \
  && sudo dpkg -i gh_${GH_VERSION#v}_linux_${ARCH}.deb || sudo apt-get install -f -y \
  && rm gh_${GH_VERSION#v}_linux_${ARCH}.deb



ENV GITHUB_TOKEN=""
# RUN gh auth login if GITHUB_TOKEN is not empty
RUN <<EOF
    if [ ! -z "$GITHUB_TOKEN" ]; then
        gh auth login --with-token
    fi
EOF

# Default command - start SSH server and shell
CMD ["/usr/local/bin/start-devcontainer.sh", "/bin/zsh"]
