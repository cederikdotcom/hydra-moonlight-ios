# hydra-moonlight-ios Runbook

## Overview

Fork of `moonlight-stream/moonlight-ios`. Adds two Hydra-specific Objective-C classes:

- `HydraStreamSession` — starts/stops a Moonlight GameStream session given a host, app name, and resolution
- `HydraPairSession` — runs the GameStream crypto handshake (port 47989) and submits the PIN to Sunshine's management API (port 47990) with Basic Auth

Consumed as a git submodule by `cederikdotcom/hydraheadipad` at `Vendors/hydra-moonlight-ios/`. Sources are compiled directly into the app target — no separate framework build.

## Key files

| File | Purpose |
|------|---------|
| `Limelight/HydraStreamSession.h/.m` | Public streaming API |
| `Limelight/HydraPairSession.h/.m` | Pairing API — GameStream handshake + Sunshine PIN |
| `Limelight/HydraOpus.h/.m` | Opus audio encode helper |

## Ports used

| Port | Protocol | Purpose |
|------|----------|---------|
| 47989 | HTTP | GameStream pairing handshake (PairManager) |
| 47990 | HTTPS | Sunshine management API — PIN submission (`POST /api/pin`) |
| 47984/47998 | TCP/UDP | Moonlight stream data |

## Pairing flow

1. `HydraPairSession` is initialized with the body's host IP, Sunshine username, and Sunshine password (fetched from HydraCluster head config).
2. `CryptoManager` generates a client key+cert on first pair (stored in app sandbox).
3. `PairManager` runs the 5-stage GameStream crypto handshake over HTTP on port 47989.
4. During the handshake, `PairCallback -startPairing:` is called with a PIN.
5. The PIN is submitted via `POST https://<host>:47990/api/pin` with `Authorization: Basic <base64(user:pass)>` and `Content-Type: application/json`, body `{"pin":"<PIN>"}`.
6. Sunshine's self-signed cert is accepted via `InsecurePinDelegate` (TLS validation bypassed for the PIN request only).
7. On success, `PairCallback -pairSuccessful:` delivers the server certificate for future stream sessions.
8. If `PairCallback -alreadyPaired` fires (client already registered with Sunshine), `HydraPairSession` sends `GET http://<host>:47989/unpair?uniqueid=0123456789ABCDEF` (the hardcoded uniqueId used by `HttpManager` for all GameStream requests) and then re-initiates pairing so the full handshake runs and the server cert is returned. A `hasAttemptedUnpair` flag prevents an infinite loop.

## Troubleshooting

**"Sunshine rejected the PIN"**
- Verify Sunshine username/password are correct in HydraCluster district provider config (`sunshine_username`, `sunshine_password`).
- Confirm port 47990 is reachable from the iPad (WireGuard tunnel must be up).
- Check Sunshine logs on the body for PIN mismatch or auth failure.

**Pairing stalls — Sunshine logs show only /serverinfo, never /pair**
- `HttpManager` was initialized with a wrong `httpsPort` (e.g. 47990) instead of `0`. With a non-zero port it skips auto-discovery and sends HTTPS calls to Sunshine's web UI port instead of the GameStream HTTPS port (47984), so the server cert fetch fails and `/pair` is never reached.
- Fix: `httpsPort:0` in `HydraPairSession -pairWithCompletion:` lets `HttpManager` read the correct HTTPS port from the HTTP `/serverinfo` XML (`HttpsPort` field, normally 47984).
- Confirm: `curl http://<host>:47989/serverinfo` and look for `<HttpsPort>`.

**Pairing hangs / times out**
- Port 47989 blocked — check firewall on body machine.
- WireGuard not routing traffic — verify `wireguard_ip` in HydraCluster body record resolves correctly.

**Stream never starts — Moonlight polls /serverinfo in a loop, no /launch in Sunshine logs**
- Cause: `HttpManager` received an empty/nil `serverCert`. The cert-pinning challenge compared against nil, always returned false, and rejected Sunshine's self-signed cert. `StreamManager` couldn't complete the HTTPS `/serverinfo` call on port 47984, called `launchFailed("Failed to connect to PC")`, and `returnToMainFrame` started the Moonlight host browser polling loop.
- Root trigger: `HydraPairSession -alreadyPaired` returned an empty cert (`[NSData data]`). This happens when `NSAllowsArbitraryLoads` is absent from the host app's `Info.plist` — ATS blocks the HTTP unpair to port 47989, so Sunshine stays paired, PairManager returns `alreadyPaired` again, `hasAttemptedUnpair` guard fires, and an empty cert is returned.
- Fixed in `HttpManager` (committed a632e7b): cert pinning is skipped when `_serverCert` is nil or empty — Sunshine's self-signed cert is accepted without pinning. Pinning is still enforced when a real cert is present (normal pair path).
- Prerequisite fix in host app: `NSAllowsArbitraryLoads: true` in `Info.plist` so ATS allows HTTP to port 47989 for pairing and unpair.

