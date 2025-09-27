FROM ghcr.io/temannin/devcontainers-base:latest

LABEL org.opencontainers.image.source=https://github.com/temannin/devcontainers

SHELL ["/bin/bash", "-c"]

RUN curl -s "https://get.sdkman.io" | bash && \
    source "$HOME/.sdkman/bin/sdkman-init.sh" && \
    sdk install java 17.0.16-tem