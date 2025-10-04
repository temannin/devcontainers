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

# Interactive image selection
echo "Available devcontainer images:"
echo "=============================="

# Define available images
IMAGES=(
    "devcontainers-base"
    "devcontainers-java-17"
    "devcontainers-java-21"
    "devcontainers-lite"
    "devcontainers-dotnet-8"
)

# Display images with numbers
for i in "${!IMAGES[@]}"; do
    echo "$((i+1)). ${IMAGES[i]}"
done

echo ""
echo "Please select an image (enter number 1-${#IMAGES[@]}):"
read -p "> " SELECTION

# Validate selection
if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -gt "${#IMAGES[@]}" ]; then
    echo "❌ Invalid selection. Please enter a number between 1 and ${#IMAGES[@]}"
    exit 1
fi

# Set the selected image name with full registry path
SELECTED_IMAGE="${IMAGES[$((SELECTION-1))]}"
IMAGE_NAME="ghcr.io/temannin/$SELECTED_IMAGE:latest"
echo "✅ Selected: $SELECTED_IMAGE"
echo "📦 Full image name: $IMAGE_NAME"
echo ""

# Set up Docker socket mounting if needed
if [ "$DOCKER_IN_DOCKER" = "true" ]; then
    MOUNT_DOCKER_SOCKET="-v /var/run/docker.sock:/var/run/docker.sock"
else
    MOUNT_DOCKER_SOCKET=""
fi

# Capture all arguments to pass to docker run
DOCKER_RUN_ARGS="$@"

echo "🚀 Starting container..."
docker run -e GITHUB_TOKEN=$(gh auth token) -p 2222:22 -d $DOCKER_RUN_ARGS $MOUNT_DOCKER_SOCKET $IMAGE_NAME zsh -c "sudo service ssh start && while true; do sleep 1000; done"