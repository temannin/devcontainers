# DevContainers

Pre-built development container images and devcontainer features.

## Images

- **devcontainers-nix-pi**: Nix and the pi coding agent, for projects that define their toolchain in a `flake.nix` (`devshell <command>` runs in the project's dev shell)
- **devcontainers-packwiz**: The [packwiz](https://github.com/packwiz/packwiz) CLI for building Minecraft modpacks (compiled from source), on the Microsoft devcontainers Debian base image. Also works as a Gitea Actions job container: includes node, python3 and the [tea](https://gitea.com/gitea/tea) CLI

Use one in a `devcontainer.json`:

```json
{
  "image": "ghcr.io/temannin/devcontainers-packwiz:latest"
}
```

or run it directly:

```bash
docker run -it --rm -v .:/workspace ghcr.io/temannin/devcontainers-packwiz:latest
```

## Features

- **lazydocker**: installs [lazydocker](https://github.com/jesseduffield/lazydocker) (`features/lazydocker`)

## Container Registry

Images and features are published to GitHub Container Registry (`ghcr.io/temannin/`) by GitHub Actions on push to `main`. Each folder with a `Dockerfile` is built as `devcontainers-<folder>`; pull requests only check that the images build.
