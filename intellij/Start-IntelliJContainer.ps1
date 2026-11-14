<#
.SYNOPSIS
Runs a Java project in a container that IntelliJ connects to over SSH.

.DESCRIPTION
Run it from a Java project on Windows. Through WSL it builds a small local
image (an Eclipse Temurin JDK, Maven and an SSH server), starts a container from it
and copies the project into a volume that belongs to that container. IntelliJ
(File > Remote Development > SSH, or JetBrains Gateway) then connects to it as
"dev" and runs the IDE backend inside.

The container engine is whatever the WSL distro has: Docker (Docker Desktop
with WSL integration, or Docker Engine installed in the distro) or Podman.

Files are copied only when the container is created. Running the script again
for the same project starts the existing container and prints how to connect;
-Stop stops it and -Remove deletes it, along with its copy of the project.

What gets copied:
  - A Git repository: .git and the untracked, not ignored, files. The container
    checks the tracked files out itself, so they get Linux line endings rather
    than the CRLF of a Windows checkout, then reapplies your uncommitted
    changes, staged and unstaged. Ignored files (target/, build/, ...) stay
    behind.
  - Anything else: the whole folder except target, build, out and .gradle.

Every run also keeps a copy of the script in ~\.devcontainers and makes sure
your PowerShell profiles (PowerShell 7 and Windows PowerShell) define the
Start-IntelliJContainer alias for it, so the command works in any new session.

.PARAMETER Path
The project folder. Defaults to the current directory.

.PARAMETER JavaVersion
The JDK's major version, e.g. 21. By default it is read from .java-version,
.sdkmanrc, .tool-versions, pom.xml or build.gradle(.kts), falling back to 17.

.PARAMETER Port
The port on 127.0.0.1 that SSH is published on. Defaults to the first free one
from 2222.

.PARAMETER PublicKey
The SSH public key to log in with. Defaults to the first of id_ed25519.pub,
id_ecdsa.pub and id_rsa.pub in ~\.ssh; if there are none, ~\.ssh\id_ed25519 is
created, without a passphrase.

.PARAMETER Distro
The WSL distro to use. Defaults to WSL's default distro.

.PARAMETER Engine
docker or podman. By default docker is used if it works, otherwise podman.

.PARAMETER Stop
Stop the project's container.

.PARAMETER Remove
Delete the project's container and its volume, including any work in it that
hasn't been pushed or copied out.

.EXAMPLE
PS C:\src\my-app> C:\tools\Start-IntelliJContainer.ps1

