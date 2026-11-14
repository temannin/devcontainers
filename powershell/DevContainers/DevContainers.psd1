@{
    RootModule           = 'DevContainers.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '3d339142-7064-4382-b136-f58cc8cf3841'
    Author               = 'Tyler Manning'
    Description          = 'Runs projects in containers that IDEs (IntelliJ, JetBrains Gateway) connect to over SSH, from Windows through WSL, with Docker or Podman.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @(
        'Start-DevContainer'
        'Stop-DevContainer'
        'Remove-DevContainer'
        'Clear-DevContainer'
        'Reset-DevContainer'
        'Get-DevContainer'
        'Enter-DevContainer'
        'Test-DevContainerHost'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @('Clean-DevContainer')
}
