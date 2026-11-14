# DevContainers: projects in containers that IDEs connect to over SSH, run from
# Windows through WSL with Docker or Podman. Get-Help Start-DevContainer -Full
# explains the whole thing.
#
# Containers, volumes, labels and the image are named intellij-* and
# intellij.*: renaming them would lose track of the containers already made.

$ImageDir = Join-Path $PSScriptRoot 'image'

Update-TypeData -TypeName 'DevContainers.DevContainer' -DefaultDisplayPropertySet Path, State, Port, Engine, Host -Force

# ---------------------------------------------------------------------------
# Output and errors
# ---------------------------------------------------------------------------

# Every command catches this and reports it as its own error.
function Stop-WithError([string]$Message) {
    $exception = New-Object System.Management.Automation.RuntimeException $Message
    throw (New-Object System.Management.Automation.ErrorRecord $exception, 'DevContainers', 'NotSpecified', $null)
}

function Write-Check($Context, [string]$Text) {
    if ($Context.Quiet) { Write-Verbose "ok  $Text"; return }
    Write-Host '  ok  ' -ForegroundColor Green -NoNewline
    Write-Host $Text
}

# Runs a command's body with WSL's output (and wsl.exe's own messages) read as
# UTF-8, then puts the console back as it was. The body sees the command's
# variables, $PSCmdlet included.
function Invoke-WithUtf8([scriptblock]$Body) {
    $savedEncoding = [Console]::OutputEncoding
    $savedWslUtf8 = $env:WSL_UTF8
    try {
        try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
        $env:WSL_UTF8 = '1'
        & $Body
    } finally {
        try { [Console]::OutputEncoding = $savedEncoding } catch { }
        $env:WSL_UTF8 = $savedWslUtf8
    }
}

function ConvertTo-ShellLiteral([string]$Value) {
    "'" + $Value.Replace("'", "'\''") + "'"
}

# ---------------------------------------------------------------------------
# WSL, Git and SSH
# ---------------------------------------------------------------------------

# Runs a bash script in the host's WSL distro and returns its output. Each entry
# of -Variables becomes a shell variable, and $E is the container engine. The
# script travels base64-encoded, so nothing in it needs quoting for Windows.
function Invoke-Wsl {
    param(
        [Parameter(Mandatory = $true, Position = 0)]$Context,
        [Parameter(Mandatory = $true, Position = 1)][string]$Script,
        [hashtable]$Variables = @{}
    )
    $lines = @('set -eo pipefail')
    # In a Podman machine, rootless podman has to use the runtime directory its
    # API service (what podman.exe talks to) uses, or it sees another state.
    if ($Context.PodmanMachine) { $lines += '[ -n "$XDG_RUNTIME_DIR" ] || [ ! -d "/run/user/$(id -u)" ] || export XDG_RUNTIME_DIR="/run/user/$(id -u)"' }
    if ($Context.Engine) { $lines += 'E=' + (ConvertTo-ShellLiteral $Context.Engine) }
    foreach ($name in $Variables.Keys) {
        $lines += $name + '=' + (ConvertTo-ShellLiteral ([string]$Variables[$name]))
    }
    $text = (($lines + $Script) -join "`n").Replace("`r`n", "`n")
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
    $arguments = @()
    if ($Context.Distro) { $arguments += @('-d', $Context.Distro) }
    if ($Context.User) { $arguments += @('-u', $Context.User) }
    $arguments += @('-e', 'bash', '-c', "source <(echo $encoded | base64 -d)")
    & wsl.exe @arguments
}

# Runs Windows Git in the project and returns its output: bytes with -Bytes,
# otherwise UTF-8 text (PowerShell's own pipes would re-encode both).
function Invoke-Git {
    param([string]$GitPath, [string]$Directory, [string[]]$Arguments, [switch]$Bytes)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $GitPath
    $info.Arguments = $Arguments -join ' '
    $info.WorkingDirectory = $Directory
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

# Makes ~\.ssh\id_ed25519 (no passphrase) for the IDE to log in with, and
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
        Write-Host "No SSH key found; creating $key (no passphrase) for the IDE to log in with..."
        $info.Arguments = "-q -t ed25519 -N `"`" -C `"$env:USERNAME@$env:COMPUTERNAME`" -f `"$key`""
        $process = [System.Diagnostics.Process]::Start($info)
        $process.WaitForExit()
        if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath "$key.pub")) { Stop-WithError "ssh-keygen couldn't create $key." }
    }
    "$key.pub"
}

# ---------------------------------------------------------------------------
# Podman for Windows
# ---------------------------------------------------------------------------

