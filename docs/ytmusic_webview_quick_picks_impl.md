# YT Music WebView Quick Picks Implementation

Source of truth: `lib/main.dart`

Purpose: this file explains how the app now fetches YouTube Music Quick Picks
through an embedded WebView before falling back to the existing Innertube path.

## Overview

The WebView path exists to get closer to real browser behavior.

Instead of trying to reconstruct YouTube Music home requests only through
Innertube headers and request context, the app can:

1. seed the pasted YT Music cookies into an embedded browser
2. load `https://music.youtube.com/`
3. read `window.ytInitialData` from the rendered page with JavaScript
4. send a compact shelf payload back into Dart
5. reuse the existing Dart quick-shelf selection logic

If this path fails, times out, or is unsupported on the current platform, the
existing Innertube implementation still runs.

## Dependency

`pubspec.yaml` now includes:

```yaml
webview_flutter: ^4.4.0
```

## Platform Gate

The WebView path is only enabled on:

- Android
- iOS
- macOS

That is controlled by:

```dart
bool _supportsYtMusicQuickPicksWebView() =>
    Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
```

Windows and Linux keep using the existing Innertube path.

## State Used

The implementation uses two extra state fields:

```dart
WebViewController? _ytMusicQuickPicksWebViewController;
int _ytMusicQuickPicksWebViewRequestId = 0;
```

`_ytMusicQuickPicksWebViewController` mounts the temporary hidden webview.

`_ytMusicQuickPicksWebViewRequestId` prevents stale callbacks from an older
extraction run from winning after a newer request has started.

## Cookie Seeding

Before loading the page, the app mirrors the pasted cookie string into the
embedded browser:

```dart
Future<void> _seedYtMusicWebViewCookies() async
```

Flow:

1. parse `_effectiveYtMusicCookie()` into a cookie map
2. clear existing WebView cookies
3. write each cookie into `WebViewCookieManager`
4. use domain `music.youtube.com` and path `/`

This makes the embedded browser boot with the same YT Music session as the
cookie dialog.

## Page Extraction

The main entry point is:

```dart
Future<List<Video>> _fetchQuickPicksViaWebView() async
```

Flow:

1. reject unsupported platforms
2. reject empty cookie state
3. create a `WebViewController`
4. enable unrestricted JavaScript
5. register a `QuickPicksExtractor` JavaScript channel
6. mount the controller into the widget tree
7. seed cookies
8. load `https://music.youtube.com/?authuser=...&hl=...&gl=...`
9. wait for `onPageFinished`
10. delay 2 seconds so the page can settle
11. run injected JavaScript against `window.ytInitialData`
12. parse the response into `Video` objects
13. return the selected Quick Picks or `[]` on failure

The future times out after 15 seconds.

## JavaScript Payload

The injected script lives in:

```dart
String _ytMusicQuickPicksWebViewScript()
```

The script:

1. reads `window.ytInitialData`
2. recursively walks the object
3. collects `musicCarouselShelfRenderer` and `musicShelfRenderer`
4. extracts shelf title, subtitle, video id, title, artist, and thumbnail
5. deduplicates shelves and videos
6. posts a compact JSON array back through `QuickPicksExtractor`

The script intentionally does not fully decide the final shelf. It only reduces
the raw page data to a shelf list that Dart can consume.

## Dart Parsing

The JavaScript output is decoded by:

```dart
List<Video> _parseQuickPicksFromWebData(dynamic data)
```

Flow:

1. validate the decoded JSON
2. convert each returned shelf into `_YtMusicHomeSection`
3. convert each returned item into the app's existing `Video` model
4. log the first shelves for debugging
5. call `_pickPrimaryYtMusicQuickSection(sections)`
6. return up to 15 videos from that shelf
7. if no quick-like shelf is found, use the first parsed shelf

This keeps the final selection behavior consistent with the non-WebView path.

## Home Builder Integration

`_buildYtMusicHomeExperience()` now tries WebView first:

```dart
final webViewPicks = await _fetchQuickPicksViaWebView();
if (webViewPicks.length >= 5) {
  return (
    quickPicks: webViewPicks,
    quickPicksLabel: 'From your YouTube Music Quick Picks',
    quickPicksFromOfficialShelf: true,
    shelves: const <_YtMusicHomeSection>[],
    mixes: const <BeastPlaylist>[],
  );
}
```

If the WebView result is too small or empty, the code continues into the normal
Innertube shelf-fetching logic.

## Hidden Widget Mount

`webview_flutter` needs a real widget in the tree, so the app mounts a tiny
hidden `WebViewWidget` inside the root `Scaffold` stack:

```dart
if (_ytMusicQuickPicksWebViewController != null &&
    _supportsYtMusicQuickPicksWebView())
  Positioned(
    right: 0,
    bottom: 0,
    width: 1,
    height: 1,
    child: IgnorePointer(
      child: Opacity(
        opacity: 0.01,
        child: WebViewWidget(
          controller: _ytMusicQuickPicksWebViewController!,
        ),
      ),
    ),
  )
```

The controller is cleared after success, failure, or timeout, which removes the
widget from the tree again.

## Cleanup

`_detachYtMusicQuickPicksWebView(...)` removes the mounted controller once the
request is finished so the hidden webview does not stay alive after extraction.

## Behavior Summary

The current priority order is:

1. try WebView Quick Picks on supported platforms
2. if WebView returns at least 5 songs, use it as the official quick-picks row
3. otherwise fall back to the existing Innertube home implementation

So the WebView path is an enhancement, not a replacement.

## Backend Proxy Path (Playwright / ytmusicapi)

The app now also supports an optional backend-first path:

1. resolve `authuser` locally
2. call backend `POST /ytmusic/home` with cookie + authuser + visitorData
3. receive compact payload: `quickPicks`, `quickPicksLabel`, `shelves`
4. render quick picks and shelves directly
5. fall back to in-app WebView / Innertube if backend is unavailable

Backend source lives in:

- `backend/ytmusic_proxy/app.py`
- `backend/ytmusic_proxy/README.md`

Runtime backend URL behavior in app:

- Android emulator default: `http://10.0.2.2:8787`
- Desktop/iOS/macOS/Linux default: `http://127.0.0.1:8787`
- override with `--dart-define=YTM_BACKEND_URL=...`
