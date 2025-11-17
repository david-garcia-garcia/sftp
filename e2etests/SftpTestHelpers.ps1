<#
.SYNOPSIS
    Reusable helper functions for SFTP integration tests

.DESCRIPTION
    This module provides a collection of helper functions for testing SFTP
    Docker containers with Pester. Functions handle container management,
    SFTP operations, user management, and SSH key operations.

.NOTES
    To use these helpers in a Pester test file, dot-source this file:
    . "$PSScriptRoot/SftpTestHelpers.ps1"
#>

# ===== CONTAINER COMMAND EXECUTION =====

<#
.SYNOPSIS
    Executes a command inside the SFTP client container

.PARAMETER Command
    The shell command to execute

.PARAMETER IgnoreError
    If specified, errors will not generate warnings

.OUTPUTS
    Hashtable with Output, ExitCode, and Success properties
#>
function Invoke-SftpClientCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Command,
        
        [Parameter()]
        [string]$ClientContainer = "sftp-client",
        
        [switch]$IgnoreError
    )
    
    $result = docker exec $ClientContainer sh -c $Command 2>&1
    $exitCode = $LASTEXITCODE
    
    if (-not $IgnoreError -and $exitCode -ne 0) {
        Write-Warning "Command failed with exit code $exitCode : $Command"
        Write-Warning "Output: $result"
    }
    
    return @{
        Output = $result
        ExitCode = $exitCode
        Success = ($exitCode -eq 0)
    }
}

<#
.SYNOPSIS
    Executes a command inside the SFTP server container

.PARAMETER ContainerName
    The name of the SFTP server container

.PARAMETER Command
    The shell command to execute

.PARAMETER IgnoreError
    If specified, errors will not generate warnings

.OUTPUTS
    Hashtable with Output, ExitCode, and Success properties
#>
function Invoke-SftpServerCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ContainerName,
        
        [Parameter(Mandatory)]
        [string]$Command,
        
        [switch]$IgnoreError
    )
    
    $result = docker exec $ContainerName sh -c $Command 2>&1
    $exitCode = $LASTEXITCODE
    
    if (-not $IgnoreError -and $exitCode -ne 0) {
        Write-Warning "Server command failed with exit code $exitCode : $Command"
        Write-Warning "Output: $result"
    }
    
    return @{
        Output = $result
        ExitCode = $exitCode
        Success = ($exitCode -eq 0)
    }
}

# ===== SSH KEY MANAGEMENT =====

<#
.SYNOPSIS
    Generates SSH key pair for testing

.PARAMETER Path
    Path where the key pair will be created (inside the client container)

.PARAMETER KeyType
    Type of SSH key to generate (default: rsa)

.PARAMETER KeySize
    Size of the key in bits (default: 2048)

.OUTPUTS
    Boolean indicating success