function Find-PodmanExe {
    $command = Get-Command podman.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    # The installers put it on the PATH, but only sessions started afterwards
    # see that.
    foreach ($candidate in "$env:LOCALAPPDATA\Programs\Podman\podman.exe", "$env:ProgramFiles\RedHat\Podman\podman.exe") {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
}

# Runs podman.exe on its WSL machines (whatever provider containers.conf
# names). Returns its output, or with -Live shows it as it comes (init's
# download progress, start's messages).
function Invoke-Podman([string]$Exe, [string[]]$Arguments, [switch]$Live) {
    # (Windows PowerShell would turn podman's stderr into a terminating error.)
    $ErrorActionPreference = 'Continue'
    $saved = $env:CONTAINERS_MACHINE_PROVIDER
    $env:CONTAINERS_MACHINE_PROVIDER = 'wsl'
    try {
        if ($Live) { & $Exe @Arguments | Out-Host }
        else { & $Exe @Arguments 2>$null }
    } finally {
        $env:CONTAINERS_MACHINE_PROVIDER = $saved
    }
}

function Get-PodmanMachine([string]$Exe) {
    $json = Invoke-Podman $Exe 'machine', 'list', '--format', 'json'
    if ($LASTEXITCODE -ne 0) { Stop-WithError "'podman machine list' failed. Try it yourself to see why:`n  podman machine list" }
    # (Piped, so Windows PowerShell's single array object is unrolled.)
    $machines = @(($json | Out-String | ConvertFrom-Json) | Where-Object { $_ })
    $machine = $machines | Where-Object { $_.Default } | Select-Object -First 1
    if (-not $machine) { $machine = $machines | Select-Object -First 1 }
    $machine
}

# Finds Podman's default WSL machine. -Mode Create creates it if there's none
# and starts it if it's stopped; Start only starts it; Running takes it only if
# it's running. Returns $null when there's no machine to use.
function Use-PodmanMachine([string]$Exe, [string]$Mode) {
    $machine = Get-PodmanMachine $Exe
    if (-not $machine) {
        if ($Mode -ne 'Create') { return $null }
        Write-Host '        No Podman machine yet; creating one (podman machine init downloads its image, once)...'
        # --import-native-ca: the machine trusts the CAs Windows trusts, so a
        # company proxy that intercepts HTTPS doesn't break pulls and builds.
        $initArguments = @('machine', 'init')
        if ((Invoke-Podman $Exe 'machine', 'init', '--help') -match '--import-native-ca') {
            $initArguments += '--import-native-ca'
        } else {
            Write-Warning "This Podman is too old for 'podman machine init --import-native-ca', so the machine won't trust the certificates Windows trusts. Behind a proxy that intercepts HTTPS, update Podman (winget upgrade Podman.CLI), then recreate the machine."
        }
        Invoke-Podman $Exe -Live $initArguments
        if ($LASTEXITCODE -ne 0) { Stop-WithError "'podman machine init' failed (its output is above)." }
        $machine = Get-PodmanMachine $Exe
        if (-not $machine) { Stop-WithError "'podman machine init' succeeded, but 'podman machine list' shows no machine." }
    }
    $name = "$($machine.Name)".TrimEnd('*')
    if (-not $machine.Running) {
        if ($Mode -eq 'Running') { return $null }
        Write-Host "        Starting the Podman machine $name..."
        Invoke-Podman $Exe -Live 'machine', 'start', $name
        if ($LASTEXITCODE -ne 0) { Stop-WithError "'podman machine start $name' failed (its output is above)." }
    }
    $rootful = "$(Invoke-Podman $Exe 'machine', 'inspect', '--format', '{{.Rootful}}', $name)".Trim() -eq 'true'
    [pscustomobject]@{
        Name    = $name
        # Podman's own naming of the machine's WSL distro.
        Distro  = if ($name.StartsWith('podman')) { $name } else { "podman-$name" }
        Rootful = $rootful
    }
}

# ---------------------------------------------------------------------------
# Pre-flight: the host (WSL distro and container engine)
# ---------------------------------------------------------------------------

# Finds and checks the WSL distro and container engine to use, printing a line
# per check unless -Quiet. Returns the host object the other functions take,
# or $null when -Engine podman's machine isn't there to use (see
# Use-PodmanMachine's -Mode). -InDistro uses the distro's podman even without
# -Distro.
function Resolve-DevContainerHost {
    param(
        [string]$Distro,
        [string]$Engine,
        [switch]$Quiet,
        [ValidateSet('Create', 'Start', 'Running')][string]$Machine = 'Create',
        [switch]$InDistro
    )
    $context = [pscustomobject]@{
        Quiet          = [bool]$Quiet
        DistroOption   = $Distro    # as given, for the commands printed later
        EngineOption   = $Engine
        Distro         = $Distro    # what wsl.exe -d gets
        User           = $null      # what wsl.exe -u gets
        DistroName     = $null
        Engine         = $null
        Kind           = $null
        NeedsKeepAlive = $true
        PodmanExe      = $null
        PodmanMachine  = $null
    }
    if (-not $Quiet) { Write-Host 'Pre-flight checks:' }

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        Stop-WithError ("WSL isn't installed. Install it from an administrator PowerShell, then restart Windows:`n" +
            "  wsl --install")
    }

    # -Engine podman without -Distro: Podman for Windows. The container runs in
    # its WSL machine, so everything done in WSL happens in that machine's
    # distro, as the user podman.exe connects as (root if rootful).
    if ($Engine -eq 'podman' -and -not $Distro -and -not $InDistro) { $context.PodmanExe = Find-PodmanExe }
    if ($context.PodmanExe) {
        $podmanMachine = Use-PodmanMachine $context.PodmanExe $Machine
        if (-not $podmanMachine) { return $null }
        $context.PodmanMachine = $podmanMachine
        $context.Distro = $podmanMachine.Distro
        if ($podmanMachine.Rootful) { $context.User = 'root' }
        $mode = if ($podmanMachine.Rootful) { 'rootful' } else { 'rootless' }
        Write-Check $context "Podman:    machine $($podmanMachine.Name), $mode ($($context.PodmanExe))"
    }

    # WSL 2. Also the distro's name and which of the tools needed are missing.
    $distroInfo = @(Invoke-Wsl $context 'printf "%s\n%s\n%s\n" "$WSL_DISTRO_NAME" "$(uname -r)" "$(command -v tar >/dev/null 2>&1 || echo tar)"')
    if ($LASTEXITCODE -ne 0 -or -not $distroInfo[0]) {
        $which = if ($context.Distro) { "the WSL distro '$($context.Distro)'" } else { "WSL's default distro" }
        Stop-WithError ("Couldn't run a command in $which.`n" +
            "  List the installed distros with:  wsl -l -v`n" +
            "  Install one with:                 wsl --install -d Ubuntu`n" +
            "  Pick one with:                    -Distro <name>")
    }
    $distroName = "$($distroInfo[0])".Trim()
    $context.DistroName = $distroName
    # WSL 1 has no Linux kernel, so no containers; it reports a version like
    # 4.4.0-22621-Microsoft, where WSL 2's real kernel says microsoft-standard.
    if ("$($distroInfo[1])".Trim() -cmatch '-Microsoft$') {
        Stop-WithError ("$distroName runs on WSL 1, and Docker and Podman need WSL 2. Convert it (its files are kept):`n" +
            "  wsl --set-version $distroName 2`n" +
            "If WSL 2 isn't enabled yet, first run 'wsl --install --no-distribution' as administrator and`n" +
            "restart Windows. Or pick a WSL 2 distro with -Distro <name> (wsl -l -v lists them).")
    }
    $missing = "$($distroInfo[2])".Trim()
    if ($missing) {
        Stop-WithError ("$distroName has no $missing, which the project is copied with. Install it:`n" +
            "  wsl -d $distroName -u root -e sh -c `"apt-get install -y $missing || dnf install -y $missing`"")
    }
    Write-Check $context "WSL 2:     $distroName"

    # Container engine
    $candidates = if ($Engine) { $Engine } else { 'docker podman' }
    $probe = @(Invoke-Wsl $context -Variables @{ candidates = $candidates } @'
for e in $candidates; do
  command -v "$e" >/dev/null 2>&1 || continue
  if out=$("$e" info 2>&1); then echo "ok $e $("$e" info --format '{{.OperatingSystem}}' 2>/dev/null)"; exit 0; fi
  echo "broken $e $(printf '%s\n' "$out" | grep -m1 -iE 'error|denied|cannot|refused' || printf '%s\n' "$out" | head -n1)"
done
'@)
    $working = $probe | Where-Object { $_ -match '^ok (\S+)' } | Select-Object -First 1
    if (-not $working) {
        $broken = $probe | Where-Object { $_ -match '^broken ' } | Select-Object -First 1
        if ($broken -match '^broken docker (.*)$') {
            $detail = $Matches[1]
            if ($detail -match 'permission denied') {
                Stop-WithError ("Docker is installed in WSL ($distroName), but your user isn't allowed to use it:`n  $detail`n" +
                    "Add yourself to the docker group, restart WSL, and try again:`n" +
                    "  wsl -d $distroName -e sudo usermod -aG docker `$USER`n" +
                    "  wsl --shutdown")
            }
            Stop-WithError ("Docker is installed in WSL ($distroName), but it isn't reachable:`n  $detail`n" +
                "  - Docker Desktop: start it, and turn on integration with $distroName under`n" +
                "    Settings > Resources > WSL integration.`n" +
                "  - Docker Engine installed in the distro: start it with`n" +
                "    wsl -d $distroName -e sudo systemctl start docker   (or: sudo service docker start)")
        }
        if ($broken -match '^broken podman (.*)$') {
            Stop-WithError ("Podman is installed in WSL ($distroName), but 'podman info' failed:`n  $($Matches[1])")
        }
        $dockerOptions = "  - Docker Desktop, with integration for $distroName turned on`n" +
            "    (Settings > Resources > WSL integration): https://docs.docker.com/desktop/`n" +
            "  - Docker Engine, inside ${distroName}: https://docs.docker.com/engine/install/`n"
        $podmanOption = "  - Podman, inside ${distroName}: sudo apt install podman  (or: sudo dnf install podman)`n"
        $wanted, $options = switch ($Engine) {
            'docker' { 'Docker', "Install one of:`n$dockerOptions" }
            'podman' {
                if ($context.PodmanMachine) { 'Podman', "(It should come with the Podman machine. Recreate the machine with podman machine reset?)`n" }
                else { 'Podman', ("Install one of:`n  - Podman for Windows, which then runs the containers on its own WSL machine:`n" +
                    "    winget install Podman.CLI  (then use -Engine podman without -Distro)`n$podmanOption") }
            }
            default  { 'Docker or Podman', "Install one of:`n$dockerOptions$podmanOption" }
        }
        $other = if ($Engine) { ", or drop -Engine $Engine to use whichever is installed" } else { '' }
        Stop-WithError ("$wanted wasn't found in the WSL distro $distroName. $options" +
            "Or point it at another distro with -Distro <name>$other.")
    }
    $context.Engine = ($working -split ' ')[1]
    # Docker Desktop keeps its own VM running; everything else lives and dies
    # with the WSL distro (see Start-KeepAlive).
    $context.NeedsKeepAlive = $working -notmatch 'Docker Desktop'
    $context.Kind = if ($context.PodmanMachine) { "Podman for Windows, in its machine $($context.PodmanMachine.Name)" }
        elseif (-not $context.NeedsKeepAlive) { 'Docker Desktop' }
        elseif ($context.Engine -eq 'docker') { "Docker Engine in $distroName" }
        else { "Podman in $distroName" }
    Write-Check $context "Engine:    $($context.Engine) ($($context.Kind))"
    $context
}

