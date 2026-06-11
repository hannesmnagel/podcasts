# iOS

## TestFlight
After iOS changes: archive, export, upload via `scripts/testflight-build.sh`. Wait for App Store Connect to mark it valid, set `usesNonExemptEncryption=false`, add to Internal Testers. Do not bypass the script unless Hannes explicitly asks.

## SwiftUI
- No explicit spacing in stacks (e.g. `HStack(spacing: 14)`)
