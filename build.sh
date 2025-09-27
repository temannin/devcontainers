#!/bin/bash

# Usage: ./build.sh <image_name> [docker_run_args...]
# Examples: 
#   ./build.sh myapp
#   ./build.sh myapp -v .:/app
#   ./build.sh myapp -v .:/app -p 8080:8080 --name mycontainer

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
IMAGE_NAME=$1

# capture all remaining arguments to pass to docker run
shift  # remove the first argument (image name)
DOCKER_RUN_ARGS="$@"

# create a SSH pub/priv key pair where it will go to ~/.ssh/id_rsa.pub
# auto overwrite the existing key if it exists
if [ -f ~/.ssh/$IMAGE_NAME/devcontainer_id_rsa.pub ]; then
    rm ~/.ssh/$IMAGE_NAME/devcontainer_id_rsa
    rm ~/.ssh/$IMAGE_NAME/devcontainer_id_rsa.pub
fi
ssh-keygen -t rsa -b 4096 -f ~/.ssh/$IMAGE_NAME/devcontainer_id_rsa -N ""

# build the image in directory $IMAGE_NAME
docker build -t $IMAGE_NAME --build-arg SSH_PUBLIC_KEY="$(cat ~/.ssh/$IMAGE_NAME/devcontainer_id_rsa.pub)" -f $IMAGE_NAME/Dockerfile .

# if build is successful, run the image
if [ $? -eq 0 ]; then
    docker run -e GITHUB_TOKEN=$(gh auth token) -p 2222:22 --rm -it $DOCKER_RUN_ARGS $IMAGE_NAME
fi

