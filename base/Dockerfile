# Base devcontainer image based on Ubuntu LTS
FROM ghcr.io/temannin/devcontainers-lite:latest

LABEL org.opencontainers.image.source=https://github.com/temannin/devcontainers

# Avoid prompts from apt
ENV DEBIAN_FRONTEND=noninteractive

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
# RUN ARCH=$(dpkg --print-architecture) \
#   && GH_VERSION=$(curl -s https://api.github.com/repos/cli/cli/releases/latest | grep '"tag_name"' | cut -d'"' -f4) \
#   && wget https://github.com/cli/cli/releases/download/${GH_VERSION}/gh_${GH_VERSION#v}_linux_${ARCH}.deb \
#   && dpkg -i gh_${GH_VERSION#v}_linux_${ARCH}.deb || sudo apt-get install -f -y \
#   && rm gh_${GH_VERSION#v}_linux_${ARCH}.deb

ENV GITHUB_TOKEN=""
# RUN gh auth login if GITHUB_TOKEN is not empty
RUN <<EOF
    if [ ! -z "$GITHUB_TOKEN" ]; then
        gh auth login --with-token
    fi
EOF

# Default command - start SSH server and shell
CMD ["/usr/local/bin/start-devcontainer.sh", "/bin/zsh"]