# Asks https://www.google.com from the distro, with curl, or wget, or (with
# neither installed) a bare TCP connection. The image build, apt-get and the
# IDE's download of its backend all need the internet. Returns $null when it
# answered, otherwise what went wrong and what to try.
function Test-Internet($Context) {
    $distroName = $Context.DistroName
    $result = Invoke-Wsl $Context @'
url=https://www.google.com
rc=0
if command -v curl >/dev/null 2>&1; then
  tool=curl; out=$(curl -sS -o /dev/null --max-time 10 "$url" 2>&1) || rc=$?
elif command -v wget >/dev/null 2>&1; then
  tool=wget; out=$(wget -q -T 10 -t 1 -O /dev/null "$url" 2>&1) || rc=$?
else
  tool=tcp; out=$(timeout 10 bash -c ': </dev/tcp/www.google.com/443' 2>&1) || rc=$?
fi
printf '%s %s %s\n' "$tool" "$rc" "$(printf '%s' "$out" | head -n1)"
'@
    if ("$result" -notmatch '^(\S+) (\d+) ?(.*)$') { return "Couldn't run the check in $distroName." }
    $tool, $code, $detail = $Matches[1], [int]$Matches[2], $Matches[3].Trim()
    if ($code -eq 0) { return $null }

    $dns = "It can't look up names (DNS). VPNs often cause this. Try restarting WSL (wsl --shutdown),`n" +
        "  or dnsTunneling=true under [wsl2] in $HOME\.wslconfig, and check /etc/resolv.conf in $distroName."
    $noAnswer = "Nothing answered: no network, a firewall or VPN blocking WSL, or a proxy is needed`n" +
        "  (set https_proxy in $distroName)."
    $tls = if ($Context.PodmanMachine) {
        "The HTTPS connection was intercepted (a company proxy or antivirus?), and the Podman machine doesn't`n" +
        "  trust its root certificate. A machine created with --import-native-ca trusts what Windows trusts:`n" +
        "  podman machine rm $($Context.PodmanMachine.Name), then Start-DevContainer -Engine podman creates one that way."
    } else {
        "The HTTPS connection was intercepted (a company proxy or antivirus?). Its root certificate`n" +
        "  has to be trusted in ${distroName}: copy it to /usr/local/share/ca-certificates/ and run`n" +
        "  sudo update-ca-certificates."
    }
    $hint = switch ($tool) {
        'curl' { switch ($code) { { $_ -in 5, 6 } { $dns } { $_ -in 7, 28 } { $noAnswer } { $_ -in 35, 60 } { $tls } } }
        'wget' { switch ($code) { 4 { "$noAnswer`n  Or: $dns" } 5 { $tls } } }
        'tcp'  { "$noAnswer`n  Or: $dns" }
    }
    $message = "$distroName can't reach https://www.google.com ($tool exit code $code"
    if ($detail) { $message += ": $detail" }
    $message += ')'
    if ($hint) { $message += "`n  $hint" }
    $message
}

# The internet check of the commands that may build: without the internet a
# new container can't be built, but an existing one can still be started.
function Assert-Internet($Context, [switch]$WarnOnly) {
    $problem = Test-Internet $Context
    if (-not $problem) {
        Write-Check $Context "Internet:  $($Context.DistroName) reaches https://www.google.com"
    } elseif ($WarnOnly) {
        Write-Warning "$problem`n  Starting the existing container anyway; the IDE may not be able to download its backend."
    } else {
        Stop-WithError "$problem`nA new container can't be built without the internet."
    }
}

# ---------------------------------------------------------------------------
# Projects and their containers
# ---------------------------------------------------------------------------

# The project at -Path and the names of its container. -MayBeMissing accepts a
# folder that no longer exists, so its container can still be stopped or
# deleted.
function Get-Project([string]$Path, $Cmdlet, [switch]$MayBeMissing) {
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($resolved -and (Test-Path -LiteralPath $resolved.ProviderPath -PathType Container)) {
        $projectPath = $resolved.ProviderPath
    } elseif ($MayBeMissing) {
        $projectPath = $Cmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    } else {
        Stop-WithError "Project folder not found: $Path"
    }
    $projectPath = $projectPath.TrimEnd('\')
    $folder = Split-Path -Leaf $projectPath
    $slug = ($folder.ToLowerInvariant() -replace '[^a-z0-9_.-]+', '-').Trim('-', '.', '_')
    if (-not $slug) { $slug = 'project' }
    if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).Trim('-', '.', '_') }
    # A hash of the full path keeps two projects with the same folder name apart.
    $sha = [Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($projectPath.ToLowerInvariant()))
    $hash = -join ($hashBytes[0..2] | ForEach-Object { $_.ToString('x2') })
    [pscustomobject]@{
        Path          = $projectPath
        Slug          = $slug
        ContainerName = "intellij-$slug-$hash"
        Directory     = '/workspace/' + ($folder -replace '[^A-Za-z0-9_.-]+', '-')
    }
}

# '' when there's no container, otherwise 'true' or 'false' (running or not).
function Get-ContainerState($Context, [string]$Name) {
    "$(Invoke-Wsl $Context -Variables @{ name = $Name } '$E container inspect -f "{{.State.Running}}" "$name" 2>/dev/null || true')".Trim()
}

function Test-VolumeExists($Context, [string]$Name) {
    "$(Invoke-Wsl $Context -Variables @{ name = $Name } '$E volume inspect "$name" >/dev/null 2>&1 && echo yes || true')".Trim() -eq 'yes'
}

function Get-ContainerPort($Context, [string]$Name) {
    # Containers record their SSH port in a label; on the host network there's
    # no published port to ask the engine about.
    $output = Invoke-Wsl $Context -Variables @{ name = $Name } @'
port=$($E inspect -f '{{index .Config.Labels "intellij.port"}}' "$name" 2>/dev/null || true)
case "$port" in
  ''|*[!0-9]*) $E port "$name" 22 2>/dev/null | head -n1 || true ;;
  *) echo "$port" ;;
