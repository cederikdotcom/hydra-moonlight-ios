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
8. If `PairCallback -alreadyPaired` fires (client already registered with Sunshine), `HydraPairSession` sends `GET http://<host>:47989/unpair?uniqueid=<id>` and then re-initiates pairing so the full handshake runs and the server cert is returned. A `hasAttemptedUnpair` flag prevents an infinite loop.

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
