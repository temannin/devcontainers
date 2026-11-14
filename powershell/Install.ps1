<#
.SYNOPSIS
Installs the DevContainers module for the current user.

.DESCRIPTION
Copies the DevContainers folder next to this script into the user Modules folder
of PowerShell 7 and of Windows PowerShell (whichever are installed), replacing
any copy already there. PowerShell then loads the module by itself the first
time one of its commands is used: Start-DevContainer, Stop-DevContainer,
Remove-DevContainer, Clear-DevContainer (alias Clean-DevContainer),
Reset-DevContainer, Get-DevContainer, Enter-DevContainer and
Test-DevContainerHost. Run it again after pulling to update.

.EXAMPLE
PS> .\powershell\Install.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'DevContainers'
$manifest = Test-ModuleManifest -Path (Join-Path $source 'DevContainers.psd1')
$documents = [Environment]::GetFolderPath('MyDocuments')
$editions = @(
    @{ Name = 'PowerShell 7'; Exe = 'pwsh.exe'; Folder = 'PowerShell' },
    @{ Name = 'Windows PowerShell'; Exe = 'powershell.exe'; Folder = 'WindowsPowerShell' }
)

# The execution policy a new session of that edition gets. Restricted (Windows
# PowerShell's default) keeps it from loading modules; AllSigned only loads
# signed ones, and this one isn't.
function Get-SessionExecutionPolicy([string]$Exe) {
    $override = $env:PSExecutionPolicyPreference
    try {
        Remove-Item Env:\PSExecutionPolicyPreference -ErrorAction SilentlyContinue
        "$(& $Exe -NoLogo -NoProfile -NonInteractive -Command 'Get-ExecutionPolicy')".Trim()
    } finally {
        if ($override) { $env:PSExecutionPolicyPreference = $override }
    }
}

foreach ($edition in $editions) {
    if (-not (Get-Command $edition.Exe -ErrorAction SilentlyContinue)) { continue }
    $target = Join-Path $documents "$($edition.Folder)\Modules\DevContainers"
    # Replaced as a whole, so files the new version dropped don't linger.
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $target)
    Copy-Item -LiteralPath $source -Destination $target -Recurse
    # A downloaded copy keeps its "from the internet" mark, and RemoteSigned
    # refuses to load it.
    Get-ChildItem -LiteralPath $target -Recurse -File | Unblock-File
    Write-Host "Installed DevContainers $($manifest.Version) for $($edition.Name): $target"

    $policy = Get-SessionExecutionPolicy $edition.Exe
    if ($policy -in 'Restricted', 'AllSigned') {
        Write-Warning ("$($edition.Name)'s execution policy is $policy, so it won't load the module. To allow local scripts and modules:`n" +
            "  $($edition.Exe) -Command Set-ExecutionPolicy -Scope CurrentUser RemoteSigned")
    }
}

# This session may have an older version loaded; the next command loads the new one.
Remove-Module DevContainers -ErrorAction SilentlyContinue
Write-Host ''
Write-Host 'Done. In a project folder: Start-DevContainer (Get-Help Start-DevContainer -Full for the options).'
