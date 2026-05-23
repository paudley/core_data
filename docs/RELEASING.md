# Release Process

This document describes the process for creating and publishing releases of the Core Data PostgreSQL Docker images.

## Table of Contents

* [Overview](#overview)
* [Version Strategy](#version-strategy)
* [Release Checklist](#release-checklist)
* [Creating a Release](#creating-a-release)
* [Verifying the Release](#verifying-the-release)
* [Troubleshooting](#troubleshooting)

## Overview

Releases are published automatically to GitHub Container Registry (GHCR) when version tags are pushed to the repository. Each release includes:

* **Docker images** published to `ghcr.io/<username>/core-data-postgres`
* **SLSA attestations** for build provenance verification
* **SBOM** (Software Bill of Materials) for dependency tracking
* **Multiple tags** for flexible version referencing

## Version Strategy

### Hybrid Versioning Format

We use a **hybrid versioning strategy** that combines PostgreSQL version with semantic versioning:

```
{PG_VERSION}-v{SEMANTIC_VERSION}
```

**Examples:**

* `18.4-v1.0.0` - Initial stable release with PostgreSQL 18.4
* `18.4-v1.0.1` - Patch/build fix (PostgreSQL version unchanged)
* `18.4-v1.1.0` - New extensions or features added (minor bump)
* `18.4-v1.2.0` - PostgreSQL minor update with features
* `19.0-v2.0.0` - PostgreSQL major upgrade (breaking change)

### Version Components

#### PostgreSQL Version (`{PG_VERSION}`)

* Format: `MAJOR.MINOR` (e.g., `18.4`)
* Changes when the base PostgreSQL version is updated
* Major version changes (17 → 18) typically require semantic major version bump

#### Semantic Version (`{SEMANTIC_VERSION}`)

* Format: `MAJOR.MINOR.PATCH` (e.g., `1.0.0`)
* Follows [Semantic Versioning 2.0.0](https://semver.org/)
  * **MAJOR**: Breaking changes, PostgreSQL major upgrades
  * **MINOR**: New features, extensions, backward-compatible changes
  * **PATCH**: Bug fixes, security patches, build improvements

### Generated Docker Tags

For a release tag `18.4-v1.0.0`, the following Docker image tags are automatically created:

* `18.4-v1.0.0` - Full version (exact release)
* `18.4-v1.0` - Minor version (latest patch)
* `18.4-v1` - Major version (latest minor)
* `18.4` - PostgreSQL version (latest semantic version)
* `18` - PostgreSQL major version (latest minor)
* `latest` - Latest stable release

## Release Checklist

Before creating a release, ensure:

* \[ ] All tests pass in CI (`smoke` and `markers` jobs)
* \[ ] Docker build validation passes
* \[ ] `CHANGELOG.md` is updated with changes since last release
* \[ ] `VERSION` file contains the correct semantic version
* \[ ] Documentation is up to date
* \[ ] Breaking changes are clearly documented
* \[ ] Security vulnerabilities are addressed
* \[ ] Local testing is complete

## Creating a Release

### Step 1: Update CHANGELOG.md

Edit `CHANGELOG.md` and move items from `[Unreleased]` to a new version section:

```markdown
## [Unreleased]

## [18.4-v1.0.0] - 2025-01-15

### Added
- Feature XYZ
- Extension ABC

### Changed
- Improved performance of ...

### Fixed
- Bug in ...
```

Update the comparison links at the bottom:

```markdown
[unreleased]: https://github.com/paudley/core_data/compare/18.4-v1.0.0...HEAD
[18.4-v1.0.0]: https://github.com/paudley/core_data/releases/tag/18.4-v1.0.0
```

### Step 2: Update VERSION File

Update the `VERSION` file with the new semantic version:

```bash
echo "1.0.0" > VERSION
```

### Step 3: Commit Changes

```bash
git add CHANGELOG.md VERSION
git commit -m "chore: prepare release 18.4-v1.0.0"
```

### Step 4: Create and Push Tag

Create an annotated tag with release notes:

```bash
git tag -a 18.4-v1.0.0 -m "Release 18.4-v1.0.0

PostgreSQL 18.4 with comprehensive extension suite

## Highlights
- PostgreSQL 18.4 on Debian Bookworm
- PostGIS 3, pgvector, Apache AGE
- Comprehensive performance and maintenance extensions
- Full SLSA attestation support

See CHANGELOG.md for complete details."
```

Push the tag to trigger the release workflow:

```bash
git push origin 18.4-v1.0.0
```

### Step 5: Monitor GitHub Actions

1. Go to the **Actions** tab in GitHub
2. Watch the **Publish Docker Image to GHCR** workflow
3. Verify all steps complete successfully
4. Check the job summary for image details

### Step 6: Create GitHub Release

After the workflow completes, create a GitHub Release:

1. Go to **Releases** → **Draft a new release**
2. Choose the tag you just pushed
3. Title: `Core Data PostgreSQL 18.4-v1.0.0`
4. Copy highlights from CHANGELOG.md
5. Add verification instructions (see template below)
6. Publish release

#### GitHub Release Template

````markdown
## Core Data PostgreSQL 18.4-v1.0.0

PostgreSQL 18.4 with comprehensive extension suite for spatial, vector, and graph data.

### 📦 Installation

```bash
docker pull ghcr.io/<username>/core-data-postgres:18.4-v1.0.0
````

### 🔐 Verify Attestation

```bash
gh attestation verify oci://ghcr.io/<username>/core-data-postgres:18.4-v1.0.0 \
  --owner <username>
```

### 📋 What's Changed

See [CHANGELOG.md](https://github.com/%3Cusername%3E/core_data/blob/main/CHANGELOG.md#18.4-v1.0.0) for complete details.

### 🐳 Available Tags

* `ghcr.io/<username>/core-data-postgres:18.4-v1.0.0` (exact version)
* `ghcr.io/<username>/core-data-postgres:18.4` (PostgreSQL version)
* `ghcr.io/<username>/core-data-postgres:latest` (latest stable)

### 🔒 Security

This release includes SLSA build attestations and SBOM for supply chain security.

````

## Verifying the Release

### 1. Pull the Image

```bash
docker pull ghcr.io/<username>/core-data-postgres:18.4-v1.0.0
````

### 2. Verify Attestation

Using GitHub CLI:

```bash
gh attestation verify oci://ghcr.io/<username>/core-data-postgres:18.4-v1.0.0 \
  --owner <username>
```

Expected output:

```
✓ Verification succeeded!

sha256:abc123... was attested by:
REPO                    PREDICATE_TYPE                  WORKFLOW
owner/core_data         https://slsa.dev/provenance/v1  .github/workflows/publish-docker.yml@refs/tags/18.4-v1.0.0
```

### 3. Inspect SBOM

View the Software Bill of Materials:

```bash
gh attestation verify oci://ghcr.io/<username>/core-data-postgres:18.4-v1.0.0 \
  --owner <username> \
  --format json | jq '.verificationResult.statement.predicate.sbom'
```

### 4. Test the Image

Run a quick test:

```bash
docker run --rm ghcr.io/<username>/core-data-postgres:18.4-v1.0.0 \
  postgres --version
```

Expected output:

```
postgres (PostgreSQL) 18.4 (Debian 18.4-1.pgdg12+1)
```

### 5. Verify Extensions

```bash
docker run --rm \
  -e POSTGRES_PASSWORD=test \
  ghcr.io/<username>/core-data-postgres:18.4-v1.0.0 \
  postgres -c "SELECT * FROM pg_available_extensions WHERE name IN ('postgis', 'vector', 'age');"
```

## Troubleshooting

### Workflow Fails to Build

**Symptom**: Build step fails in GitHub Actions

**Solutions**:

1. Check build logs for specific errors
2. Verify Dockerfile syntax locally: `docker build -f postgres/Dockerfile .`
3. Ensure all build dependencies are available
4. Check if base image (`postgres:18-bookworm`) is accessible

### Attestation Generation Fails

**Symptom**: Build succeeds but attestation step fails

**Solutions**:

1. Verify workflow permissions include `id-token: write` and `attestations: write`
2. Check if `GITHUB_TOKEN` has required permissions
3. Ensure repository settings allow attestation generation
4. Verify GitHub Actions is up to date

### Tag Already Exists

**Symptom**: `git push` fails because tag already exists

**Solutions**:

Delete local tag:

```bash
git tag -d 18.4-v1.0.0
```

Delete remote tag (use with caution):

```bash
git push origin :refs/tags/18.4-v1.0.0
```

Create corrected tag and push again.

### Wrong Tags Generated

**Symptom**: Docker image has incorrect or missing tags

**Solutions**:

1. Verify tag format matches `{PG_VERSION}-v{SEM_VERSION}` pattern
2. Check workflow logs for tag extraction step
3. Ensure version extraction regex is working correctly
4. Test locally: Extract version from tag name using the workflow logic

### Permission Denied on GHCR

**Symptom**: Cannot push to GitHub Container Registry

**Solutions**:

1. Verify repository settings → Actions → General → Workflow permissions
2. Enable "Read and write permissions" for `GITHUB_TOKEN`
3. Ensure package visibility settings allow publishing
4. Check if personal access token is needed (should not be for same org)

## Best Practices

1. **Test Locally First**: Build and test the Docker image locally before tagging
2. **Use Annotated Tags**: Include release notes in git tag message
3. **Update Documentation**: Ensure all docs reflect changes before release
4. **Semantic Versioning**: Follow semantic versioning strictly for predictability
5. **Security First**: Address all known vulnerabilities before releasing
6. **Communicate Changes**: Clearly document breaking changes and migration paths
7. **Verify Before Announcing**: Pull and test published image before announcing release

## Emergency Hotfix Process

For critical security fixes or severe bugs:

1. Create a branch from the affected release tag
2. Apply minimal fix
3. Update CHANGELOG.md with `[18.4-v1.0.1] - YYYY-MM-DD` section
4. Increment PATCH version in VERSION file
5. Create tag with PATCH bump (e.g., `18.4-v1.0.1`)
6. Push tag to trigger automated release
7. Create GitHub release with clear hotfix description

## Support

For questions or issues with the release process:

* Check existing [GitHub Issues](https://github.com/%3Cusername%3E/core_data/issues)
* Review [GitHub Discussions](https://github.com/%3Cusername%3E/core_data/discussions)
* Consult [GitHub Actions Documentation](https://docs.github.com/en/actions)
* Read [Artifact Attestations Guide](https://docs.github.com/en/actions/security-guides/using-artifact-attestations-to-establish-provenance-for-builds)
