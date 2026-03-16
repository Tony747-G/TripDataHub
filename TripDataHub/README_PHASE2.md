# BidProSchedule Phase 2

Phase 2 adds the authentication foundation:

- `WKWebView` login screen for TripBoard (`TripBoardLoginView`)
- Session detection via current URL + TripBoard cookies
- Cookie persistence to Keychain (`KeychainService`, `TripBoardAuthService`)
- Home `Sync` flow now opens login when unauthenticated

## Current Behavior

1. Open app
2. Tap `Sync`
3. If unauthenticated, login sheet opens (`WKWebView`)
4. On successful login detection, cookies are stored in Keychain and auth state becomes `loggedIn`
5. Data sync remains stubbed (Phase 3)
