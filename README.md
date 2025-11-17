# SFTP

> This is a fork of [atmoz/sftp](https://github.com/atmoz/sftp) with the following enhancements:
> - **User expiration**: Support for account expiration dates in `YYYY-MM-DD` or `YYYYMMDD` format
> - **Improved environment configuration**: All SSHD settings configurable via environment variables
> - **Template-based configuration**: `sshd_config` generated from template with `envsubst`

![GitHub Workflow Status](https://img.shields.io/github/actions/workflow/status/david-garcia-garcia/sftp/build.yml?logo=github) ![GitHub stars](https://img.shields.io/github/stars/david-garcia-garcia/sftp?logo=github) ![Docker Stars](https://img.shields.io/docker/stars/davidbcn86/sftp?label=stars&logo=docker) ![Docker Pulls](https://img.shields.io/docker/pulls/davidbcn86/sftp?label=pulls&logo=docker)

![OpenSSH logo](https://raw.githubusercontent.com/david-garcia-garcia/sftp/master/openssh.png "Powered by OpenSSH")

# Supported tags and respective `Dockerfile` links

- [`debian`, `latest` (*Dockerfile*)](https://github.com/david-garcia-garcia/sftp/blob/master/Dockerfile) ![Docker Image Size (debian)](https://img.shields.io/docker/image-size/davidbcn86/sftp/debian?label=debian&logo=debian&style=plastic)
- [`alpine` (*Dockerfile*)](https://github.com/david-garcia-garcia/sftp/blob/master/Dockerfile-alpine) ![Docker Image Size (alpine)](https://img.shields.io/docker/image-size/davidbcn86/sftp/alpine?label=alpine&logo=Alpine%20Linux&style=plastic)

# Securely share your files

Easy to use SFTP ([SSH File Transfer Protocol](https://en.wikipedia.org/wiki/SSH_File_Transfer_Protocol)) server with [OpenSSH](https://en.wikipedia.org/wiki/OpenSSH).

## mmproxy Support

This image can be used with [mmproxy](https://github.com/path-network/mmproxy) to preserve original client IP addresses when behind a load balancer or proxy. mmproxy uses the kernel's TPROXY feature to make connections appear to come from the original client IP.

### Using with mmproxy

**Important**: mmproxy requires clients or upstream proxies to send [PROXY protocol](https://www.haproxy.org/download/1.8/doc/proxy-protocol.txt) headers (v1 or v2). This is typically configured in your load balancer (HAProxy, nginx, AWS NLB, etc.), not in individual SFTP clients.

1. Ensure you have the mmproxy Docker image available
2. Start the services with your desired variant profile:
   ```bash
   # For Debian variant
   docker compose --profile debian up -d
   
   # For Alpine variant
   docker compose --profile alpine up -d
   ```
3. Configure your load balancer to:
   - Send PROXY protocol headers to mmproxy
   - Forward connections to mmproxy port (not directly to SFTP)

The mmproxy service will listen on:
- **Port 2224** - Proxies to SFTP server on port 2222 (expects PROXY protocol)

Connections through mmproxy will preserve the original client IP address in the SFTP server logs.

### Architecture

```
Client → Load Balancer (adds PROXY protocol) → mmproxy (port 2224/2225) → SFTP Server (port 22)
                                                         ↓
                                            Preserves original client IP using TPROXY
```

See `docker-compose.yml` for the complete mmproxy configuration example.

## Security Features

This container includes several security hardening measures by default:

- **MaxAuthTries 3** - Limits failed authentication attempts per connection to prevent brute force attacks
- **LoginGraceTime 20** - Limits time for unauthenticated connections to 20 seconds
- **MaxStartups 3** - Limits simultaneous unauthenticated connections to prevent connection flooding
- **PermitRootLogin no** - Root login is disabled
- **ChrootDirectory** - Users are chrooted to their home directory
- **ForceCommand internal-sftp** - Only SFTP access is allowed (no shell access)

# Configuration

## Environment Variables

This image accepts the following environment variables for configuration:

### Base Image Versions (for building)

| Variable | Default | Description |
|----------|---------|-------------|
| `DEBIAN_VERSION` | `12` | Debian base image version (when building) |
| `ALPINE_VERSION` | `3.22` | Alpine base image version (when building) |

The Debian and Alpine base image versions can be configured using a `.env` file for local development:

1. Copy `.env.example` to `.env`
2. Adjust the versions as needed

The `.env` file is automatically loaded by Docker Compose. Default values are also specified in the Dockerfiles as fallbacks.

### SSHD Configuration

All SSHD settings can be configured via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `SSHD_PORT` | `22` | SSH server port |
| `SSHD_PASSWORD_AUTH` | `yes` | Enable password authentication (`yes` or `no`) |
| `SSHD_PUBKEY_AUTH` | `yes` | Enable public key authentication (`yes` or `no`) |
| `SSHD_MAX_AUTH_TRIES` | `3` | Maximum authentication attempts per connection |
| `SSHD_LOGIN_GRACE_TIME` | `20` | Time limit for authentication (seconds) |
| `SSHD_MAX_STARTUPS` | `3` | Maximum concurrent unauthenticated connections |
| `SSHD_LOG_LEVEL` | `INFO` | SSH log level (values: `QUIET`, `FATAL`, `ERROR`, `INFO`, `VERBOSE`, `DEBUG`, `DEBUG1`, `DEBUG2`, `DEBUG3`) |

#### Extending SSHD Configuration

You can extend the SSH server configuration by mounting additional configuration files to `/etc/ssh/sshd_config.d/`. Files in this directory (with `.conf` extension) will be automatically included and can override default settings.

**Note**: Values in sub-files generally override values in the main `sshd_config` file.

Example:
```bash
docker run \
  -v /path/to/custom.conf:/etc/ssh/sshd_config.d/custom.conf:ro \
  -e SFTP_USERS="user1:pass1" \
  -p 2222:22 \
  davidbcn86/sftp
```

### User Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `SFTP_USERS` | _(none)_ | Space-separated list of users to create (syntax: `user:pass[:e][:uid[:gid[:dir1[,dir2]...][:expiry_date]]]`) |
| `SFTP_READONLY` | _(none)_ | When set to `true`, enables full readonly mode for SFTP. Users will be able to download files but cannot upload, delete, or modify files. This adds the `-R` flag to `ForceCommand internal-sftp`. |

Example usage:
```bash
docker run \
  -e SSHD_PORT=2222 \
  -e SSHD_LOG_LEVEL=VERBOSE \
  -e SSHD_MAX_AUTH_TRIES=5 \
  -e SFTP_USERS="user1:pass1 user2:pass2::1001:1001:upload,download" \
  -p 2222:2222 \
  davidbcn86/sftp
```

**Note**: Just set the value (e.g., `VERBOSE`, `INFO`), not the full directive. The entrypoint will format it correctly for `sshd_config`.

#### Readonly Mode

To enable full readonly mode for all SFTP users (download only, no uploads or modifications), set `SFTP_READONLY=true`:

```bash
docker run \
  -e SFTP_READONLY=true \
  -e SFTP_USERS="user1:pass1:::download" \
  -p 2222:22 \
  davidbcn86/sftp
```

When readonly mode is enabled, users can:
- ✅ Download files
- ✅ List directories
- ❌ Upload files
- ❌ Delete files
- ❌ Modify files
- ❌ Create directories

# Usage

- Define users in (1) command arguments, (2) `SFTP_USERS` environment variable
  or (3) in file mounted as `/etc/sftp/users.conf` (syntax:
  `user:pass[:e][:uid[:gid[:dir1[,dir2]...][:expiry_date]]] ...`, see below for examples)
  - `expiry_date` is optional and can be in `YYYY-MM-DD` or `YYYYMMDD` format.
    Users will be unable to login after the expiration date.
  - Set UID/GID manually for your users if you want them to make changes to
    your mounted volumes with permissions matching your host filesystem.
  - Directory names at the end will be created under user's home directory with
    write permission, if they aren't already present.
- Mount volumes
  - The users are chrooted to their home directory, so you can mount the
    volumes in separate directories inside the user's home directory
    (/home/user/**mounted-directory**) or just mount the whole **/home** directory.
    Just remember that the users can't create new files directly under their
    own home directory, so make sure there are at least one subdirectory if you
    want them to upload files.
  - For consistent server fingerprint, mount your own host keys (i.e. `/etc/ssh/ssh_host_*`)

# Examples

## Simplest docker run example

```
docker run -p 22:22 -d davidbcn86/sftp foo:pass:::upload
```

User "foo" with password "pass" can login with sftp and upload files to a folder called "upload". No mounted directories or custom UID/GID. Later you can inspect the files and use `--volumes-from` to mount them somewhere else (or see next example).

## Sharing a directory from your computer

Let's mount a directory and set UID:

```
docker run \
    -v <host-dir>/upload:/home/foo/upload \
    -p 2222:22 -d davidbcn86/sftp \
    foo:pass:1001
```

### Using Docker Compose:

```
sftp:
    image: davidbcn86/sftp
    volumes:
        - <host-dir>/upload:/home/foo/upload
    ports:
        - "2222:22"
    command: foo:pass:1001
```

### Logging in

The OpenSSH server runs by default on port 22, and in this example, we are forwarding the container's port 22 to the host's port 2222. To log in with the OpenSSH client, run: `sftp -P 2222 foo@<host-ip>`

## Store users in config

```
docker run \
    -v <host-dir>/users.conf:/etc/sftp/users.conf:ro \
    -v mySftpVolume:/home \
    -p 2222:22 -d davidbcn86/sftp
```

<host-dir>/users.conf:

```
foo:123:1001:100
bar:abc:1002:100
baz:xyz:1003:100
```

## User account expiration

You can set an expiration date for user accounts. After the expiration date, users will be unable to login. The expiration date can be specified in `YYYY-MM-DD` or `YYYYMMDD` format.

```
docker run \
    -v <host-dir>/share:/home/foo/share \
    -p 2222:22 -d davidbcn86/sftp \
    foo:pass:1001:100:share:2024-12-31
```

Or using YYYYMMDD format:

```
docker run \
    -v <host-dir>/share:/home/foo/share \
    -p 2222:22 -d davidbcn86/sftp \
    foo:pass:1001:100:share:20241231
```

In users.conf file:

```
foo:pass:1001:100:share:2024-12-31
bar:pass:1002:100:uploads:20241231
```

## Encrypted password

Add `:e` behind password to mark it as encrypted. Use single quotes if using terminal.

```
docker run \
    -v <host-dir>/share:/home/foo/share \
    -p 2222:22 -d davidbcn86/sftp \
    'foo:$1$0G2g0GSt$ewU0t6GXG15.0hWoOX8X9.:e:1001'
```

You can combine encrypted password with expiration date:

```
docker run \
    -v <host-dir>/share:/home/foo/share \
    -p 2222:22 -d davidbcn86/sftp \
    'foo:$1$0G2g0GSt$ewU0t6GXG15.0hWoOX8X9.:e:1001:100:share:2024-12-31'
```

Tip: you can use this Python code to generate encrypted passwords:  
`docker run --rm python:alpine python -c "import crypt; print(crypt.crypt('YOUR_PASSWORD'))"`

## Logging in with SSH keys

Mount public keys in the user's `.ssh/keys/` directory. All keys are automatically appended to `.ssh/authorized_keys` (you can't mount this file directly, because OpenSSH requires limited file permissions). In this example, we do not provide any password, so the user `foo` can only login with his SSH key.

```
docker run \
    -v <host-dir>/id_rsa.pub:/home/foo/.ssh/keys/id_rsa.pub:ro \
    -v <host-dir>/id_other.pub:/home/foo/.ssh/keys/id_other.pub:ro \
    -v <host-dir>/share:/home/foo/share \
    -p 2222:22 -d davidbcn86/sftp \
    foo::1001
```

## Providing your own SSH host key (recommended)

This container will generate new SSH host keys at first run. To avoid that your users get a MITM warning when you recreate your container (and the host keys changes), you can mount your own host keys.

```
docker run \
    -v <host-dir>/ssh_host_ed25519_key:/etc/ssh/ssh_host_ed25519_key \
    -v <host-dir>/ssh_host_rsa_key:/etc/ssh/ssh_host_rsa_key \
    -v <host-dir>/share:/home/foo/share \
    -p 2222:22 -d davidbcn86/sftp \
    foo::1001
```

Tip: you can generate your keys with these commands:

```
ssh-keygen -t ed25519 -f ssh_host_ed25519_key < /dev/null
ssh-keygen -t rsa -b 4096 -f ssh_host_rsa_key < /dev/null
```

## Execute custom scripts or applications

Put your programs in `/etc/sftp.d/` and it will automatically run when the container starts.
See next section for an example.

## Bindmount dirs from another location

If you are using `--volumes-from` or just want to make a custom directory available in user's home directory, you can add a script to `/etc/sftp.d/` that bindmounts after container starts.

```
#!/bin/bash
# File mounted as: /etc/sftp.d/bindmount.sh
# Just an example (make your own)

function bindmount() {
    if [ -d "$1" ]; then
        mkdir -p "$2"
    fi
    mount --bind $3 "$1" "$2"
}

# Remember permissions, you may have to fix them:
# chown -R :users /data/common

bindmount /data/admin-tools /home/admin/tools
bindmount /data/common /home/dave/common
bindmount /data/common /home/peter/common
bindmount /data/docs /home/peter/docs --read-only
```

**NOTE:** Using `mount` requires that your container runs with the `CAP_SYS_ADMIN` capability turned on. [See this answer for more information](https://github.com/david-garcia-garcia/sftp/issues/60#issuecomment-332909232).

# What's the difference between Debian and Alpine?

The biggest differences are in size and OpenSSH version. [Alpine](https://hub.docker.com/_/alpine/) is 10 times smaller than [Debian](https://hub.docker.com/_/debian/). OpenSSH version can also differ, as it's two different teams maintaining the packages. Debian is generally considered more stable and only bugfixes and security fixes are added after each Debian release (about 2 years). Alpine has a faster release cycle (about 6 months) and therefore newer versions of OpenSSH. Recommended reading: [Comparing Debian vs Alpine for container & Docker apps](https://www.turnkeylinux.org/blog/alpine-vs-debian)

# What version of OpenSSH do I get?

It depends on which linux distro and version you choose (see available images at the top). You can see what version you get by checking the distro's packages online. I have provided direct links below for easy access.

- [List of `openssh` packages on Alpine releases](https://pkgs.alpinelinux.org/packages?name=openssh&branch=&repo=main&arch=x86_64)
- [List of `openssh-server` packages on Debian releases](https://packages.debian.org/search?keywords=openssh-server&searchon=names&exact=1&suite=all&section=main)

# Testing

This project uses PowerShell and Pester for integration testing. The test suite validates both Debian and Alpine variants of the SFTP server.

## Running Tests Locally

### Prerequisites

- Docker and Docker Compose
- PowerShell 7+ ([Install PowerShell](https://docs.microsoft.com/en-us/powershell/scripting/install/installing-powershell))
- Pester 5+ (will be installed automatically if missing)

### Run Tests

```powershell
# Test Debian image
./Test-Integration.ps1 -ImageVariant debian

# Test Alpine image
./Test-Integration.ps1 -ImageVariant alpine
```

**Note:** The `ImageVariant` parameter is required. You must specify either `debian` or `alpine`.

### Keep Services Running After Tests

Useful for debugging:

```powershell
./Test-Integration.ps1 -SkipDockerCleanup
```

### Test Structure

- `Test-Integration.ps1` - Main test runner script
- `e2etests/` - Pester test suites and fixtures
  - `integration-tests.Tests.ps1` - Main integration test suite
  - `SftpTestHelpers.ps1` - Reusable helper functions for testing
  - `fixtures/` - Test configuration files (e.g., users.conf)
  - `testdata/` - Directory for test data files
- `docker-compose.yml` - Test environment with SFTP server and client containers

The test helper functions can be reused across multiple test suites by dot-sourcing the `SftpTestHelpers.ps1` file.
