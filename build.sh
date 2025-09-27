#!/bin/bash

# take in the image name as an argument
IMAGE_NAME=$1

# create a SSH pub/priv key pair where it will go to ~/.ssh/id_rsa.pub
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""

# build the image in directory $IMAGE_NAME
docker build -t $IMAGE_NAME --build-arg SSH_PUBLIC_KEY="$(cat ~/.ssh/id_rsa.pub)" -f $IMAGE_NAME/Dockerfile .

# if build is successful, run the image
if [ $? -eq 0 ]; then
    docker run -e GITHUB_TOKEN=$(gh auth token) -p 2222:22 --rm -it $IMAGE_NAME
fi