esac
'@
    if ("$output" -match '(\d+)\s*$') { return [int]$Matches[1] }
}

# The engine's inspect data of every container this module made.
function Get-ContainerData($Context) {
    # JSON rather than a -f template: Podman applies a template that uses
    # "range" to the whole list instead of to each container.
    $json = @(Invoke-Wsl $Context 'ids=$($E ps -aq --filter label=intellij.project); [ -z "$ids" ] || $E container inspect $ids') -join "`n"
    if (-not $json.Trim()) { return }
    ($json | ConvertFrom-Json) | Where-Object { $_ }
}

function ConvertTo-DevContainer($Context, $Data) {
    $labels = $Data.Config.Labels
    $port = $labels.'intellij.port'
    if (-not $port -and $Data.HostConfig.PortBindings) {
        $port = $Data.HostConfig.PortBindings.PSObject.Properties.Value | ForEach-Object { $_.HostPort } | Select-Object -First 1
    }
    $image = if ($Data.ImageName) { $Data.ImageName } else { $Data.Config.Image }
    [pscustomobject]@{
        PSTypeName = 'DevContainers.DevContainer'
        Path       = $labels.'intellij.project'
        Name       = "$($Data.Name)".TrimStart('/')
        State      = $Data.State.Status
        Port       = if ("$port" -match '^\d+$') { [int]$port } else { $null }
        Engine     = $Context.Engine
        Host       = if ($Context.PodmanMachine) { "Podman machine $($Context.PodmanMachine.Name)" } else { $Context.DistroName }
        # Empty for a Podman machine's containers, so piping the object into
        # the other commands picks the machine again (-Engine podman, no -Distro).
        Distro     = if ($Context.PodmanMachine) { '' } else { $Context.DistroName }
        Image      = $image
    }
}

# Every container this module made, each with the host it's in: Docker and
# Podman in the distro, and Podman for Windows' machine, or only the -Engine
# asked for. -Machine Running skips a stopped machine; Start starts it. (A
# missing machine is never created.) Engines that aren't there, or don't work,
# are skipped.
function Find-DevContainers([string]$Distro, [string]$Engine, [string]$Machine) {
    if ($Engine) {
        $places = @(@{ Engine = $Engine })
    } else {
        $places = @(@{ Engine = 'docker' }, @{ Engine = 'podman'; InDistro = $true })
        if (-not $Distro -and (Find-PodmanExe)) { $places += @{ Engine = 'podman' } }
    }
    foreach ($place in $places) {
        try {
            $context = Resolve-DevContainerHost -Distro $Distro -Engine $place.Engine -InDistro:([bool]$place.InDistro) -Quiet -Machine $Machine
        } catch {
            Write-Verbose "Skipping $($place.Engine): $($_.Exception.Message)"
            continue
        }
        if (-not $context) { Write-Verbose 'Skipping Podman for Windows: there is no machine running.'; continue }
        foreach ($data in @(Get-ContainerData $context)) {
            [pscustomobject]@{ Context = $context; Container = ConvertTo-DevContainer $context $data }
        }
    }
}

# Gives the container your GitHub login: the token of the gh CLI on Windows
# goes into Git's credential store in the container, for https://github.com.
# Run on every start, so a new login on Windows carries over.
function Set-GitHubAuth($Context, [string]$Name) {
    $gh = Get-Command gh.exe -ErrorAction SilentlyContinue
    if (-not $gh) { return }
    # (Windows PowerShell turns gh's error output into a terminating error.)
    try { $token = "$(& $gh.Source auth token --hostname github.com 2>$null)".Trim() } catch { $token = '' }
    if (-not $token) {
        Write-Host "GitHub: your Windows gh isn't logged in, so the container can't clone private repos. Run 'gh auth login', then Start-DevContainer again."
        return
    }
    $null = Invoke-Wsl $Context -Variables @{ name = $Name; token = $token } @'
printf 'https://x-access-token:%s@github.com\n' "$token" \
  | $E exec -i -u dev "$name" sh -c 'umask 077 && cat > "$HOME/.git-credentials" && git config --global credential.https://github.com.helper store'
'@
    if ($LASTEXITCODE -eq 0) {
        Write-Host 'GitHub: the container uses your gh login for https://github.com.'
    } else {
        Write-Warning "Couldn't pass your GitHub login to the container."
    }
}

# Waits for sshd's greeting on 127.0.0.1:<port>, so a container that's up but
# unreachable is reported instead of looking ready.
function Assert-SshAnswers($Context, [string]$Name, [int]$HostPort) {
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
    $logs = if ($Context.PodmanMachine) { "podman logs $Name" } else { "wsl -d $($Context.DistroName) -e $($Context.Engine) logs $Name" }
    Stop-WithError ("$Name is running, but SSH isn't answering on 127.0.0.1:${HostPort} ($lastError).`n" +
        "  Its log:  $logs")
}

# WSL shuts a distro down a few seconds after its last wsl.exe session ends,
# taking Docker Engine or Podman, and the container, with it. A hidden session
# per container keeps the distro up. (Docker Desktop keeps its own VM running,
# so it doesn't need one.)
#
# A project's containers in different engines share a name, so a keepalive is
# matched by its distro too.
function Get-KeepAlive([string]$Name, [string]$Distro) {
    $marker = "intellij-keepalive-$Name"
    Get-CimInstance Win32_Process -Filter "Name = 'wsl.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($marker) -and $_.CommandLine.Contains("-d $Distro ") }
}

function Start-KeepAlive($Context, [string]$Name) {
    if (-not $Context.NeedsKeepAlive -or (Get-KeepAlive $Name $Context.DistroName)) { return }
    # wsl.exe rejects a quoted distro name (and names can't contain spaces).
    $arguments = "-d $($Context.DistroName) -e sh -c `"exec sleep infinity`" intellij-keepalive-$Name"
    $null = Start-Process wsl.exe -ArgumentList $arguments -WindowStyle Hidden -PassThru
}

function Stop-KeepAlive([string]$Name, [string]$Distro) {
    Get-KeepAlive $Name $Distro | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# The options to repeat in the commands printed for a project.
function Get-CommandOptions($Context, $Project) {
    $options = " -Path '" + $Project.Path.Replace("'", "''") + "'"
    if ($Context.DistroOption) { $options += " -Distro $($Context.DistroOption)" }
    if ($Context.EngineOption) { $options += " -Engine $($Context.EngineOption)" }
    $options
}

function Write-ConnectionInfo($Context, $Project, [int]$HostPort, [string]$KeyPath, [bool]$HostNetwork) {
    $options = Get-CommandOptions $Context $Project
    Write-Host ''
    Write-Host "Ready: $($Project.ContainerName) ($($Context.Kind))" -ForegroundColor Green
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
    Write-Host "  Project directory: $($Project.Directory)"
    Write-Host ''
    Write-Host "Shell:  Enter-DevContainer$options   (or: ssh -p $HostPort dev@127.0.0.1)"
    Write-Host "Stop:   Stop-DevContainer$options"
    Write-Host "Delete: Remove-DevContainer$options"
    if ($HostNetwork) {
        Write-Host ''
        Write-Host 'The container shares WSL''s network: a server it runs on, say, port 8080 is at'
        Write-Host 'http://localhost:8080 on Windows (two projects can''t use the same port at once).'
    }
    if ($Context.NeedsKeepAlive) {
        Write-Host ''
        Write-Host "A hidden wsl.exe keeps $($Context.DistroName) (and so the container) running until Stop-DevContainer."
        Write-Host 'After restarting Windows or WSL, run Start-DevContainer again to start the container.'
    }
}

function Get-WindowsListenerPort {
    [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | ForEach-Object { $_.Port }
}

# The first free port from 2222, warning when that isn't 2222 itself.
function Select-Port($Context) {
    # What holds each port, for the warning. Later entries are more telling and
    # win: anything listening on Windows, then in WSL (where the host network
    # puts sshd, and which shows up on Windows too), then this engine's
    # containers. Stopped containers don't hold their ports, but will when
    # started.
    $used = @{}
    foreach ($p in @(Get-WindowsListenerPort)) { $used[[int]$p] = 'a program on Windows' }
    $listening = Invoke-Wsl $Context '! command -v ss >/dev/null 2>&1 || ss -Hltn | awk ''{ n = split($4, a, ":"); print a[n] }'''
    foreach ($p in @($listening)) {
        if ("$p" -match '^\d+$') { $used[[int]$p] = 'something in WSL (another container engine''s dev container, say)' }
    }
    foreach ($container in @(Get-ContainerData $Context)) {
        $labels = $container.Config.Labels
        $holder = "the dev container for $($labels.'intellij.project')"
        $ports = @($labels.'intellij.port')
        $bindings = $container.HostConfig.PortBindings
        if ($bindings) { $ports += $bindings.PSObject.Properties.Value | ForEach-Object { $_.HostPort } }
        foreach ($p in $ports) { if ("$p" -match '^\d+$') { $used[[int]$p] = $holder } }
    }
    $port = 2222
    while ($used.ContainsKey($port)) { $port++ }
    if ($port -ne 2222) {
        $holders = (2222..($port - 1) | ForEach-Object { "  ${_}: $($used[$_])" }) -join "`n"
        Write-Warning ("Port 2222 isn't free, so this container gets ${port}:`n$holders`n" +
            "A saved IDE connection to one of those ports reaches that, not this project. -Port picks the port.")
    }
    $port
}

