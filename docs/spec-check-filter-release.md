# spec-check-filter-release

Spec Check Filter Release

## Inputs

All configuration comes from KaptainPM.yaml and layers, except secrets.

## Secrets

| Secret | Description |
|--------|-------------|
| `docker-registry-logins-secrets` | JSON object of secrets for docker-registry-logins (e.g., {"DOCKER_USER": "x", "DOCKER_PASS": "y"}) |
| `vendor-read-token` | Optional read-only token for hook scripts that fetch from private repositories. Exposed to hook scripts as VENDOR_READ_TOKEN; never logged. |

## Outputs

| Output | Description |
|--------|-------------|
| `version` | The generated version |
| `version-major` | Major version number |
| `version-minor` | Minor version number |
| `version-patch` | Patch version number |
| `version-2-part` | Version padded/truncated to 2 parts |
| `version-3-part` | Version padded/truncated to 3 parts |
| `version-4-part` | Version padded/truncated to 4 parts |
| `docker-tag` | Tag for Docker images |
| `docker-image-name` | Docker image name |
| `git-tag` | Tag for git |
| `project-name` | The repository/project name |
| `is-release` | Whether this is a release build |
| `docker-target-image-full-uri` | Full target image reference |
| `images-pushed` | Number of images pushed |
