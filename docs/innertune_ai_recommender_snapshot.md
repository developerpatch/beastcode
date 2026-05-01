# Current YT Music / AI Recommender Snapshot

This is the current implementation map from `lib/main.dart`.

The goal of this file is not to be another live code path. It is a reference dump so you can patch the logic without hunting through the monolith.

## 1. YT Music / "InnerTune-style" path

Core constants and state:

- `lib/main.dart:615-623`
  - `_ytMusicApiBase`
  - `_ytMusicApiPrefix`
  - `_ytMusicApiKey`
  - `_ytMusicClientHeaderName`
  - `_ytMusicClientName`
  - `_ytMusicDefaultVisitorData`
  - `_ytMusicUserAgent`
- `lib/main.dart:841-845`
  - `_ytMusicAuthUser`
  - `_ytMusicVisitorData`
  - `_ytMusicResolvedClientVersion`
  - `_ytMusicSessionValid`
- `lib/main.dart:652`
  - `_usingYtMusicHomeFeed`

Context body:

```dart
Map<String, dynamic> _ytMusicContextBody() {
  return {
    'context': {
      'client': {
        'clientName': _ytMusicClientName,
        'clientVersion': _ytMusicClientVersion(),
        'gl': _ytMusicGl(),
        'hl': _ytMusicHl(),
        'visitorData': _ytMusicVisitorData,
      },
      'user': {},
    },
  };
}
```

Visitor bootstrap:

- `lib/main.dart:1479`
  - `_fetchFreshYtMusicVisitorData()`
- `lib/main.dart:1538`
  - `_ensureFreshYtMusicVisitorData()`

Current request helper:

- `lib/main.dart:2405`
  - `_ytMusicPostJson()`

Current shape:

```dart
Future<Map<String, dynamic>?> _ytMusicPostJson(
  String endpoint, {
  Map<String, dynamic>? body,
  Map<String, String>? query,
}) async {
  if (_ytMusicVisitorData.trim().isEmpty ||
      _ytMusicVisitorData == _ytMusicDefaultVisitorData) {
    await _ensureFreshYtMusicVisitorData();
  }

  final params = <String, String>{
    'key': _ytMusicApiKey,
    'prettyPrint': 'false',
    if (query != null) ...query,
  };

  final uri = Uri.https(_ytMusicApiBase, '$_ytMusicApiPrefix/$endpoint', params);

  final headers = <String, String>{
    HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
    'X-Goog-Api-Format-Version': '1',
    'X-YouTube-Client-Name': _ytMusicClientHeaderName,
    'X-YouTube-Client-Version': _ytMusicClientVersion(),
    'X-Goog-AuthUser': _normalizeYtMusicAuthUser(_ytMusicAuthUser),
    'X-Goog-Visitor-Id': _ytMusicVisitorData,
    HttpHeaders.acceptHeader: '*/*',
    HttpHeaders.acceptEncodingHeader: 'gzip, deflate',
    HttpHeaders.acceptLanguageHeader: _ytMusicHl(),
    'Origin': 'https://music.youtube.com',
    'x-origin': 'https://music.youtube.com',
    'Referer': 'https://music.youtube.com/',
    HttpHeaders.userAgentHeader: _ytMusicUserAgent,
  };

  final rawCookie = _effectiveYtMusicCookie();
  if (rawCookie.isNotEmpty) {
    headers[HttpHeaders.cookieHeader] = rawCookie;
  }

  final authHeader = _ytMusicAuthorizationHeader();
  if (authHeader != null && authHeader.isNotEmpty) {
    headers[HttpHeaders.authorizationHeader] = authHeader;
  }

  final response = await http.post(
    uri,
    headers: headers,
    body: jsonEncode(body ?? _ytMusicContextBody()),
  );

  // then jsonDecode(response.body), update visitorData, return Map<String, dynamic>?
}
```

Current home parsing helpers:

- `lib/main.dart:2233`
  - `_ytMusicHomeSection()`
- `lib/main.dart:2300`
  - `_ytMusicHomeVideo()`
- `lib/main.dart:2487`
  - `_ytMusicHomeContentItems()`
- `lib/main.dart:2540`
  - `_ytMusicHomeContinuationToken()`

Current home fetch path:

- `lib/main.dart:2594`
  - `_fetchYtMusicHomeSongs()`
- `lib/main.dart:2619`
  - `_fetchYtMusicNextSongs()`
- `lib/main.dart:2660`
  - `_fetchYtMusicHomeSections()`
- `lib/main.dart:2714`
  - `_fetchYtMusicPlaylistSongs()`

Current home assembly:

- `lib/main.dart:4814`
  - `_buildYtMusicHomeExperience()`
- `lib/main.dart:4944`
  - `_loadHome()`
- `lib/main.dart:13575`
  - `_buildHomeScreen()`

Quick picks selection logic right now:

```dart
_YtMusicHomeSection? quickSection;

for (final section in sections) {
  if (_isExactYtMusicQuickPicksTitle(section.title) &&
      section.videos.isNotEmpty) {
    quickSection = section;
    break;
  }
}

if (quickSection == null) {
  for (final section in sections) {
    if (_looksLikeYtMusicQuickPicksSection(section) &&
        section.videos.isNotEmpty) {
      quickSection = section;
      break;
    }
  }
}

if (quickSection == null) {
  for (final section in sections) {
    final normalizedTitle = section.title.trim().toLowerCase();
    if (normalizedTitle == 'listen again' ||
        normalizedTitle == 'forget your favorites') {
      continue;
    }
    if (section.videos.length >= 4) {
      quickSection = section;
      break;
    }
  }
}
```

The debug line I added for diagnosis is in `lib/main.dart:4821`:

```dart
debugPrint(
  '[YTM] home section titles: ${sections.take(12).map((section) => section.title).join(' | ')}',
);
```

## 2. Local AI recommender path

Core taste/profile builder:

- `lib/main.dart:3332`
  - `_buildTasteProfile()`

This pulls from:

- local likes
- YT liked songs
- history
- listening logs
- session momentum
- transition signals
- skip penalties
- language/genre boosts

Quick-pick ranking:

- `lib/main.dart:4351`
  - `_quickPickScore()`
- `lib/main.dart:4565`
  - `_buildQuickPicksSmart()`

Current quick-pick inputs:

- seed IDs
- seed artists
- recent artists
- recent IDs
- taste profile
- genre overlap
- language match
- session momentum
- query affinity
- repeat penalties
- blocked-song / blocked-artist filters

General personalized scorer:

- `lib/main.dart:5132`
  - `_personalTasteScore()`

Current score sources:

- top artists / artist affinity
- top genres / genre affinity
- top language / language affinity
- per-video / per-artist / per-language action boosts
- listening-log boosts
- hour-of-day genre boosts
- skip penalties
- recent repeat penalties
- query affinity
- session momentum

Radio scorer:

- `lib/main.dart:12201`
  - `_radioRelevanceScore()`

Search / recommendation reranker:

- `lib/main.dart:12422`
  - `_rankPersonalizedRecommendations()`

Other related local recommendation surfaces:

- `lib/main.dart:5450`
  - `_loadBecauseYouLiked()`
- `lib/main.dart:7489`
  - `_startRadioFromSong()`
- `lib/main.dart:2619`
  - `_fetchYtMusicNextSongs()`
- `lib/main.dart:2714`
  - `_fetchYtMusicPlaylistSongs()`

## 3. What is mixed together right now

The app currently blends two systems:

1. YT Music / Innertube-backed retrieval
   - home browse
   - next queue
   - mix queue

2. Local scoring / AI-ish reranking
   - taste profile
   - session momentum
   - transition boosts
   - skip / like / replay penalties and boosts

That means the app is not "pure InnerTune". It is:

- YT Music retrieval
- plus a custom local ranking layer
- plus a fallback layer when YT Music home is empty

## 4. If you want the exact places to edit

If you want to hard-replace the current logic, these are the main choke points:

- `lib/main.dart:2405`
  - `_ytMusicPostJson()`
- `lib/main.dart:2233`
  - `_ytMusicHomeSection()`
- `lib/main.dart:2487`
  - `_ytMusicHomeContentItems()`
- `lib/main.dart:2660`
  - `_fetchYtMusicHomeSections()`
- `lib/main.dart:4814`
  - `_buildYtMusicHomeExperience()`
- `lib/main.dart:4944`
  - `_loadHome()`
- `lib/main.dart:3332`
  - `_buildTasteProfile()`
- `lib/main.dart:4351`
  - `_quickPickScore()`
- `lib/main.dart:5132`
  - `_personalTasteScore()`
- `lib/main.dart:12201`
  - `_radioRelevanceScore()`
- `lib/main.dart:12422`
  - `_rankPersonalizedRecommendations()`

## 5. Current dependency additions

- `pubspec.yaml:13`
  - `http: ^1.2.2`
- `pubspec.yaml:14`
  - `protobuf: ^3.1.0`

The current guest / signed-in home path still uses JSON parsing against Innertube responses. The `protobuf` dependency is present, but it is not wired into the current home parser.