# Starts the project's existing container if it's stopped and waits for SSH.
# Returns its port and whether it's on the host network.
function Start-ExistingContainer($Context, $Project, [string]$State) {
    $name = $Project.ContainerName
    Start-KeepAlive $Context $name
    if ($State -ne 'true') {
        $null = Invoke-Wsl $Context -Variables @{ name = $name } '$E start "$name"'
        if ($LASTEXITCODE -ne 0) {
            Stop-KeepAlive $name $context.DistroName
            Stop-WithError "Couldn't start $name (is its port taken by something else?)."
        }
    }
    $hostPort = Get-ContainerPort $Context $name
    $hostNetwork = "$(Invoke-Wsl $Context -Variables @{ name = $name } '$E inspect -f "{{.HostConfig.NetworkMode}}" "$name"')".Trim() -eq 'host'
    Assert-SshAnswers $Context $name $hostPort
    [pscustomobject]@{ Port = $hostPort; HostNetwork = $hostNetwork }
}

# Deletes the project's container and volume, and forgets the container's SSH
# host key. Returns the port it had, if it could tell.
function Remove-ProjectContainer($Context, $Project, [string]$State) {
    $name = $Project.ContainerName
    $hostPort = if ($State) { Get-ContainerPort $Context $name }
    $null = Invoke-Wsl $Context -Variables @{ name = $name } '$E rm -f "$name" >/dev/null 2>&1 || true; $E volume rm -f "$name" >/dev/null 2>&1 || true'
    # The next container on this port has new host keys; forget the old ones.
    $sshKeygen = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
    if ($hostPort -and $sshKeygen -and (Test-Path -LiteralPath (Join-Path $HOME '.ssh\known_hosts'))) {
        $null = & $sshKeygen.Source -R "[127.0.0.1]:$hostPort" 2>&1
    }
    $hostPort
}