.EXAMPLE
PS> .\Start-IntelliJContainer.ps1 -Path C:\src\my-app -JavaVersion 17 -Distro Ubuntu
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Start')]
param(
    [string]$Path = '.',

    [Parameter(ParameterSetName = 'Start')]
    [ValidateRange(8, 99)]
    [int]$JavaVersion,

    [Parameter(ParameterSetName = 'Start')]
    [ValidateRange(1, 65535)]
    [int]$Port,

    [Parameter(ParameterSetName = 'Start')]
    [string]$PublicKey,

    [string]$Distro,

    [ValidateSet('docker', 'podman')]
    [string]$Engine,

    [Parameter(ParameterSetName = 'Stop', Mandatory = $true)]
    [switch]$Stop,

    [Parameter(ParameterSetName = 'Remove', Mandatory = $true)]
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# The image. Built locally (never pushed) as intellij-dev:jdk<version>.
# ---------------------------------------------------------------------------

$Dockerfile = @'
ARG BASE
FROM ${BASE}

ARG DEBIAN_FRONTEND=noninteractive

# openssh-server: what IntelliJ connects to.
# tini: PID 1, so processes the IDE leaves behind (Gradle/Maven daemons, test
#   runs) are reaped.
# fontconfig, libfreetype6, libx*: the IDE backend runs headless but still
#   loads AWT, which needs them.
# The host keys the package generates are deleted: each container makes its own
# on first start.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server sudo tini git curl ca-certificates unzip zip less procps \
      fontconfig libfreetype6 libxext6 libxrender1 libxtst6 libxi6 \
 && rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_*

# Maven, for projects without a wrapper (./mvnw) and for the terminal. Ubuntu's
# package would pull in a second JDK, so it comes from Maven Central (which
# keeps every release), checked against the SHA-512 published there.
ARG MAVEN_VERSION=3.9.16
RUN url=https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/$MAVEN_VERSION/apache-maven-$MAVEN_VERSION-bin.tar.gz \
 && curl -fsSL -o /tmp/maven.tar.gz "$url" \
 && echo "$(curl -fsSL "$url.sha512" | cut -d' ' -f1)  /tmp/maven.tar.gz" | sha512sum -c - \
 && mkdir -p /opt/maven \
 && tar -xzf /tmp/maven.tar.gz -C /opt/maven --strip-components=1 \
 && ln -s /opt/maven/bin/mvn /usr/local/bin/mvn \
 && rm /tmp/maven.tar.gz

RUN useradd --create-home --shell /bin/bash dev \
 && echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev \
 && chmod 440 /etc/sudoers.d/dev \
 && install -d -o dev -g dev /workspace

# SSH sessions don't inherit the image's ENV, so java wouldn't be on the PATH.
# PAM loads /etc/environment into every session.
RUN env | grep -E '^(JAVA_HOME|PATH|LANG|LANGUAGE|LC_ALL)=' \
      | sed 's/^\([^=]*\)=\(.*\)$/\1="\2"/' > /etc/environment

COPY sshd.conf /etc/ssh/sshd_config.d/intellij.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh
COPY project.sh /etc/profile.d/zz-intellij-project.sh

WORKDIR /workspace
EXPOSE 22
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
'@

$SshdConfig = @'
# Read before the rest of sshd_config; sshd keeps the first value it sees.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers dev

# The key from the script, plus any the user adds to ~/.ssh/authorized_keys.
AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/intellij_authorized_keys

# IntelliJ reaches the IDE backend through an SSH port forward.
AllowTcpForwarding yes
ClientAliveInterval 60
'@

$Entrypoint = @'
#!/bin/sh
set -e
# Host keys: generated on first start, then kept with the container.
ssh-keygen -A
printf '%s\n' "$SSH_PUBLIC_KEY" > /etc/ssh/intellij_authorized_keys
chmod 644 /etc/ssh/intellij_authorized_keys
# Where /etc/profile.d/zz-intellij-project.sh takes SSH logins.
printf '%s\n' "$PROJECT_DIR" > /etc/intellij-project
mkdir -p /run/sshd
# On the host network (SSH_PORT set) sshd listens on 127.0.0.1:<port>, which
# WSL forwards to Windows; otherwise on port 22, published by the engine.
if [ -n "$SSH_PORT" ]; then
  exec /usr/sbin/sshd -D -e -p "$SSH_PORT" -o ListenAddress=127.0.0.1
fi
exec /usr/sbin/sshd -D -e
'@

# Interactive SSH logins start in the project rather than the home directory.
# Commands run over SSH (ssh host command, IntelliJ's own connections) don't
# start login shells, so they keep their working directory.
$ProjectProfile = @'
case $- in
  *i*)
    if [ -n "$SSH_CONNECTION" ] && [ "$PWD" = "$HOME" ] && [ -r /etc/intellij-project ]; then
      __project=$(cat /etc/intellij-project)
      [ -n "$__project" ] && [ -d "$__project" ] && cd "$__project"
      unset __project
    fi
    ;;
esac
'@

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Stop-WithError([string]$Message) {
    Write-Host ''
    Write-Host $Message -ForegroundColor Red
    exit 1
}

function ConvertTo-ShellLiteral([string]$Value) {
    "'" + $Value.Replace("'", "'\''") + "'"
}

# Runs a bash script in the WSL distro and returns its output. Each entry of
# -Variables becomes a shell variable, and $E is the container engine. The
# script travels base64-encoded, so nothing in it needs quoting for Windows.
function Invoke-Wsl {
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [hashtable]$Variables = @{}
    )
    $lines = @('set -eo pipefail')
    if ($script:EngineCommand) { $lines += 'E=' + (ConvertTo-ShellLiteral $script:EngineCommand) }
    foreach ($name in $Variables.Keys) {
        $lines += $name + '=' + (ConvertTo-ShellLiteral ([string]$Variables[$name]))
    }
    $text = (($lines + $Script) -join "`n").Replace("`r`n", "`n")
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
    $arguments = @()
    if ($Distro) { $arguments += @('-d', $Distro) }
    $arguments += @('-e', 'bash', '-c', "source <(echo $encoded | base64 -d)")
    & wsl.exe @arguments
}

# Runs Windows Git in the project and returns its output: bytes with -Bytes,
# otherwise UTF-8 text (PowerShell's own pipes would re-encode both).
function Invoke-Git {
    param([string[]]$Arguments, [switch]$Bytes)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:GitPath
    $info.Arguments = $Arguments -join ' '
    $info.WorkingDirectory = $script:ProjectPath
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    if (-not $Bytes) { $info.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false }
    $process = [System.Diagnostics.Process]::Start($info)
    if ($Bytes) {
        $buffer = New-Object System.IO.MemoryStream
        $process.StandardOutput.BaseStream.CopyTo($buffer)
        $output = $buffer.ToArray()
    } else {
        $output = $process.StandardOutput.ReadToEnd().Trim()
    }
    $process.WaitForExit()
    [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output }
}

