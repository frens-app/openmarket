# Phone login and iOS verification-code AutoFill

**Date:** 2026-08-11
**Code:** `apps/ios/Sources/UI/PhoneLoginView.swift`,
`apps/ios/Sources/Account/AccountSession.swift`,
`apps/backend/cmd/api/auth.go`, `apps/backend/pkg/verify/prelude.go`
**Related:** `onboarding.md`, `backend.md` §3

Phone login is the first required step of onboarding. The app asks for a US
phone number, Prelude sends a one-time code, and the backend exchanges an
approved code for the app's own session. Facebook sign-in is a separate session
for Marketplace browsing and is not part of this flow.

This document records the client behavior that works on a physical iPhone, the
iOS setting that can remove used codes from Messages or Mail, and the AutoFill
failure modes found while building the flow.

## The user flow

1. The phone field accepts ten national digits. Contact AutoFill may provide a
   complete `+1` number, so the model removes one leading US country code before
   creating E.164.
2. `StartPhoneVerification` asks Prelude to deliver a code and returns the code
   length and resend cooldown.
3. The code field becomes focused after it has appeared. iOS detects the code in
   Messages and offers it above the keyboard.
4. Tapping the suggestion fills the field. It does **not** submit.
5. Continue becomes available only when the field contains the exact number of
   digits reported by the server. Tapping Continue normalizes the digits and
   calls `VerifyPhone`.
6. A failed check leaves the entered code visible. A successful check creates or
   restores the account session and advances onboarding.

The deliberate extra Continue tap makes text entry and server verification two
observable events. A delivery, network or provider error can no longer erase the
field quickly enough to look like AutoFill failed.

## The native iOS contract

The verification UI is one ordinary SwiftUI `TextField`:

```swift
TextField("000000", text: $model.code)
    .keyboardType(.numberPad)
    .textContentType(.oneTimeCode)
```

Keep it as one field. Six visual digit boxes usually require custom distribution
logic for paste and AutoFill, while one field marked `.oneTimeCode` is the path
iOS is designed to fill.

Do not rewrite the binding from `onChange` while the system is inserting text.
The earlier implementation filtered and reassigned `code` on every change, then
started an unstructured task that submitted as soon as the expected length was
reached. That created two ways for a successful insertion to appear blank:

- a binding write could race the one-shot AutoFill edit; and
- any verification failure immediately assigned `code = ""`.

The current implementation lets the native field own entry. Normalization waits
until the explicit Continue tap, when there is no in-flight keyboard edit to
overwrite.

## Apple's automatic cleanup setting

Apple lets the person using the phone decide whether consumed verification-code
messages are retained:

- On current iOS versions: **Settings → General → AutoFill & Passwords →
  Verification Codes → Delete After Use**.
- On iOS 17: **Settings → Passwords → Password Options → Clean Up
  Automatically**.

When enabled, iOS deletes a verification code from Messages or Mail after the
code has been entered with AutoFill. Tapping the suggestion above the keyboard
is the relevant AutoFill action. This is expected system behavior, not deletion
performed by Open Market or Prelude. The app cannot enable, disable or observe
the preference and must not depend on the original message remaining available.

Apple documents the current setting in
[Automatically fill in one-time verification codes on iPhone](https://support.apple.com/en-euro/guide/iphone/ipha6173c19f/ios).

This setting is also useful when testing: after a successful fill, the source
message may disappear before someone returns to Messages to inspect it. That is
not evidence that delivery failed.

## Layout and focus lessons

### Treat keyboard accessories as variable-height UI

The phone and code suggestions live in the keyboard's AutoFill/QuickType area.
That area can appear or disappear after a suggestion is selected, changing the
keyboard safe area while the keyboard itself remains visible.

The original login form sat between flexible spacers above and below. Every
keyboard-height change altered the available height and vertically recentered
the entire form, producing a visible jump. The form is now top-anchored inside a
vertical `ScrollView`: keyboard changes happen below the content, and smaller
phones can still scroll to every control.

Do not automatically dismiss the keyboard when a full code arrives. Besides
being an unexpected side effect of filling rather than submitting, a keyboard
dismissal creates a much larger geometry change. A successful Continue naturally
moves to the next screen; a failed Continue should leave the keyboard available
for correction.

### Focus only fields that exist

The phone and code fields occupy opposite branches of the same view. Assigning
the code focus in the exact state update that removes the phone field can target
a field that has not been mounted yet, leaving the outgoing phone field as first
responder. The current code yields one main-actor turn after `step` changes, then
focuses the newly created field.

The appearance of a code suggestion proves that iOS recognized something code-
like in the message. It does not by itself prove that the visible code field is
the current first responder, so focus remains one of the first things to check
when a suggestion appears but a tap seems inert.

## Server and provider lessons

The app and backend divide responsibility deliberately:

- The backend reports `code_length`; the client does not assume every provider
  or configuration uses six digits.
- The client requires exactly that many digits before enabling Continue.
- Prelude owns code generation, delivery, expiry and attempt limits.
- The backend owns session creation only after Prelude approves the check.

`PreludeSender.Start` now logs every provider send status and reason. This
matters because a successful HTTP response is not synonymous with an SMS:
Prelude can return statuses such as `challenged`, `shadow_blocked` or `blocked`.
The log intentionally records provider status without recording the phone number
or verification code.

Keep these failure domains separate during diagnosis:

| Observation | Likely layer |
|---|---|
| No suggestion above the keyboard | SMS content/delivery, iOS recognition, or field content type |
| Suggestion appears but tapping it changes no visible text | Field focus or client binding mutation |
| Code remains visible and Continue reports an error | API reachability, expired/wrong code, or provider check |
| Backend accepted the send but no SMS arrived | Provider status/channel; inspect the Prelude send log |
| Code message disappears after AutoFill | Apple's Delete After Use/Clean Up Automatically preference |

## Physical-device regression checklist

Simulator and dev-bypass testing can verify the screen and RPCs, but not the
complete SMS handoff. Before shipping a login change, use a physical iPhone and
confirm:

1. Manual ten-digit phone entry can request a code.
2. Contact AutoFill containing `+1` also enables Send code and sends the same
   E.164 value.
3. The code suggestion appears above the number pad.
4. Tapping it leaves the complete code visible and enables Continue without
   submitting.
5. The form does not jump when the phone or code suggestion disappears.
6. A rejected code remains visible with an error.
7. A correct code advances exactly once.
8. Repeat once with Delete After Use enabled and confirm that message cleanup
   does not affect the app flow.
