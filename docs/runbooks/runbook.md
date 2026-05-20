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
| `Limelight/HydraLog.h` | Global ObjC→AppLogger logging bridge |

## Diagnostic logging infrastructure

`HydraLog.h` declares a `HydraLog(format, ...)` C function that logs to both `NSLog` (device console / Xcode Organizer) and, if a Swift callback is registered, to the in-app log viewer (⋯ → Logs).

**Reading logs while the stream is stuck:** tap the ⋯ button while on the "Starting \<app\>..." screen → "View logs" opens a log sheet over the stream, showing live `[ObjC]` entries as they arrive. Use this instead of waiting for an error and then tapping ⋯ → Create issue — it gives real-time visibility into which HTTPS phase or moonlight stage is blocking.

The callback is registered once at app launch in `HydraHeadiPadApp.init()`:
```swift
HydraStreamSession.setGlobalLogCallback { message in
    AppLogger.shared.log("[ObjC] \(message ?? "")")
}
```

All subsequent log calls from any session — including during failed sessions where the per-session delegate chain is broken — flow through this global callback. The `[ObjC]` prefix distinguishes these entries in the log viewer.

**What to look for in a hanging stream:**
- `StreamManager: main START` — confirms StreamManager started on a background thread
- `StreamManager: crypto ready` — key pair exists (generated on first pair), HTTPS requests about to start
- `StreamManager: serverinfo done` — first HTTPS completed; state and pairStatus visible
- `StreamManager: applist done` — second HTTPS completed; resolved appID visible
- `StreamManager: serverCodecModeSupport=N` — N must be non-zero; 0 causes immediate LiStartConnection -1
- `StreamManager: /launch HTTPS request starting` — third HTTPS sent (60 s inactivity timeout)
- `StreamManager: /launch response` — Sunshine responded; statusCode + gameSession visible
- `StreamManager: launch/resume OK — dispatching LiStartConnection` — HTTPS phase complete
- `Connection: acquiring initLock` — Connection.main() started on opQueue thread
- `Connection: calling LiStartConnection` — moonlight-common-c protocol begins
- `Stage starting: <name>` — each moonlight stage logs this with block state (SET/NIL)
- `connectionStarted` — all stages complete, video should appear

If logs stop mid-sequence, the gap between the last entry and the next one (or the absence of a next entry) identifies the exact hang point.

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

**Stream shows "Starting [app]..." indefinitely with no error — applicationWillResignActive fires at stream start**
- Cause: iOS fires `UIApplicationWillResignActiveNotification` shortly after the Moonlight VC is presented (e.g. system notification banner, WireGuard VPN state change, Guided Access, or other system-level UI event). `StreamFrameViewController -applicationWillResignActive:` starts a 60-second inactivity timer. During those 60 seconds the connection runs and video arrives, but `AVSampleBufferDisplayLayer` suspends rendering while the app is in the inactive state. No error fires and the spinner never disappears. After 60 seconds `inactiveTimerExpired:` calls `returnToMainFrame` and the session terminates silently.
- Fixed (committed 1cb4e4f): `applicationWillResignActive:` now skips the 60-second timer when `_connectionStarted == YES` (i.e. `connectionStarted` has already fired, meaning all stages completed and video is flowing). `applicationDidEnterBackground` still terminates the stream immediately for true backgrounding. The 60-second timer is retained only for the setup phase (before the first IDR frame).
- Diagnostic: the `hydraApplicationResignActiveCallback` block on StreamFrameViewController forwards this event to `HydraStreamSessionDelegate -streamSessionApplicationResignActive`, which is logged by `StreamSessionBridge` via AppLogger: `"Stream: applicationWillResignActive fired"`.
- If the symptom recurs: check for `"Stream: applicationWillResignActive fired"` in the in-app log viewer. If it appears BEFORE `"Stream: connectionStarted — all stages complete"`, the timer is still the cause — investigate what system event is causing the resign-active.

