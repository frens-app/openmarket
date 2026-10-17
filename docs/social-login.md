# Apple and Google account sign-in

The iOS app offers native Sign in with Apple and the Google Sign-In SDK.
Phone login and SMS verification are retired, including for older app versions.
Existing phone sessions remain signed in and can link Apple or Google from
Discover. The Go backend verifies signed ID tokens against the provider's public keys and the
configured audience, issuer, expiry and nonce. Identity is `(provider, subject)`;
email addresses are stored as profile data and are not used to link accounts.
Signing in with Apple and Google creates separate accounts, even if their emails
match. Ordinary sign-in never links accounts automatically; a signed-in phone
user can explicitly replace their login through the flow below.
Facebook browsing remains a separate, device-local session.

## Profile names

The `users` table has nullable `first_name`, `last_name`, and `display_name`
columns. Migration `00016_user_names.sql` adds first and last name; display name
already exists. Signup sends Google's given, family, and full names, or Apple's
full-name components and a locale-formatted display name. These are profile
metadata; identity still comes only from the verified provider token.

Apple's `.fullName` and `.email` scopes are requested during login. Because Apple may supply
names only on the first authorization, the client keeps pending names in Keychain,
scoped to the Apple user, until the backend confirms sign-in. A failed request or
app restart therefore does not discard that first response. Deletion's Apple
reauthorization does not request profile scopes.

Sign-in fills missing name fields without replacing saved names. A missing or
blank provider value stays NULL and does not block signup. `Viewer` returns all
three fields. `UpdateViewer` can change them: absent leaves the field unchanged,
while present-and-empty clears it. First and last names allow 256 Unicode code
points each, display name 512. Account deletion clears all three columns.

Successful account linking also returns these three separate name fields and
the new sign-in provider. iOS saves the full returned `Viewer` in Keychain, so
the updated provider and names remain available after an offline app restart.
Linking fills missing names without replacing existing profile names.