# Builds the image, creates the project's container, copies the project in and
# prints how to connect. -Pull fetches the newest base image.
function New-ProjectContainer {
    param($Context, $Project, [int]$JavaVersion, [int]$Port, [string]$PublicKey, [switch]$Pull)
    $name = $Project.ContainerName

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
        $java = Get-JavaVersion $Project.Path
    }
    $image = "intellij-dev:jdk$($java.Version)"
    # The official Maven image: Eclipse Temurin with Maven 3 on top.
    $baseImage = "docker.io/library/maven:3-eclipse-temurin-$($java.Version)"

    if (-not $Port) { $Port = Select-Port $Context }

    # What to copy
    $gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
    $gitPath = if ($gitCommand) { $gitCommand.Source } else { $null }
    $gitMode = $false
    if (Test-Path -LiteralPath (Join-Path $Project.Path '.git') -PathType Container) {
        if (-not $gitPath) {
            Write-Warning "Git for Windows isn't on the PATH; copying the folder as it is instead of through Git."
        } elseif ((Invoke-Git $gitPath $Project.Path 'rev-parse', '--verify', '-q', 'HEAD').ExitCode -eq 0) {
            $gitMode = $true
        } else {
            Write-Warning "The repository has no commits yet; copying the folder as it is."
        }
    }

    Write-Host "Project:   $($Project.Path)"
    Write-Host "JDK:       Temurin $($java.Version) (from $($java.Source))"
    Write-Host ''
    Start-KeepAlive $Context $name
    Write-Host "Building $image (the first build takes a minute or two)..."
    $imageFiles = @{}
    foreach ($file in 'Containerfile', 'sshd.conf', 'entrypoint.sh', 'project.sh') {
        $imageFiles[$file] = [IO.File]::ReadAllText((Join-Path $ImageDir $file))
    }
    $null = Invoke-Wsl $Context -Variables @{
        containerfile = $imageFiles['Containerfile']; sshd_config = $imageFiles['sshd.conf']
        entrypoint = $imageFiles['entrypoint.sh']; project_profile = $imageFiles['project.sh']
        image = $image; base = $baseImage
        pull = $(if ($Pull) { 'yes' } else { '' })
    } @'
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
printf '%s\n' "$containerfile" > "$dir/Dockerfile"
printf '%s\n' "$sshd_config" > "$dir/sshd.conf"
printf '%s\n' "$entrypoint" > "$dir/entrypoint.sh"
printf '%s\n' "$project_profile" > "$dir/project.sh"
# Reset-DevContainer: fetch the newest base image instead of reusing the one cached.
$E build -q ${pull:+--pull} --build-arg "BASE=$base" -t "$image" "$dir"
'@
    if ($LASTEXITCODE -ne 0) {
        Stop-KeepAlive $name $context.DistroName
        Stop-WithError "Building $image failed (is there a maven:3-eclipse-temurin-$($java.Version) image? Pick another JDK with -JavaVersion)."
    }

    # With the engine inside WSL, the container joins WSL's own network. Then
    # sshd and any server the project runs are reachable from Windows through
    # WSL's localhost forwarding, and nothing depends on the engine's bridge,
    # which another engine in a different distro (they all share one network)
    # can clash with. Docker Desktop runs in its own VM, so it keeps the bridge
    # and publishes SSH.
    $hostNetwork = $Context.NeedsKeepAlive
    $removeContainer = '$E rm -f "$name" >/dev/null 2>&1 || true; $E volume rm -f "$name" >/dev/null 2>&1 || true'
    Write-Host "Starting $name on 127.0.0.1:$Port..."
    $null = Invoke-Wsl $Context -Variables @{
        name = $name; hostname = $Project.Slug; image = $image; port = $Port
        project = $Project.Path; key = $publicKeyText; project_dir = $Project.Directory
        host_network = $(if ($hostNetwork) { 'yes' } else { '' })
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
        $null = Invoke-Wsl $Context -Variables @{ name = $name } $removeContainer
        Stop-KeepAlive $name $context.DistroName
        Stop-WithError "Couldn't start the container (is port $Port free? Pick another with -Port)."
    }

    Write-Host "Copying the project to $($Project.Directory)..."
    $listFile = $null
    try {
        $copyVariables = @{ name = $name; winpath = $Project.Path; dir = $Project.Directory }
        if ($gitMode) {
            # A commit of the uncommitted changes, staged and unstaged, that
            # leaves the working tree and index alone. Empty when there are none.
            $stash = Invoke-Git $gitPath $Project.Path '-c', 'user.name=intellij', '-c', 'user.email=intellij@localhost', '-c', 'core.safecrlf=false', 'stash', 'create'
            if ($stash.ExitCode -ne 0) { Stop-WithError "git stash create failed in $($Project.Path)." }
            $untracked = Invoke-Git $gitPath $Project.Path -Bytes 'ls-files', '--others', '--exclude-standard', '-z'
            if ($untracked.ExitCode -ne 0) { Stop-WithError "git ls-files failed in $($Project.Path)." }
            $listFile = [IO.Path]::GetTempFileName()
            [IO.File]::WriteAllBytes($listFile, $untracked.Output)

            $copyVariables.winlist = $listFile
            $copyVariables.stash = $stash.Output
            $null = Invoke-Wsl $Context -Variables $copyVariables @'
src=$(wslpath -a "$winpath")
list=$(wslpath -a "$winlist")
$E exec -u dev "$name" mkdir -p "$dir"
# -m: the copies get the current time. Files from a zip (Spring Initializr's,
# say) can carry times hours in the future, which makes tar warn about every
# file and Maven recompile on every build until that time passes.
{ printf '.git\0'; cat "$list"; } \
  | tar -C "$src" --null -T - -cf - \
  | $E exec -i -u dev "$name" tar -C "$dir" -xmf -
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
            $null = Invoke-Wsl $Context -Variables $copyVariables @'
src=$(wslpath -a "$winpath")
$E exec -u dev "$name" mkdir -p "$dir"
# -m: the copies get the current time (see the Git case above).
tar -C "$src" --anchored --exclude=./target --exclude=./build --exclude=./out --exclude=./.gradle -cf - . \
  | $E exec -i -u dev "$name" tar -C "$dir" -xmf -
# Wrapper scripts with Windows line endings won't run.
$E exec -u dev -w "$dir" "$name" sh -c 'for f in mvnw gradlew; do [ ! -f "$f" ] || { sed -i "s/\r\$//" "$f"; chmod +x "$f"; }; done'
'@
        }
        if ($LASTEXITCODE -ne 0) {
            $null = Invoke-Wsl $Context -Variables @{ name = $name } $removeContainer
            Stop-KeepAlive $name $context.DistroName
            Stop-WithError "Copying the project failed; the container was removed."
        }
    } finally {
        if ($listFile) { Remove-Item -LiteralPath $listFile -ErrorAction SilentlyContinue }
    }

    # Your Git identity, for commits made in the container, whether or not the
    # project is a repository yet. Read in the project, so a repository's own
    # user.name/user.email wins over your global ones.
    if ($gitPath) {
        $gitName = (Invoke-Git $gitPath $Project.Path 'config', 'user.name').Output
        $gitEmail = (Invoke-Git $gitPath $Project.Path 'config', 'user.email').Output
        if ($gitName -or $gitEmail) {
            $null = Invoke-Wsl $Context -Variables @{ name = $name; git_name = $gitName; git_email = $gitEmail } @'
[ -z "$git_name" ] || $E exec -u dev "$name" git config --global user.name "$git_name"
[ -z "$git_email" ] || $E exec -u dev "$name" git config --global user.email "$git_email"
'@
            if ($LASTEXITCODE -ne 0) { Write-Warning "Couldn't set your Git identity in the container." }
        }
    }

    Assert-SshAnswers $Context $name $Port
    Set-GitHubAuth $Context $name
    Write-ConnectionInfo $Context $Project $Port $privateKeyPath $hostNetwork
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
Runs a project in a container that IntelliJ (or another IDE) connects to over SSH.

.DESCRIPTION
Run it from a project on Windows. Through WSL it builds a small local image (the
official Maven image for the project's JDK, plus an SSH server), starts a
container from it and copies the project into a volume that belongs to that
container. IntelliJ (File > Remote Development > SSH, or JetBrains Gateway) then
connects to it as "dev" and runs the IDE backend inside.

The container engine is whatever the WSL distro has: Docker (Docker Desktop with
WSL integration, or Docker Engine installed in the distro) or Podman. -Engine
podman without -Distro uses Podman for Windows instead, when it's installed.

First come pre-flight checks: the distro runs on WSL 2, its container engine
works, and it can reach the internet (it asks https://www.google.com). Without
the internet a new container can't be built, so creating one stops there; an
existing one is started with a warning.

Files are copied only when the container is created. Running it again for the
same project starts the existing container and prints how to connect.
Stop-DevContainer stops it, Remove-DevContainer deletes it with its copy of the
project, and Reset-DevContainer creates it again from a fresh copy.

What gets copied:
  - A Git repository: .git and the untracked, not ignored, files. The container
    checks the tracked files out itself, so they get Linux line endings rather
    than the CRLF of a Windows checkout, then reapplies your uncommitted
    changes, staged and unstaged. Ignored files (target/, build/, ...) stay
    behind.
  - Anything else: the whole folder except target, build, out and .gradle.

The container also gets your Git identity, and your GitHub login if the gh CLI
on Windows is logged in.

.PARAMETER Path
The project folder. Defaults to the current directory.

.PARAMETER JavaVersion
The JDK's major version, e.g. 21. By default it is read from .java-version,
.sdkmanrc, .tool-versions, pom.xml or build.gradle(.kts), falling back to 17.

.PARAMETER Port
The port on 127.0.0.1 that SSH is on. Defaults to the first free one from 2222,
with a warning saying what holds the ports skipped.

.PARAMETER PublicKey
The SSH public key to log in with. Defaults to the first of id_ed25519.pub,
id_ecdsa.pub and id_rsa.pub in ~\.ssh; if there are none, ~\.ssh\id_ed25519 is
created, without a passphrase.

.PARAMETER Distro
The WSL distro to use. Defaults to WSL's default distro.

.PARAMETER Engine
docker or podman. By default the distro's docker is used if it works, otherwise
its podman.

-Engine podman without -Distro uses Podman for Windows (podman.exe) when it's
installed: the container runs in its WSL machine, which is created
(podman machine init) if there isn't one yet, and started if it's stopped. With
-Distro, or without podman.exe, it uses Podman installed inside the distro.

Pass the same -Distro and -Engine to the other commands, or pipe
Get-DevContainer into them.

.EXAMPLE
PS C:\src\my-app> Start-DevContainer

.EXAMPLE
PS> Start-DevContainer -Path C:\src\my-app -JavaVersion 21 -Distro Ubuntu

.EXAMPLE
PS C:\src\my-app> Start-DevContainer -Engine podman

Runs it in Podman for Windows' machine, creating the machine first if needed.
#>
function Start-DevContainer {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string]$Path = '.',
        [ValidateRange(8, 99)][int]$JavaVersion,
        [ValidateRange(1, 65535)][int]$Port,
        [string]$PublicKey,
        [Parameter(ValueFromPipelineByPropertyName = $true)][string]$Distro,
        [Parameter(ValueFromPipelineByPropertyName = $true)][ValidateSet('docker', 'podman')][string]$Engine
    )
    process {
        try {
            Invoke-WithUtf8 {
                $ErrorActionPreference = 'Stop'
                $project = Get-Project $Path $PSCmdlet
                $context = Resolve-DevContainerHost -Distro $Distro -Engine $Engine
                $state = Get-ContainerState $context $project.ContainerName
                Assert-Internet $context -WarnOnly:([bool]$state)
                Write-Host ''
                if ($state) {
                    $running = Start-ExistingContainer $context $project $state
                    Write-Host "Using the existing container; files weren't copied again (Reset-DevContainer starts over)."
                    Set-GitHubAuth $context $project.ContainerName
                    Write-ConnectionInfo $context $project $running.Port $null $running.HostNetwork
                    return
                }
                New-ProjectContainer -Context $context -Project $project -JavaVersion $JavaVersion -Port $Port -PublicKey $PublicKey
            }
        } catch {
            $PSCmdlet.WriteError($_)
        }
    }
}

