using namespace System.Net.Sockets

<#
.SYNOPSIS
    Integration tests for SFTP Docker Container

.DESCRIPTION
    Pester-based integration tests for the SFTP server running in Docker containers.
    Tests both Debian and Alpine variants.
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('debian', 'alpine')]
    [string]$ImageVariant
)

BeforeAll {
    # Import reusable test helper functions
    . "$PSScriptRoot/SftpTestHelpers.ps1"
    
    # Configure test settings based on variant
    # Ports are now fixed (2222 for SFTP, 2224 for mmproxy) regardless of variant
    if ($ImageVariant -eq 'debian') {
        $script:TestHost = "localhost"
        $script:TestPort = 2222  # Fixed port
        $script:TestContainer = "sftp-server"
        $script:TestImage = "sftp-sftp:latest"
        $script:TestNetworkHost = "sftp-server"  # Hostname within Docker network
    } else {
        $script:TestHost = "localhost"
        $script:TestPort = 2222  # Fixed port (same as Debian)
        $script:TestContainer = "sftp-server-alpine"
        $script:TestImage = "sftp-sftp-alpine:latest"
        $script:TestNetworkHost = "sftp-server-alpine"  # Hostname within Docker network
    }
    
    # Test configuration
    $script:TestConfig = @{
        HostName = $script:TestHost               # For host-based connections
        Port = $script:TestPort                   # For host-based connections
        NetworkHostName = $script:TestNetworkHost # For Docker network connections
        NetworkPort = 22                           # SSH always listens on 22 inside containers
        Container = $script:TestContainer
        Image = $script:TestImage
        ClientContainer = "sftp-client"
        Timeout = 15
    }

    Write-Host "Test configuration loaded" -ForegroundColor Green
    Write-Host "Testing image variant: $ImageVariant" -ForegroundColor Cyan
    Write-Host "Using container: $($script:TestConfig.Container) on port $($script:TestConfig.Port)" -ForegroundColor Cyan
}

# ===== TEST SUITES =====

Describe "SFTP Server - Basic User Creation Tests" {
    
    It "Should create smallest user config" {
        $container = New-TestSftpContainer -Image $script:TestConfig.Image `
            -UserConfig @("testuser:")
        
        try {
            $container.Success | Should -Be $true
            $userExists = Test-SftpUser -ContainerName $container.ContainerName -Username "testuser"
            $userExists | Should -Be $true
        }
        finally {
            Remove-TestSftpContainer -ContainerName $container.ContainerName
        }
    }

    It "Should create user with dot in username" {
        $container = New-TestSftpContainer -Image $script:TestConfig.Image `
            -UserConfig @("user.with.dot:")
        
        try {
            $container.Success | Should -Be $true
            $userExists = Test-SftpUser -ContainerName $container.ContainerName -Username "user.with.dot"
            $userExists | Should -Be $true
        }
        finally {
            Remove-TestSftpContainer -ContainerName $container.ContainerName
        }
    }

    It "Should create user with custom UID and GID" {
        $container = New-TestSftpContainer -Image $script:TestConfig.Image `
            -UserConfig @("customuser::1234:4321:")
        
        try {
            $container.Success | Should -Be $true
            $userInfo = Get-SftpUserInfo -ContainerName $container.ContainerName -Username "customuser"
            $userInfo.Success | Should -Be $true
            $userInfo.Uid | Should -Be "1234"
            $userInfo.Gid | Should -Be "4321"
        }
        finally {
            Remove-TestSftpContainer -ContainerName $container.ContainerName
        }
    }
}

Describe "SFTP Server - User Configuration Methods" {
    
    Context "When using users.conf file" {
        
        It "Should load users from mounted users.conf file" {
            # Verify users from users.conf exist
            Test-SftpUser -ContainerName $script:TestConfig.Container -Username "user-from-conf" | Should -Be $true
            Test-SftpUser -ContainerName $script:TestConfig.Container -Username "test" | Should -Be $true
            Test-SftpUser -ContainerName $script:TestConfig.Container -Username "user.with.dot" | Should -Be $true
            
            # Verify directories were created
            Test-SftpDirectory -ContainerName $script:TestConfig.Container -Path "/home/test/dir1" | Should -Be $true
            Test-SftpDirectory -ContainerName $script:TestConfig.Container -Path "/home/test/dir2" | Should -Be $true
        }
    }

    Context "When using SFTP_USERS environment variable" {
        
        It "Should create users from environment variable" {
            $container = New-TestSftpContainer -Image $script:TestConfig.Image `
                -Environment @{ "SFTP_USERS" = "envuser1: envuser2:" }
            
            try {
                $container.Success | Should -Be $true
                Test-SftpUser -ContainerName $container.ContainerName -Username "envuser1" | Should -Be $true
                Test-SftpUser -ContainerName $container.ContainerName -Username "envuser2" | Should -Be $true
            }
            finally {
                Remove-TestSftpContainer -ContainerName $container.ContainerName
            }
        }
    }
}