See [Apple's native sign-in guide](https://developer.apple.com/documentation/authenticationservices/implementing-user-authentication-with-sign-in-with-apple)
and [Google profile fields](https://developers.google.com/identity/sign-in/ios/people).

## Facebook connection history

`users.facebook_last_connected_at` is the most recent connection reported on any
of the account's installs. NULL means no connection has been recorded. Migration
`00017_user_facebook_connection.sql` backfills it from device connection dates.
The timestamp advances on a disconnected-to-connected transition, stays unchanged
on repeat reports, and remains after disconnecting. Account deletion clears it.

Current status stays on `user_devices`: `facebook_connected`,
`facebook_connected_at`, and `facebook_disconnected_at`. The account timestamp is
history, not proof that Facebook is still available on the phone in use. Reports
come from the app's cookie check, not a Facebook OAuth grant or a server-verified
session. Facebook cookies and credentials are never sent to our backend.

The app reports its existing browser session after app-account sign-in or
restoration, including sign-in from Settings, and on foreground/session changes.
A new Apple/Google account can therefore record the Facebook session already on
that install without opening Facebook login again.

## Email

Migration `00018_user_email.sql` adds nullable `users.email`. Sign-in saves the
email claim from the verified Apple/Google ID token only when `email_verified`
is true (including Apple's string `"true"` form). The client cannot submit a
separate email address. Apple's private relay addresses are stored as supplied.

A later sign-in updates the email when the provider supplies a verified address.
A missing, blank, or unverified address does not erase an existing value or block
sign-in. Existing accounts populate this column on their next provider sign-in;
refreshing an Openmarket session does not fetch provider profile data. Account
deletion clears it. Email is not sent to PostHog or used as an account identifier.

Provider claims: [Apple identity token](https://developer.apple.com/documentation/signinwithapple/receiving-a-users-identity-token)
and [Google backend authentication](https://developers.google.com/identity/sign-in/ios/backend-auth).

## Provider setup

Configure development and production separately. Debug's bundle ID is
`lol.frens.openmarket.dev`; Release's is `lol.frens.openmarket`.

### Apple

1. Enable **Sign in with Apple** for each App ID in Apple Developer. Regenerate
   provisioning profiles; `project.yml` includes the entitlement.
2. Set backend `APPLE_CLIENT_ID` to the bundle ID for that deployment. A production
   backend should accept only the production bundle ID.
3. Create a Sign in with Apple key and download its `.p8` file. Configure backend
   `APPLE_TEAM_ID`, `APPLE_SIGN_IN_KEY_ID`, and `APPLE_SIGN_IN_PRIVATE_KEY` (PEM text; literal
   `\n` escapes also work). Keep the private key on the backend only.
4. On account deletion, the app asks the user to authorize Apple again. The backend
   verifies that this is the same account, exchanges the fresh authorization code,
   revokes the Apple grant, then deletes the app account. No Apple refresh tokens
   are stored. Cancellation or a provider failure leaves the account intact.

`APPLE_SIGN_IN_KEY_ID` is the identifier shown under the key's name in
Apple Developer > Certificates, Identifiers & Profiles > Keys.
`APPLE_SIGN_IN_PRIVATE_KEY` contains that key's full `.p8` contents. These
credentials authorize Sign in with Apple token exchange and revocation;
APNs credentials authorize push notifications and belong in separate settings.
See [Apple's key identifier guide](https://developer.apple.com/help/account/keys/get-a-key-identifier/).

### Google

1. Configure Google Auth Platform branding, audience/test users and the consent
   screen. Create an **iOS OAuth client** for each bundle ID.
2. Create a **Web application OAuth client** for the backend token audience.
3. In `Configurations/Debug.local.xcconfig` or `Release.local.xcconfig`, set:

   ```xcconfig
   GOOGLE_IOS_CLIENT_ID = your-ios-client.apps.googleusercontent.com
   GOOGLE_SERVER_CLIENT_ID = your-web-client.apps.googleusercontent.com
   GOOGLE_REVERSED_CLIENT_ID = com.googleusercontent.apps.your-ios-client
   ```

4. Set backend `GOOGLE_CLIENT_ID` to the same **web client ID** used by that build.
   No Google client secret is needed for ID-token verification.
5. Run `make ios-generate` and rebuild. Google callbacks use the registered reversed
   client ID URL scheme and `onOpenURL` in `OpenMarketApp`.

Configure Apple and Google before releasing the app. An unconfigured provider
returns an explicit unavailable error. When Apple sign-in is enabled in production,
its revocation signing credentials are required. Prelude is no longer initialized
or required by the API; the retired phone RPCs cannot send SMS.

## Flow and sessions

`BeginSignIn(provider, install_id)` issues a random 256-bit nonce valid for five
minutes. The app passes it unchanged to the provider. `SignIn` validates the ID
token and consumes the matching provider/install challenge in the same database
transaction that creates the app session. Replay and expired challenges fail.
Concurrent first sign-ins for one identity serialize on a database advisory lock.
Expired challenges are pruned every minute. Add edge request limiting before
exposing the unauthenticated endpoints to significant public traffic.

App access and rotating refresh tokens retain their existing behavior. Every
protected RPC checks the session row, so deletion and logout invalidate access
immediately. Apple/Google sessions use the established Keychain token and viewer keys and
keep their cached viewer during an outage. Existing phone sessions also restore
and refresh normally, including offline restoration. Apple credential state is checked on session restoration;
revoked Apple access signs the client out. The backend does not retain provider ID
tokens or put them in application logs.

## Linking existing phone accounts

Discover shows “We’re changing sign-in” with a “Link your account” button only
for signed-in phone accounts. This includes a cached viewer with a phone number
but no provider field from an older app. Guests and existing Apple/Google users
see no Discover sign-in banner or button. If the provider is unknown offline,
the app waits for a successful profile fetch rather than guessing.

The link screen uses native Apple/Google authorization. Cancelling or a failed
request keeps the existing phone account signed in. Success removes the banner
and confirms which provider to use next time. The same account ID, session tokens,
device, onboarding, saved listings, follows, and history remain in place.
Device-local viewing history remains local; linking does not add history sync.

`BeginLinkSignIn` and `LinkSignIn` require an existing authenticated session. The
five-minute challenge is bound to that exact session and the chosen provider.
Linking challenges cannot be used for ordinary sign-in or account deletion, and
sign-in challenges cannot be used for linking. ID tokens get the same signature,
audience, issuer, expiry, and nonce validation as ordinary sign-in.

One transaction attaches the provider identity to the current user ID and retains
the phone auth method. The provider identity lock is shared with ordinary sign-in;
account/session locks serialize linking with deletion, logout, and competing
link requests. An identity belonging to another account is rejected without
merging or changing either account. Retrying the same identity with a fresh
challenge is safe. Switching between social providers afterward is not supported.
Apple-linked accounts use the existing Apple reauthorization/revocation flow for
account deletion.

Analytics continues to use the original user ID. Linking does not reset analytics
or emit `account_created` / `account_signed_in`. It emits `account_sign_in_linked`
with `sign_in_provider` and refreshes profile properties on the existing identity.
Subsequent Apple/Google sign-in resolves to that same user ID.

Migration `00023_link_sign_in.sql` only adds a nullable session binding to the
challenge table; it does not purge users or invalidate sessions. Phone sign-in
remains retired: `GetSignInOptions` returns no countries, and the verification
RPCs return an error without sending SMS or issuing sessions, even for old apps.
The phone method remains stored after linking; it does not enable phone sign-in.
When reading the account's sign-in provider, Apple or Google takes precedence over
the retained phone record, including session restoration and Apple account deletion.

Deploy the backend migration before the iOS build. Verify Apple/Google production
configuration and real authorization on a device. Keep `JWT_SECRET` and
`REFRESH_TOKEN_HMAC_KEY` unchanged so existing sessions survive. A user who has
already lost their phone session cannot recover that account through ordinary
Apple/Google sign-in; linking requires proof of the existing account session.

## Validation

Run `go build ./...`, `go vet ./...`, and `go test ./...` in `apps/backend`.
For the integration test, create a **fresh disposable Postgres 18 database** with
its name ending in `_auth_test`, and run:

```bash
AUTH_TEST_DATABASE_URL=postgres://…/openmarket_auth_test go test ./cmd/api -run TestSocialAuthIntegration -count=1
```

The test installs the phone-only schema, creates a phone account/session and
associated data, and checks that the additive migration preserves them. It tests
retired phone RPCs over HTTP, authenticated linking, unchanged user IDs and
history, conflicts, concurrent linking, social login/signup, refresh rotation,
and social challenge expiry/replay/binding, provider
separation, concurrent signup, profile names, account deletion, and Facebook
connection history. SMS and identity providers use test doubles.

Before release, use a physical device with configured provider accounts to check
both signup and returning login, cancellation, incorrect-account Apple deletion,
logout, reinstall, offline restore, and account deletion. Confirm production
provisioning includes Sign in with Apple and test the Google callback URL. Update
App Store privacy disclosures to match the provider account identifier collection.

## Provider references

- [Google iOS setup](https://developers.google.com/identity/sign-in/ios/start-integrating)
- [Google backend authentication](https://developers.google.com/identity/sign-in/ios/backend-auth)
- [Apple identity verification](https://developer.apple.com/documentation/signinwithapple/verifying-a-user)
- [Apple deletion and token revocation](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple)