function Get-JavaVersion([string]$Directory) {
    $rules = @(
        @('.java-version', '^\s*(?:[a-z][a-z0-9]*-)?(\d[\d.]*)'),
        @('.sdkmanrc', '(?m)^\s*java\s*=\s*(\d[\d.]*)'),
        @('.tool-versions', '(?m)^\s*java\s+(?:[a-z][a-z0-9]*-)*(\d[\d.]*)'),
        @('pom.xml', '<maven\.compiler\.release>\s*(\d[\d.]*)'),
        @('pom.xml', '<java\.version>\s*(\d[\d.]*)'),
        @('pom.xml', '<maven\.compiler\.source>\s*(\d[\d.]*)'),
        @('pom.xml', '<release>\s*(\d[\d.]*)\s*</release>'),
        @('build.gradle.kts', 'JavaLanguageVersion\.of\(\s*"?(\d+)'),
        @('build.gradle.kts', 'jvmToolchain\(\s*(\d+)'),
        @('build.gradle.kts', 'JavaVersion\.VERSION_(\d+(?:_\d+)?)'),
        @('build.gradle', 'JavaLanguageVersion\.of\(\s*[''"]?(\d+)'),
        @('build.gradle', 'jvmToolchain\(\s*(\d+)'),
        @('build.gradle', 'JavaVersion\.VERSION_(\d+(?:_\d+)?)'),
        @('build.gradle', '(?:source|target)Compatibility\s*=\s*[''"]?(\d[\d.]*)')
    )
    foreach ($rule in $rules) {
        $file = Join-Path $Directory $rule[0]
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        $content = [IO.File]::ReadAllText($file)
        if ($content -match $rule[1]) {
            $value = $Matches[1]
            # "1.8" and VERSION_1_8 mean Java 8.
            if ($value -match '^1[._](\d+)') { $major = [int]$Matches[1] }
            else { $major = [int]($value -replace '\D.*$', '') }
            if ($major -ge 8) { return [pscustomobject]@{ Version = $major; Source = $rule[0] } }
        }
    }
    [pscustomobject]@{ Version = 17; Source = 'default' }
}

# Makes ~\.ssh\id_ed25519 (no passphrase) for IntelliJ to log in with, and
# returns its public key's path. If id_ed25519 exists but its .pub doesn't, the
# .pub is rebuilt from it instead of replacing the key.
function New-SshKey {
    $sshKeygen = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
    if (-not $sshKeygen) {
        Stop-WithError ("No SSH key was found in $HOME\.ssh, and ssh-keygen isn't available to make one.`n" +
            "Install the OpenSSH client (Settings > System > Optional features > OpenSSH Client),`n" +
            "or pass an existing public key with -PublicKey <path\to\key.pub>.")
    }
    $directory = Join-Path $HOME '.ssh'
    $key = Join-Path $directory 'id_ed25519'
    $null = New-Item -ItemType Directory -Force -Path $directory

    # The command line is built by hand: PowerShell versions disagree on how
    # to pass the empty passphrase as a native argument.
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $sshKeygen.Source
    $info.UseShellExecute = $false
    if (Test-Path -LiteralPath $key) {
        Write-Host "Rebuilding the missing $key.pub from $key..."
        $info.Arguments = "-y -f `"$key`""
        $info.RedirectStandardOutput = $true
        $process = [System.Diagnostics.Process]::Start($info)
        $publicKey = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0 -or -not $publicKey.Trim()) { Stop-WithError "Couldn't read the public key from $key." }
        [IO.File]::WriteAllText("$key.pub", $publicKey.Trim() + "`n")
    } else {
        Write-Host "No SSH key found; creating $key (no passphrase) for IntelliJ to log in with..."
        $info.Arguments = "-q -t ed25519 -N `"`" -C `"$env:USERNAME@$env:COMPUTERNAME`" -f `"$key`""
        $process = [System.Diagnostics.Process]::Start($info)
        $process.WaitForExit()
        if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath "$key.pub")) { Stop-WithError "ssh-keygen couldn't create $key." }
    }
    "$key.pub"
}

function Get-ContainerPort {
    # Containers record their SSH port in a label; on the host network there's
    # no published port to ask the engine about.
    $output = Invoke-Wsl -Variables @{ name = $ContainerName } @'
port=$($E inspect -f '{{index .Config.Labels "intellij.port"}}' "$name" 2>/dev/null || true)
case "$port" in
  ''|*[!0-9]*) $E port "$name" 22 2>/dev/null | head -n1 || true ;;
  *) echo "$port" ;;
esac
'@
    if ("$output" -match '(\d+)\s*$') { return [int]$Matches[1] }
}

# Waits for sshd's greeting on 127.0.0.1:<port>, so a container that's up but
# unreachable is reported instead of looking ready.
function Assert-SshAnswers([int]$HostPort) {
    $deadline = (Get-Date).AddSeconds(15)
    $lastError = $null
    while ((Get-Date) -lt $deadline) {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $client.Connect('127.0.0.1', $HostPort)
            $stream = $client.GetStream()
            $stream.ReadTimeout = 3000
            $buffer = New-Object byte[] 4
            if ($stream.Read($buffer, 0, 4) -eq 4 -and [Text.Encoding]::ASCII.GetString($buffer) -eq 'SSH-') { return }
            $lastError = 'the connection was closed before the SSH greeting'
        } catch {
            $lastError = $_.Exception.InnerException.Message
            if (-not $lastError) { $lastError = $_.Exception.Message }
        } finally {
            $client.Close()
        }
        Start-Sleep -Milliseconds 500
    }
    Stop-WithError ("$ContainerName is running, but SSH isn't answering on 127.0.0.1:${HostPort} ($lastError).`n" +
        "  Its log:  wsl -d $DistroName -e $EngineCommand logs $ContainerName")
}

