# Base Image Version Automation

This repository includes automated tracking and updating of base Docker images (Debian and Alpine).

## How It Works

### 1. Version Management

Base image versions are managed in three places:

- **Dockerfiles** (`Dockerfile` and `Dockerfile-alpine`):
  ```dockerfile
  ARG DEBIAN_VERSION=12
  FROM debian:${DEBIAN_VERSION}
  ```

- **Build Workflow** (`.github/workflows/build.yml`):
  ```yaml
  env:
    DEBIAN_VERSION: "12"
    ALPINE_VERSION: "3.22"
  ```

### 2. Automated Version Checking

The `.github/workflows/check-base-images.yml` workflow runs daily at 2 AM UTC and:

1. **Checks Docker Hub** for the latest versions of:
   - Debian 12.x (e.g., 12.0, 12.1, 12.2)
   - Alpine 3.x (e.g., 3.20, 3.21, 3.22)

2. **Compares versions** against the current versions in the repository

3. **Creates a Pull Request** if updates are found, which:
   - Updates the `ARG` statements in both Dockerfiles
   - Updates the environment variables in `build.yml`
   - Includes a detailed description of what changed

### 3. Review and Merge Process

When a PR is created:

1. **Review** the PR to ensure the versions are correct
2. **CI runs automatically** to test both variants
3. **Merge** the PR once tests pass
4. **Create a git tag** (e.g., `v1.2.3`) to trigger a release
5. **Images are pushed** to Docker Hub with tags like:
   - `v1.2.3-debian-12`
   - `v1.2.3-alpine-3.22`

## Manual Triggering

You can manually trigger the version check workflow:

```bash
gh workflow run check-base-images.yml
```

Or via the GitHub UI: Actions → Check Base Image Updates → Run workflow

## Image Tagging Strategy

When you create a git tag, images are built and pushed with:

- **Format**: `{git-tag}-{variant}-{base-version}`
- **Examples**:
  - `v1.0.0-debian-12`
  - `v1.0.0-alpine-3.22`
  - `v2.1.5-debian-12`
  - `v2.1.5-alpine-3.23` (after Alpine updates)

## Benefits

✅ **Automatic updates** - No manual tracking needed  
✅ **Security** - Get notified of new base images promptly  
✅ **Traceability** - Version numbers in image tags  
✅ **Safe** - PR-based review before merging  
✅ **Flexible** - Can override versions during build if needed

## Overriding Versions

You can build with a different version locally:

```bash
# Build Alpine with a different version
docker build \
  --build-arg ALPINE_VERSION=3.21 \
  -f Dockerfile-alpine \
  -t my-sftp:alpine \
  .

# Build Debian with a different version
docker build \
  --build-arg DEBIAN_VERSION=11 \
  -f Dockerfile \
  -t my-sftp:debian \
  .
```

## Maintenance

To update the version check logic:

1. Edit `.github/workflows/check-base-images.yml`
2. Modify the version detection regex patterns if needed
3. Test manually with `workflow_dispatch`

