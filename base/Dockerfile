# Base devcontainer image based on Ubuntu LTS
FROM ghcr.io/temannin/devcontainers-lite:latest

# build command: 
# docker build -t ghcr.io/temannin/devcontainers-base:latest -f base/Dockerfile .

LABEL org.opencontainers.image.source=https://github.com/temannin/devcontainers

# Avoid prompts from apt
ENV DEBIAN_FRONTEND=noninteractive

RUN sudo apt-get update && sudo apt-get install openssh-server -y

EXPOSE 22

# Install oh-my-zsh
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

# Install latest GitHub CLI (architecture-aware)
RUN ARCH=$(dpkg --print-architecture) \
  && GH_VERSION=$(curl -s https://api.github.com/repos/cli/cli/releases/latest | grep '"tag_name"' | cut -d'"' -f4) \
  && GH_VERSION_NO_V=$(echo "$GH_VERSION" | sed 's/^v//') \
  && wget "https://github.com/cli/cli/releases/download/${GH_VERSION}/gh_${GH_VERSION_NO_V}_linux_${ARCH}.deb" \
  && sudo dpkg -i "gh_${GH_VERSION_NO_V}_linux_${ARCH}.deb" || sudo apt-get install -f -y \
  && rm "gh_${GH_VERSION_NO_V}_linux_${ARCH}.deb"

ENV GITHUB_TOKEN=""
# RUN gh auth login if GITHUB_TOKEN is not empty
RUN <<EOF
    if [ ! -z "$GITHUB_TOKEN" ]; then
        gh auth login --with-token
    fi
EOF

USER root

RUN sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
RUN echo "$USERNAME:changeme" | chpasswd

USER $USERNAME
