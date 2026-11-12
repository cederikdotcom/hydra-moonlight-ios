# hydra-moonlight-ios

Fork of `moonlight-stream/moonlight-ios` for ExperienceNet's iPad kiosk head.

## Purpose

This fork adds `HydraStreamSession` — a minimal Objective-C API that lets HydraHeadiPad start and stop a Moonlight GameStream session without wiring into Moonlight's internal host/app discovery state machines. The upstream UI (host browser, app list, settings) is compiled in but never shown.

## Hydra additions

| File | Purpose |
|------|---------|
| `Limelight/HydraStreamSession.h` | Public API: `startWithHost:appName:width:height:bitrateKbps:serverCert:presenter:` and `stop` |
| `Limelight/HydraStreamSession.m` | Wires into `StreamConfiguration` + `StreamFrameViewController` |
| `Limelight/Input/NativeTouchHandler.h` | Native touch handler interface |
| `Limelight/Input/NativeTouchHandler.m` | Sends `LiSendTouchEvent()` for true multi-touch passthrough; falls back to absolute mouse when host doesn't support it |
| `Limelight/Input/StreamView.h` | Exposes `adjustCoordinatesForVideoArea:` and `getVideoAreaSize` (used by `NativeTouchHandler`) |
| `Limelight/Input/StreamView.m` | Uses `NativeTouchHandler` instead of `RelativeTouchHandler`/`AbsoluteTouchHandler` |
| `Limelight/Input/HydraSyntheticController.h` | Plays a scripted gamepad, text and key sequence into a live stream (issues 1155, 1159) |
| `Limelight/Input/HydraSyntheticController.m` | Drives `ControllerSupport` and `LiSendUtf8TextEvent`/`LiSendKeyboardEvent` from a private serial queue |
| `Limelight/Stream/HydraFrameCapture.h` | Decodes one key frame a second time so an admin screenshot shows the game, not a black rectangle (issue 1162) |
| `Limelight/Stream/HydraFrameCapture.m` | `VTDecompressionSession` on a private serial queue; the main thread only retains the frame |
| `Limelight/Stream/VideoDecoderRenderer.h` | Adds `hydraCaptureVideoFrameWithCompletion:`, `hydraVideoRectInWindow` and `hydraRunWithVideoBackgroundClear:` |
| `Limelight/Stream/StreamManager.h` | Exposes `hydraVideoRenderer`, the only accessor for the renderer |

## How it's consumed

HydraHeadiPad adds this repo as a git submodule at `Vendors/hydra-moonlight-ios/`. XcodeGen compiles the Limelight C/ObjC sources directly into the app target. No separate framework build step.

## Upstream sync

Commits go directly to `master`. Periodically rebase onto `upstream/master` (moonlight-stream/moonlight-ios) to pick up streaming engine improvements. Hydra-specific changes are the files listed in the table above.

## Related repos

- `cederikdotcom/hydraheadipad` — the iOS kiosk app that uses this fork
- `cederikdotcom/hydra-moonlight-web-stream` — equivalent web streaming fork (Rust)
