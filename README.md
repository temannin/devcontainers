# DevContainers

A repository for setting up various development environments quickly using Docker containers with SSH access and GitHub CLI integration.

## Available Environments

- **lite**: Minimal development environment with essential tools and non-root user setup
- **base**: Full-featured development environment built on top of lite, adding SSH server, GitHub CLI, oh-my-zsh, and enhanced tooling

## Usage

Use the provided `build.sh` script to build and run a development environment:

```bash
./build.sh <image_name>
```

Where `<image_name>` is either `base` or `lite`.

### Example

```bash
./build.sh base
```

This will:
1. Generate SSH keys for the container
2. Build the Docker image with SSH key authentication
3. Run the container with SSH server on port 2222

## Architecture Support

This project supports multiple architectures including AMD64 (x86_64) and ARM64. The GitHub CLI installation is architecture-aware and automatically detects the target platform.

## Features

### Lite Environment
- Ubuntu latest base image
- Non-root user (`vscode`) with sudo access
- Essential development tools (git, vim, build-essential, curl, wget, etc.)
- Network utilities (ping, net-tools, dnsutils)
- Process management tools (htop, procps)
- Text processing tools (jq)
- Minimal footprint for quick builds

### Base Environment
- Built on top of the lite environment
- SSH server with key-based authentication
- GitHub CLI with automatic token authentication
- oh-my-zsh shell environment with enhanced prompt
- SSH server exposed on port 22
- Startup script for automatic SSH server initialization

## Requirements

- Docker
- GitHub CLI (for base environment authentication)
- SSH client for connecting to containers

## Docker Image Structure

The environments use a layered approach:
- **lite** provides the foundation with essential tools and user setup
- **base** extends lite with SSH capabilities and enhanced development features

This allows for efficient builds and the ability to create custom environments based on the lite foundation.
