# End-to-End Tests

This directory contains integration tests for the SFTP Docker containers using PowerShell and Pester.

## Structure

```
e2etests/
├── README.md                        # This file
├── SftpTestHelpers.ps1             # Reusable helper functions
├── integration-tests.Tests.ps1     # Main integration test suite
├── fixtures/                        # Test configuration files
│   └── users.conf                   # Sample user configuration for testing
└── testdata/                        # Directory for test data files
```

## Adding New Test Suites

To create a new test suite:

1. Create a new `.Tests.ps1` file in this directory (e.g., `security-tests.Tests.ps1`)
2. Import the helper functions at the beginning:

```powershell
BeforeAll {
    # Import reusable test helper functions
    . "$PSScriptRoot/SftpTestHelpers.ps1"
}
```

3. Write your Pester tests using the available helper functions

## Available Helper Functions

### Container Command Execution

- **`Invoke-SftpClientCommand`** - Execute commands in the SFTP client container
- **`Invoke-SftpServerCommand`** - Execute commands in the SFTP server container

### SSH Key Management

- **`New-TestSshKey`** - Generate SSH key pairs for testing

### SFTP Operations

- **`Test-SftpConnection`** - Test SFTP connection and execute commands
- **`Send-SftpFile`** - Upload a file via SFTP
- **`Get-SftpFile`** - Download a file via SFTP

### User and Directory Management

- **`Test-SftpUser`** - Check if a user exists in the container
- **`Test-SftpDirectory`** - Check if a directory exists in the container
- **`Test-SftpFile`** - Check if a file exists in the container
- **`Get-SftpUserInfo`** - Get user information (UID, GID, etc.)

### Container Management

- **`New-TestSftpContainer`** - Create a temporary container for testing
- **`Remove-TestSftpContainer`** - Remove a test container
- **`Get-ContainerSshPort`** - Get the SSH port for a container
- **`Get-ContainerIpAddress`** - Get the IP address of a container

### File Operations

- **`New-TestFile`** - Create a temporary test file in the client container
- **`Get-ContainerFileContent`** - Read file content from a container

## Example Test Suite

```powershell
BeforeAll {
    # Import helper functions
    . "$PSScriptRoot/SftpTestHelpers.ps1"
    
    # Test configuration
    $script:TestConfig = @{
        DebianHost = "localhost"
        DebianPort = 2222
    }
}

Describe "My Custom Tests" {
    Context "When testing user creation" {
        It "Should create a user with custom configuration" {
            $container = New-TestSftpContainer -Image "david-garcia-garcia/sftp:latest" `
                -UserConfig @("testuser:password:1000:1000:")
            
            try {
                $container.Success | Should -Be $true
                $userExists = Test-SftpUser -ContainerName $container.ContainerName `
                    -Username "testuser"
                $userExists | Should -Be $true
            }
            finally {
                Remove-TestSftpContainer -ContainerName $container.ContainerName
            }
        }
    }
}
```

## Running Tests

From the repository root:

```powershell
# Run all tests
./Test-Integration.ps1

# Run specific test file
./Test-Integration.ps1 -TestPath "./e2etests/my-custom-tests.Tests.ps1"

# Run tests for specific variant
./Test-Integration.ps1 -ImageVariant debian

# Keep services running after tests for debugging
./Test-Integration.ps1 -SkipDockerCleanup
```

## Test Best Practices

1. **Always clean up** - Use `try/finally` blocks to ensure test containers are removed
2. **Use descriptive names** - Make test descriptions clear and specific
3. **Test both variants** - Use `-Skip:($ImageVariant -eq 'alpine')` to run tests per variant
4. **Reuse helpers** - Don't duplicate logic; use or extend the helper functions
5. **Document complex tests** - Add comments explaining non-obvious test logic

## Debugging Tips

### Keep Services Running

Use `-SkipDockerCleanup` to keep containers running after tests:

```powershell
./Test-Integration.ps1 -SkipDockerCleanup
```

Then inspect manually:

```bash
docker ps
docker logs sftp-server
docker exec -it sftp-server sh
```

### View Container Logs

```bash
docker compose logs sftp
docker compose logs sftp-alpine
docker compose logs sftp-client
```

### Connect to Client Container

```bash
docker exec -it sftp-client sh
```

### Test SFTP Connection Manually

From within the client container:

```bash
sftp -P 22 -o StrictHostKeyChecking=no testuser@sftp-server
```

## Contributing

When adding new helper functions:

1. Add them to `SftpTestHelpers.ps1`
2. Use proper PowerShell cmdlet naming conventions (Verb-Noun)
3. Add comprehensive documentation with `.SYNOPSIS`, `.PARAMETER`, and `.OUTPUTS`
4. Include parameter validation where appropriate
5. Update this README with a brief description of the new function