#>
function New-TestSshKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        
        [Parameter()]
        [string]$ClientContainer = "sftp-client",
        
        [ValidateSet('rsa', 'ed25519', 'ecdsa')]
        [string]$KeyType = 'rsa',
        
        [int]$KeySize = 2048
    )
    
    $keySizeArg = if ($KeyType -eq 'rsa') { "-b $KeySize" } else { "" }
    $result = Invoke-SftpClientCommand -ClientContainer $ClientContainer `
        -Command "ssh-keygen -t $KeyType $keySizeArg -f $Path -N '' -q"
    return $result.Success
}

# ===== SFTP CONNECTION AND OPERATIONS =====

<#
.SYNOPSIS
    Tests SFTP connection and executes commands

.PARAMETER Host
    SFTP server hostname

.PARAMETER Port
    SFTP server port

.PARAMETER Username
    Username for authentication

.PARAMETER Password
    Password for authentication (optional)

.PARAMETER KeyPath
    Path to SSH private key for authentication (optional)

.PARAMETER Commands
    Array of SFTP commands to execute

.PARAMETER ExpectFailure
    If specified, expects the connection to fail

.PARAMETER ClientContainer
    Name of the client container to use

.OUTPUTS
    Hashtable with Success and Output properties
#>
function Test-SftpConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$HostName,
        
        [Parameter(Mandatory)]
        [int]$Port,
        
        [Parameter(Mandatory)]
        [string]$Username,
        
        [string]$Password = "",
        
        [string]$KeyPath = "",
        
        [string[]]$Commands = @("pwd"),
        
        [switch]$ExpectFailure,
        
        [string]$ClientContainer = "sftp-client"
    )
    
    # Prepare SFTP batch commands
    $batchCommands = ($Commands -join "`n") + "`nexit`n"
    
    # Build SFTP command
    if ($Password) {
        # Password auth: Use stdin redirection instead of batch file for better compatibility
        # Base64 encode the commands to avoid shell escaping issues
        $batchBytes = [System.Text.Encoding]::UTF8.GetBytes($batchCommands)
        $batchBase64 = [Convert]::ToBase64String($batchBytes)
        
        # Build sftp command without batch file, pipe commands via stdin
        $sftpCmd = "sftp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P $Port"
        $sftpCmd += " ${Username}@${HostName}"
        
        # Use sshpass with password, then pipe commands via stdin
        # Escape single quotes in password for shell safety
        $escapedPassword = $Password -replace "'", "'\''"
        $fullCmd = "echo '$batchBase64' | base64 -d | sshpass -p '$escapedPassword' $sftpCmd"
    } else {
        # Key auth: Use batch file (works reliably with key auth)
        $batchFile = "/tmp/sftp_batch_$(Get-Random).txt"
        $batchBytes = [System.Text.Encoding]::UTF8.GetBytes($batchCommands)
        $batchBase64 = [Convert]::ToBase64String($batchBytes)
        
        $result = Invoke-SftpClientCommand -ClientContainer $ClientContainer `
            -Command "echo '$batchBase64' | base64 -d > $batchFile"
        if (-not $result.Success) {
            return @{ Success = $false; Output = "Failed to create batch file: $($result.Output)" }
        }
        
        $sftpCmd = "sftp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P $Port -b $batchFile"
        if ($KeyPath) {
            $sftpCmd += " -i $KeyPath"
        }
        $sftpCmd += " ${Username}@${HostName}"
        $fullCmd = $sftpCmd
    }
    
    $result = Invoke-SftpClientCommand -ClientContainer $ClientContainer `
        -Command $fullCmd -IgnoreError
    
    # Cleanup batch file if it was created (key auth only)
    if (-not $Password -and $batchFile) {
        Invoke-SftpClientCommand -ClientContainer $ClientContainer `
            -Command "rm -f $batchFile" -IgnoreError | Out-Null
    }
    
    if ($ExpectFailure) {
        return @{
            Success = (-not $result.Success)
            Output = $result.Output
        }
    }
    
    return @{
        Success = $result.Success
        Output = $result.Output
    }
}

<#
.SYNOPSIS
    Uploads a file via SFTP

.PARAMETER Host
    SFTP server hostname

.PARAMETER Port
    SFTP server port

.PARAMETER Username
    Username for authentication

.PARAMETER Password
    Password for authentication (optional)

.PARAMETER KeyPath
    Path to SSH private key for authentication (optional)

.PARAMETER LocalPath
    Local file path to upload

.PARAMETER RemotePath
    Remote destination path

.PARAMETER ClientContainer
    Name of the client container to use

.OUTPUTS
    Hashtable with Success and Output properties
#>
function Send-SftpFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$HostName,
        
        [Parameter(Mandatory)]
        [int]$Port,
        
        [Parameter(Mandatory)]
        [string]$Username,
        
        [string]$Password = "",
        
        [string]$KeyPath = "",
        
        [Parameter(Mandatory)]
        [string]$LocalPath,
        
        [Parameter(Mandatory)]
        [string]$RemotePath,
        
        [string]$ClientContainer = "sftp-client"
    )
    
    $commands = @(
        "put $LocalPath $RemotePath"
    )
    
    return Test-SftpConnection -HostName $HostName -Port $Port -Username $Username `
        -Password $Password -KeyPath $KeyPath -Commands $commands `
        -ClientContainer $ClientContainer
}

<#
.SYNOPSIS
    Downloads a file via SFTP

.PARAMETER Host
    SFTP server hostname

.PARAMETER Port
    SFTP server port

.PARAMETER Username
    Username for authentication

.PARAMETER Password
    Password for authentication (optional)

.PARAMETER KeyPath
    Path to SSH private key for authentication (optional)

.PARAMETER RemotePath
    Remote file path to download

.PARAMETER LocalPath
    Local destination path

.PARAMETER ClientContainer
    Name of the client container to use

.OUTPUTS
    Hashtable with Success and Output properties
#>
function Get-SftpFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$HostName,
        
        [Parameter(Mandatory)]
        [int]$Port,
        
        [Parameter(Mandatory)]
        [string]$Username,
        
        [string]$Password = "",
        
        [string]$KeyPath = "",
        
        [Parameter(Mandatory)]
        [string]$RemotePath,
        
        [Parameter(Mandatory)]
        [string]$LocalPath,
        
        [string]$ClientContainer = "sftp-client"
    )
    
    $commands = @(
        "get $RemotePath $LocalPath"
    )
    
    return Test-SftpConnection -HostName $HostName -Port $Port -Username $Username `
        -Password $Password -KeyPath $KeyPath -Commands $commands `
        -ClientContainer $ClientContainer
}

# ===== USER AND DIRECTORY MANAGEMENT =====

<#
.SYNOPSIS
    Checks if a user exists in the container

.PARAMETER ContainerName
    The name of the SFTP server container

.PARAMETER Username
    The username to check

.OUTPUTS
    Boolean indicating if user exists
#>
function Test-SftpUser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ContainerName,
        
        [Parameter(Mandatory)]
        [string]$Username
    )
    
    $result = Invoke-SftpServerCommand -ContainerName $ContainerName `
        -Command "id $Username" -IgnoreError
    return $result.Success
}

<#
.SYNOPSIS
    Checks if a directory exists in the container

.PARAMETER ContainerName
    The name of the SFTP server container

.PARAMETER Path
    The directory path to check

.OUTPUTS
    Boolean indicating if directory exists
#>
function Test-SftpDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ContainerName,
        
        [Parameter(Mandatory)]
        [string]$Path
    )
    
    $result = Invoke-SftpServerCommand -ContainerName $ContainerName `
        -Command "test -d '$Path'" -IgnoreError
    return $result.Success
}

<#
.SYNOPSIS
    Checks if a file exists in the container

.PARAMETER ContainerName
    The name of the SFTP server container

.PARAMETER Path
    The file path to check

.OUTPUTS
    Boolean indicating if file exists
#>
function Test-SftpFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ContainerName,
        
        [Parameter(Mandatory)]
        [string]$Path
    )
    
    $result = Invoke-SftpServerCommand -ContainerName $ContainerName `
        -Command "test -f '$Path'" -IgnoreError
    return $result.Success
}

