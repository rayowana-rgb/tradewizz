# Google & Apple Sign-In

TradeWizz supports signing in / registering with Google or Apple in addition to
email + password. We never store a social password or any long-lived provider
token: the app obtains a short-lived **ID token**, sends it to the backend, the
backend verifies it server-side, and only the resulting **TradeWizz JWT** is
persisted on the device (same as email login).

## Flow

1. User taps **Continue with Google** / **Continue with Apple** on the Account
   tab (logged-out view).
2. Flutter (`lib/services/social_sign_in.dart`) runs the native flow and gets an
   ID token.
3. Flutter POSTs `{ "id_token": "..." }` to `POST /v1/auth/google` or
   `POST /v1/auth/apple`.
4. The backend verifies the token signature against the provider JWKS and
   validates issuer / audience / expiry / (Google) email_verified / (Apple)
   subject, then returns the standard `AuthResponse`
   (`access_token`, `token_type`, `user`).
5. Flutter stores only the TradeWizz session.

## Backend configuration (env only — never commit secrets)

Set these in the backend `.env` (see `backend/.env.example`):

```
TRADEWIZZ_GOOGLE_CLIENT_ID=<google-oauth-client-id>   # the ID token `aud`
TRADEWIZZ_APPLE_CLIENT_ID=<apple-services-id-or-bundle-id>
```

If a value is blank, the matching endpoint returns a clear error:

- `503 "Google Sign-In is not configured."`
- `503 "Apple Sign-In is not configured."`

## Account model

The `users` table gains `provider` (`EMAIL` / `GOOGLE` / `APPLE`) and
`provider_user_id` (the verified `sub`). EMAIL users keep their bcrypt
`password_hash`; GOOGLE/APPLE users store an **empty** hash.

### Account linking (intentionally conservative)

If a Google/Apple login presents an email that already belongs to a different
account, the backend does **not** auto-link or touch the existing
`password_hash`. It returns:

> `409 "An account with this email already exists. Please login with email
> first to link Google/Apple."`

This avoids unsafe automatic linking (option B in the spec). Linking can be
added later behind an explicit, authenticated "link provider" action.

## Native platform setup (required for the real flow at runtime)

The plugins (`google_sign_in`, `sign_in_with_apple`) need platform config. Tests
inject a fake `SocialSignIn`, so they pass without this, but real devices need:

### iOS

- Add the **Sign in with Apple** capability in Xcode (Runner target →
  Signing & Capabilities).
- Add the Google reversed-client-id URL scheme to `Info.plist` (from the
  `GoogleService-Info.plist` / OAuth iOS client), e.g.:

  ```xml
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLSchemes</key>
      <array><string>com.googleusercontent.apps.XXXX</string></array>
    </dict>
  </array>
  ```

### Android

- Google Sign-In needs the app's SHA-1/SHA-256 registered in the Google Cloud
  OAuth client (Android client). Apple Sign-In is iOS/macOS only — the Apple
  button is hidden on Android by `SocialSignIn.appleAvailable`.

## Button visibility

- **Google**: shown on iOS, Android (and web).
- **Apple**: shown on iOS / macOS only.
- Email **Login** and **Register** are always shown when logged out.
