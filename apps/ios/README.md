# iOS app

SwiftUI. The Xcode project is **generated** — `project.yml` is the source of
truth and `make ios-generate` writes `OpenMarket.xcodeproj` from it. Anything
typed into Xcode's own panes survives exactly until the next regenerate.

## Two builds

| | Debug | Release |
|---|---|---|
| Bundle id | `lol.frens.openmarket.dev` | `lol.frens.openmarket` |
| Home screen | **Open Market Dev** | **Open Market** |
| Backend | `http://localhost:8080` | `https://api-production-22b5.up.railway.app` |
| APNs | `development` | `production` |

Different bundle identifiers, so **they install side by side**. A dev build
cannot overwrite the App Store one, and the two share no keychain, no container
and no UserDefaults — signing in to one leaves the other signed out, which is
the point.

Both names fit on the home screen untruncated. A freshly installed app shows a
"new" dot that steals label width and clips the longer one to "OpenMarket…" —
that is transient, and it clears the first time the app is launched.

Inside the app, Debug builds show the backend and bundle id under
**Settings → Build**, and every launch logs one line:

```
[openmarket] lol.frens.openmarket.dev → http://localhost:8080
```

## Where the differences live

`Configurations/Debug.xcconfig` and `Configurations/Release.xcconfig`. Nothing
environment-shaped belongs anywhere else — not in `#if DEBUG`, not in
`project.yml`'s `settings`, and not in Xcode.

`#if DEBUG` is a *compiler* flag rather than a build configuration: it cannot
describe a third environment, and it is invisible to the Info.plist, which is
what the app actually reads at runtime. The endpoint used to be a `#if DEBUG`
branch with an environment-variable override, and the override only existed when
Xcode launched the process — so it silently did nothing on TestFlight or on a
device launched from the home screen.

Two settings for the endpoint rather than one URL, because **xcconfig treats
`//` as a comment**: `API_BASE_URL = https://x.com` quietly becomes `https:`.

`API.baseURL` reads both keys out of the Info.plist and **fails the launch** if
they are missing, or if a Release build is configured for cleartext. A build
misconfiguration is identical on every launch, so failing loudly surfaces it the
first time anyone runs that build — the alternative is a login screen where every
attempt reports "couldn't reach the server", which looks like an outage.

## Pointing Debug somewhere else

```bash
cp apps/ios/Configurations/Debug.example.xcconfig apps/ios/Configurations/Debug.local.xcconfig
```

Gitignored, `#include?`d by `Debug.xcconfig`, and it overrides only what it
sets. This is how you point at a physical device's reachable host or at Railway
without editing a committed file — and without accidentally committing it.

**A physical device needs an https host.** The app ships no ATS exception, so
plain HTTP to a LAN address is blocked. The Simulator is fine on `localhost`
because ATS exempts loopback. `project.yml` records why a per-configuration
exception isn't expressible here: plist substitution produces strings, and
`NSAllowsLocalNetworking` is specified as a Boolean, so `$(…)` would yield an
exception that may simply be ignored.

## Running on a physical device

The phone is a different machine on a different network, so it needs a real
hostname with a real certificate in front of `make dev`. Tailscale Serve gives
one, without an account at a tunnel vendor and without opening anything to the
internet — the address resolves only for devices signed into your tailnet.

**`make dev` sets the tunnel up for you** — it registers
`https://<your-mac>.<your-tailnet>.ts.net:8443` → `127.0.0.1:8080` with
`tailscaled` before starting the API. `--bg`, so the mapping survives a reboot
and holds no terminal, which makes every run after the first a check rather than
a change.

Two things it won't do, both because they're yours to click:

- **Turn Serve on for the tailnet.** It's off until an owner enables it at
  [login.tailscale.com](https://login.tailscale.com/admin/settings/features), and
  the CLI's response is to print the link and block until somebody clicks. `make
  dev` gives that 15 seconds, prints the link, and carries on to the API rather
  than hanging on you. Enable it, then `make tunnel` — that one *does* wait.
- **Sign the devices in.** The Tailscale app running on the Mac, and the iPhone
  on the same account. If either is off, `make dev` says so and keeps going —
  Simulator work needs no tunnel, so a missing one is a note, not an error.

`make tunnel-status` prints what's registered plus the two lines for
`Debug.local.xcconfig`; `make tunnel-stop` removes the mapping.

Port 8443 rather than 443, because **the Serve config belongs to the Mac, not to
this repo.** Every checkout on the machine shares one set of mappings, and 443 is
the one another project is most likely to have taken for a web surface — taking
it here would silently repoint theirs. It's the tailnet-side port only; the API
still listens on 8080, read from `.env.development` so the two can't drift.

That sharing cuts both ways: another repo whose API also runs on 8080 wants the
identical `8443 → 127.0.0.1:8080` mapping, so `make tunnel` finds it already
registered and leaves it alone. Which one the phone actually reaches is decided
by which API is running — and since they'd both bind 8080, only one can be.
`make tunnel-status` prints every mapping on the machine, not just this one's.

So the everyday loop is:

1. `make dev`
2. `make ios-generate`, then run the **OpenMarket** scheme in Xcode with the
   device selected.

The endpoint is compiled into the Info.plist, so changing it means editing
`Debug.local.xcconfig` and rebuilding — there is no runtime setting, deliberately
(`APIClient.swift` says why). This is also the argument for Serve over ngrok:
ngrok mints a new hostname per run, and each one costs that edit-and-rebuild.

`make ios-build-device` compiles Debug for `generic/platform=iOS` with no phone
attached — the quick way to find a missing provisioning profile, since a
simulator build signs ad-hoc and proves nothing about device signing.

Nothing on the server side needs configuring: it binds `:8080` on every
interface, Serve reaches it over loopback, and Connect carries no browser-style
origin check for the tunnel to trip over.

If the phone reports it can't find the server, that device isn't resolving
`*.ts.net` — check Tailscale DNS is on. A certificate error usually means the
hostname in `Debug.local.xcconfig` is stale; `make tunnel-status` prints the
current one.

## Before a device build or an archive

Both bundle identifiers need their own App ID in the developer portal, each with
**Push Notifications enabled** — without it the entitlement is present, the build
succeeds, and APNs refuses a token at runtime.

Build numbers live in the xcconfigs. Only `Release.xcconfig` tracks one that
ships; Debug pins a throwaway `1`.

## Commands

```bash
make ios-generate     # rewrite OpenMarket.xcodeproj from project.yml
make ios-build        # Debug, simulator
make ios-build-device # Debug, generic iOS device — checks signing
make ios-build-release
make ios-settings     # print the resolved per-configuration settings

make tunnel           # expose the API on the tailnet — `make dev` does this too,
                      #   but this one waits while you enable Serve
make tunnel-status    # what's registered, and the xcconfig lines for it
make tunnel-stop
```
