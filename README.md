# DevContainers

A repository for setting up various development environments quickly using pre-built Docker containers with SSH access and GitHub CLI integration.

## Available Environments

- **devcontainers-base**: Full-featured development environment with SSH server, GitHub CLI, oh-my-zsh, and enhanced tooling
- **devcontainers-java-17**: Java 17 development environment with Maven, Gradle, and Java tooling
- **devcontainers-java-21**: Java 21 development environment with Maven, Gradle, and Java tooling
- **devcontainers-lite**: Minimal development environment with essential tools and non-root user setup
- **devcontainers-dotnet-8**: .NET 8 development environment with SDK and tooling

## Usage

Use the provided `dc.sh` script to interactively select and run a development environment:

```bash
./dc.sh [docker_run_args...]
```

### Examples

```bash
# Basic usage - shows interactive menu to select environment
./dc.sh

# With volume mount
./dc.sh -v .:/workspace

# With multiple Docker options
./dc.sh -v .:/workspace -p 8080:8080 --name mydevcontainer

## Features

### All Environments Include
- Ubuntu latest base image
- Non-root user (`vscode`) with sudo access
- Essential development tools (git, vim, build-essential, curl, wget, etc.)
- Network utilities (ping, net-tools, dnsutils)
- Process management tools (htop, procps)
- Text processing tools (jq)
- SSH server with password authentication

### Specialized Environments
- **Java 17/21**: Maven, Gradle, OpenJDK, and Java development tools
- **.NET 8**: .NET SDK, NuGet, and .NET development tools
- **Base**: Enhanced with oh-my-zsh and additional development tools

## Environment Variables

- `DOCKER_IN_DOCKER=true`: Mounts Docker socket for Docker-in-Docker integration

## Requirements

- Docker
- GitHub CLI (optional)
- SSH client (optional, for SSH connections)

## Container Registry

All images are automatically built and published to GitHub Container Registry:
- Registry: `ghcr.io/temannin/`
- Images are built via GitHub Actions on push to main branch
