#!/bin/bash

# take in the image name as an argument
IMAGE_NAME=$1

# build the image in directory $IMAGE_NAME
docker build -t $IMAGE_NAME . -f $IMAGE_NAME/Dockerfile

# if build is successful, run the image
if [ $? -eq 0 ]; then
    docker run -e GITHUB_TOKEN=$(gh auth token) --rm -it $IMAGE_NAME
fi

