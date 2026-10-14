# Apple and Google account sign-in

The iOS app offers native Sign in with Apple and the Google Sign-In SDK.
Phone login and signup remain available through the backend for older app versions. The Go
backend verifies signed ID tokens against the provider's public keys and the
configured audience, issuer, expiry and nonce. Identity is `(provider, subject)`;
email addresses are stored as profile data and are not used to link accounts.
Signing in with Apple and Google creates separate accounts, even if their emails
match. Phone accounts also remain separate; there is no automatic account linking.
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

Apple and Google configuration is optional during the transition, including in
production. An unconfigured provider returns an explicit unavailable error. When
Apple sign-in is enabled in production, its revocation signing credentials are
required. Existing Prelude configuration remains required for phone login;
development's phone verification bypass is forbidden in production. See
[phone-login.md](phone-login.md) for the SMS setup and country allowlist.

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
immediately. All three sign-in methods use the established Keychain token and
viewer keys, so existing phone sessions restore on upgrade and keep their cached
viewer during an outage. Apple credential state is checked on session restoration;
revoked Apple access signs the client out. The backend does not retain provider ID
tokens or put them in application logs.

## Gradual rollout

Migration `00015_social_auth.sql` adds APPLE and GOOGLE to the auth enum and creates
`sign_in_challenges`. It preserves PHONE, the verification-send ledger, all
accounts, sessions, devices, price checks, photo metadata, and model-usage history.
The existing `GetSignInOptions`, `StartPhoneVerification`, and `VerifyPhone` RPCs
and the `Viewer.phone_number` field remain compatible with older app versions.
Phone verification continues to support both returning users and new accounts.

The new app offers Apple/Google sign-in only.
Updating the app does not force logout, reset onboarding, or remove Facebook
cookies. Existing phone sessions keep access to their saved history; signing in
by phone after logout requires an older app version. Choosing Apple/Google
creates a separate account unless that provider
identity already has an account; linking providers to a phone account is not
implemented in this iteration.

Keep Prelude credentials, the existing country allowlist and SMS spend controls,
`JWT_SECRET`, and `REFRESH_TOKEN_HMAC_KEY` unchanged during rollout. Phone login
still incurs its normal SMS fees while it is enabled. The social provider setup
can be completed separately, without interrupting the phone service.

Migrations run at backend startup. Deploy the compatible backend before the new
iOS build. Disabling phone login, retiring old app versions, and any account/data
purge belong to a later release. No production migration is run as part of
preparing this code change.

## Validation

Run `go build ./...`, `go vet ./...`, and `go test ./...` in `apps/backend`.
For the integration test, create a **fresh disposable Postgres 18 database** with
its name ending in `_auth_test`, and run:

```bash
AUTH_TEST_DATABASE_URL=postgres://…/openmarket_auth_test go test ./cmd/api -run TestSocialAuthIntegration -count=1
```

The test installs the phone-only schema, creates a phone account/session and
associated data, and checks that the additive migration preserves them. It tests
legacy phone RPCs over HTTP, login/signup, refresh rotation, country restrictions,
and the send ceiling, plus social challenge expiry/replay/binding, provider
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
