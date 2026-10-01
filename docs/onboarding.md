# Onboarding: optional account, location, and Facebook

**Code:** `apps/ios/Sources/UI/OnboardingView.swift`,
`apps/ios/Sources/UI/OpenMarketApp.swift`,
`apps/ios/Sources/UI/AccountGateView.swift`
**Related:** `phone-login.md`, `location-targeting.md`,
`logged-in-findings.md`, `app-store.md`, `analytics.md`

## 1. The first run

**Optional phone verification → Location → optional Facebook → optional
notifications for verified accounts → Browse.** Browsing, local saves, viewing
history and buyer-side price comparisons do not require an Openmarket account.

## 2. The order

| Step | Required | Actions |
|---|---|---|
| Phone | No | Verify a number, or Not now — browse without an account |
| Location | Yes, a supported browsing place | Use current location, or search for a city or ZIP without location permission |
| Facebook | No | Connect Facebook, or Browse without Facebook |
| Notifications | No; only for verified accounts with undetermined permission | Turn on notifications, or Not now |

`OnboardingView.current` starts at `.phone`; an existing Openmarket session skips
to `.location`. The phone skip action stays outside the scrolling form, including
on the code-entry screen. Late verification callbacks cannot advance another
step after the user skips. Skipping phone does not create an account.

Only explicit actions advance the flow. Progress includes notification setup
only for an account that can still be asked. Quitting before completion restarts
the flow, skipping phone if already verified. Facebook benefits scroll separately
from its buttons so the skip action stays accessible.

## 3. When onboarding appears

`RootView` waits for account restoration and then checks
`Preferences.needsOnboarding`:

```swift
!hasCompletedOnboarding || !hasBrowseablePlace
```

Being signed out is not a reason to open onboarding. Declining Facebook does not
make onboarding incomplete. Signing out or an expired Openmarket session leaves
a completed browsing setup intact.

Visibility is latched: `openIfNeeded` can open onboarding, but only `finish`
closes it. A pending place resolution settles before completion; failure returns
to the location screen with its error. A supported place is required even when
the user skips Facebook.

Signing into an account after guest onboarding pushes local completion to the
server rather than restarting the flow for a server-side `false`. Changing to a
different account or deleting an account resets the install's onboarding state.
Debug Settings → Restart onboarding resets the setup without signing out.

## 4. The location step

`PlaceChooser` resolves a device coordinate or an Apple city-search result
through Facebook's place picker. Device location permission is optional; manual
city or ZIP search is a full alternative. The map shows a pending choice while
it resolves, and resolution can continue during the Facebook step.

The existing limitation remains: there is no invented place-slug fallback if
Facebook's place picker is unavailable. Test this path with a clean, signed-out
Facebook session before release (`location-targeting.md`).

## 5. The Facebook step

The primary action is **Connect Facebook**. Benefits describe seller information,
more listings, and personalized results, based on `logged-in-findings.md`.
**Browse without Facebook** is a plainly visible secondary action. An already
connected session instead offers **Start browsing**.

Connecting opens Facebook's own page in `SignInView`. Closing or dismissing that
sheet returns to the step and does not require completion. Cookie detection
updates `ListingStore` and reports the connection to an Openmarket account only
if one exists. An Openmarket account is never created by connecting Facebook.

Signed-out results can have less seller information and limited pagination.
Guest browsing must be verified with live listings and empty cookie stores;
removing the app's signup requirement cannot guarantee Facebook availability.

## 6. Notifications

After Facebook, verified accounts are offered notification setup if iOS has no
permission decision yet. Both “Not now” and denying the system prompt continue
to Browse. Guests are never prompted. Already authorized accounts register
with APNs without another prompt. Seller Price Check and Settings sign-in do
not request notification permission.

The push token is registered against a verified Openmarket account. This is
separate from local saves, which work without an account. Token registration
does not by itself establish that alert delivery works; verify the delivery
service separately before promising alerts.

## 7. Verification

- Clean install: skip phone, manually choose a supported city, skip Facebook, reach real
  listings without a phone number, and open/search/filter/save listings.
- Verify phone: complete SMS verification, then finish setup with notifications
  accepted, denied, and skipped. Guests must never see notification setup.
- Facebook step: connect successfully, cancel login, dismiss the sheet, and
  skip. Check both a small screen and large accessibility text.
- Deny device location permission and use manual city search.
- Fail place resolution: show its error, allow retry, and never silently browse
  the fallback city. Retrying completion must not create duplicate work.
- Relaunch as a guest; sign in later; sign out; expire the Openmarket session.
  Completed browsing setup should remain usable.
- Start seller Price Check: the account gate is dismissible and preserves the
  entered description/photo. Completing it resumes the requested check.
- Confirm account-backed pricing and history APIs still reject missing tokens.

## 8. The account gate

Phone verification creates or restores an Openmarket account. It is required for
seller Price Check: item identification, saving completed checks, reading the
account's previous checks, and recording feedback/copy actions on those checks.
`PricingService` calls authenticated APIs for these operations.

Seller Price Check also requires a Facebook connection for comparable searches.
`AccountGateView` opens phone verification first, then an onboarding-style
Facebook introduction. The user taps “Connect Facebook” to open the login page;
returning from that page resumes the check only if the session is connected. It skips
any step whose session already exists and resumes automatically when both are
connected. Neither is required
for browsing or for the buyer-side “is this a good price?” comparison, which
runs on-device. Local saves and recently viewed listings do not sync to the
Openmarket account.

The gate appears on submission, not when opening Tools or filling out the form.
“Cancel” is available throughout and preserves the draft. Completing phone
verification creates or restores the account even if the user later cancels
Facebook login; the next attempt resumes with Facebook. On success, the original
submission resumes after the sheet dismisses. There is no notification prompt.

Authentication remains enforced by the backend. No pricing or account endpoint
becomes public as part of this onboarding change. The account-backed history is
the product rationale for the phone account; App Review may still assess the
seller tool separately from the browsing issue.

### Verification performed, 2026-09-30

The simulator build and all 40 existing iOS unit tests passed. Backend build,
vet, and tests also passed. On a newly created iPhone 17e simulator (iOS 26.3),
manual San Francisco selection led to the optional Facebook step; opening and
cancelling login preserved the skip action. Skipping loaded real Discover
listings, a listing could be opened, and a guest relaunch went directly to
Browse. Tools and the seller Price Check form were accessible; its separate
account gate showed both requirements and could be dismissed.

This used the Debug build. Successful Facebook authentication, phone
verification, the full search/filter/save matrix, accessibility text sizes, and
the exact release build on a physical device remain release QA items.

The sequential Price Check sign-in update passed all 44 iOS unit tests, including
the four phone/Facebook session combinations. On the iPhone 17 Pro simulator,
the gate opened directly to phone verification and Cancel returned to the
unchanged draft. Live phone and Facebook authentication remain unverified.

The optional-phone onboarding update passed all 49 iOS unit tests. The installed
iPhone 17 Pro simulator build opens on phone entry with the guest skip action
visible. Automated tapping was blocked by a simulator window-control error;
live SMS verification and notification permission/token delivery remain QA items.
