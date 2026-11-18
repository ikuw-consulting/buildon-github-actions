# basic-quality-checks

Basic Quality Checks

## Inputs

All configuration comes from KaptainPM.yaml and layers, except secrets.

## Secrets

| Secret | Description |
|--------|-------------|
| `docker-registry-logins-secrets` | JSON object of secrets for docker-registry-logins (e.g., {"DOCKER_USER": "x", "DOCKER_PASS": "y"}) |
| `vendor-read-token` | Optional read-only token for hook scripts that fetch from private repositories. Exposed to hook scripts as VENDOR_READ_TOKEN; never logged. |
