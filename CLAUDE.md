# hydra-moonlight-ios

Fork of `moonlight-stream/moonlight-ios` for ExperienceNet's iPad kiosk head.

## Purpose

This fork adds `HydraStreamSession` — a minimal Objective-C API that lets HydraHeadiPad start and stop a Moonlight GameStream session without wiring into Moonlight's internal host/app discovery state machines. The upstream UI (host browser, app list, settings) is compiled in but never shown.

## Hydra additions

| File | Purpose |
|------|---------|
| `Limelight/HydraStreamSession.h` | Public API: `startWithHost:appName:width:height:bitrateKbps:serverCert:presenter:` and `stop` |
| `Limelight/HydraStreamSession.m` | Wires into `StreamConfiguration` + `StreamFrameViewController` |

## How it's consumed

HydraHeadiPad adds this repo as a git submodule at `Vendors/hydra-moonlight-ios/`. XcodeGen compiles the Limelight C/ObjC sources directly into the app target. No separate framework build step.

## Upstream sync

Commits go directly to `master`. Periodically rebase onto `upstream/master` (moonlight-stream/moonlight-ios) to pick up streaming engine improvements. Our only changes are the two files above — no modifications to upstream streaming logic.

## Related repos

- `cederikdotcom/hydraheadipad` — the iOS kiosk app that uses this fork
- `cederikdotcom/hydra-moonlight-web-stream` — equivalent web streaming fork (Rust)
