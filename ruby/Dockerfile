FROM ubuntu:24.04

LABEL org.opencontainers.image.source=https://github.com/temannin/devcontainers

ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update -y && \
    apt-get install -y build-essential curl git sudo bash zlib1g-dev && \
    useradd -m -s /bin/bash devuser && \
    echo "devuser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Switch to devuser
USER devuser
WORKDIR /home/devuser

# Install Homebrew (as devuser)
RUN /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Configure Homebrew for devuser
RUN echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> ~/.bashrc && \
    echo 'bash -c "source ~/.bashrc"' >> ~/.profile

# Install rbenv (as devuser)
RUN /home/linuxbrew/.linuxbrew/bin/brew install rbenv && \
    echo 'eval "$(rbenv init -)"' >> ~/.bashrc && \
    bash -c "source ~/.bashrc"

CMD ["/bin/bash"]