# WSL shuts a distro down a few seconds after its last wsl.exe session ends,
# taking Docker Engine or Podman, and the container, with it. A hidden session
# per container keeps the distro up. (Docker Desktop keeps its own VM running,
# so it doesn't need one.)
function Get-KeepAlive {
    $marker = "intellij-keepalive-$ContainerName"
    Get-CimInstance Win32_Process -Filter "Name = 'wsl.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($marker) }
}

function Start-KeepAlive {
    if (-not $NeedsKeepAlive -or (Get-KeepAlive)) { return }
    # wsl.exe rejects a quoted distro name (and names can't contain spaces).
    $arguments = "-d $DistroName -e sh -c `"exec sleep infinity`" intellij-keepalive-$ContainerName"
    $null = Start-Process wsl.exe -ArgumentList $arguments -WindowStyle Hidden -PassThru
}

function Stop-KeepAlive {
    Get-KeepAlive | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Write-ConnectionInfo([int]$HostPort, [string]$KeyPath) {
    $command = "Start-IntelliJContainer -Path '" + $ProjectPath.Replace("'", "''") + "'"
    if ($Distro) { $command += " -Distro $Distro" }
    Write-Host ''
    Write-Host "Ready: $ContainerName ($EngineCommand in WSL distro $DistroName)" -ForegroundColor Green
    Write-Host ''
    Write-Host 'In IntelliJ: File > Remote Development > SSH > New Connection (or JetBrains Gateway)'
    Write-Host "  Username:          dev"
    Write-Host "  Host:              127.0.0.1"
    Write-Host "  Port:              $HostPort"
    if ($KeyPath) {
        Write-Host "  Authentication:    Key pair, $KeyPath"
    } else {
        Write-Host "  Authentication:    Key pair (the private key of the public key the container was created with)"
    }
    Write-Host "  Project directory: $ProjectDir"
    Write-Host ''
    Write-Host "Shell:  ssh -p $HostPort dev@127.0.0.1"
    Write-Host "Stop:   $command -Stop"
    Write-Host "Delete: $command -Remove"
    if ($UseHostNetwork) {
        Write-Host ''
        Write-Host 'The container shares WSL''s network: a server it runs on, say, port 8080 is at'
        Write-Host 'http://localhost:8080 on Windows (two projects can''t use the same port at once).'
    }
    if ($NeedsKeepAlive) {
        Write-Host ''
        Write-Host "A hidden wsl.exe keeps $DistroName (and so the container) running until -Stop."
        Write-Host 'After restarting Windows or WSL, run the script again to start the container.'
    }
}

# ---------------------------------------------------------------------------
# The Start-IntelliJContainer command
# ---------------------------------------------------------------------------

$InstalledScript = Join-Path $HOME '.devcontainers\Start-IntelliJContainer.ps1'
$ProfileMarker = '# devcontainers: Start-IntelliJContainer'
$ProfileLines = @(
    $ProfileMarker
    "Set-Alias -Name Start-IntelliJContainer -Value (Join-Path `$HOME '.devcontainers\Start-IntelliJContainer.ps1')"
)

# The execution policy a new session of that edition gets. Restricted (Windows
# PowerShell's default) and AllSigned keep the profile from loading.
function Get-SessionExecutionPolicy([string]$Exe) {
    $override = $env:PSExecutionPolicyPreference
    try {
        Remove-Item Env:\PSExecutionPolicyPreference -ErrorAction SilentlyContinue
        "$(& $Exe -NoLogo -NoProfile -NonInteractive -Command 'Get-ExecutionPolicy')".Trim()
    } finally {
        if ($override) { $env:PSExecutionPolicyPreference = $override }
    }
}