**Pairing fails — Sunshine logs "Event timeout: 0123456789ABCDEF"**
- Cause: the PIN POST to port 47990 arrived after Sunshine's pairing event window (~0.75s from when it receives `/pair?phrase=getservercert`). Sunshine discards the PIN and the handshake stalls.
- Root cause in old builds: `HydraPairSession -startPairing:` used a `dispatch_after` of 1.0s, which consistently landed after the window.
- Fixed (committed ba00ade): delay reduced to 0.3s — long enough for PairManager to send `/serverinfo` and `/pair?getservercert`, short enough to arrive before Sunshine times out.
- If the timeout recurs, check Sunshine's log for the gap between the `/pair?getservercert` line and the "Event timeout" line; the gap is the window size. The `dispatch_after` delay in `HydraPairSession.m` must be smaller than that gap.

**alreadyPaired loop — unpair silently fails, hasAttemptedUnpair fires, returns empty cert**
- Cause: `HydraPairSession -alreadyPaired` was reading the uniqueId from `NSUserDefaults` via key `HydraLimelightUniqueId`. `HydraHeadiPad` never calls `IdManager.getUniqueId`, so the key is never initialized. The fallback produced an empty string → unpair request `http://host:47989/unpair?uniqueid=` → Sunshine found no client with uniqueid="" → did not unpair → re-pair returned `alreadyPaired` again → `hasAttemptedUnpair` guard fired → empty cert returned.
- Fixed: hardcoded `@"0123456789ABCDEF"` in the unpair URL (matches `HttpManager`'s hardcoded uniqueId used for all GameStream requests). Sunshine now correctly removes the client from its paired list and the re-pair completes with a real server cert.
- Do not attempt to fix by calling `IdManager.getUniqueId` — it would generate a random ID different from `0123456789ABCDEF`, so Sunshine still wouldn't find the client to unpair.

**Stream never launches — `launchFailed("Failed to launch app")` fires immediately after pairing**
- Cause: `config.appID = @"0"` in `HydraStreamSession`. Sunshine assigns large opaque integer IDs to apps at creation time; `appid=0` does not match any user-defined app. Sunshine returned `gameSession=0` → `launchFailed` → `returnToMainFrame`.
- Fixed: `StreamManager.main()` now queries `/applist` (HTTPS on port 47984) using `newAppListRequest` + `AppListResponse`, finds the `TemporaryApp` with `name == config.appName`, and sets `config.appID = app.id` before calling `launchApp`.
- If the applist lookup fails or the app name has no match, `config.appID` stays as `@"0"` and the launch will fail with the same error — verify the `appName` passed to `HydraStreamSession` matches the app title exactly as registered in Sunshine.

**Stream connected, Sunshine streaming, but iPad shows black screen / no video**
- Cause: `returnToMainFrame` in `StreamFrameViewController` only calls `[self.navigationController popToRootViewControllerAnimated:YES]`. Since HydraHeadiPad presents the VC as a UIKit modal (not on a nav stack), `self.navigationController` is nil — the call is a complete no-op. When the Limelight connection terminates for any reason (error, graceful, timeout), `returnToMainFrame` fires but the VC stays on screen in a stuck/blank state. `ML_ERROR_GRACEFUL_TERMINATION` additionally skips `hydraErrorCallback` entirely, so even the error callback path doesn't fire.
- Fixed: `StreamFrameViewController` now has a `hydraReturnToMainFrame` block property. `HydraStreamSession` sets this block to call `[s stop]`, which properly dismisses the modal VC and fires `streamSessionDidStop` → Swift state resets. `StreamSessionBridge` now has a `hasReportedTermination` guard to prevent double-callback when both `hydraErrorCallback` and the subsequent stop fire.
- If the iPad shows a stuck black screen with no video after connecting: force-kill the app and reinstall v0.2.80+ which has this fix.
- After this fix, failed connections surface a clear error message (e.g. port blocked, launch failed) on the experience grid instead of being invisible.

**Pairing always triggers the full handshake (never hits the fast path)**
- `HydraPairSession` now unpairs automatically when `alreadyPaired` fires, so every session where no cached cert exists performs a fresh pair.
- This is expected after `resetEnrollment` (re-enroll gesture: 3-second long-press on the experience grid) or after deleting and reinstalling the app.
- If pairing loops (alreadyPaired → unpair → alreadyPaired again), check whether `CryptoManager` is generating a new key pair — it should only generate once; `readCertFromFile` must return non-nil on subsequent launches.

## Updating from upstream

```sh
git remote add upstream https://github.com/moonlight-stream/moonlight-ios.git
git fetch upstream
git rebase upstream/master
# Resolve conflicts in Hydra-specific files only
git push origin master
```

Our additions are isolated to `HydraStreamSession.*`, `HydraPairSession.*`, `HydraOpus.*` — upstream changes to the streaming engine do not touch these files.