<#
.SYNOPSIS
Stops a project's dev container.

.DESCRIPTION
Stops the container Start-DevContainer made for the project, and the hidden
wsl.exe that kept its distro running. Its copy of the project stays;
Start-DevContainer starts it again.

.PARAMETER Path
The project folder. Defaults to the current directory. The folder doesn't have
to exist any more.

.PARAMETER Distro
The WSL distro, as given to Start-DevContainer.

.PARAMETER Engine
docker or podman, as given to Start-DevContainer.

.EXAMPLE
PS C:\src\my-app> Stop-DevContainer

.EXAMPLE
PS> Get-DevContainer | Stop-DevContainer

Stops every dev container, whichever engine it's in.
#>
function Stop-DevContainer {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string]$Path = '.',
        [Parameter(ValueFromPipelineByPropertyName = $true)][string]$Distro,
        [Parameter(ValueFromPipelineByPropertyName = $true)][ValidateSet('docker', 'podman')][string]$Engine
    )
    process {
        try {
            Invoke-WithUtf8 {
                $ErrorActionPreference = 'Stop'
                $project = Get-Project $Path $PSCmdlet -MayBeMissing
                $name = $project.ContainerName
                # Starting the Podman machine just to stop the container would be silly.
                $context = Resolve-DevContainerHost -Distro $Distro -Engine $Engine -Quiet -Machine Running
                if (-not $context) {
                    Write-Host "The Podman machine isn't running, so neither is a container for $($project.Path)."
                    return
                }
                $state = Get-ContainerState $context $name
                if (-not $state) {
                    Stop-KeepAlive $name $context.DistroName
                    Write-Host "There's no container for $($project.Path)."
                    return
                }
                if (-not $PSCmdlet.ShouldProcess($name, 'Stop')) { return }
                Stop-KeepAlive $name $context.DistroName
                if ($state -eq 'true') {
                    $null = Invoke-Wsl $context -Variables @{ name = $name } '$E stop "$name"'
                    if ($LASTEXITCODE -ne 0) { Stop-WithError "Couldn't stop $name." }
                }
                Write-Host "Stopped $name."
            }
        } catch {
            $PSCmdlet.WriteError($_)
        }
    }
}

<#
.SYNOPSIS
Deletes a project's dev container and its copy of the project.

.DESCRIPTION
Deletes the container Start-DevContainer made for the project and its volume,
including any work in it that hasn't been pushed or copied out. It asks first;
-Confirm:$false doesn't. Clear-DevContainer deletes them all.

.PARAMETER Path
The project folder. Defaults to the current directory. The folder doesn't have
to exist any more.

.PARAMETER Distro
The WSL distro, as given to Start-DevContainer.

.PARAMETER Engine
docker or podman, as given to Start-DevContainer.

.EXAMPLE
PS C:\src\my-app> Remove-DevContainer

.EXAMPLE
PS> Get-DevContainer | Where-Object State -ne running | Remove-DevContainer
#>
function Remove-DevContainer {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string]$Path = '.',
        [Parameter(ValueFromPipelineByPropertyName = $true)][string]$Distro,
        [Parameter(ValueFromPipelineByPropertyName = $true)][ValidateSet('docker', 'podman')][string]$Engine
    )
    process {
        try {
            Invoke-WithUtf8 {
                $ErrorActionPreference = 'Stop'
                $project = Get-Project $Path $PSCmdlet -MayBeMissing
                $name = $project.ContainerName
                $context = Resolve-DevContainerHost -Distro $Distro -Engine $Engine -Quiet -Machine Start
                if (-not $context) { Write-Host "There's no Podman machine, so no container for $($project.Path)."; return }
                $state = Get-ContainerState $context $name
                if (-not $state -and -not (Test-VolumeExists $context $name)) {
                    Write-Host "There's no container for $($project.Path)."
                    return
                }
                if (-not $PSCmdlet.ShouldProcess("$name and its copy of the project, with any work in it that isn't pushed", 'Delete')) { return }
                $null = Remove-ProjectContainer $context $project $state
                Stop-KeepAlive $name $context.DistroName
                Write-Host "Deleted $name."
            }
        } catch {
            $PSCmdlet.WriteError($_)
        }
    }
}

<#
.SYNOPSIS
Deletes every dev container, whatever its project.

.DESCRIPTION
Deletes all the containers Start-DevContainer made, and their volumes, with any
work in them that hasn't been pushed or copied out: in Docker and Podman in
WSL's default distro, and in Podman for Windows' machine (started if it's
stopped). It lists them and asks once first; -Confirm:$false doesn't ask.
-Distro and -Engine limit it to one place. The images stay.

Clean-DevContainer is an alias of it.

.PARAMETER Distro
Only the containers in this WSL distro.

.PARAMETER Engine
Only the containers of this engine (podman without -Distro: Podman for
Windows' machine).

.EXAMPLE
PS> Clean-DevContainer

.EXAMPLE
PS> Clear-DevContainer -Engine podman -WhatIf

Shows which of Podman for Windows' containers would be deleted.
#>
function Clear-DevContainer {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [string]$Distro,
        [ValidateSet('docker', 'podman')][string]$Engine
    )
    try {
        Invoke-WithUtf8 {
            $ErrorActionPreference = 'Stop'
            $found = @(Find-DevContainers $Distro $Engine 'Start')
            if (-not $found) { Write-Host 'There are no dev containers.'; return }
            $list = ($found | ForEach-Object { "  $($_.Container.Path)  ($($_.Container.Engine), $($_.Container.Host), $($_.Container.State))" }) -join "`n"
            $what = if ($found.Count -eq 1) { "the only dev container, with its copy of the project and any work in it that isn't pushed" }
                else { "all $($found.Count) dev containers, with their copies of the projects and any work in them that isn't pushed" }
            if (-not $PSCmdlet.ShouldProcess("${what}:`n$list`n", 'Delete')) { return }
            foreach ($item in $found) {
                $container = $item.Container
                $null = Remove-ProjectContainer $item.Context ([pscustomobject]@{ ContainerName = $container.Name }) $container.State
                Stop-KeepAlive $container.Name $item.Context.DistroName
                Write-Host "Deleted $($container.Name) ($($container.Path), $($container.Host))."
            }
        }
    } catch {
        $PSCmdlet.WriteError($_)
    }
}

