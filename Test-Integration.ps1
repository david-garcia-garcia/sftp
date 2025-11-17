#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Runs integration tests for the SFTP Docker Container

.DESCRIPTION
    This script starts the Docker Compose services, waits for them to be ready,
    runs the Pester integration tests, and then cleans up the services.

.PARAMETER SkipDockerCleanup
    Skip stopping Docker services after tests complete (useful for debugging)

.PARAMETER SkipWait
    Skip waiting for services to be ready (assumes they're already running)

.PARAMETER ImageVariant
    Which image variant to test: 'debian' or 'alpine' (required)

.PARAMETER TestPath
    Path to the Pester test file (defaults to ./e2etests)


.EXAMPLE
    ./Test-Integration.ps1 -ImageVariant debian
    Test Debian image

.EXAMPLE
    ./Test-Integration.ps1 -ImageVariant alpine
    Test Alpine image

.EXAMPLE
    ./Test-Integration.ps1 -SkipDockerCleanup
    Runs tests but leaves Docker services running for debugging

.EXAMPLE
    ./Test-Integration.ps1 -ImageVariant alpine
    Runs tests only against the Alpine image
#>

[CmdletBinding()]
param(
    [switch]$SkipDockerCleanup,
    [switch]$SkipWait,
    [Parameter(Mandatory=$true)]
    [ValidateSet('debian', 'alpine')]
    [string]$ImageVariant,
    [string]$TestPath = "./e2etests"
)

$ErrorActionPreference = "Stop"

# Colors for output
$Colors = @{
    Info = "Cyan"
    Success = "Green"
    Warning = "Yellow"
    Error = "Red"
}

function Write-Step {
    param([string]$Message, [string]$Color = "Cyan")
    Write-Host "🔄 $Message" -ForegroundColor $Color
}

function Write-Success {
    param([string]$Message)
    Write-Host "✅ $Message" -ForegroundColor $Colors.Success
}

function Write-Warning {
    param([string]$Message)
    Write-Host "⚠️  $Message" -ForegroundColor $Colors.Warning
}

function Write-ErrorMessage {
    param([string]$Message)
    Write-Host "❌ $Message" -ForegroundColor $Colors.Error
}

function Test-SftpServiceHealth {
    param(
        [string]$ContainerName,
        [int]$Port,
        [int]$TimeoutSeconds = 15,
        [int]$RetryIntervalSeconds = 2
    )
    
    Write-Step "Waiting for $ContainerName to be ready..."
    $elapsed = 0
    
    do {
        try {
            # Test if SSH port is responding
            $tcpClient = New-Object System.Net.Sockets.TcpClient
            $tcpClient.ConnectAsync("localhost", $Port).Wait(1000) | Out-Null
            if ($tcpClient.Connected) {
                $tcpClient.Close()
                Write-Success "$ContainerName is ready!"
                return $true
            }
            $tcpClient.Close()
        }
        catch {
            # Service not ready yet, continue waiting
        }
        
        Start-Sleep $RetryIntervalSeconds
        $elapsed += $RetryIntervalSeconds
        
        if ($elapsed % 10 -eq 0) {
            Write-Host "  Still waiting for $ContainerName... ($elapsed/$TimeoutSeconds seconds)" -ForegroundColor Gray
        }
        
    } while ($elapsed -lt $TimeoutSeconds)
    
    Write-ErrorMessage "$ContainerName failed to become ready within $TimeoutSeconds seconds"
    return $false
}

# Main execution
try {
    Write-Host ""
    Write-Host "🚀 SFTP Docker Container Integration Test Runner" -ForegroundColor $Colors.Info
    Write-Host "=================================================" -ForegroundColor $Colors.Info
    Write-Host ""

    # Check if Pester is available
    Write-Step "Checking Pester availability..."
    try {
        Import-Module Pester -Force -ErrorAction Stop
        $pesterVersion = (Get-Module Pester).Version
        Write-Success "Pester $pesterVersion is available"
    }
    catch {
        Write-ErrorMessage "Pester module not found. Installing Pester..."
        try {
            Install-Module -Name Pester -Force -Scope CurrentUser -SkipPublisherCheck
            Import-Module Pester -Force
            Write-Success "Pester installed and imported successfully"
        }
        catch {
            Write-ErrorMessage "Failed to install Pester: $($_.Exception.Message)"
            exit 1
        }
    }

    # Check if Docker Compose is available
    Write-Step "Checking Docker Compose availability..."
    try {
        $dockerComposeVersion = docker compose version 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Docker Compose is available"
        } else {
            throw "Docker Compose not found"
        }
    }
    catch {
        Write-ErrorMessage "Docker Compose is not available. Please install Docker Desktop or Docker Compose."
        exit 1
    }

    # Build Docker images
    Write-Step "Building Docker images..."
    try {
        docker compose build
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to build Docker images"
        }
        Write-Success "Docker images built successfully"
    }
    catch {
        Write-ErrorMessage "Failed to build Docker images: $($_.Exception.Message)"
        exit 1
    }

    # Generate test SSH keys if they don't exist
    $testKeyPath = "./e2etests/fixtures/test_rsa"
    $testKeyPubPath = "./e2etests/fixtures/test_rsa.pub"
    
    if (-not (Test-Path $testKeyPath) -or -not (Test-Path $testKeyPubPath) -or (Test-Path $testKeyPubPath -PathType Container)) {
        Write-Step "Generating test SSH keys..."
        try {
            # Clean up any existing invalid keys
            Get-ChildItem "./e2etests/fixtures/test_rsa*" -ErrorAction SilentlyContinue | ForEach-Object {
                Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
            
            # Create fixtures directory if it doesn't exist
            New-Item -ItemType Directory -Force -Path "./e2etests/fixtures" | Out-Null
            
            # Use docker run to generate SSH keys (avoiding compose volume mount complexities)
            $keyGenCmd = "docker run --rm -v `"${PWD}/e2etests/fixtures:/keys`" alpine:3.21 sh -c `"apk add --no-cache openssh-keygen > /dev/null 2>&1 && ssh-keygen -t rsa -b 2048 -f /keys/test_rsa -N '' -C 'test@sftp' > /dev/null 2>&1`""
            Invoke-Expression $keyGenCmd | Out-Null
            
            if ($LASTEXITCODE -eq 0 -and (Test-Path $testKeyPath) -and (Test-Path $testKeyPubPath) -and -not (Test-Path $testKeyPubPath -PathType Container)) {
                Write-Success "Test SSH keys generated"
            }
            else {
                Write-Warning "Could not generate SSH keys properly, key-based auth tests may be skipped"
            }
        }
        catch {
            Write-Warning "Failed to generate test SSH keys: $($_.Exception.Message)"
        }
    }
    
    # Start Docker services
    Write-Step "Starting Docker Compose services..."
    try {
        # Determine Docker Compose profile based on variant
        $composeProfile = if ($ImageVariant -eq 'debian') { 'debian' } else { 'alpine' }
        
        # Start services with the appropriate profile
        # Services without profiles (like sftp-client) will start automatically
        # The SFTP server will be started based on the profile
        docker compose --profile $composeProfile up -d
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to start Docker services"
        }
        
        Write-Success "Docker services started successfully (profile: $composeProfile)"
    }
    catch {
        Write-ErrorMessage "Failed to start Docker services: $($_.Exception.Message)"
        exit 1
    }

    if (-not $SkipWait) {
        # Wait for services to be ready
        Write-Step "Waiting for services to become ready..."
        
        $containerName = if ($ImageVariant -eq 'debian') { "sftp-server (Debian)" } else { "sftp-server-alpine (Alpine)" }
        $port = 2222  # Fixed port for both variants
        
        $serviceReady = Test-SftpServiceHealth -ContainerName $containerName -Port $port
        
        if (-not $serviceReady) {
            Write-ErrorMessage "Service failed to start properly"
            if (-not $SkipDockerCleanup) {
                Write-Step "Cleaning up Docker services..."
                docker compose down -v
            }
            exit 1
        }
        
        Write-Success "Service is ready!"
    } else {
        Write-Warning "Skipping service readiness check (assuming services are already running)"
    }

    # Run Pester tests
    Write-Step "Running Pester integration tests..."
    Write-Host ""
    
    if (-not (Test-Path $TestPath)) {
        Write-ErrorMessage "Test path not found: $TestPath"
        exit 1
    }

    try {
        $pesterConfig = New-PesterConfiguration
        $pesterConfig.Run.Path = $TestPath
        $pesterConfig.Output.Verbosity = 'Detailed'
        $pesterConfig.Run.Exit = $false
        $pesterConfig.Run.PassThru = $true
        
        # Pass the image variant as a parameter
        $container = New-PesterContainer -Path $TestPath -Data @{ ImageVariant = $ImageVariant }
        $pesterConfig.Run.Container = $container
        
        $result = Invoke-Pester -Configuration $pesterConfig
        
        Write-Host ""
        if ($result -and $result.FailedCount -eq 0) {
            Write-Success "All integration tests passed! 🎉"
            $exitCode = 0
        } elseif ($result) {
            Write-ErrorMessage "$($result.FailedCount) test(s) failed out of $($result.TotalCount) total tests"
            $exitCode = 1
        } else {
            Write-Warning "Could not determine test results"
            $exitCode = 1
        }
    }
    catch {
        Write-ErrorMessage "Failed to run Pester tests: $($_.Exception.Message)"
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
        $exitCode = 1
    }
}
catch {
    Write-ErrorMessage "Unexpected error: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    $exitCode = 1
}
finally {
    # Cleanup Docker services
    if (-not $SkipDockerCleanup) {
        Write-Step "Cleaning up Docker services..."
        try {
            docker compose down -v 2>$null
            Write-Success "Docker services stopped and cleaned up"
        }
        catch {
            Write-Warning "Failed to clean up Docker services: $($_.Exception.Message)"
        }
    } else {
        Write-Warning "Skipping Docker cleanup (services left running for debugging)"
        Write-Host "To manually stop services, run: docker compose down -v" -ForegroundColor Gray
    }
    
    Write-Host ""
    Write-Host "=================================================" -ForegroundColor $Colors.Info
    if ($exitCode -eq 0) {
        Write-Host "🏁 Integration tests completed successfully!" -ForegroundColor $Colors.Success
    } else {
        Write-Host "🏁 Integration tests completed with failures!" -ForegroundColor $Colors.Error
    }
    Write-Host ""
}

exit $exitCode

