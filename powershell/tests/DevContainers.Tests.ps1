#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# Tests for the DevContainers module. WSL, the container engines, Podman for
# Windows and the network are all mocked: nothing here starts, stops or
# deletes a real container.
#
#   Invoke-Pester .\powershell\tests -Output Detailed

BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '..\DevContainers\DevContainers.psd1') -Force
    # Pester can only mock commands that exist, and a CI runner may not have
    # these.
    foreach ($command in 'wsl.exe', 'ssh.exe') {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            New-Item -Path "Function:\global:$command" -Value { } -Force | Out-Null
        }
    }
}

InModuleScope DevContainers {

Describe 'DevContainers' {
    BeforeAll {
        # A host object like Resolve-DevContainerHost's: Docker Engine in
        # Ubuntu, or (-Machine) Podman for Windows' machine.
        function global:New-TestContext([switch]$Machine, [switch]$DockerDesktop) {
            [pscustomobject]@{
                Quiet          = $true
                DistroOption   = $null
                EngineOption   = $null
                Distro         = if ($Machine) { 'podman-machine-default' } else { $null }
                User           = $null
                DistroName     = if ($Machine) { 'podman-machine-default' } else { 'Ubuntu' }
                Engine         = if ($Machine) { 'podman' } else { 'docker' }
                Kind           = 'test'
                NeedsKeepAlive = -not $DockerDesktop
                PodmanExe      = if ($Machine) { 'C:\podman\podman.exe' } else { $null }
                PodmanMachine  = if ($Machine) { [pscustomobject]@{ Name = 'podman-machine-default'; Distro = 'podman-machine-default'; Rootful = $false } } else { $null }
            }
        }
        # A container as Get-DevContainer lists it, with the host it's in.
        function global:New-TestFound([string]$Path, [string]$Name, [switch]$Machine) {
            $context = New-TestContext -Machine:$Machine
            [pscustomobject]@{
                Context   = $context
                Container = [pscustomobject]@{
                    PSTypeName = 'DevContainers.DevContainer'
                    Path = $Path; Name = $Name; State = 'running'; Port = 2222
                    Engine = $context.Engine; Host = $context.DistroName
                    Distro = if ($Machine) { '' } else { 'Ubuntu' }; Image = 'intellij-dev:jdk17'
                }
            }
        }
        Mock Write-Host { }
    }

    AfterAll {
        Remove-Item Function:\New-TestContext, Function:\New-TestFound -ErrorAction SilentlyContinue
    }

    Context 'The module' {
        It 'has a valid manifest' {
            { Test-ModuleManifest (Join-Path (Get-Module DevContainers).ModuleBase 'DevContainers.psd1') } | Should -Not -Throw
        }

        It 'exports exactly its commands' {
            (Get-Module DevContainers).ExportedFunctions.Keys | Sort-Object | Should -Be @(
                'Clear-DevContainer', 'Enter-DevContainer', 'Get-DevContainer', 'Remove-DevContainer',
                'Reset-DevContainer', 'Start-DevContainer', 'Stop-DevContainer', 'Test-DevContainerHost')
        }

        It 'names every command with an approved verb' {
            $approved = (Get-Verb).Verb
            foreach ($name in (Get-Module DevContainers).ExportedFunctions.Keys) {
                $approved | Should -Contain ($name -split '-')[0] -Because $name
            }
        }

        It 'gives every command help' {
            foreach ($name in (Get-Module DevContainers).ExportedFunctions.Keys) {
                $help = Get-Help $name
                $help.Synopsis | Should -Not -BeNullOrEmpty -Because $name
                $help.Synopsis | Should -Not -BeLike "$name *" -Because "$name's synopsis should be written, not generated"
            }
        }

        It 'makes Clean-DevContainer an alias of Clear-DevContainer' {
            (Get-Module DevContainers).ExportedAliases.Keys | Should -Be @('Clean-DevContainer')
            (Get-Alias Clean-DevContainer).Definition | Should -Be 'Clear-DevContainer'
        }

        It 'keeps the image files with LF line endings' {
            foreach ($file in 'Containerfile', 'sshd.conf', 'entrypoint.sh', 'project.sh') {
                $text = [IO.File]::ReadAllText((Join-Path $ImageDir $file))
                $text | Should -Not -Match "`r" -Because "$file is copied into a Linux image"
            }
        }

        It 'has no file named Dockerfile, which the image workflow would build and push' {
            Get-ChildItem (Get-Module DevContainers).ModuleBase -Recurse -Filter Dockerfile | Should -BeNullOrEmpty
        }
    }

    Context 'ConvertTo-ShellLiteral' {
        It 'quotes a plain value' {
            ConvertTo-ShellLiteral 'abc def' | Should -Be "'abc def'"
        }

        It 'escapes single quotes' {
            ConvertTo-ShellLiteral "it's" | Should -Be "'it'\''s'"
        }
    }

    Context 'Invoke-Wsl' {
        BeforeAll {
            # The bash script that wsl.exe was handed, decoded.
            function global:Get-SentScript {
                # (-match, not Should -Match: only -match fills in $Matches.)
                if ($global:DevContainersWslArgs[-1] -notmatch 'echo (\S+) \| base64 -d') { throw "No script in: $($global:DevContainersWslArgs[-1])" }
                [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1]))
            }
            Mock wsl.exe { $global:DevContainersWslArgs = $args }
        }

        AfterAll {
            Remove-Item Function:\Get-SentScript -ErrorAction SilentlyContinue
            Remove-Variable DevContainersWslArgs -Scope Global -ErrorAction SilentlyContinue
        }

        It 'sends the engine and the variables as shell literals, with LF line endings' {
            $null = Invoke-Wsl (New-TestContext) -Variables @{ name = "it's" } "echo `"`$name`"`r`necho done"
            $script = Get-SentScript
            $script | Should -Match '(?m)^set -eo pipefail$'
            $script | Should -Match "(?m)^E='docker'$"
            $script | Should -Match "(?m)^name='it'\\''s'$"
            $script | Should -Not -Match "`r"
        }

        It 'runs in WSL''s default distro unless one is set' {
            $null = Invoke-Wsl (New-TestContext) 'true'
            $global:DevContainersWslArgs | Should -Not -Contain '-d'
        }

        It 'runs in the Podman machine''s distro, as root when it''s rootful' {
            $context = New-TestContext -Machine
            $context.User = 'root'
            $null = Invoke-Wsl $context 'true'
            $global:DevContainersWslArgs[0..3] | Should -Be @('-d', 'podman-machine-default', '-u', 'root')
        }

        It 'points rootless podman at its API service''s runtime directory in a Podman machine' {
            $null = Invoke-Wsl (New-TestContext -Machine) 'true'
            Get-SentScript | Should -Match 'XDG_RUNTIME_DIR="/run/user/\$\(id -u\)"'
            $null = Invoke-Wsl (New-TestContext) 'true'
            Get-SentScript | Should -Not -Match 'XDG_RUNTIME_DIR'
        }
    }

    Context 'Get-JavaVersion' {
        BeforeEach {
            $project = Join-Path $TestDrive ([guid]::NewGuid())
            $null = New-Item -ItemType Directory -Path $project
        }

        It 'reads <File>' -ForEach @(
            @{ File = '.java-version'; Content = 'temurin-21.0.2'; Version = 21 }
            @{ File = '.sdkmanrc'; Content = "java=17.0.9-tem`n"; Version = 17 }
            @{ File = '.tool-versions'; Content = "java temurin-21.0.1+12`n"; Version = 21 }
            @{ File = 'pom.xml'; Content = '<properties><maven.compiler.release>21</maven.compiler.release></properties>'; Version = 21 }
            @{ File = 'pom.xml'; Content = '<properties><java.version>17</java.version></properties>'; Version = 17 }
            @{ File = 'build.gradle.kts'; Content = 'kotlin { jvmToolchain(21) }'; Version = 21 }
            @{ File = 'build.gradle'; Content = "sourceCompatibility = '1.8'"; Version = 8 }
            @{ File = 'build.gradle'; Content = 'java { sourceCompatibility = JavaVersion.VERSION_1_8 }'; Version = 8 }
        ) {
            Set-Content -Path (Join-Path $project $File) -Value $Content
            $java = Get-JavaVersion $project
            $java.Version | Should -Be $Version
            $java.Source | Should -Be $File
        }

        It 'prefers .java-version over pom.xml' {
            Set-Content (Join-Path $project '.java-version') '21'
            Set-Content (Join-Path $project 'pom.xml') '<java.version>17</java.version>'
            (Get-JavaVersion $project).Version | Should -Be 21
        }

        It 'falls back to 17' {
            $java = Get-JavaVersion $project
            $java.Version | Should -Be 17
            $java.Source | Should -Be 'default'
        }
    }

    Context 'Get-Project' {
        BeforeAll { $paths = $ExecutionContext.SessionState.Path }

        It 'keeps container names stable, so existing containers are still found' {
            # Changing how names are made would lose every container made before.
            (Get-Project 'C:\src\my-app' $paths -MayBeMissing).ContainerName | Should -Be 'intellij-my-app-13efc5'
            (Get-Project 'D:\work\my-app' $paths -MayBeMissing).ContainerName | Should -Be 'intellij-my-app-d46b83'
        }

        It 'ignores the case and a trailing backslash of the path' {
            (Get-Project 'C:\SRC\My-App\' $paths -MayBeMissing).ContainerName | Should -Be 'intellij-my-app-13efc5'
        }

        It 'makes a slug and a directory from an awkward folder name' {
            $project = Get-Project 'C:\src\My App!' $paths -MayBeMissing
            $project.Slug | Should -Be 'my-app'
            $project.ContainerName | Should -Be 'intellij-my-app-dd6737'
            $project.Directory | Should -Be '/workspace/My-App-'
        }

        It 'shortens a long slug to 40 characters' {
            (Get-Project ('C:\src\' + ('a' * 60)) $paths -MayBeMissing).Slug.Length | Should -Be 40
        }

        It 'refuses a missing folder unless -MayBeMissing' {
            $missing = Join-Path $TestDrive 'nope'
            { Get-Project $missing $paths } | Should -Throw '*Project folder not found*'
            (Get-Project $missing $paths -MayBeMissing).Path | Should -Be $missing
        }
    }

    Context 'Test-Internet' {
        It 'returns nothing when the distro answers' {
            Mock Invoke-Wsl { 'curl 0 ' }
            Test-Internet (New-TestContext) | Should -BeNullOrEmpty
        }

        It 'explains curl exit code <Code>' -ForEach @(
            @{ Code = 6; Detail = 'curl: (6) Could not resolve host: www.google.com'; Hint = '*look up names (DNS)*' }
            @{ Code = 28; Detail = 'curl: (28) Connection timed out'; Hint = '*Nothing answered*' }
            @{ Code = 60; Detail = 'curl: (60) SSL certificate problem'; Hint = '*intercepted*update-ca-certificates*' }
        ) {
            Mock Invoke-Wsl { "curl $Code $Detail" }
            $problem = Test-Internet (New-TestContext)
            $problem | Should -BeLike "Ubuntu can't reach https://www.google.com (curl exit code ${Code}: $Detail)*"
            $problem | Should -BeLike $Hint
        }

        It 'suggests recreating the Podman machine with --import-native-ca when HTTPS is intercepted there' {
            Mock Invoke-Wsl { 'curl 60 curl: (60) SSL certificate problem' }
            Test-Internet (New-TestContext -Machine) | Should -BeLike '*--import-native-ca*podman machine rm podman-machine-default*'
        }

        It 'explains the wget and bare TCP fallbacks' {
            Mock Invoke-Wsl { 'wget 4 ' }
            Test-Internet (New-TestContext) | Should -BeLike '*wget exit code 4)*Nothing answered*DNS*'
            Mock Invoke-Wsl { 'tcp 1 bash: no-such-host: Name or service not known' }
            Test-Internet (New-TestContext) | Should -BeLike '*tcp exit code 1*'
        }

        It 'says so when the check itself couldn''t run' {
            Mock Invoke-Wsl { }
            Test-Internet (New-TestContext) | Should -Be "Couldn't run the check in Ubuntu."
        }
    }

    Context 'Resolve-DevContainerHost' {
        BeforeAll {
            Mock Get-Command -ParameterFilter { $Name -contains 'wsl.exe' } { [pscustomobject]@{ Name = 'wsl.exe'; Source = 'C:\Windows\System32\wsl.exe' } }
            Mock Find-PodmanExe { $null }
        }

        BeforeEach {
            Mock Invoke-Wsl -ParameterFilter { $Script -like '*WSL_DISTRO_NAME*' } { $global:LASTEXITCODE = 0; 'Ubuntu'; '6.6.87.2-microsoft-standard-WSL2'; '' }
            Mock Invoke-Wsl -ParameterFilter { $Script -like '*for e in $candidates*' } { $global:LASTEXITCODE = 0; 'ok docker Ubuntu 24.04.3 LTS' }
        }

        It 'finds Docker Engine in the distro' {
            $context = Resolve-DevContainerHost -Quiet
            $context.DistroName | Should -Be 'Ubuntu'
            $context.Engine | Should -Be 'docker'
            $context.NeedsKeepAlive | Should -BeTrue
            $context.Kind | Should -Be 'Docker Engine in Ubuntu'
        }

        It 'needs no keepalive with Docker Desktop' {
            Mock Invoke-Wsl -ParameterFilter { $Script -like '*for e in $candidates*' } { $global:LASTEXITCODE = 0; 'ok docker Docker Desktop' }
            $context = Resolve-DevContainerHost -Quiet
            $context.NeedsKeepAlive | Should -BeFalse
            $context.Kind | Should -Be 'Docker Desktop'
        }

        It 'prints the checks unless -Quiet' {
            $null = Resolve-DevContainerHost
            Should -Invoke Write-Host -ParameterFilter { $Object -eq 'Pre-flight checks:' } -Times 1 -Exactly
            Should -Invoke Write-Host -ParameterFilter { $Object -eq 'WSL 2:     Ubuntu' } -Times 1 -Exactly
        }

        It 'stops without WSL' {
            Mock Get-Command -ParameterFilter { $Name -contains 'wsl.exe' } { $null }
            { Resolve-DevContainerHost -Quiet } | Should -Throw "*WSL isn't installed*wsl --install*"
        }

        It 'stops when the distro won''t run a command' {
            Mock Invoke-Wsl -ParameterFilter { $Script -like '*WSL_DISTRO_NAME*' } { $global:LASTEXITCODE = 1 }
            { Resolve-DevContainerHost -Distro Nope -Quiet } | Should -Throw "*Couldn't run a command in the WSL distro 'Nope'*"
        }

        It 'stops on WSL 1' {
            Mock Invoke-Wsl -ParameterFilter { $Script -like '*WSL_DISTRO_NAME*' } { $global:LASTEXITCODE = 0; 'Ubuntu'; '4.4.0-22621-Microsoft'; '' }
            { Resolve-DevContainerHost -Quiet } | Should -Throw '*runs on WSL 1*wsl --set-version Ubuntu 2*'
        }

        It 'stops when the distro has no tar' {
            Mock Invoke-Wsl -ParameterFilter { $Script -like '*WSL_DISTRO_NAME*' } { $global:LASTEXITCODE = 0; 'Ubuntu'; '6.6.87.2-microsoft-standard-WSL2'; 'tar' }
            { Resolve-DevContainerHost -Quiet } | Should -Throw '*has no tar*'
        }

        It 'says to join the docker group when Docker refuses the user' {
            Mock Invoke-Wsl -ParameterFilter { $Script -like '*for e in $candidates*' } { $global:LASTEXITCODE = 0; 'broken docker permission denied while trying to connect to the Docker daemon socket' }
            { Resolve-DevContainerHost -Quiet } | Should -Throw '*usermod -aG docker*'
        }

        It 'offers only Podman''s installs when Podman was asked for and isn''t there' {
            Mock Invoke-Wsl -ParameterFilter { $Script -like '*for e in $candidates*' } { $global:LASTEXITCODE = 0 }
            $message = try { Resolve-DevContainerHost -Engine podman -Quiet } catch { $_.Exception.Message }
            $message | Should -BeLike "Podman wasn't found in the WSL distro Ubuntu*winget install Podman.CLI*"
            $message | Should -Not -BeLike '*Docker Desktop*'
        }

        It 'uses Podman for Windows'' machine for -Engine podman without -Distro' {
            Mock Find-PodmanExe { 'C:\podman\podman.exe' }
            Mock Use-PodmanMachine { [pscustomobject]@{ Name = 'podman-machine-default'; Distro = 'podman-machine-default'; Rootful = $true } }
            Mock Invoke-Wsl -ParameterFilter { $Script -like '*WSL_DISTRO_NAME*' } { $global:LASTEXITCODE = 0; 'podman-machine-default'; '6.6.87.2-microsoft-standard-WSL2'; '' }
            Mock Invoke-Wsl -ParameterFilter { $Script -like '*for e in $candidates*' } { $global:LASTEXITCODE = 0; 'ok podman ' }
            $context = Resolve-DevContainerHost -Engine podman -Quiet
            $context.Distro | Should -Be 'podman-machine-default'
            $context.User | Should -Be 'root'
            $context.Engine | Should -Be 'podman'
            $context.Kind | Should -BeLike 'Podman for Windows*'
        }

        It 'uses the distro''s podman with -Distro, even with Podman for Windows installed' {
            Mock Find-PodmanExe { 'C:\podman\podman.exe' }
            Mock Use-PodmanMachine { throw 'should not be used' }
            Mock Invoke-Wsl -ParameterFilter { $Script -like '*for e in $candidates*' } { $global:LASTEXITCODE = 0; 'ok podman ' }
            (Resolve-DevContainerHost -Engine podman -Distro Ubuntu -Quiet).Kind | Should -Be 'Podman in Ubuntu'
        }

        It 'returns nothing when the Podman machine isn''t there to use' {
            Mock Find-PodmanExe { 'C:\podman\podman.exe' }
            Mock Use-PodmanMachine { $null }
            Resolve-DevContainerHost -Engine podman -Quiet -Machine Running | Should -BeNullOrEmpty
        }
    }

    Context 'Podman machines' {
        BeforeEach {
            $global:DevContainersTest = @{ Initialized = $false }
            Mock Invoke-Podman -ParameterFilter { $Arguments -contains '--help' } { 'Flags:'; '      --import-native-ca       Import the host trusted CA certificates into the machine' }
            Mock Invoke-Podman -ParameterFilter { $Live } { $global:LASTEXITCODE = 0; if ($Arguments -contains 'init') { $global:DevContainersTest.Initialized = $true } }
            Mock Invoke-Podman -ParameterFilter { $Arguments -contains 'inspect' } { 'false' }
            Mock Get-PodmanMachine {
                if ($global:DevContainersTest.Initialized) { [pscustomobject]@{ Name = 'podman-machine-default*'; Default = $true; Running = $true } }
            }
            Mock Write-Warning { }
        }

        AfterAll { Remove-Variable DevContainersTest -Scope Global -ErrorAction SilentlyContinue }

        It 'creates a missing machine with --import-native-ca' {
            $machine = Use-PodmanMachine 'C:\podman\podman.exe' 'Create'
            Should -Invoke Invoke-Podman -ParameterFilter { $Live -and ($Arguments -contains 'init') -and ($Arguments -contains '--import-native-ca') } -Times 1 -Exactly
            $machine.Name | Should -Be 'podman-machine-default'
            $machine.Distro | Should -Be 'podman-machine-default'
            $machine.Rootful | Should -BeFalse
        }

        It 'creates it without the flag, warning, when the Podman is too old for it' {
            Mock Invoke-Podman -ParameterFilter { $Arguments -contains '--help' } { 'Flags:'; '      --now   Start machine now' }
            $null = Use-PodmanMachine 'C:\podman\podman.exe' 'Create'
            Should -Invoke Invoke-Podman -ParameterFilter { $Live -and ($Arguments -contains 'init') -and -not ($Arguments -contains '--import-native-ca') } -Times 1 -Exactly
            Should -Invoke Write-Warning -ParameterFilter { $Message -like '*too old*--import-native-ca*' } -Times 1 -Exactly
        }

        It 'creates nothing with -Mode <Mode>' -ForEach @(@{ Mode = 'Start' }, @{ Mode = 'Running' }) {
            Use-PodmanMachine 'C:\podman\podman.exe' $Mode | Should -BeNullOrEmpty
            Should -Invoke Invoke-Podman -ParameterFilter { $Live } -Times 0
        }

        It 'starts a stopped machine, except with -Mode Running' {
            Mock Get-PodmanMachine { [pscustomobject]@{ Name = 'dev'; Default = $true; Running = $false } }
            Use-PodmanMachine 'C:\podman\podman.exe' 'Running' | Should -BeNullOrEmpty
            $machine = Use-PodmanMachine 'C:\podman\podman.exe' 'Start'
            Should -Invoke Invoke-Podman -ParameterFilter { $Live -and ($Arguments -join ' ') -eq 'machine start dev' } -Times 1 -Exactly
            # Podman's naming of a machine's WSL distro.
            $machine.Distro | Should -Be 'podman-dev'
        }
    }

    Context 'Get-PodmanMachine' {
        It 'picks the default machine, or else the first' {
            Mock Invoke-Podman { $global:LASTEXITCODE = 0; '[{"Name":"other","Default":false,"Running":false},{"Name":"podman-machine-default*","Default":true,"Running":true}]' }
            (Get-PodmanMachine 'C:\podman\podman.exe').Name | Should -Be 'podman-machine-default*'
            Mock Invoke-Podman { $global:LASTEXITCODE = 0; '[{"Name":"first","Default":false},{"Name":"second","Default":false}]' }
            (Get-PodmanMachine 'C:\podman\podman.exe').Name | Should -Be 'first'
        }

        It 'returns nothing when there are no machines' {
            Mock Invoke-Podman { $global:LASTEXITCODE = 0; '[]' }
            Get-PodmanMachine 'C:\podman\podman.exe' | Should -BeNullOrEmpty
        }
    }

    Context 'ConvertTo-DevContainer' {
        It 'reads a Docker container' {
            $data = '{"Name":"/intellij-my-app-13efc5","State":{"Status":"running"},"Config":{"Image":"intellij-dev:jdk21","Labels":{"intellij.project":"C:\\src\\my-app","intellij.port":"2223"}},"HostConfig":{"NetworkMode":"host","PortBindings":{}}}' | ConvertFrom-Json
            $container = ConvertTo-DevContainer (New-TestContext) $data
            $container.Path | Should -Be 'C:\src\my-app'
            $container.Name | Should -Be 'intellij-my-app-13efc5'
            $container.State | Should -Be 'running'
            $container.Port | Should -Be 2223
            $container.Engine | Should -Be 'docker'
            $container.Host | Should -Be 'Ubuntu'
            $container.Distro | Should -Be 'Ubuntu'
            $container.Image | Should -Be 'intellij-dev:jdk21'
            $container.PSObject.TypeNames | Should -Contain 'DevContainers.DevContainer'
        }

        It 'takes the published port when there''s no port label' {
            $data = '{"Name":"/x","State":{"Status":"exited"},"Config":{"Labels":{"intellij.project":"C:\\a"}},"HostConfig":{"PortBindings":{"22/tcp":[{"HostIp":"127.0.0.1","HostPort":"2230"}]}}}' | ConvertFrom-Json
            (ConvertTo-DevContainer (New-TestContext -DockerDesktop) $data).Port | Should -Be 2230
        }

        It 'leaves Distro empty for a Podman machine''s container, so piping picks the machine again' {
            $data = '{"Name":"intellij-a-111111","ImageName":"localhost/intellij-dev:jdk17","State":{"Status":"running"},"Config":{"Labels":{"intellij.project":"C:\\a","intellij.port":"2224"}},"HostConfig":{"PortBindings":{}}}' | ConvertFrom-Json
            $container = ConvertTo-DevContainer (New-TestContext -Machine) $data
            $container.Distro | Should -Be ''
            $container.Host | Should -Be 'Podman machine podman-machine-default'
            $container.Image | Should -Be 'localhost/intellij-dev:jdk17'
        }
    }

    Context 'Select-Port' {
        BeforeEach {
            Mock Get-WindowsListenerPort { }
            Mock Invoke-Wsl { }
            Mock Get-ContainerData { }
            Mock Write-Warning { }
        }

        It 'takes 2222 when it''s free, without a warning' {
            Select-Port (New-TestContext) | Should -Be 2222
            Should -Invoke Write-Warning -Times 0
        }

        It 'skips taken ports, saying what holds each' {
            Mock Get-WindowsListenerPort { 2222, 2223, 2224 }
            Mock Invoke-Wsl { '2223' }
            Mock Get-ContainerData { '{"Config":{"Labels":{"intellij.project":"C:\\src\\other","intellij.port":"2222"}},"HostConfig":{"PortBindings":{}}}' | ConvertFrom-Json }
            Select-Port (New-TestContext) | Should -Be 2225
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -like '*gets 2225*2222: the dev container for C:\src\other*2223: something in WSL*2224: a program on Windows*'
            }
        }

        It 'counts a stopped container''s published port as taken' {
            Mock Get-ContainerData { '{"Config":{"Labels":{"intellij.project":"C:\\a"}},"HostConfig":{"PortBindings":{"22/tcp":[{"HostPort":"2222"}]}}}' | ConvertFrom-Json }
            Select-Port (New-TestContext) | Should -Be 2223
        }
    }

    Context 'Keepalives' {
        BeforeAll {
            $name = 'intellij-a-111111'
            Mock Get-CimInstance {
                [pscustomobject]@{ ProcessId = 1; CommandLine = "`"wsl.exe`" -d Ubuntu -e sh -c `"exec sleep infinity`" intellij-keepalive-intellij-a-111111" }
                [pscustomobject]@{ ProcessId = 2; CommandLine = "`"wsl.exe`" -d podman-machine-default -e sh -c `"exec sleep infinity`" intellij-keepalive-intellij-a-111111" }
                [pscustomobject]@{ ProcessId = 3; CommandLine = "`"wsl.exe`" -d Ubuntu -e sh -c `"exec sleep infinity`" intellij-keepalive-intellij-b-222222" }
                [pscustomobject]@{ ProcessId = 4; CommandLine = $null }
            }
            Mock Stop-Process { }
            Mock Start-Process { }
        }

        It 'finds a container''s keepalive in its own distro only' {
            (Get-KeepAlive $name 'Ubuntu').ProcessId | Should -Be 1
            (Get-KeepAlive $name 'podman-machine-default').ProcessId | Should -Be 2
        }

        It 'stops only the keepalive of that container in that distro' {
            Stop-KeepAlive $name 'podman-machine-default'
            Should -Invoke Stop-Process -ParameterFilter { $Id -eq 2 } -Times 1 -Exactly
            Should -Invoke Stop-Process -Times 1 -Exactly
        }

        It 'starts none for Docker Desktop, or when one is running' {
            Start-KeepAlive (New-TestContext -DockerDesktop) 'intellij-new-333333'
            Start-KeepAlive (New-TestContext) $name
            Should -Invoke Start-Process -Times 0
        }

        It 'starts one in the container''s distro' {
            Start-KeepAlive (New-TestContext) 'intellij-new-333333'
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                "$ArgumentList" -like '-d Ubuntu *intellij-keepalive-intellij-new-333333'
            }
        }
    }

    Context 'Start-DevContainer' {
        BeforeAll {
            $project = Join-Path $TestDrive 'app'
            $null = New-Item -ItemType Directory -Force -Path $project
        }

        BeforeEach {
            Mock Resolve-DevContainerHost { New-TestContext }
            Mock Get-ContainerState { '' }
            Mock Test-Internet { $null }
            Mock Start-ExistingContainer { [pscustomobject]@{ Port = 2223; HostNetwork = $true } }
            Mock Set-GitHubAuth { }
            Mock Write-ConnectionInfo { }
            Mock New-ProjectContainer { }
            Mock Write-Warning { }
        }

        It 'reports a missing project folder as an error' {
            { Start-DevContainer (Join-Path $TestDrive 'nope') -ErrorAction Stop } | Should -Throw '*Project folder not found*'
            Should -Invoke Resolve-DevContainerHost -Times 0
        }

        It 'creates the container when there is none' {
            Start-DevContainer $project -JavaVersion 21 -Port 2300
            Should -Invoke New-ProjectContainer -Times 1 -Exactly -ParameterFilter { $JavaVersion -eq 21 -and $Port -eq 2300 -and -not $Pull }
        }

        It 'starts an existing container instead of copying the project again' {
            Mock Get-ContainerState { 'false' }
            Start-DevContainer $project
            Should -Invoke Start-ExistingContainer -Times 1 -Exactly
            Should -Invoke Write-ConnectionInfo -Times 1 -Exactly -ParameterFilter { $HostPort -eq 2223 }
            Should -Invoke New-ProjectContainer -Times 0
        }

        It 'won''t create a container without the internet' {
            Mock Test-Internet { "Ubuntu can't reach https://www.google.com" }
            { Start-DevContainer $project -ErrorAction Stop } | Should -Throw "*can't be built without the internet*"
            Should -Invoke New-ProjectContainer -Times 0
        }

        It 'starts an existing container without the internet, with a warning' {
            Mock Get-ContainerState { 'true' }
            Mock Test-Internet { "Ubuntu can't reach https://www.google.com" }
            Start-DevContainer $project
            Should -Invoke Write-Warning -Times 1 -Exactly
            Should -Invoke Start-ExistingContainer -Times 1 -Exactly
        }

        It 'passes -Distro and -Engine on' {
            Start-DevContainer $project -Distro Fedora -Engine podman
            Should -Invoke Resolve-DevContainerHost -ParameterFilter { $Distro -eq 'Fedora' -and $Engine -eq 'podman' } -Times 1 -Exactly
        }
    }

    Context 'Stop-DevContainer' {
        BeforeEach {
            Mock Resolve-DevContainerHost { New-TestContext }
            Mock Get-ContainerState { 'true' }
            Mock Invoke-Wsl { $global:LASTEXITCODE = 0 }
            Mock Stop-KeepAlive { }
        }

        It 'stops a running container and its keepalive' {
            Stop-DevContainer 'C:\src\my-app'
            Should -Invoke Invoke-Wsl -ParameterFilter { $Script -like '*$E stop*' -and $Variables.name -eq 'intellij-my-app-13efc5' } -Times 1 -Exactly
            Should -Invoke Stop-KeepAlive -ParameterFilter { $Name -eq 'intellij-my-app-13efc5' -and $Distro -eq 'Ubuntu' } -Times 1 -Exactly
        }

        It 'doesn''t start the Podman machine to stop a container' {
            Mock Resolve-DevContainerHost { $null }
            Stop-DevContainer 'C:\src\my-app' -Engine podman
            Should -Invoke Resolve-DevContainerHost -ParameterFilter { $Machine -eq 'Running' } -Times 1 -Exactly
            Should -Invoke Write-Host -ParameterFilter { $Object -like "*Podman machine isn't running*" } -Times 1 -Exactly
            Should -Invoke Invoke-Wsl -Times 0
        }

        It 'says so when there''s no container' {
            Mock Get-ContainerState { '' }
            Stop-DevContainer 'C:\src\my-app'
            Should -Invoke Write-Host -ParameterFilter { $Object -like "There's no container for C:\src\my-app*" } -Times 1 -Exactly
            Should -Invoke Invoke-Wsl -Times 0
        }

        It 'does nothing with -WhatIf' {
            Stop-DevContainer 'C:\src\my-app' -WhatIf
            Should -Invoke Invoke-Wsl -Times 0
            Should -Invoke Stop-KeepAlive -Times 0
        }

        It 'takes the containers Get-DevContainer lists from the pipeline' {
            @((New-TestFound 'C:\src\my-app' 'intellij-my-app-13efc5').Container,
              (New-TestFound 'D:\work\my-app' 'intellij-my-app-d46b83' -Machine).Container) | Stop-DevContainer
            Should -Invoke Resolve-DevContainerHost -ParameterFilter { $Distro -eq 'Ubuntu' -and $Engine -eq 'docker' } -Times 1 -Exactly
            # The machine's containers come with no distro, so the machine is picked again.
            Should -Invoke Resolve-DevContainerHost -ParameterFilter { -not $Distro -and $Engine -eq 'podman' } -Times 1 -Exactly
            Should -Invoke Invoke-Wsl -ParameterFilter { $Variables.name -eq 'intellij-my-app-d46b83' } -Times 1 -Exactly
        }
    }

    Context 'Remove-DevContainer' {
        BeforeEach {
            Mock Resolve-DevContainerHost { New-TestContext }
            Mock Get-ContainerState { 'false' }
            Mock Test-VolumeExists { $false }
            Mock Remove-ProjectContainer { }
            Mock Stop-KeepAlive { }
        }

        It 'deletes the container' {
            Remove-DevContainer 'C:\src\my-app' -Confirm:$false
            Should -Invoke Remove-ProjectContainer -ParameterFilter { $Project.ContainerName -eq 'intellij-my-app-13efc5' } -Times 1 -Exactly
            Should -Invoke Write-Host -ParameterFilter { $Object -eq 'Deleted intellij-my-app-13efc5.' } -Times 1 -Exactly
        }

        It 'deletes a volume left without its container' {
            Mock Get-ContainerState { '' }
            Mock Test-VolumeExists { $true }
            Remove-DevContainer 'C:\src\my-app' -Confirm:$false
            Should -Invoke Remove-ProjectContainer -Times 1 -Exactly
        }

        It 'says so when there''s nothing to delete' {
            Mock Get-ContainerState { '' }
            Remove-DevContainer 'C:\src\my-app' -Confirm:$false
            Should -Invoke Remove-ProjectContainer -Times 0
        }

        It 'deletes nothing with -WhatIf' {
            Remove-DevContainer 'C:\src\my-app' -WhatIf
            Should -Invoke Remove-ProjectContainer -Times 0
        }

        It 'asks first' {
            (Get-Command Remove-DevContainer).ScriptBlock.Attributes.Where({ $_ -is [System.Management.Automation.CmdletBindingAttribute] }).ConfirmImpact |
                Should -Be 'High'
        }
    }

    Context 'Clear-DevContainer' {
        BeforeEach {
            Mock Find-DevContainers {
                New-TestFound 'C:\src\my-app' 'intellij-my-app-13efc5'
                New-TestFound 'D:\work\my-app' 'intellij-my-app-d46b83' -Machine
            }
            Mock Remove-ProjectContainer { }
            Mock Stop-KeepAlive { }
        }

        It 'deletes every container, in every engine' {
            Clear-DevContainer -Confirm:$false
            Should -Invoke Remove-ProjectContainer -Times 2 -Exactly
            Should -Invoke Remove-ProjectContainer -ParameterFilter { $Project.ContainerName -eq 'intellij-my-app-d46b83' -and $Context.PodmanMachine } -Times 1 -Exactly
            Should -Invoke Stop-KeepAlive -ParameterFilter { $Name -eq 'intellij-my-app-13efc5' -and $Distro -eq 'Ubuntu' } -Times 1 -Exactly
            Should -Invoke Stop-KeepAlive -ParameterFilter { $Name -eq 'intellij-my-app-d46b83' -and $Distro -eq 'podman-machine-default' } -Times 1 -Exactly
        }

        It 'starts a stopped Podman machine to find its containers, but doesn''t create one' {
            Clear-DevContainer -Confirm:$false
            Should -Invoke Find-DevContainers -ParameterFilter { $Machine -eq 'Start' } -Times 1 -Exactly
        }

        It 'deletes nothing with -WhatIf' {
            Clear-DevContainer -WhatIf
            Should -Invoke Remove-ProjectContainer -Times 0
        }

        It 'says so when there are none' {
            Mock Find-DevContainers { }
            Clear-DevContainer -Confirm:$false
            Should -Invoke Write-Host -ParameterFilter { $Object -eq 'There are no dev containers.' } -Times 1 -Exactly
        }

        It 'can be limited to one engine' {
            Clear-DevContainer -Engine podman -Confirm:$false
            Should -Invoke Find-DevContainers -ParameterFilter { $Engine -eq 'podman' } -Times 1 -Exactly
        }

        It 'runs as Clean-DevContainer' {
            Clean-DevContainer -Confirm:$false
            Should -Invoke Remove-ProjectContainer -Times 2 -Exactly
        }
    }

    Context 'Reset-DevContainer' {
        BeforeAll {
            $project = Join-Path $TestDrive 'app'
            $null = New-Item -ItemType Directory -Force -Path $project
        }

        BeforeEach {
            Mock Resolve-DevContainerHost { New-TestContext }
            Mock Get-ContainerState { 'true' }
            Mock Test-VolumeExists { $true }
            Mock Test-Internet { $null }
            Mock Remove-ProjectContainer { 2230 }
            Mock New-ProjectContainer { }
        }

        It 'creates the container again on its old port, pulling the newest base image' {
            Reset-DevContainer $project -Confirm:$false
            Should -Invoke Remove-ProjectContainer -Times 1 -Exactly
            Should -Invoke New-ProjectContainer -ParameterFilter { $Port -eq 2230 -and $Pull } -Times 1 -Exactly
        }

        It 'takes -Port over the old port' {
            Reset-DevContainer $project -Port 2300 -Confirm:$false
            Should -Invoke New-ProjectContainer -ParameterFilter { $Port -eq 2300 } -Times 1 -Exactly
        }

        It 'deletes nothing when it couldn''t build the new container' {
            Mock Test-Internet { "Ubuntu can't reach https://www.google.com" }
            { Reset-DevContainer $project -Confirm:$false -ErrorAction Stop } | Should -Throw "*can't be built*"
            Should -Invoke Remove-ProjectContainer -Times 0
        }

        It 'deletes nothing with -WhatIf' {
            Reset-DevContainer $project -WhatIf
            Should -Invoke Remove-ProjectContainer -Times 0
            Should -Invoke New-ProjectContainer -Times 0
        }

        It 'just creates the container when there is none' {
            Mock Get-ContainerState { '' }
            Mock Test-VolumeExists { $false }
            Reset-DevContainer $project -Confirm:$false
            Should -Invoke Remove-ProjectContainer -Times 0
            Should -Invoke New-ProjectContainer -ParameterFilter { $Pull } -Times 1 -Exactly
        }
    }

    Context 'Get-DevContainer and Find-DevContainers' {
        It 'looks in Docker and Podman in the distro, and in Podman for Windows'' machine' {
            Mock Find-PodmanExe { 'C:\podman\podman.exe' }
            Mock Resolve-DevContainerHost { if ($Engine -eq 'podman' -and -not $InDistro) { New-TestContext -Machine } else { New-TestContext } }
            Mock Get-ContainerData { '{"Name":"/x","State":{"Status":"running"},"Config":{"Labels":{"intellij.project":"C:\\a","intellij.port":"2222"}},"HostConfig":{}}' | ConvertFrom-Json }
            @(Find-DevContainers $null $null 'Running').Count | Should -Be 3
            Should -Invoke Resolve-DevContainerHost -ParameterFilter { $Engine -eq 'docker' } -Times 1 -Exactly
            Should -Invoke Resolve-DevContainerHost -ParameterFilter { $Engine -eq 'podman' -and $InDistro } -Times 1 -Exactly
            Should -Invoke Resolve-DevContainerHost -ParameterFilter { $Engine -eq 'podman' -and -not $InDistro -and $Machine -eq 'Running' } -Times 1 -Exactly
        }

        It 'skips an engine that isn''t there' {
            Mock Find-PodmanExe { $null }
            Mock Resolve-DevContainerHost { if ($Engine -eq 'docker') { New-TestContext } else { throw "Podman wasn't found" } }
            Mock Get-ContainerData { '{"Name":"/x","State":{"Status":"running"},"Config":{"Labels":{}},"HostConfig":{}}' | ConvertFrom-Json }
            @(Find-DevContainers $null $null 'Running').Count | Should -Be 1
        }

        It 'lists only the project''s container with -Path' {
            Mock Find-DevContainers {
                New-TestFound 'C:\src\my-app' 'intellij-my-app-13efc5'
                New-TestFound 'D:\work\my-app' 'intellij-my-app-d46b83'
            }
            $found = @(Get-DevContainer 'C:\src\my-app')
            $found.Count | Should -Be 1
            $found[0].Name | Should -Be 'intellij-my-app-13efc5'
        }

        It 'doesn''t start the Podman machine to list containers' {
            Mock Find-DevContainers { }
            $null = Get-DevContainer
            Should -Invoke Find-DevContainers -ParameterFilter { $Machine -eq 'Running' } -Times 1 -Exactly
        }
    }

    Context 'Enter-DevContainer' {
        BeforeEach {
            # Like the real one, the host remembers the -Engine it was asked for.
            Mock Resolve-DevContainerHost { $context = New-TestContext; $context.EngineOption = $Engine; $context }
            Mock Start-ExistingContainer { [pscustomobject]@{ Port = 2223; HostNetwork = $true } }
            Mock ssh.exe { $global:DevContainersSshArgs = $args }
        }

        AfterAll { Remove-Variable DevContainersSshArgs -Scope Global -ErrorAction SilentlyContinue }

        It 'opens SSH on the container''s port' {
            Mock Get-ContainerState { 'false' }
            Enter-DevContainer 'C:\src\my-app'
            Should -Invoke Start-ExistingContainer -Times 1 -Exactly
            $global:DevContainersSshArgs | Should -Contain '2223'
            $global:DevContainersSshArgs | Should -Contain 'dev@127.0.0.1'
        }

        It 'says how to create the container when there is none' {
            Mock Get-ContainerState { '' }
            { Enter-DevContainer 'C:\src\my-app' -Engine podman -ErrorAction Stop } |
                Should -Throw "*no container for C:\src\my-app*Start-DevContainer -Path 'C:\src\my-app' -Engine podman creates it*"
            Should -Invoke ssh.exe -Times 0
        }
    }

    Context 'Test-DevContainerHost' {
        It 'returns $true when every check passes' {
            Mock Resolve-DevContainerHost { New-TestContext }
            Mock Test-Internet { $null }
            Test-DevContainerHost | Should -BeTrue
        }

        It 'returns $false, saying why, when a check fails' {
            Mock Resolve-DevContainerHost { Stop-WithError 'Ubuntu runs on WSL 1' }
            Test-DevContainerHost | Should -BeFalse
            Should -Invoke Write-Host -ParameterFilter { $Object -eq 'Ubuntu runs on WSL 1' } -Times 1 -Exactly
        }

        It 'returns $false without the internet' {
            Mock Resolve-DevContainerHost { New-TestContext }
            Mock Test-Internet { "Ubuntu can't reach https://www.google.com" }
            Test-DevContainerHost | Should -BeFalse
        }

        It 'starts a stopped Podman machine, but doesn''t create one' {
            Mock Resolve-DevContainerHost { $null }
            Test-DevContainerHost -Engine podman | Should -BeTrue
            Should -Invoke Resolve-DevContainerHost -ParameterFilter { $Machine -eq 'Start' } -Times 1 -Exactly
        }
    }
}

}