<#
.SYNOPSIS
Creates a project's dev container again, from a fresh copy of the project.

.DESCRIPTION
Deletes the project's container and its volume (asking first, since work in it
that hasn't been pushed is lost), then creates it again as Start-DevContainer
does, on the newest base image. It keeps its port, so saved connections still
work. With no container yet, it just creates one.

.PARAMETER Path
The project folder. Defaults to the current directory.

.PARAMETER JavaVersion
See Start-DevContainer.

.PARAMETER Port
The port for the new container. Defaults to the old container's.

.PARAMETER PublicKey
See Start-DevContainer.

.PARAMETER Distro
The WSL distro, as given to Start-DevContainer.

.PARAMETER Engine
docker or podman, as given to Start-DevContainer.

.EXAMPLE
PS C:\src\my-app> Reset-DevContainer
#>
function Reset-DevContainer {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string]$Path = '.',
        [ValidateRange(8, 99)][int]$JavaVersion,
        [ValidateRange(1, 65535)][int]$Port,
        [string]$PublicKey,
        [Parameter(ValueFromPipelineByPropertyName = $true)][string]$Distro,
        [Parameter(ValueFromPipelineByPropertyName = $true)][ValidateSet('docker', 'podman')][string]$Engine
    )
    process {
        try {
            Invoke-WithUtf8 {
                $ErrorActionPreference = 'Stop'
                $project = Get-Project $Path $PSCmdlet
                $name = $project.ContainerName
                $context = Resolve-DevContainerHost -Distro $Distro -Engine $Engine
                # Checked before deleting anything: the new container can't be
                # built without it.
                Assert-Internet $context
                Write-Host ''
                $newPort = $Port
                $state = Get-ContainerState $context $name
                if ($state -or (Test-VolumeExists $context $name)) {
                    if (-not $PSCmdlet.ShouldProcess("$name and its copy of the project, with any work in it that isn't pushed", 'Delete, then create again from a fresh copy of the project')) { return }
                    $oldPort = Remove-ProjectContainer $context $project $state
                    Write-Host "Deleted $name; creating it again."
                    # Same port as before, so saved connections keep working.
                    if (-not $newPort -and $oldPort) { $newPort = $oldPort }
                }
                New-ProjectContainer -Context $context -Project $project -JavaVersion $JavaVersion -Port $newPort -PublicKey $PublicKey -Pull
            }
        } catch {
            $PSCmdlet.WriteError($_)
        }
    }
}

<#
.SYNOPSIS
Lists dev containers.

.DESCRIPTION
Lists the containers Start-DevContainer made, with their project, state, SSH
port, engine and where they run. Without -Distro or -Engine it looks at Docker
and Podman in WSL's default distro, and at Podman for Windows' machine if it's
running. Its objects can be piped into Stop-, Remove-, Reset-, Start- and
Enter-DevContainer, which then use the right engine.

.PARAMETER Path
Only the container of this project.

.PARAMETER Distro
Only look in this WSL distro.

.PARAMETER Engine
Only look at this engine (podman without -Distro: Podman for Windows' machine).

.EXAMPLE
PS> Get-DevContainer

.EXAMPLE
PS> Get-DevContainer | Stop-DevContainer
#>
function Get-DevContainer {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Path,
        [string]$Distro,
        [ValidateSet('docker', 'podman')][string]$Engine
    )
    try {
        Invoke-WithUtf8 {
            $ErrorActionPreference = 'Stop'
            $wantedName = if ($Path) { (Get-Project $Path $PSCmdlet -MayBeMissing).ContainerName }
            foreach ($found in @(Find-DevContainers $Distro $Engine 'Running')) {
                if (-not $wantedName -or $found.Container.Name -eq $wantedName) { $found.Container }
            }
        }
    } catch {
        $PSCmdlet.WriteError($_)
    }
}

<#
.SYNOPSIS
Opens a shell in a project's dev container, over SSH.

.DESCRIPTION
Starts the project's container if it's stopped, then runs
ssh -p <port> dev@127.0.0.1 in this window. Interactive logins start in the
project's folder.

.PARAMETER Path
The project folder. Defaults to the current directory.

.PARAMETER Distro
The WSL distro, as given to Start-DevContainer.

.PARAMETER Engine
docker or podman, as given to Start-DevContainer.

.EXAMPLE
PS C:\src\my-app> Enter-DevContainer
#>
function Enter-DevContainer {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipelineByPropertyName = $true)][string]$Path = '.',
        [Parameter(ValueFromPipelineByPropertyName = $true)][string]$Distro,
        [Parameter(ValueFromPipelineByPropertyName = $true)][ValidateSet('docker', 'podman')][string]$Engine
    )
    # (No process block: one shell, for the last object piped in.)
    try {
        $hostPort = Invoke-WithUtf8 {
            $ErrorActionPreference = 'Stop'
            $ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
            if (-not $ssh) { Stop-WithError "ssh isn't available. Install the OpenSSH client (Settings > System > Optional features > OpenSSH Client)." }
            $project = Get-Project $Path $PSCmdlet -MayBeMissing
            $context = Resolve-DevContainerHost -Distro $Distro -Engine $Engine -Quiet -Machine Start
            $state = if ($context) { Get-ContainerState $context $project.ContainerName }
            if (-not $state) {
                $options = if ($context) { Get-CommandOptions $context $project } else { '' }
                Stop-WithError "There's no container for $($project.Path). Start-DevContainer$options creates it."
            }
            (Start-ExistingContainer $context $project $state).Port
        }
    } catch {
        $PSCmdlet.WriteError($_)
        return
    }
    # Outside Invoke-WithUtf8: the shell gets the console as it was.
    & ssh.exe -p $hostPort -o StrictHostKeyChecking=accept-new dev@127.0.0.1
}

<#
.SYNOPSIS
Checks that a dev container can run: WSL 2, a container engine, the internet.

.DESCRIPTION
Runs only Start-DevContainer's pre-flight checks, printing each, and returns
$true if they all pass. Failures say what to do about them. With -Engine podman
and Podman for Windows, the machine is started if it's stopped, but not
created.

.PARAMETER Distro
The WSL distro to check. Defaults to WSL's default distro.

.PARAMETER Engine
docker or podman. See Start-DevContainer.

.EXAMPLE
PS> Test-DevContainerHost -Engine podman
#>
function Test-DevContainerHost {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$Distro,
        [ValidateSet('docker', 'podman')][string]$Engine
    )
    try {
        Invoke-WithUtf8 {
            $ErrorActionPreference = 'Stop'
            $context = Resolve-DevContainerHost -Distro $Distro -Engine $Engine -Machine Start
            if (-not $context) {
                Write-Host '  --  Podman:    no machine yet; Start-DevContainer -Engine podman creates one.'
                return $true
            }
            Assert-Internet $context
            $true
        }
    } catch {
        Write-Host ''
        Write-Host $_.Exception.Message -ForegroundColor Red
        $false
    }
}

# "Clean" isn't an approved verb, so it can't name a command, but an alias is fine.
Set-Alias -Name Clean-DevContainer -Value Clear-DevContainer

Export-ModuleMember -Function Start-DevContainer, Stop-DevContainer, Remove-DevContainer, Clear-DevContainer, Reset-DevContainer, Get-DevContainer, Enter-DevContainer, Test-DevContainerHost `
    -Alias Clean-DevContainer
