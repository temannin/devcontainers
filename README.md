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

## IntelliJ over SSH (Windows + WSL)

`intellij/Start-IntelliJContainer.ps1` runs a Java project in a container that
IntelliJ connects to with Remote Development over SSH. Run it from the project
on Windows:

```powershell
PS C:\src\my-app> C:\path\to\devcontainers\intellij\Start-IntelliJContainer.ps1
```

Each run also saves the script to `~\.devcontainers\` and, once, adds a
`Start-IntelliJContainer` alias for it to your PowerShell 7 and Windows
PowerShell profiles, so afterwards it's just:

```powershell
PS C:\src\my-app> Start-IntelliJContainer
```

(Windows PowerShell only loads profiles if its execution policy allows it; the
script warns when it doesn't.)

Through WSL it uses the distro's Docker (Docker Desktop with WSL integration, or
Docker Engine installed in the distro) or Podman to:

- build a local image (nothing is published) on the official Maven image,
  `maven:3-eclipse-temurin-<N>`, with the JDK version read from `.java-version`,
  `.sdkmanrc`, `.tool-versions`, `pom.xml` or `build.gradle(.kts)` (default 17,
  or `-JavaVersion`), plus sshd;
- start a container with SSH on `127.0.0.1:2222` (or the next free port), letting
  in `~\.ssh\id_ed25519.pub` (or `-PublicKey`), which it creates if you have no
  SSH key yet. With Docker Engine or Podman in the distro, the container shares
  WSL's network, so a server it runs (say Spring Boot on 8080) is at
  `http://localhost:8080` on Windows;
- copy the project into a volume at `/workspace/<folder>`. For a Git repository
  the container checks the tracked files out itself, so they get Linux line
  endings, and reapplies uncommitted changes; ignored files such as `target/`
  aren't copied.

It then prints the details for IntelliJ's **File > Remote Development > SSH**
(or JetBrains Gateway): user `dev`, host `127.0.0.1`, the port, and the project
directory. Running it again starts the existing container without copying
again; `-Stop` stops it and `-Remove` deletes it with its copy of the project.
Missing prerequisites (WSL, a distro, a container engine, an SSH key) are
reported with how to fix them; `Get-Help ~\.devcontainers\Start-IntelliJContainer.ps1 -Full`
lists every option.

## Features

- **lazydocker**: installs [lazydocker](https://github.com/jesseduffield/lazydocker) (`features/lazydocker`)

## Container Registry

Images and features are published to GitHub Container Registry (`ghcr.io/temannin/`) by GitHub Actions on push to `main`. Each folder with a `Dockerfile` is built as `devcontainers-<folder>`; pull requests only check that the images build.
