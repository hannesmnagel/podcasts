# AGENTS.md - Podcasts / The Podcatcher

## Release habit

When making iOS app changes that Hannes should test, do not stop at pushing code and verifying builds. Also check whether a new TestFlight build is needed, archive/export/upload it, wait until App Store Connect marks it valid, set `usesNonExemptEncryption=false`, and add it to the Internal Testers group.

Always run the project TestFlight script for that flow: `scripts/testflight-build.sh`. Do not bypass it with raw `asc publish testflight` unless Hannes explicitly asks for a one-off manual flow.

When Hannes asks to deploy backend/worker changes, treat deploy as: commit the requested changes and push the current branch (usually `main`) to origin.

If the change is backend/worker-only and no iOS build is needed, say that explicitly.

## Product priorities

- Smart Speed is on ice; do not work on it unless Hannes explicitly asks.
- Current priority is transcript alignment for DAI/local downloads.
- Future idea: user-selected ad transcript segments / similar-part skipping, but check in with Hannes before starting it.
