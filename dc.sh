#!/bin/bash

# if CI is defined, exit with an error
if [ "$CI" != "" ]; then
    echo "This script should not be run in a CI environment. Exiting."
    exit 1
fi

# if GITHUB_ACTIONS is defined, exit with an error
if [ "$GITHUB_ACTIONS" != "" ]; then
    echo "This script should not be run in a GitHub Actions environment. Exiting."
    exit 1
fi

# if GITHUB_RUN_ID is defined, exit with an error
if [ "$GITHUB_RUN_ID" != "" ]; then
    echo "This script should not be run in a GitHub Actions environment. Exiting."
    exit 1
fi

# take in the image name as an argument
IMAGE_NAME="ghcr.io/temannin/devcontainers-java-17:latest"
if [ "$DOCKER_IN_DOCKER" = "true" ]; then
    $MOUNT_DOCKER_SOCKET = "-v /var/run/docker.sock:/var/run/docker.sock"   
fi

docker run -e GITHUB_TOKEN=$(gh auth token) -p 2222:22 -d $DOCKER_RUN_ARGS $MOUNT_DOCKER_SOCKET $IMAGE_NAME zsh -c "sudo service ssh start && while true; do sleep 1000; done"