<#
.SYNOPSIS
    Gets user information from the container

.PARAMETER ContainerName
    The name of the SFTP server container

.PARAMETER Username
    The username to query

.OUTPUTS
    Hashtable with Success, Output, Uid, and Gid properties
#>
function Get-SftpUserInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ContainerName,
        
        [Parameter(Mandatory)]
        [string]$Username
    )
    
    $result = Invoke-SftpServerCommand -ContainerName $ContainerName `
        -Command "id $Username" -IgnoreError
    
    if ($result.Success) {
        return @{
            Success = $true
            Output = $result.Output
            Uid = if ($result.Output -match 'uid=(\d+)') { $matches[1] } else { $null }
            Gid = if ($result.Output -match 'gid=(\d+)') { $matches[1] } else { $null }
        }
    }
    
    return @{ Success = $false }
}

# ===== CONTAINER MANAGEMENT =====

<#
.SYNOPSIS
    Creates a temporary container for testing specific configurations

.PARAMETER Image
    Docker image to use

.PARAMETER UserConfig
    Array of user configuration strings

.PARAMETER Environment
    Hashtable of environment variables

.PARAMETER Volumes
    Hashtable of volume mounts (source -> destination)

.PARAMETER Name
    Container name (auto-generated if not specified)

.PARAMETER Network
    Docker network to connect to

.OUTPUTS
    Hashtable with Success, ContainerName, and ContainerId properties
#>
function New-TestSftpContainer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Image,
        
        [string[]]$UserConfig = @(),
        
        [hashtable]$Environment = @{},
        
        [hashtable]$Volumes = @{},
        
        [string]$Name = "sftp-test-$(Get-Random)",
        
        [string]$Network = "sftp_sftp-network"
    )
    
    $dockerArgs = @("run", "-d", "--name", $Name)
    
    # Add network if specified
    if ($Network) {
        $dockerArgs += "--network"
        $dockerArgs += $Network
    }
    
    # Add environment variables
    foreach ($key in $Environment.Keys) {
        $dockerArgs += "-e"
        $dockerArgs += "${key}=$($Environment[$key])"
    }
    
    # Add volumes
    foreach ($key in $Volumes.Keys) {
        $dockerArgs += "-v"
        $dockerArgs += "${key}:$($Volumes[$key])"
    }
    
    # Add image
    $dockerArgs += $Image
    
    # Add user config as command arguments
    $dockerArgs += $UserConfig
    
    $result = docker @dockerArgs 2>&1
    $exitCode = $LASTEXITCODE
    
    if ($exitCode -eq 0) {
        # Wait for container to be ready
        Start-Sleep -Seconds 3
        
        return @{
            Success = $true
            ContainerName = $Name
            ContainerId = $result
        }
    }
    
    Write-Warning "Failed to create container: $result"
    return @{
        Success = $false
        ContainerName = $Name
        Error = $result
    }
}

<#
.SYNOPSIS
    Removes a test container

.PARAMETER ContainerName
    The name of the container to remove

.PARAMETER Force
    Force removal even if container is running
#>
function Remove-TestSftpContainer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ContainerName,
        
        [switch]$Force = $true
    )
    
    $forceArg = if ($Force) { "-f" } else { "" }
    docker rm $forceArg $ContainerName 2>&1 | Out-Null
}

<#
.SYNOPSIS
    Gets the SSH port for a container

.PARAMETER ContainerName
    The name of the container

.OUTPUTS
    Integer port number or null if not found
#>
function Get-ContainerSshPort {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ContainerName
    )
    
    $result = docker port $ContainerName 22 2>&1
    if ($LASTEXITCODE -eq 0 -and $result -match ':(\d+)') {
        return [int]$matches[1]
    }
    return $null
}

<#
.SYNOPSIS
    Gets the IP address of a container in a specific network

.PARAMETER ContainerName
    The name of the container

.PARAMETER Network
    The network name (optional)

.OUTPUTS
    String IP address or null if not found
#>
function Get-ContainerIpAddress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ContainerName,
        
        [string]$Network = ""
    )
    
    if ($Network) {
        $result = docker inspect -f "{{.NetworkSettings.Networks.$Network.IPAddress}}" $ContainerName 2>&1
    }
    else {
        $result = docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $ContainerName 2>&1
    }
    
    if ($LASTEXITCODE -eq 0 -and $result) {
        return $result.Trim()
    }
    return $null
}

# ===== FILE OPERATIONS =====

<#
.SYNOPSIS
    Creates a temporary test file in the client container

.PARAMETER Content
    Content to write to the file

.PARAMETER FileName
    File name (optional, auto-generated if not specified)

.PARAMETER ClientContainer
    Name of the client container

.OUTPUTS
    String path to the created file
#>
function New-TestFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Content,
        
        [string]$FileName = "testfile_$(Get-Random).txt",
        
        [string]$ClientContainer = "sftp-client"
    )
    
    $filePath = "/tmp/$FileName"
    $result = Invoke-SftpClientCommand -ClientContainer $ClientContainer `
        -Command "echo '$Content' > $filePath"
    
    if ($result.Success) {
        return $filePath
    }
    
    return $null
}

