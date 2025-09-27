# DevContainers

A repository for setting up various development environments quickly using Docker containers.

## Available Environments

- **base**: Full-featured development environment with SSH server, GitHub CLI, oh-my-zsh, and comprehensive tooling
- **lite**: Minimal development environment with essential tools only

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

⚠️ **Note**: This project currently only builds for AMD-based architectures (x86_64/amd64). Support for ARM-based architectures (like Apple Silicon Macs) is not yet available.

## Features

### Base Environment
- Ubuntu 22.04 LTS base
- SSH server with key-based authentication
- GitHub CLI with automatic authentication
- oh-my-zsh shell environment
- Comprehensive development tools (git, vim, build-essential, etc.)
- Network and system utilities

### Lite Environment
- Ubuntu 22.04 LTS base
- Essential development tools only
- Minimal footprint
- Basic shell environment

## Requirements

- Docker
- GitHub CLI (for base environment)
- SSH client for connecting to containers