**Stream shows "Starting [app]..." for 30-60 seconds then fails (or never shows error)**
- Cause: `StreamFrameViewController -connectionTerminated:` and `-stageFailed:` both call `LiTestClientConnectivity("ios.conntest.moonlight-stream.org", 443, portFlags)` **synchronously** before dispatching to the main queue. On a closed venue LAN without internet access, DNS resolution for `ios.conntest.moonlight-stream.org` fails or times out (30-60 seconds). The error message is suppressed for that entire window — the user sees the loading screen frozen on "Starting [app]...".
- Fixed (committed ce6a0d1): both `LiTestClientConnectivity` calls replaced with the constant `ML_TEST_RESULT_INCONCLUSIVE`. The error message now appears within 2-3 seconds of the failure. The connectivity hint ("ports blocked by your network") is omitted, but port flags from `LiStringifyPortFlags` still appear in the error detail — sufficient for venue LAN diagnosis.
- If errors reappear as slow: check whether upstream sync re-introduced the `LiTestClientConnectivity` calls in `StreamFrameViewController.m`. Grep for `LiTestClientConnectivity` — it must not appear in that file.

**Stream connected, Sunshine streaming indefinitely, iPad shows black screen / no video and no error**
- Cause: iOS VideoToolbox rejects the HEVC (H.265) VPS/SPS/PPS parameter sets produced by certain NVENC encoder configurations (RTX 4000+/Blackwell generation). `CMVideoFormatDescriptionCreateFromHEVCParameterSets` returns a non-zero status → `VideoDecoderRenderer.submitDecodeBuffer` returns `DR_NEED_IDR` on every frame → moonlight-common-c requests a new IDR from Sunshine in an infinite loop. The RTSP/control connection stays alive (Sunshine keeps streaming, `stream_count` stays at 1), but `AVSampleBufferDisplayLayer.hidden` is never set to `NO` because no IDR ever successfully decodes. No `connectionTerminated:` fires, so the error callback is never triggered.
- Fixed (committed ce6a0d1): `config.supportedVideoFormats = VIDEO_FORMAT_H264` in `HydraStreamSession.m`. Forcing H.264 eliminates the NVENC/VideoToolbox incompatibility. Sunshine encodes in H.264 which iOS has decoded reliably since A7.
- To re-enable HEVC later: test with `VIDEO_FORMAT_H265 | VIDEO_FORMAT_H264` on a known-good body (non-Blackwell NVENC or AMD). If HEVC works, confirm by checking Sunshine logs for `video codec: hevc` — if H.264 is always selected, Sunshine's encoder may not support HEVC negotiation at the configured resolution/bitrate.
- Distinguishing from stuck modal bug (v0.2.79 and earlier): the old bug showed a black screen after the connection was already terminated; this bug shows a black screen while Sunshine is actively streaming (check `stream_count` on the body node via HydraCluster API).

**Pairing always triggers the full handshake (never hits the fast path)**
- `HydraPairSession` now unpairs automatically when `alreadyPaired` fires, so every session where no cached cert exists performs a fresh pair.
- This is expected after `resetEnrollment` (re-enroll gesture: 3-second long-press on the experience grid) or after deleting and reinstalling the app.
- If pairing loops (alreadyPaired → unpair → alreadyPaired again), check whether `CryptoManager` is generating a new key pair — it should only generate once; `readCertFromFile` must return non-nil on subsequent launches.

