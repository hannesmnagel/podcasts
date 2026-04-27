# Status

2026-04-27

- Recreated project foundation after live folder only contained backend build artifacts.
- Privacy model updated: no backend accounts for MVP; CloudKit private sync for user data.
- Implemented Vapor backend scaffold with podcasts, episodes, transcript/chapter artifacts, worker jobs, and anonymous demand counters.
- Implemented requested prioritization: transcript/artifact requests increment per-episode and per-podcast demand, then worker jobs prefer hot podcasts over cold ones.
- Added SwiftUI/iOS scaffold with All Episodes, All Podcasts, Search tabs, SwiftData models, backend client, and AVPlayer high-speed mini-player shell.
- Added Mac worker stub.
- Backend tests pass with `swift test`.

## Deployment automation progress — 2026-04-27

- Checked server state: `/root/podcasts-backend` exists and Caddy routes `podcasts.hannesnagel.com` to `:8011`, but no podcast containers are currently running.
- Confirmed local project backend and server backend have the same tracked source/config files, excluding `.env`, `.build`, and `.DS_Store`.
- Added GitHub Actions workflow at `.github/workflows/deploy-backend.yml` to test, build, push GHCR image, and deploy via SSH.
- Updated `backend/docker-compose.yml` so the app service has `image: ghcr.io/hannesmnagel/podcasts:latest` while keeping `build: .` for local development.
- Updated `backend/Dockerfile` so its `swift build` output is filtered through `grep` and only tails a bounded log chunk on failure.
- Updated `docs/DEPLOYMENT.md` with current server state, target Actions flow, required secrets, and fallback manual deployment.
- Initialized a local Git repository on branch `main`; no remote is configured yet.
- Verified `swift build` locally with filtered output; final run succeeded (`Build complete`). First verification attempt also built successfully but the shell wrapper used zsh's read-only `status` variable, so I reran it with a safe `rc` variable.
- Verified `docker compose config --quiet`; it passed. Compose warned that `DATABASE_PASSWORD` is unset locally, which is expected without a local `.env`.

### Still needed / blocked on confirmation

- Create or choose the GitHub repository for this project.
- Push the local project to GitHub.
- Add required GitHub Actions secret: `DEPLOY_SSH_PRIVATE_KEY`.
- Update the server copy of `/root/podcasts-backend/docker-compose.yml` to use the GHCR image, then let Actions deploy.