# Copies this script to ~\.devcontainers (when it differs) and adds the alias
# to the CurrentUserAllHosts profile of each installed edition, once.
function Install-Command {
    if ($PSCommandPath -ne $InstalledScript) {
        $same = (Test-Path -LiteralPath $InstalledScript) -and
            ((Get-FileHash -LiteralPath $InstalledScript).Hash -eq (Get-FileHash -LiteralPath $PSCommandPath).Hash)
        if (-not $same) {
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $InstalledScript)
            Copy-Item -LiteralPath $PSCommandPath -Destination $InstalledScript -Force
            # A downloaded script keeps its "from the internet" mark through the
            # copy, and RemoteSigned refuses to run it.
            Unblock-File -LiteralPath $InstalledScript
            Write-Host "Saved the script as $InstalledScript"
        }
    }

    $documents = [Environment]::GetFolderPath('MyDocuments')
    $editions = @(
        @{ Name = 'PowerShell 7'; Exe = 'pwsh.exe'; Profile = Join-Path $documents 'PowerShell\profile.ps1' },
        @{ Name = 'Windows PowerShell'; Exe = 'powershell.exe'; Profile = Join-Path $documents 'WindowsPowerShell\profile.ps1' }
    )
    foreach ($edition in $editions) {
        if (-not (Get-Command $edition.Exe -ErrorAction SilentlyContinue)) { continue }
        $file = $edition.Profile
        # (Not "$bytes = if ...": PowerShell would turn an empty array into $null.)
        $bytes = New-Object byte[] 0
        if (Test-Path -LiteralPath $file) { $bytes = [IO.File]::ReadAllBytes($file) }
        # Profiles saved by Windows PowerShell's ">" are UTF-16; anything else
        # takes the ASCII lines as they are.
        $utf16 = $bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE
        $encoding = if ($utf16) { [Text.Encoding]::Unicode } else { [Text.Encoding]::ASCII }
        $existing = if ($utf16) { $encoding.GetString($bytes) } else { [Text.Encoding]::UTF8.GetString($bytes) }
        if ($existing.Contains($ProfileMarker)) { continue }

        $text = ''
        if ($existing -and -not $existing.EndsWith("`n")) { $text += "`r`n" }
        if ($existing) { $text += "`r`n" }
        $text += ($ProfileLines -join "`r`n") + "`r`n"
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $file)
        $stream = [IO.File]::Open($file, [IO.FileMode]::Append)
        try {
            $data = $encoding.GetBytes($text)
            $stream.Write($data, 0, $data.Length)
        } finally {
            $stream.Dispose()
        }
        Write-Host "Added the Start-IntelliJContainer command to your $($edition.Name) profile ($file)"

        $policy = Get-SessionExecutionPolicy $edition.Exe
        if ($policy -in 'Restricted', 'AllSigned') {
            Write-Warning ("$($edition.Name)'s execution policy is $policy, so it won't load the profile. To allow local scripts:`n" +
                "  $($edition.Exe) -Command Set-ExecutionPolicy -Scope CurrentUser RemoteSigned")
        }
    }

    # Available in this session too, not only in new ones.
    Set-Alias -Name Start-IntelliJContainer -Value $InstalledScript -Scope Global
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$previousOutputEncoding = [Console]::OutputEncoding
try {
    # Read WSL's output, and wsl.exe's own messages, as UTF-8.
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
    $env:WSL_UTF8 = '1'

    Install-Command

    # --- Project -------------------------------------------------------------

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $resolved -or -not (Test-Path -LiteralPath $resolved.ProviderPath -PathType Container)) {
        Stop-WithError "Project folder not found: $Path"
    }
    $ProjectPath = $resolved.ProviderPath.TrimEnd('\')
    $folder = Split-Path -Leaf $ProjectPath
    $slug = ($folder.ToLowerInvariant() -replace '[^a-z0-9_.-]+', '-').Trim('-', '.', '_')
    if (-not $slug) { $slug = 'project' }
    if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).Trim('-', '.', '_') }
    # A hash of the full path keeps two projects with the same folder name apart.
    $sha = [Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($ProjectPath.ToLowerInvariant()))
    $hash = -join ($hashBytes[0..2] | ForEach-Object { $_.ToString('x2') })
    $ContainerName = "intellij-$slug-$hash"
    $ProjectDir = '/workspace/' + ($folder -replace '[^A-Za-z0-9_.-]+', '-')

    # --- WSL -----------------------------------------------------------------

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        Stop-WithError ("WSL isn't installed. Install it from an administrator PowerShell, then restart Windows:`n" +
            "  wsl --install")
    }
    $DistroName = Invoke-Wsl 'printf "%s\n" "$WSL_DISTRO_NAME"'
    if ($LASTEXITCODE -ne 0 -or -not $DistroName) {
        $which = if ($Distro) { "the WSL distro '$Distro'" } else { "WSL's default distro" }
        Stop-WithError ("Couldn't run a command in $which.`n" +
            "  List the installed distros with:  wsl -l -v`n" +
            "  Install one with:                 wsl --install -d Ubuntu`n" +
            "  Pick one for this script with:    -Distro <name>")
    }
    $DistroName = "$DistroName".Trim()

    # --- Container engine ----------------------------------------------------

    $candidates = if ($Engine) { $Engine } else { 'docker podman' }
    $probe = Invoke-Wsl -Variables @{ candidates = $candidates } @'
for e in $candidates; do
  command -v "$e" >/dev/null 2>&1 || continue
  if out=$("$e" info 2>&1); then echo "ok $e $("$e" info --format '{{.OperatingSystem}}' 2>/dev/null)"; exit 0; fi
  echo "broken $e $(printf '%s\n' "$out" | grep -m1 -iE 'error|denied|cannot|refused' || printf '%s\n' "$out" | head -n1)"
