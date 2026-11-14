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

## Dev containers over SSH (Windows + WSL)

The `DevContainers` PowerShell module (`powershell/DevContainers`) runs a Java
project in a container that IntelliJ connects to with Remote Development over
SSH. Install it once, for PowerShell 7 and Windows PowerShell (run it again
after pulling to update):

```powershell
PS C:\path\to\devcontainers> .\powershell\Install.ps1
```

Then, from a project on Windows:

```powershell
PS C:\src\my-app> Start-DevContainer
```

| Command | Does |
| --- | --- |
| `Start-DevContainer` | Creates the project's container if needed, starts it, and prints how to connect |
| `Stop-DevContainer` | Stops it |
| `Remove-DevContainer` | Deletes it and its copy of the project (asks first) |
| `Clear-DevContainer` | Deletes every dev container, whatever the project, in every engine (lists them and asks first). Alias: `Clean-DevContainer` |
| `Reset-DevContainer` | Deletes it and creates it again from a fresh copy, on the newest base image and the same port |
| `Get-DevContainer` | Lists the containers, across engines; pipe it into the others |
| `Enter-DevContainer` | Opens a shell in the container over SSH |
| `Test-DevContainerHost` | Runs only the pre-flight checks |

Through WSL it uses the distro's Docker (Docker Desktop with WSL integration, or
Docker Engine installed in the distro) or Podman; `-Engine podman` uses Podman
for Windows instead when it's installed, creating its machine if there isn't
one. It first checks that the distro runs on WSL 2, that the engine works and
that the distro reaches the internet. Then it:

- builds a local image (nothing is published) on the official Maven image,
  `maven:3-eclipse-temurin-<N>`, with the JDK version read from `.java-version`,
  `.sdkmanrc`, `.tool-versions`, `pom.xml` or `build.gradle(.kts)` (default 17,
  or `-JavaVersion`), plus sshd;
- starts a container with SSH on `127.0.0.1:2222` (or the next free port, with a
  warning saying what holds the ones skipped), letting in
  `~\.ssh\id_ed25519.pub` (or `-PublicKey`), which it creates if you have no SSH
  key yet. Except with Docker Desktop, the container shares WSL's network, so a
  server it runs (say Spring Boot on 8080) is at `http://localhost:8080` on
  Windows;
- copies the project into a volume at `/workspace/<folder>`. For a Git
  repository the container checks the tracked files out itself, so they get
  Linux line endings, and reapplies uncommitted changes; ignored files such as
  `target/` aren't copied.

It then prints the details for IntelliJ's **File > Remote Development > SSH**
(or JetBrains Gateway): user `dev`, host `127.0.0.1`, the port, and the project
directory. Running it again starts the existing container without copying
again. Missing prerequisites (WSL, a distro, a container engine, the internet,
an SSH key) are reported with how to fix them; `Get-Help Start-DevContainer -Full`
lists every option.

## Features

- **lazydocker**: installs [lazydocker](https://github.com/jesseduffield/lazydocker) (`features/lazydocker`)

## Container Registry

Images and features are published to GitHub Container Registry (`ghcr.io/temannin/`) by GitHub Actions on push to `main`. Each folder with a `Dockerfile` is built as `devcontainers-<folder>`; pull requests only check that the images build.
