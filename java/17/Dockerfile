FROM ghcr.io/temannin/devcontainers-base:latest

# build command: docker build -t ghcr.io/temannin/devcontainers-java-17:latest -f java/17/Dockerfile .

LABEL org.opencontainers.image.source=https://github.com/temannin/devcontainers
LABEL org.opencontainers.image.description="Java 17 development environment with Maven, Gradle, and Java tooling"

SHELL ["/bin/bash", "-c"]

RUN curl -s "https://get.sdkman.io" | bash && \
    source "$HOME/.sdkman/bin/sdkman-init.sh" && \
    sdk install java 17.0.16-tem