**Sunshine keeps streaming after iPad user exits — stream_count stays at 1 on body**
- Cause: when the user exits before `LiStartConnection` runs (stream stuck on "Starting..."), `_connection` is nil so `[_connection terminate]` is a no-op. Sunshine launched the app and is actively streaming, but moonlight-common-c never established the RTSP control channel, so there is no graceful disconnect path through moonlight-common-c.
- Fixed: `HydraStreamSession.stop()` now fires `GET https://<host>:47984/cancel?uniqueid=0123456789ABCDEF` as a 3-second fire-and-forget before dismissing the VC. Sunshine terminates the app session immediately on receipt. This mirrors what Moonlight-Qt does on process exit.
- If Sunshine still keeps streaming after exit: confirm the cancel request reaches port 47984 (`curl -k "https://<host>:47984/cancel?uniqueid=0123456789ABCDEF"` from iPad's network should return an XML response with `<cancel>1</cancel>`).

**LiStartConnection returns -1 immediately — no stage callbacks fire, no error displayed**
- Symptom: log shows `Connection: calling LiStartConnection` then immediately `LiStartConnection returned -1`, with no `ClStageStarting` entry. The in-app log gives no reason because moonlight-common-c's `Limelog` writes to stderr, not the HydraLog callback.
- There are two checks in `LiStartConnection` that fire silently before any stage:

  **(1) `serverCodecModeSupport == 0`** — fixed in v0.2.87. `HydraStreamSession` bypasses the upstream host-discovery state machine which normally caches this value from `/serverinfo`. `StreamManager.main()` now reads `ServerCodecModeSupport` from the live serverinfo XML and sets `_config.serverCodecModeSupport`; if the tag is absent (some Sunshine versions omit it), falls back to `0x1` (H.264). Look for `StreamManager: serverCodecModeSupport=N` in the log — N must be non-zero.

  **(2) `MAGIC_BYTE_FROM_AUDIO_CONFIG(audioConfiguration) != 0xCA`** — fixed in v0.2.88. `audioConfiguration` must be constructed via `MAKE_AUDIO_CONFIGURATION(channelCount, channelMask)` which embeds `0xCA` as the low byte (magic sentinel). Setting it to a raw integer (e.g. `1`) fails this check. `HydraStreamSession` now uses `AUDIO_CONFIGURATION_STEREO` (= `MAKE_AUDIO_CONFIGURATION(2, 0x3)` = `0x302CA`).

- If the symptom recurs: add temporary `NSLog` or stderr output inside the `if (serverCodecModeSupport == 0)` and `if (MAGIC_BYTE_FROM_AUDIO_CONFIG(...) != 0xCA)` blocks in moonlight-common-c `Connection.c` to identify which check fires.

**Exit triggers immediate stream restart — ⋯ button stops responding**
- Cause: SwiftUI `onAppear` race during UIKit modal dismiss. When `StreamFrameViewController` is dismissed, `UIHostingController` briefly becomes visible → SwiftUI re-fires `onAppear` on `StreamingView` while `appState.state` is still `.streaming` → `StreamSessionBridge.start()` runs a second time → bridge's `session` pointer replaced → first `HydraStreamSession` loses strong reference from bridge → `streamSessionDidStop` fires quickly (from first session's dismiss completion block) → bridge transitions to `.selfService` → bridge deallocs → `delegate` on first session = `nil`.
- Consequence: callbacks from the still-running `StreamManager` (stage, launchFailed, connectionStarted) fire into `nil` delegate — nothing is logged, the error is invisible.
- Fixed: `StreamSessionBridge.stop()` no longer sets `isModalPresented = false` — that flag is only cleared by `streamSessionDidStop`/`streamSessionDidFailWithError` (inside the UIKit dismiss completion). `start()` now has a `guard !isModalPresented` check that returns early if the modal is already presented, blocking the race.
- If exit-restart recurs: check whether `stop()` was changed to set `isModalPresented = false` again, or whether a new code path creates a `HydraStreamSession` without the guard.

## Updating from upstream

```sh
git remote add upstream https://github.com/moonlight-stream/moonlight-ios.git
git fetch upstream
git rebase upstream/master
# Resolve conflicts in Hydra-specific files only
git push origin master
```

Our additions are isolated to `HydraStreamSession.*`, `HydraPairSession.*`, `HydraOpus.*` — upstream changes to the streaming engine do not touch these files.
