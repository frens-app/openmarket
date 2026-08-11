# iOS app

SwiftUI. The Xcode project is **generated** — `project.yml` is the source of
truth and `make ios-generate` writes `OpenMarket.xcodeproj` from it. Anything
typed into Xcode's own panes survives exactly until the next regenerate.

## Two builds

| | Debug | Release |
|---|---|---|
| Bundle id | `lol.frens.openmarket.dev` | `lol.frens.openmarket` |
| Home screen | **Open Market Dev** | **Open Market** |
| Backend | `http://localhost:8080` | `https://api.openmarket.app` |
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

## Before a device build or an archive

Both bundle identifiers need their own App ID in the developer portal, each with
**Push Notifications enabled** — without it the entitlement is present, the build
succeeds, and APNs refuses a token at runtime.

`Release.xcconfig` still points at the placeholder `api.openmarket.app`. Replace
it with the Railway service domain before the first archive.

Build numbers live in the xcconfigs. Only `Release.xcconfig` tracks one that
ships; Debug pins a throwaway `1`.

## Commands

```bash
make ios-generate    # rewrite OpenMarket.xcodeproj from project.yml
make ios-build       # Debug, simulator
make ios-build-release
make ios-settings    # print the resolved per-configuration settings
```