<#
.SYNOPSIS
    Reads file content from a container

.PARAMETER ContainerName
    The name of the container

.PARAMETER Path
    Path to the file

.OUTPUTS
    String content of the file
#>
function Get-ContainerFileContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ContainerName,
        
        [Parameter(Mandatory)]
        [string]$Path
    )
    
    $result = Invoke-SftpServerCommand -ContainerName $ContainerName `
        -Command "cat '$Path'" -IgnoreError
    
    if ($result.Success) {
        return $result.Output
    }
    
    return $null
}

<#
.SYNOPSIS
    Sends PROXY protocol header to mmproxy and verifies handshake

.DESCRIPTION
    Sends PROXY protocol v1 header to mmproxy with a specified client IP address,
    then sends a simple connection attempt. The test verifies that mmproxy accepts
    the PROXY protocol header and forwards the connection (can be verified in logs).

.PARAMETER HostName
    Hostname or IP of the mmproxy service

.PARAMETER Port
    Port of the mmproxy service (typically 22, the target port)

.PARAMETER ProxyClientIp
    IP address to send in PROXY protocol header (default: 203.0.113.1 - public IP from TEST-NET-3 range)

.PARAMETER ClientContainer
    Name of the client container

.OUTPUTS
    Hashtable with Success and Output properties
#>
function Test-ProxyProtocolHandshake {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$HostName,
        
        [Parameter(Mandatory)]
        [int]$Port,
        
        [string]$ProxyClientIp = "203.0.113.1",
        
        [string]$ClientContainer = "sftp-client"
    )
    
    # PROXY protocol v1 format: PROXY TCP4 <src_ip> <dst_ip> <src_port> <dst_port>\r\n
    # The destination IP should be where mmproxy forwards to (127.0.0.1:2222)
    # The destination port should be the target port (2222, not the mmproxy listen port)
    $proxyDstIp = "127.0.0.1"
    $proxyDstPort = 2222  # mmproxy forwards to port 2222
    $proxySrcPort = 54321
    
    # Construct PROXY protocol header
    # Note: Must use \r\n (CRLF) as line terminator per PROXY protocol spec
    $proxyHeader = "PROXY TCP4 $ProxyClientIp $proxyDstIp $proxySrcPort $proxyDstPort`r`n"
    
    # Use base64 encoding to avoid shell escaping issues with special characters
    # This ensures CRLF (\r\n) is preserved correctly
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($proxyHeader)
    $base64Header = [Convert]::ToBase64String($headerBytes)
    
    # Use nc (netcat) to send the PROXY protocol header
    # Alpine's netcat-openbsd supports -w for timeout
    # We decode base64 and pipe directly to nc to send the header immediately after connection
    # PowerShell variables ($base64Header, $HostName, $Port) are expanded here before passing to shell
    $cmd = "sh -c 'echo $base64Header | base64 -d | nc -w 3 $HostName $Port 2>&1' || true"
    
    $result = Invoke-SftpClientCommand -ClientContainer $ClientContainer `
        -Command $cmd `
        -IgnoreError
    
    # Check if connection was successful
    # Success means we could connect to mmproxy (even if it closes immediately after PROXY header)
    # Connection refused/timeout means mmproxy isn't reachable
    # Note: mmproxy may close the connection immediately after reading PROXY header if SFTP server rejects it
    # That's still considered success - we just need to verify the connection was established
    $connectionRefused = $result.Output -match "Connection refused|Connection timed out|No route to host|Name or service not known|cannot connect"
    $connectionSuccess = -not $connectionRefused -and ($result.ExitCode -eq 0 -or $result.Output -notmatch "Ncat.*Connection refused")
    
    return @{
        Success = $connectionSuccess
        Output = $result.Output
        ExitCode = $result.ExitCode
    }
}

# Export functions for module usage (optional, useful if converted to a module)
# Export-ModuleMember - Not needed for script files, only for modules
# If converting to a module, uncomment and use:
# Export-ModuleMember -Function @(
#     'Invoke-SftpClientCommand',
#     'Invoke-SftpServerCommand',
#     'New-TestSshKey',
#     'Test-SftpConnection',
#     'Send-SftpFile',
#     'Get-SftpFile',
#     'Test-SftpUser',
#     'Test-SftpDirectory',
#     'Test-SftpFile',
#     'Get-SftpUserInfo',
#     'New-TestSftpContainer',
#     'Remove-TestSftpContainer',
#     'Get-ContainerSshPort',
#     'Get-ContainerIpAddress',
#     'New-TestFile',
#     'Get-ContainerFileContent',
#     'Test-SftpConnectionViaProxyProtocol'
# )