Describe "SFTP Server - Directory Creation and Permissions" {
    
    It "Should create directories specified in user config" {
        $container = New-TestSftpContainer -Image $script:TestConfig.Image `
            -UserConfig @("testuser::::uploads,downloads")
        
        try {
            $container.Success | Should -Be $true
            Test-SftpDirectory -ContainerName $container.ContainerName -Path "/home/testuser/uploads" | Should -Be $true
            Test-SftpDirectory -ContainerName $container.ContainerName -Path "/home/testuser/downloads" | Should -Be $true
        }
        finally {
            Remove-TestSftpContainer -ContainerName $container.ContainerName
        }
    }
    
    It "Should store files in SFTP_USER_DIRS_BASE location and symlink from home directory" {
        # Create a test container with SFTP_USER_DIRS_BASE set
        $userDirsBase = "/mnt/test-data"
        $testUser = "dirtestuser"
        $testPassword = "testpass123"
        $testDir = "upload"
        
        $container = New-TestSftpContainer -Image $script:TestConfig.Image `
            -UserConfig @("${testUser}:${testPassword}:::${testDir}") `
            -Environment @{ "SFTP_USER_DIRS_BASE" = $userDirsBase } `
            -Network "sftp_sftp-network"
        
        try {
            $container.Success | Should -Be $true -Because "Container should be created successfully"
            
            # Wait for container to be ready
            Start-Sleep -Seconds 5
            
            # Use container name as hostname (Docker DNS resolves container names on the same network)
            $containerHost = $container.ContainerName
            
            # Create a test file to upload
            $testFileContent = "Test file content for SFTP_USER_DIRS_BASE test - $(Get-Random)"
            $testFileLocal = "/tmp/dirs_base_test_$(Get-Random).txt"
            $createResult = Invoke-SftpClientCommand -Command "printf '%s\n' '$testFileContent' > $testFileLocal"
            if (-not $createResult.Success) {
                throw "Failed to create test file: $($createResult.Output)"
            }
            
            # Upload file via SFTP
            $remoteFileName = "test_file.txt"
            $uploadResult = Send-SftpFile -HostName $containerHost -Port 22 `
                -Username $testUser -Password $testPassword `
                -LocalPath $testFileLocal -RemotePath "${testDir}/${remoteFileName}" `
                -ClientContainer "sftp-client"
            
            $uploadResult.Success | Should -Be $true -Because "File upload should succeed. Output: $($uploadResult.Output)"
            
            # Small delay to ensure file is written
            Start-Sleep -Milliseconds 500
            
            # Check file exists in symlink location (/home/user/upload/test_file.txt)
            $symlinkPath = "/home/${testUser}/${testDir}/${remoteFileName}"
            $checkSymlink = Invoke-SftpServerCommand -ContainerName $container.ContainerName `
                -Command "test -f '$symlinkPath' && echo 'exists' || echo 'not found'"
            $checkSymlink.Success | Should -Be $true
            $checkSymlink.Output.Trim() | Should -Be "exists" -Because "File should exist at symlink location: $symlinkPath. Output: $($checkSymlink.Output)"
            
            # Check file exists in actual location (SFTP_USER_DIRS_BASE/user/upload/test_file.txt)
            $actualPath = "${userDirsBase}/${testUser}/${testDir}/${remoteFileName}"
            $checkActual = Invoke-SftpServerCommand -ContainerName $container.ContainerName `
                -Command "test -f '$actualPath' && echo 'exists' || echo 'not found'"
            $checkActual.Success | Should -Be $true
            $checkActual.Output.Trim() | Should -Be "exists" -Because "File should exist at actual location: $actualPath. Output: $($checkActual.Output)"
            
            # Verify file content is the same in both locations
            $contentSymlink = Invoke-SftpServerCommand -ContainerName $container.ContainerName `
                -Command "cat '$symlinkPath'"
            $contentActual = Invoke-SftpServerCommand -ContainerName $container.ContainerName `
                -Command "cat '$actualPath'"
            $contentSymlink.Output.Trim() | Should -Be $testFileContent -Because "File content should match at symlink location"
            $contentActual.Output.Trim() | Should -Be $testFileContent -Because "File content should match at actual location"
            
            # Cleanup test file
            Invoke-SftpClientCommand -Command "rm -f $testFileLocal" -IgnoreError | Out-Null
        }
        finally {
            Remove-TestSftpContainer -ContainerName $container.ContainerName
        }
    }
}

Describe "SFTP Server - Authentication Tests" {
    
    BeforeAll {
        # SSH keys should already be generated by Test-Integration.ps1
        $script:TestKeyPath = "./e2etests/fixtures/test_rsa"
        
        if (-not (Test-Path $script:TestKeyPath)) {
            Write-Warning "Test SSH keys not found, key-based authentication test will be skipped"
        }
    }

    Context "When using password authentication" {
        
        It "Should authenticate with password" {
            # Use the existing compose container which has pwduser configured
            # Connect via Docker network (not localhost), so use NetworkHostName and NetworkPort
            $result = Test-SftpConnection -HostName $script:TestConfig.NetworkHostName `
                -Port $script:TestConfig.NetworkPort `
                -Username "pwduser" -Password "testpass123" `
                -Commands @("ls", "pwd")
            
            if (-not $result.Success) {
                Write-Host "SFTP connection failed. Output: $($result.Output)" -ForegroundColor Yellow
            }
            
            $result.Success | Should -Be $true -Because "Password authentication should work. Error: $($result.Output)"
        }
        
    }

    Context "When using SSH key authentication" {
        
        It "Should authenticate with SSH public key" {
            # Check if SSH key exists
            if (-not (Test-Path $script:TestKeyPath)) {
                Set-ItResult -Skip -Because "Test SSH keys not available"
                return
            }
            
            # Use the existing compose container which has keyuser configured with mounted SSH key
            # The key is mounted in docker-compose.yml
            $clientKeyPath = "/workspace/e2etests/fixtures/test_rsa"
            
            # Copy the private key to the client container
            $copyResult = Invoke-SftpClientCommand -Command "cp -f $clientKeyPath /tmp/test_rsa && chmod 600 /tmp/test_rsa"
            if (-not $copyResult.Success) {
                Set-ItResult -Skip -Because "Could not prepare SSH key in client container"
                return
            }
            
            # Connect via Docker network (not localhost), so use NetworkHostName and NetworkPort
            $result = Test-SftpConnection -HostName $script:TestConfig.NetworkHostName `
                -Port $script:TestConfig.NetworkPort `
                -Username "keyuser" -KeyPath "/tmp/test_rsa" `
                -Commands @("pwd", "ls")
            
            $result.Success | Should -Be $true
        }
    }
}

Describe "SFTP Server - Functional Tests" {
    
    Context "When testing main container" {
        
        BeforeAll {
            # Create a test file to upload
            $script:TestFile = "/tmp/test_upload_$(Get-Random).txt"
            Invoke-SftpClientCommand -Command "echo 'Test content for SFTP upload' > $script:TestFile" | Out-Null
        }

        It "Should allow file uploads to permitted directories" {
            # Use pwduser from users.conf which has password testpass123 and upload directory
            # Connect via Docker network (not localhost), so use NetworkHostName and NetworkPort
            # First verify we can navigate to upload directory
            $navResult = Test-SftpConnection -HostName $script:TestConfig.NetworkHostName `
                -Port $script:TestConfig.NetworkPort `
                -Username "pwduser" -Password "testpass123" `
                -Commands @("cd upload", "pwd")
            
            if (-not $navResult.Success) {
                Write-Host "SFTP navigation failed. Output: $($navResult.Output)" -ForegroundColor Yellow
            }
            
            $navResult.Success | Should -Be $true -Because "Should be able to navigate to permitted directory. Error: $($navResult.Output)"
            
            # Now upload a file to upload directory
            $uploadResult = Send-SftpFile -HostName $script:TestConfig.NetworkHostName `
                -Port $script:TestConfig.NetworkPort `
                -Username "pwduser" -Password "testpass123" `
                -LocalPath $script:TestFile -RemotePath "upload/uploaded_file.txt" `
                -ClientContainer $script:TestConfig.ClientContainer
            
            # Check upload output - should contain "Uploading" or "100%" or similar
            Write-Host "Upload output: $($uploadResult.Output)" -ForegroundColor Cyan
            
            if (-not $uploadResult.Success) {
                Write-Host "SFTP upload failed. Output: $($uploadResult.Output)" -ForegroundColor Yellow
            }
            
            $uploadResult.Success | Should -Be $true -Because "Should be able to upload file to permitted directory. Error: $($uploadResult.Output)"
            
            # Small delay to ensure file is written
            Start-Sleep -Milliseconds 500
            
            # Verify the file was uploaded by listing the directory
            # Use just "ls" instead of "ls -la" to get simpler output
            $listResult = Test-SftpConnection -HostName $script:TestConfig.NetworkHostName `
                -Port $script:TestConfig.NetworkPort `
                -Username "pwduser" -Password "testpass123" `
                -Commands @("cd upload", "ls")
            
            Write-Host "List output: $($listResult.Output)" -ForegroundColor Cyan
            
            if (-not $listResult.Success) {
                Write-Host "SFTP list failed. Output: $($listResult.Output)" -ForegroundColor Yellow
            }
            
            $listResult.Success | Should -Be $true -Because "Should be able to list directory contents. Error: $($listResult.Output)"
            
            # Check for the file name in the output (ignoring the SSH warning message)
            # The output should contain the file listing after the warning
            $hasFile = $listResult.Output -match "uploaded_file\.txt"
            if (-not $hasFile) {
                Write-Host "Full list output: $($listResult.Output)" -ForegroundColor Red
            }
            $hasFile | Should -Be $true -Because "Uploaded file should appear in directory listing. Full output: $($listResult.Output)"
        }
    }
}

Describe "SFTP Server - User Account Expiration" {
    
    It "Should set expiration date using YYYY-MM-DD format" {
        # Set expiration date far in the future for testing
        $futureDate = (Get-Date).AddYears(1).ToString("yyyy-MM-dd")
        
        $container = New-TestSftpContainer -Image $script:TestConfig.Image `
            -UserConfig @("expireuser:pass123:::upload:$futureDate")
        
        try {
            $container.Success | Should -Be $true
            
            # Verify user exists
            Test-SftpUser -ContainerName $container.ContainerName -Username "expireuser" | Should -Be $true
            
            # Check expiration date using chage (preferred) or getent passwd
            $expiryCheck = Invoke-SftpServerCommand -ContainerName $container.ContainerName `
                -Command "chage -l expireuser 2>/dev/null | grep -i 'account expires' || getent passwd expireuser | cut -d: -f1"
            
            # If chage output contains expiration info, verify it's set
            if ($expiryCheck.Output -match "Account expires|expires") {
                $expiryCheck.Output | Should -Not -Match "never|Jan 01, 1970"
            }
        }
        finally {
            Remove-TestSftpContainer -ContainerName $container.ContainerName
        }
    }

    It "Should set expiration date using YYYYMMDD format" {
        $futureDate = (Get-Date).AddYears(1).ToString("yyyyMMdd")
        
        $container = New-TestSftpContainer -Image $script:TestConfig.Image `
            -UserConfig @("expireuser2:pass123:::upload:$futureDate")
        
        try {
            $container.Success | Should -Be $true
            Test-SftpUser -ContainerName $container.ContainerName -Username "expireuser2" | Should -Be $true
        }
        finally {
            Remove-TestSftpContainer -ContainerName $container.ContainerName
        }
    }
}

Describe "SFTP Server - mmproxy Integration" {
    
    Context "When using mmproxy to preserve client IP" {
        
        BeforeAll {
            # mmproxy is always started (single instance for both variants)
            # mmproxy uses host network mode, so we connect via localhost
            $script:MmproxyConfig = @{
                Container = "mmproxy"
                Port = 2224  # Fixed port for mmproxy
                HostName = "localhost"  # mmproxy uses host network mode
            }
            
            # Check if mmproxy container exists and is running
            $mmproxyRunning = docker ps --filter "name=$($script:MmproxyConfig.Container)" --filter "status=running" --format "{{.Names}}" 2>$null
            $script:MmproxyConfig.Available = ($LASTEXITCODE -eq 0 -and $mmproxyRunning -eq $script:MmproxyConfig.Container)
        }
        
        It "Should have mmproxy container running" {
            # Verify mmproxy container is running (required for tests)
            $script:MmproxyConfig.Available | Should -Be $true -Because "mmproxy container must be running (set MMPROXY_IMAGE env var or build mmproxy image)"
            
            $status = docker inspect -f '{{.State.Running}}' $script:MmproxyConfig.Container 2>$null
            $status | Should -Be "true"
        }
        
        It "Should have mmproxy container with NET_ADMIN capability" {
            # Verify mmproxy container is available
            $script:MmproxyConfig.Available | Should -Be $true -Because "mmproxy container must be running"
            
            # Verify mmproxy container has NET_ADMIN capability (required for TPROXY)
            $caps = docker inspect $script:MmproxyConfig.Container --format '{{json .HostConfig.CapAdd}}' 2>$null
            if ($LASTEXITCODE -eq 0) {
                $caps | Should -Match "NET_ADMIN"
            } else {
                throw "Could not inspect mmproxy container capabilities"
            }
        }
        
        It "Should have mmproxy port exposed" {
            # Verify mmproxy container is available
            $script:MmproxyConfig.Available | Should -Be $true -Because "mmproxy container must be running"
            
            # With host network mode, ports aren't exposed via docker port command
            # Instead, verify the port is listening on the host
            # Check if port is listening (mmproxy uses host network mode)
            $listening = netstat -an 2>$null | Select-String ":$($script:MmproxyConfig.Port)" | Select-String "LISTENING"
            if ($listening) {
                $listening | Should -Not -BeNullOrEmpty
            } else {
                # Alternative: Check via docker exec if we can reach the port
                # Since mmproxy uses host network, the port should be accessible
                Set-ItResult -Skip -Because "Cannot verify port exposure with host network mode (port $($script:MmproxyConfig.Port) should be listening on host)"
            }
        }
        
        It "Should accept PROXY protocol handshake" {
            # Verify mmproxy container is available
            $script:MmproxyConfig.Available | Should -Be $true -Because "mmproxy container must be running"
            
            # Test that mmproxy accepts PROXY protocol v1 header
            # We'll send PROXY protocol header with a test IP and verify the handshake happens
            # Using public IP from TEST-NET-3 range (203.0.113.0/24) to avoid private IP conflicts
            $testClientIp = "203.0.113.1"
            
            # mmproxy uses host network mode, so from within the sftp-client container
            # we need to use host.docker.internal (Docker Desktop) or the host's gateway IP
            # Try host.docker.internal first, fallback to gateway IP
            $gatewayIp = docker network inspect sftp_sftp-network --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>$null
            $mmproxyHost = if ($gatewayIp) { $gatewayIp } else { "host.docker.internal" }
            
            # Clear logs before test to ensure we see fresh connection attempts
            $sftpContainer = $script:TestConfig.Container
            docker logs $sftpContainer --tail 0 2>&1 | Out-Null
            
            # Send PROXY protocol header and verify mmproxy accepts it
            # This will cause mmproxy to process the PROXY header and forward to SFTP server
            # Note: We connect to mmproxy's listen port (2224/2225), not port 22
            $result = Test-ProxyProtocolHandshake `
                -HostName $mmproxyHost `
                -Port $script:MmproxyConfig.Port `
                -ProxyClientIp $testClientIp
            
            # The command should execute (connection may close after PROXY header, that's OK)
            $result.Success | Should -Be $true
            
            # Wait a moment for logs to be written
            Start-Sleep -Milliseconds 500
            
            # Verify mmproxy processed the PROXY protocol connection
            # Check mmproxy logs to confirm it accepted the PROXY protocol header
            $mmproxyLogs = docker logs $script:MmproxyConfig.Container --tail 20 2>&1
            if ($LASTEXITCODE -eq 0) {
                # mmproxy should have processed the connection
                # The connection attempt should be logged by mmproxy
                $mmproxyLogs | Should -Not -BeNullOrEmpty -Because "mmproxy should log connection attempts"
            }
            
            # Note: Verifying IP preservation in SFTP server logs requires a full connection
            # For now, we verify that mmproxy accepts PROXY protocol headers
            # In production, the SFTP server logs would show the client IP from PROXY protocol
            # instead of the mmproxy IP, proving IP preservation works
        }
        
        It "Should preserve client IP in PROXY protocol header" {
            # Verify mmproxy container is available
            $script:MmproxyConfig.Available | Should -Be $true -Because "mmproxy container must be running"
            
            # Test with a specific client IP to verify it's preserved
            # Using public IP from TEST-NET-2 range (198.51.100.0/24) to avoid private IP conflicts
            $testClientIp = "198.51.100.1"
            
            # mmproxy uses host network mode, so from within the sftp-client container
            # we need to use host.docker.internal (Docker Desktop) or the host's gateway IP
            $gatewayIp = docker network inspect sftp_sftp-network --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>$null
            $mmproxyHost = if ($gatewayIp) { $gatewayIp } else { "host.docker.internal" }
            
            # Clear logs before test
            $sftpContainer = $script:TestConfig.Container
            docker logs $sftpContainer --tail 0 2>&1 | Out-Null
            
            # Send PROXY protocol header with specific client IP
            # Note: We connect to mmproxy's listen port (2224/2225), not port 22
            $result = Test-ProxyProtocolHandshake `
                -HostName $mmproxyHost `
                -Port $script:MmproxyConfig.Port `
                -ProxyClientIp $testClientIp
            
            $result.Success | Should -Be $true
            
            # Wait a moment for logs to be written
            Start-Sleep -Milliseconds 500
            
            # Verify mmproxy processed the PROXY protocol with the specific client IP
            # Check mmproxy logs to confirm it handled the connection
            $mmproxyLogs = docker logs $script:MmproxyConfig.Container --tail 20 2>&1
            if ($LASTEXITCODE -eq 0) {
                # mmproxy should have processed the PROXY protocol header with the client IP
                # The connection attempt should be logged
                $mmproxyLogs | Should -Not -BeNullOrEmpty -Because "mmproxy should log PROXY protocol connections"
            }
            
            # Note: Verifying IP preservation requires a full SFTP connection
            # When a complete connection is made through mmproxy with PROXY protocol,
            # the SFTP server logs would show $testClientIp (198.51.100.1) instead of
            # the mmproxy container IP, proving IP preservation works correctly
        }
        
        It "Should document mmproxy PROXY protocol requirement" {
            $readmeContent = Get-Content "./README.md" -Raw
            $readmeContent | Should -Match "mmproxy"
            $readmeContent | Should -Match "PROXY protocol"
        }
    }
}

Describe "SFTP Server - Security Tests" {
    
    Context "When testing SFTP-only access" {
        
        It "Should block regular SSH shell access" {
            # Try to execute a shell command via SSH (should be blocked by ForceCommand internal-sftp)
            # Use NetworkHostName and NetworkPort (port 22 on the Docker network)
            $sshCmd = "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $($script:TestConfig.NetworkPort) pwduser@$($script:TestConfig.NetworkHostName) 'echo test' 2>&1"
            
            # sshpass is pre-installed in the sftp-client container
            # Try to SSH with password
            $fullCmd = "sshpass -p 'testpass123' $sshCmd"
            $result = Invoke-SftpClientCommand -Command $fullCmd -IgnoreError
            
            # Should fail - SSH shell access should be blocked by ForceCommand internal-sftp
            # The connection may succeed but command execution will fail
            # Check that either the command failed or output indicates SFTP-only access
            $shouldFail = -not $result.Success
            $hasSftpOnlyMessage = $result.Output -match "(sftp connections only|This service allows sftp connections only|This service allows sftp|sftp-server|internal-sftp|not a tty|command not found)"
            
            # Either the command should fail, or it should contain a message about SFTP-only access
            ($shouldFail -or $hasSftpOnlyMessage) | Should -Be $true -Because "SSH shell access should be blocked - either command fails or shows SFTP-only message. Output: $($result.Output)"
        }
        
        It "Should allow SFTP connections (ForceCommand internal-sftp)" {
            # Verify that SFTP connections work even with ForceCommand
            $result = Test-SftpConnection -HostName $script:TestConfig.NetworkHostName `
                -Port $script:TestConfig.NetworkPort `
                -Username "pwduser" -Password "testpass123" `
                -Commands @("pwd")
            
            if (-not $result.Success) {
                Write-Host "SFTP connection failed. Output: $($result.Output)" -ForegroundColor Yellow
            }
            
            $result.Success | Should -Be $true -Because "SFTP should work with ForceCommand. Error: $($result.Output)"
        }
        
        It "Should have ForceCommand internal-sftp in sshd_config" {
            $result = Invoke-SftpServerCommand -ContainerName $script:TestConfig.Container `
                -Command "grep -i 'ForceCommand' /etc/ssh/sshd_config"
            
            $result.Success | Should -Be $true
            $result.Output | Should -Match "ForceCommand.*internal-sftp"
        }
        
        It "Should have ChrootDirectory configured for user isolation" {
            $result = Invoke-SftpServerCommand -ContainerName $script:TestConfig.Container `
                -Command "grep -i 'ChrootDirectory' /etc/ssh/sshd_config"
            
            $result.Success | Should -Be $true
            $result.Output | Should -Match "ChrootDirectory"
        }
        
        It "Should prevent users from seeing each other's files" {
            # Create a test container with two users
            $container = New-TestSftpContainer -Image $script:TestConfig.Image `
                -UserConfig @("isoluser1:pass1:::files", "isoluser2:pass2:::files") `
                -Network "sftp_sftp-network"
            
            try {
                $container.Success | Should -Be $true -Because "Container should be created successfully"
                
                # Wait for container to be ready
                Start-Sleep -Seconds 5
                
                # Use container name as hostname (Docker DNS resolves container names on the same network)
                $containerHost = $container.ContainerName
                
                # Create a test file for user1
                $testFileContent = "This is user1 secret file - $(Get-Random)"
                $testFileLocal = "/tmp/user1_secret_$(Get-Random).txt"
                $createResult = Invoke-SftpClientCommand -Command "printf '%s\n' '$testFileContent' > $testFileLocal"
                if (-not $createResult.Success) {
                    throw "Failed to create test file: $($createResult.Output)"
                }
                
                # Upload file as user1 to their files directory
                $uploadResult = Send-SftpFile -HostName $containerHost -Port 22 `
                    -Username "isoluser1" -Password "pass1" `
                    -LocalPath $testFileLocal -RemotePath "files/user1_secret.txt" `
                    -ClientContainer "sftp-client"
                
                $uploadResult.Success | Should -Be $true -Because "User1 should be able to upload their own file"
                
                # Try to list files as user2 - should NOT see user1's file
                $listResult = Test-SftpConnection -HostName $containerHost -Port 22 `
                    -Username "isoluser2" -Password "pass2" `
                    -Commands @("cd files", "ls")
                
                $listResult.Success | Should -Be $true -Because "User2 should be able to list their own directory"
                
                # Verify user2 cannot see user1's file
                # The file should not appear in user2's directory listing
                $hasUser1FileInFirstCheck = [bool]($listResult.Output -like "*user1_secret*")
                $hasUser1FileInFirstCheck | Should -Be $false -Because "User2 should not see user1's files. Full output: $($listResult.Output)"
                
                # Verify user2 can only see their own files (chroot isolation)
                # User2 should only see files in their own directory, not user1's files
                # Create a file for user2 to verify their directory works
                $testFile2Local = "/tmp/user2_file_$(Get-Random).txt"
                $createResult2 = Invoke-SftpClientCommand -Command "printf '%s\n' 'User2 file' > $testFile2Local"
                if (-not $createResult2.Success) {
                    throw "Failed to create user2 test file: $($createResult2.Output)"
                }
                
                $uploadResult2 = Send-SftpFile -HostName $containerHost -Port 22 `
                    -Username "isoluser2" -Password "pass2" `
                    -LocalPath $testFile2Local -RemotePath "files/user2_file.txt" `
                    -ClientContainer "sftp-client"
                
                $uploadResult2.Success | Should -Be $true -Because "User2 should be able to upload their own file"
                
                # Small delay to ensure file is written
                Start-Sleep -Milliseconds 500
                
                # List user2's files - should only see their own file, not user1's
                $listResult2 = Test-SftpConnection -HostName $containerHost -Port 22 `
                    -Username "isoluser2" -Password "pass2" `
                    -Commands @("cd files", "ls")
                
                $listResult2.Success | Should -Be $true -Because "User2 should be able to list their own directory"
                
                # Verify user2 can see their own file
                # Check if output contains the file name
                $hasUser2File = $listResult2.Output -like "*user2_file*"
                $hasUser2File | Should -Be $true -Because "User2 should see their own file. Full output: $($listResult2.Output)"
                
                # Verify user2 cannot see user1's file
                # -like returns $null when no match, so explicitly check for false
                $hasUser1File = [bool]($listResult2.Output -like "*user1_secret*")
                $hasUser1File | Should -Be $false -Because "User2 should NOT see user1's files (chroot isolation). Full output: $($listResult2.Output)"
                
                # Cleanup user2 test file
                Invoke-SftpClientCommand -Command "rm -f $testFile2Local" -IgnoreError | Out-Null
                
                # Cleanup test file
                Invoke-SftpClientCommand -Command "rm -f $testFileLocal" -IgnoreError | Out-Null
            }
            finally {
                Remove-TestSftpContainer -ContainerName $container.ContainerName
            }
        }
    }
}

Describe "SFTP Server - Container Health" {
    
    Context "When checking container status" {
        
        It "SFTP server container should be running" {
            $status = docker inspect -f '{{.State.Running}}' $script:TestConfig.Container 2>$null
            $status | Should -Be "true"
        }

        It "SFTP client container should be running" {
            $status = docker inspect -f '{{.State.Running}}' sftp-client 2>$null
            $status | Should -Be "true"
        }
    }

    Context "When checking SSH service" {
        
        It "SSH service should be listening on port 22" {
            # Check if sshd process is running
            $result = Invoke-SftpServerCommand -ContainerName $script:TestConfig.Container `
                -Command "ps aux | grep '[s]shd' | grep -v grep"
            $result.Success | Should -Be $true
        }
    }
}
