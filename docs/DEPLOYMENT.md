# Deployment

The backend is intended to deploy through GitHub Actions to the existing server stack.

## Current server state checked 2026-04-27

- Server directory exists: `/root/podcasts-backend`
- Caddy route exists: `podcasts.hannesnagel.com` -> `:8011`
- Docker Compose file exists on the server with app + Postgres
- No podcast containers were running when checked with `docker ps` / `docker compose ps`
- The server copy is not a Git checkout; it appears to be a manually copied backend snapshot

## Target flow

1. Push this project to a GitHub repo.
2. GitHub Actions runs backend tests.
3. GitHub Actions builds `backend/Dockerfile`.
4. GitHub Actions pushes `ghcr.io/hannesmnagel/podcasts:latest`.
5. GitHub Actions SSHes into the server and runs:

```bash
cd /root/podcasts-backend
docker compose pull app
docker compose up -d --remove-orphans
```

## Workflow added locally

Workflow file:

```text
.github/workflows/deploy-backend.yml
```

It currently expects these GitHub Actions secrets:

- `DEPLOY_SSH_PRIVATE_KEY` — private deploy key allowed to SSH to the server

The workflow follows the same pattern as `main-backend`: server host/user are workflow env values (`hannesnagel.com`, `root`) and the private key is stored as a GitHub Actions secret.

The workflow uses the built-in `GITHUB_TOKEN` to push to GHCR, with `packages: write` permission.

## Compose

Local `backend/docker-compose.yml` now includes:

```yaml
image: ghcr.io/hannesmnagel/podcasts:latest
build: .
```

That keeps local builds possible with `docker compose up --build`, while allowing production to pull the GHCR image.

## Manual fallback

If GitHub Actions is not ready yet:

```bash
cd backend
cp .env.example .env
# edit DATABASE_PASSWORD
docker compose up -d --build
```

Default host port: `8011`, intended Caddy route: `podcasts.hannesnagel.com` -> `127.0.0.1:8011`.

## Output safety note

Swift build/test output should be filtered to avoid giant logs. The Dockerfile and GitHub Actions test step pipe Swift output through `grep` and only tail a bounded log chunk on failure.