done
'@
    $probe = @($probe)
    $working = $probe | Where-Object { $_ -match '^ok (\S+)' } | Select-Object -First 1
    if ($working) {
        $EngineCommand = ($working -split ' ')[1]
        $NeedsKeepAlive = $working -notmatch 'Docker Desktop'
    } else {
        $broken = $probe | Where-Object { $_ -match '^broken ' } | Select-Object -First 1
        if ($broken -match '^broken docker (.*)$') {
            $detail = $Matches[1]
            if ($detail -match 'permission denied') {
                Stop-WithError ("Docker is installed in WSL ($DistroName), but your user isn't allowed to use it:`n  $detail`n" +
                    "Add yourself to the docker group, restart WSL, and run this again:`n" +
                    "  wsl -d $DistroName -e sudo usermod -aG docker `$USER`n" +
                    "  wsl --shutdown")
            }
            Stop-WithError ("Docker is installed in WSL ($DistroName), but it isn't reachable:`n  $detail`n" +
                "  - Docker Desktop: start it, and turn on integration with $DistroName under`n" +
                "    Settings > Resources > WSL integration.`n" +
                "  - Docker Engine installed in the distro: start it with`n" +
                "    wsl -d $DistroName -e sudo systemctl start docker   (or: sudo service docker start)")
        }
        if ($broken -match '^broken podman (.*)$') {
            Stop-WithError ("Podman is installed in WSL ($DistroName), but 'podman info' failed:`n  $($Matches[1])")
        }
        $wanted = if ($Engine) { $Engine } else { 'Docker or Podman' }
        Stop-WithError ("$wanted wasn't found in the WSL distro $DistroName. Install one of:`n" +
            "  - Docker Desktop, with integration for $DistroName turned on`n" +
            "    (Settings > Resources > WSL integration): https://docs.docker.com/desktop/`n" +
            "  - Docker Engine, inside ${DistroName}: https://docs.docker.com/engine/install/`n" +
            "  - Podman, inside ${DistroName}: sudo apt install podman  (or: sudo dnf install podman)`n" +
            "Or point the script at another distro with -Distro <name>.")
    }

    $state = Invoke-Wsl -Variables @{ name = $ContainerName } '$E container inspect -f "{{.State.Running}}" "$name" 2>/dev/null || true'
    $state = "$state".Trim()

    # --- Stop / Remove -------------------------------------------------------

    if ($Stop) {
        Stop-KeepAlive
        if (-not $state) { Write-Host "There's no container for $ProjectPath."; return }
        if ($state -eq 'true') {
            $null = Invoke-Wsl -Variables @{ name = $ContainerName } '$E stop "$name"'
            if ($LASTEXITCODE -ne 0) { Stop-WithError "Couldn't stop $ContainerName." }
        }
        Write-Host "Stopped $ContainerName."
        return
    }

    if ($Remove) {
        $volumeExists = Invoke-Wsl -Variables @{ name = $ContainerName } '$E volume inspect "$name" >/dev/null 2>&1 && echo yes || true'
        if (-not $state -and "$volumeExists".Trim() -ne 'yes') { Write-Host "There's no container for $ProjectPath."; return }
        if (-not $PSCmdlet.ShouldProcess("$ContainerName and its copy of the project", 'Delete')) { return }
        $hostPort = if ($state) { Get-ContainerPort }
        $null = Invoke-Wsl -Variables @{ name = $ContainerName } '$E rm -f "$name" >/dev/null 2>&1 || true; $E volume rm -f "$name" >/dev/null 2>&1 || true'
        Stop-KeepAlive
        # The next container on this port has new host keys; forget the old ones.
        $sshKeygen = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
        if ($hostPort -and $sshKeygen -and (Test-Path -LiteralPath (Join-Path $HOME '.ssh\known_hosts'))) {
            $null = & $sshKeygen.Source -R "[127.0.0.1]:$hostPort" 2>&1
        }
        Write-Host "Deleted $ContainerName."
        return
    }

    # --- Start an existing container ------------------------------------------

    if ($state) {
        Start-KeepAlive
        if ($state -ne 'true') {
            $null = Invoke-Wsl -Variables @{ name = $ContainerName } '$E start "$name"'
            if ($LASTEXITCODE -ne 0) {
                Stop-KeepAlive
                Stop-WithError "Couldn't start $ContainerName (is its port taken by something else?)."
            }
        }
        Write-Host "Using the existing container; files weren't copied again (-Remove starts over)."
        $hostPort = Get-ContainerPort
        $UseHostNetwork = "$(Invoke-Wsl -Variables @{ name = $ContainerName } '$E inspect -f "{{.HostConfig.NetworkMode}}" "$name"')".Trim() -eq 'host'
        Assert-SshAnswers $hostPort
        Write-ConnectionInfo $hostPort $null
        return
    }

    # --- Create --------------------------------------------------------------

    # SSH key
    if ($PublicKey) {
        if (-not (Test-Path -LiteralPath $PublicKey -PathType Leaf)) { Stop-WithError "Public key not found: $PublicKey" }
        $publicKeyPath = (Resolve-Path -LiteralPath $PublicKey).ProviderPath
    } else {
        $publicKeyPath = 'id_ed25519.pub', 'id_ecdsa.pub', 'id_rsa.pub' |
            ForEach-Object { Join-Path $HOME ".ssh\$_" } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1
        if (-not $publicKeyPath) { $publicKeyPath = New-SshKey }
    }
    $publicKeyText = ([IO.File]::ReadAllText($publicKeyPath)).Trim()
    $privateKeyPath = $publicKeyPath -replace '\.pub$', ''

    # JDK
    if ($JavaVersion) {
        $java = [pscustomobject]@{ Version = $JavaVersion; Source = '-JavaVersion' }
    } else {
        $java = Get-JavaVersion $ProjectPath
    }
    $image = "intellij-dev:jdk$($java.Version)"
    $baseImage = "docker.io/library/eclipse-temurin:$($java.Version)-jdk"

    # Port
    if (-not $Port) {
        $used = @{}
        foreach ($listener in [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()) {
            $used[$listener.Port] = $true
        }
        # Stopped containers don't hold their ports, but will when started. And
        # on the host network, sshd competes with everything listening in WSL.
        $taken = Invoke-Wsl @'
ids=$($E ps -aq --filter label=intellij.project)
[ -z "$ids" ] || $E inspect -f '{{index .Config.Labels "intellij.port"}} {{range .HostConfig.PortBindings}}{{range .}}{{.HostPort}} {{end}}{{end}}' $ids
! command -v ss >/dev/null 2>&1 || ss -Hltn | awk '{ n = split($4, a, ":"); print a[n] }'
'@
        foreach ($p in ("$taken" -split '\s+')) { if ($p -match '^\d+$') { $used[[int]$p] = $true } }
        $Port = 2222
        while ($used.ContainsKey($Port)) { $Port++ }
    }

    # What to copy
    $gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
    $GitPath = if ($gitCommand) { $gitCommand.Source } else { $null }
    $gitMode = $false
    if (Test-Path -LiteralPath (Join-Path $ProjectPath '.git') -PathType Container) {
        if (-not $GitPath) {
            Write-Warning "Git for Windows isn't on the PATH; copying the folder as it is instead of through Git."
        } else {
            if ((Invoke-Git 'rev-parse', '--verify', '-q', 'HEAD').ExitCode -eq 0) {
                $gitMode = $true
            } else {
                Write-Warning "The repository has no commits yet; copying the folder as it is."
            }
        }
    }

    Write-Host "Project:   $ProjectPath"
    Write-Host "Engine:    $EngineCommand (WSL distro $DistroName)"
    Write-Host "JDK:       Temurin $($java.Version) (from $($java.Source))"
    Write-Host ''
    Start-KeepAlive
    Write-Host "Building $image (the first build takes a minute or two)..."
    $null = Invoke-Wsl -Variables @{
        dockerfile = $Dockerfile; sshd_config = $SshdConfig; entrypoint = $Entrypoint; project_profile = $ProjectProfile
        image = $image; base = $baseImage
    } @'
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
printf '%s\n' "$dockerfile" > "$dir/Dockerfile"
printf '%s\n' "$sshd_config" > "$dir/sshd.conf"
printf '%s\n' "$entrypoint" > "$dir/entrypoint.sh"
printf '%s\n' "$project_profile" > "$dir/project.sh"
$E build -q --build-arg "BASE=$base" -t "$image" "$dir"
'@
    if ($LASTEXITCODE -ne 0) {
        Stop-KeepAlive
        Stop-WithError "Building $image failed (is there a Temurin $($java.Version) image? Pick another with -JavaVersion)."
    }

    # With the engine inside WSL, the container joins WSL's own network. Then
    # sshd and any server the project runs are reachable from Windows through
    # WSL's localhost forwarding, and nothing depends on the engine's bridge,
    # which another engine in a different distro (they all share one network)
    # can clash with. Docker Desktop runs in its own VM, so it keeps the bridge
    # and publishes SSH.
    $UseHostNetwork = $NeedsKeepAlive
    Write-Host "Starting $ContainerName on 127.0.0.1:$Port..."
    $null = Invoke-Wsl -Variables @{
        name = $ContainerName; hostname = $slug; image = $image; port = $Port
        project = $ProjectPath; key = $publicKeyText; project_dir = $ProjectDir
        host_network = $(if ($UseHostNetwork) { 'yes' } else { '' })
    } @'
if [ -n "$host_network" ]; then
  # The host network brings no /etc/hosts entry for the container's own
  # hostname, and servers (jwebserver, Spring Boot) look it up.
  network=(--network host --add-host "$hostname:127.0.0.1" -e "SSH_PORT=$port")
else
  network=(-p "127.0.0.1:$port:22")
fi
$E volume create "$name" >/dev/null
# AUDIT_WRITE: Docker grants it by default, Podman doesn't, and sshd's PAM
# session needs it.
$E run -d --name "$name" --hostname "$hostname" \
  --label "intellij.project=$project" --label "intellij.port=$port" \
  "${network[@]}" --cap-add AUDIT_WRITE \
  -e "SSH_PUBLIC_KEY=$key" -e "PROJECT_DIR=$project_dir" \
  -v "$name:/workspace" \
  "$image" >/dev/null
'@
    if ($LASTEXITCODE -ne 0) {
        $null = Invoke-Wsl -Variables @{ name = $ContainerName } '$E rm -f "$name" >/dev/null 2>&1 || true; $E volume rm -f "$name" >/dev/null 2>&1 || true'
        Stop-KeepAlive
        Stop-WithError "Couldn't start the container (is port $Port free? Pick another with -Port)."
    }

    Write-Host "Copying the project to ${ProjectDir}..."
    $listFile = $null
    try {
        $copyVariables = @{ name = $ContainerName; winpath = $ProjectPath; dir = $ProjectDir }
        if ($gitMode) {
            # A commit of the uncommitted changes, staged and unstaged, that
            # leaves the working tree and index alone. Empty when there are none.
            $stash = Invoke-Git '-c', 'user.name=intellij', '-c', 'user.email=intellij@localhost', '-c', 'core.safecrlf=false', 'stash', 'create'
            if ($stash.ExitCode -ne 0) { Stop-WithError "git stash create failed in $ProjectPath." }
            $untracked = Invoke-Git -Bytes 'ls-files', '--others', '--exclude-standard', '-z'
            if ($untracked.ExitCode -ne 0) { Stop-WithError "git ls-files failed in $ProjectPath." }
            $listFile = [IO.Path]::GetTempFileName()
            [IO.File]::WriteAllBytes($listFile, $untracked.Output)

            $copyVariables.winlist = $listFile
            $copyVariables.stash = $stash.Output
            $null = Invoke-Wsl -Variables $copyVariables @'
src=$(wslpath -a "$winpath")
list=$(wslpath -a "$winlist")
$E exec -u dev "$name" mkdir -p "$dir"
{ printf '.git\0'; cat "$list"; } \
  | tar -C "$src" --null -T - -cf - \
  | $E exec -i -u dev "$name" tar -C "$dir" -xf -
$E exec -i -u dev -w "$dir" "$name" bash -s -- "$stash" <<'EOS'
set -e
# Settings Git for Windows writes into the repository that are wrong on Linux.
for key in core.ignorecase core.symlinks core.filemode core.autocrlf core.fsmonitor core.untrackedcache; do
  git config --unset-all "$key" || true
done
git reset -q --hard HEAD
if [ -n "$1" ]; then
  git stash apply -q --index "$1" 2>/dev/null || git stash apply -q "$1"
fi
if [ -f .gitmodules ]; then
  git submodule update -q --init --recursive || echo "warning: couldn't check out the submodules" >&2
fi
EOS
'@
        } else {
            $null = Invoke-Wsl -Variables $copyVariables @'
src=$(wslpath -a "$winpath")
$E exec -u dev "$name" mkdir -p "$dir"
tar -C "$src" --anchored --exclude=./target --exclude=./build --exclude=./out --exclude=./.gradle -cf - . \
  | $E exec -i -u dev "$name" tar -C "$dir" -xf -
# Wrapper scripts with Windows line endings won't run.
$E exec -u dev -w "$dir" "$name" sh -c 'for f in mvnw gradlew; do [ ! -f "$f" ] || { sed -i "s/\r\$//" "$f"; chmod +x "$f"; }; done'
'@
        }
        if ($LASTEXITCODE -ne 0) {
            $null = Invoke-Wsl -Variables @{ name = $ContainerName } '$E rm -f "$name" >/dev/null 2>&1 || true; $E volume rm -f "$name" >/dev/null 2>&1 || true'
            Stop-KeepAlive
            Stop-WithError "Copying the project failed; the container was removed."
        }
    } finally {
        if ($listFile) { Remove-Item -LiteralPath $listFile -ErrorAction SilentlyContinue }
    }

    # Your Git identity, for commits made in the container, whether or not the
    # project is a repository yet. Read in the project, so a repository's own
    # user.name/user.email wins over your global ones.
    if ($GitPath) {
        $gitName = (Invoke-Git 'config', 'user.name').Output
        $gitEmail = (Invoke-Git 'config', 'user.email').Output
        if ($gitName -or $gitEmail) {
            $null = Invoke-Wsl -Variables @{ name = $ContainerName; git_name = $gitName; git_email = $gitEmail } @'
[ -z "$git_name" ] || $E exec -u dev "$name" git config --global user.name "$git_name"
[ -z "$git_email" ] || $E exec -u dev "$name" git config --global user.email "$git_email"
'@
            if ($LASTEXITCODE -ne 0) { Write-Warning "Couldn't set your Git identity in the container." }
        }
    }

    Assert-SshAnswers $Port
    Write-ConnectionInfo $Port $privateKeyPath
} finally {
    try { [Console]::OutputEncoding = $previousOutputEncoding } catch { }
}
