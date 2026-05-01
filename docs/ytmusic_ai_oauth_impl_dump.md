# YT Music Quick Picks / Feed Implementation Dump

Source of truth: `lib/main.dart` in the current workspace state.

Purpose: this file explains exactly how the app currently builds the YouTube
Music home feed and Quick Picks so a fix can be proposed against the real
implementation, not an older snapshot.

This is a runtime dump, not a design doc.

## 1) Main state used by the YT Music home path

```dart
String? _ytMusicCookie;
String _ytMusicAuthUser = '0';
String _ytMusicVisitorData = _ytMusicDefaultVisitorData;
String? _ytMusicResolvedClientVersion;

bool _ytMusicSessionChecking = false;
bool _ytMusicSessionValid = false;
String? _ytMusicSessionName;
String? _ytMusicSessionEmail;
String? _ytMusicSessionHandle;
String? _ytMusicSessionError;

bool _strictYtMusicFeedMode = true;
bool _usingYtMusicHomeFeed = false;

List<Video> _quickRow1 = [];
String _quickRow1Label = '';
List<_YtMusicHomeSection> _ytMusicHomeShelves = [];
List<BeastPlaylist> _ytHomeMixes = [];
```

## 2) Entry points

There are 3 main routes into the YT Music home/quick-picks logic:

1. App startup:
   ` _initAndLoad() -> _refreshYtMusicSession(...) -> _loadHome() `
2. Cookie dialog save/clear:
   ` _showYtMusicCookieDialog() -> _refreshYtMusicSession(reloadHome: true) `
3. Manual home refresh:
   ` _loadHome() `

Startup currently does this:

```dart
Future<void> _initAndLoad() async {
  await _initDownloadPath();
  await _loadData();
  await _restoreOAuthClientFromPrefs();
  unawaited(_restoreGoogleSignInSession());
  final hasYtMusicCookie = (_ytMusicCookie ?? '').trim().isNotEmpty;
  if (hasYtMusicCookie) {
    unawaited(_refreshYtMusicSession(reloadHome: true));
  } else {
    unawaited(_refreshYtMusicSession());
    unawaited(_loadHome());
  }
}
```

## 3) Current YT Music constants

```dart
static const String _ytMusicApiBase = 'music.youtube.com';
static const String _ytMusicApiPrefix = '/youtubei/v1';
static const String _ytMusicApiKey =
    'AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30';
static const String _ytMusicClientHeaderName = '67';
static const String _ytMusicClientName = 'WEB_REMIX';
static const String _ytMusicDefaultVisitorData =
    'CgtsZG1ySnZiQWtSbyiMjuGSBg%3D%3D';
static const String _ytMusicUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';
```

Client version is either the value resolved from the YT Music homepage HTML or
the generated date fallback:

```dart
String _ytMusicClientVersion() {
  final resolved = (_ytMusicResolvedClientVersion ?? '').trim();
  if (resolved.isNotEmpty) return resolved;
  final now = DateTime.now().toUtc();
  final yyyy = now.year.toString().padLeft(4, '0');
  final mm = now.month.toString().padLeft(2, '0');
  final dd = now.day.toString().padLeft(2, '0');
  return '1.$yyyy$mm$dd.01.00';
}
```

## 4) Visitor-data + client-version refresh

Before most YT Music requests, the app tries to refresh visitor data from the
actual `https://music.youtube.com/` HTML:

```dart
Future<String?> _fetchFreshYtMusicVisitorData() async {
  try {
    final headers = <String, String>{
      HttpHeaders.userAgentHeader: _ytMusicUserAgent,
      HttpHeaders.acceptHeader: 'text/html,application/xhtml+xml',
      HttpHeaders.acceptLanguageHeader: _ytMusicHl(),
      'Origin': 'https://music.youtube.com',
      'Referer': 'https://music.youtube.com/',
      'X-Goog-AuthUser': _normalizeYtMusicAuthUser(_ytMusicAuthUser),
    };
    final rawCookie = _effectiveYtMusicCookie();
    if (_ytMusicSessionValid && rawCookie.isNotEmpty) {
      headers[HttpHeaders.cookieHeader] = rawCookie;
      debugPrint('[YTM] Using real cookie for personalized feed');
    } else if (rawCookie.isNotEmpty) {
      headers[HttpHeaders.cookieHeader] = rawCookie;
    }

    final response = await http
        .get(
          Uri.https(_ytMusicApiBase, '/', {
            'authuser': _normalizeYtMusicAuthUser(_ytMusicAuthUser),
          }),
          headers: headers,
        )
        .timeout(const Duration(seconds: 12));

    final html = response.body;
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        html.trim().isEmpty) {
      debugPrint('[YTM] visitor GET failed: ${response.statusCode}');
      return null;
    }

    final clientVersionPatterns = <RegExp>[
      RegExp(r'''"INNERTUBE_CLIENT_VERSION":"([^"]+)"'''),
      RegExp(r'''"INNERTUBE_CONTEXT_CLIENT_VERSION":"([^"]+)"'''),
    ];
    for (final pattern in clientVersionPatterns) {
      final match = pattern.firstMatch(html);
      final value = match?.group(1)?.trim();
      if (value != null && value.isNotEmpty) {
        _ytMusicResolvedClientVersion = value;
        break;
      }
    }

    final patterns = <RegExp>[
      RegExp(r'''"VISITOR_DATA":"([^"]+)"'''),
      RegExp(r'''"visitorData":"([^"]+)"'''),
      RegExp(r'''VISITOR_DATA['"]?\s*:\s*['"]([^'"]+)['"]'''),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(html);
      final value = match?.group(1)?.trim();
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
  } on TimeoutException catch (e) {
    debugPrint('[YTM] visitor GET timeout: $e');
  } catch (e) {
    debugPrint('[YTM] visitor GET error: $e');
  }
  return null;
}
```

The public wrapper is:

```dart
Future<void> _ensureFreshYtMusicVisitorData() async {
  final freshVisitorData = await _fetchFreshYtMusicVisitorData();
  if (freshVisitorData == null || freshVisitorData.trim().isEmpty) return;
  _ytMusicVisitorData = freshVisitorData.trim();
}
```

## 5) Cookie dialog / saved identity inputs

The cookie dialog currently collects:

- Cookie header values
- `AuthUser`
- `X-Goog-Visitor-Id`

The result is stored into:

```dart
_ytMusicCookie
_ytMusicAuthUser
_ytMusicVisitorData
```

If the dialog is cleared, the app resets to:

```dart
_ytMusicCookie = null;
_ytMusicAuthUser = '0';
_ytMusicVisitorData = _ytMusicDefaultVisitorData;
_ytMusicResolvedClientVersion = null;
_ytMusicSessionValid = false;
_usingYtMusicHomeFeed = false;
_ytHomeMixes = [];
_ytMusicHomeShelves = [];
```

## 6) Session verification path

When a cookie exists, the app verifies it like this:

```text
_refreshYtMusicSession()
  -> _resolveBestYtMusicAuthUser()
  -> _fetchYtMusicAccountInfo()
  -> set _ytMusicSessionValid
  -> optionally _loadHome()
```

### 6.1) AuthUser probing

The app tries multiple `authuser` candidates, fetches `account/account_menu`,
then also probes the home feed and scores the result:

```dart
Future<String> _resolveBestYtMusicAuthUser({
  int maxCandidates = 9,
}) async {
  final initialAuthUser = _normalizeYtMusicAuthUser(_ytMusicAuthUser);
  final targetEmail = _normalizeYtIdentity(_ytAccountEmail);
  final targetName = _normalizeYtIdentity(_ytAccountName);
  final initialVisitorData = _normalizeYtMusicVisitorData(_ytMusicVisitorData);
  final hasCustomVisitorData = _hasCustomYtMusicVisitorData();
  final candidates = <String>[
    initialAuthUser,
    for (var i = 0; i <= maxCandidates; i++) '$i',
  ];

  final seen = <String>{};
  var bestAuthUser = initialAuthUser;
  var bestVisitorData = initialVisitorData;
  var bestScore = double.negativeInfinity;
  for (final rawCandidate in candidates) {
    final candidateAuthUser = _normalizeYtMusicAuthUser(rawCandidate);
    if (!seen.add(candidateAuthUser)) continue;

    _ytMusicAuthUser = candidateAuthUser;
    if (hasCustomVisitorData) {
      _ytMusicVisitorData = initialVisitorData;
    } else {
      await _ensureFreshYtMusicVisitorData();
    }
    final candidateVisitorData =
        _normalizeYtMusicVisitorData(_ytMusicVisitorData);
    final account = await _fetchYtMusicAccountInfo();
    final accountLabel = account?.email?.trim().isNotEmpty == true
        ? account!.email!
        : account?.name ?? 'null';
    debugPrint(
      '[YTM] authUser=$candidateAuthUser account=$accountLabel activeHeader=${account != null}',
    );
    if (account == null) continue;

    final identityScore = _scoreYtMusicAccountCandidate(...);

    var feedScore = -8.0;
    List<Video> candidateQuickPicks = const <Video>[];
    try {
      final sections = await _fetchYtMusicHomeSections(
        maxSections: 6,
        maxContinuations: 0,
      );
      final quickSection = _pickPrimaryYtMusicQuickSection(sections);
      if (quickSection != null) {
        candidateQuickPicks = quickSection.videos.take(15).toList();
      }
      feedScore = _scoreYtMusicFeedCandidate(candidateQuickPicks);
    } catch (e) {
      debugPrint('[YTM] authUser $candidateAuthUser feed probe failed: $e');
    }

    final totalScore = identityScore.toDouble() + (feedScore * 2.0);
    if (totalScore > bestScore ||
        (totalScore == bestScore && candidateAuthUser == initialAuthUser)) {
      bestScore = totalScore;
      bestAuthUser = candidateAuthUser;
      bestVisitorData = candidateVisitorData;
    }
  }

  _ytMusicAuthUser = bestAuthUser;
  if (bestVisitorData.isNotEmpty) {
    _ytMusicVisitorData = bestVisitorData;
  }
  return bestAuthUser;
}
```

The probing path now always tries `authUser` 0..N even when custom
`visitorData` is present, but it keeps that custom `visitorData` stable for each
probe instead of overwriting it with guest metadata.

Important: the app does not use OAuth to fetch YT Music home. OAuth is only
used for Google account data / liked videos. Home feed personalization is driven
by the YT Music cookie + `authuser` + `visitorData`.

### 6.2) account_menu fallback behavior

`_fetchYtMusicAccountInfo()` now accepts more response shapes than just
`activeAccountHeaderRenderer`.

Current fallback behavior:

- try top-level `header.activeAccountHeaderRenderer`
- try popup `actions[0].openPopupAction.popup.multiPageMenuRenderer.header.activeAccountHeaderRenderer`
- try recursive search for `activeAccountHeaderRenderer`
- inspect account-like nodes collected from the response
- if header is still missing but `compactLinkRenderer` / account-ish response
  content exists, treat the response as authenticated and return a minimal
  record: `name: 'authenticated'`

## 7) Innertube request context and transport

### 7.1) Context body

```dart
Map<String, dynamic> _ytMusicContextBody({
  String clientName = _ytMusicClientName,
  String? clientVersion,
}) {
  final resolvedClientVersion =
      (clientVersion ?? _ytMusicClientVersion()).trim();
  return {
    'context': {
      'client': {
        'clientName': clientName,
        'clientVersion': resolvedClientVersion,
        'gl': _ytMusicGl(),
        'hl': _ytMusicHl(),
        'visitorData': _ytMusicVisitorData,
      },
      'user': {},
    },
  };
}
```

### 7.2) POST transport

All YT Music API requests go through `_ytMusicPostJson(...)`.

The request includes:

- `key`
- `prettyPrint=false`
- `authuser`
- `X-YouTube-Client-Name`
- `X-YouTube-Client-Version`
- `X-Goog-AuthUser`
- `X-Goog-Visitor-Id`
- browser-style `Origin` / `Referer` / `User-Agent`
- cookie header if present
- `SAPISIDHASH ...` authorization header when SAPISID/APISID cookies exist

Current behavior:

```dart
Future<Map<String, dynamic>?> _ytMusicPostJson(
  String endpoint, {
  Map<String, dynamic>? body,
  Map<String, String>? query,
  String clientHeaderName = _ytMusicClientHeaderName,
  String clientName = _ytMusicClientName,
  String? clientVersion,
  String userAgent = _ytMusicUserAgent,
}) async {
  try {
    final preservePinnedVisitorData = _hasCustomYtMusicVisitorData();
    if (_ytMusicVisitorData.trim().isEmpty ||
        _ytMusicVisitorData == _ytMusicDefaultVisitorData) {
      await _ensureFreshYtMusicVisitorData();
    }
    final resolvedClientVersion =
        (clientVersion ?? _ytMusicClientVersion()).trim();
    final params = <String, String>{
      'key': _ytMusicApiKey,
      'prettyPrint': 'false',
      'authuser': _normalizeYtMusicAuthUser(_ytMusicAuthUser),
      if (query != null) ...query,
    };

    final headers = <String, String>{
      HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
      'X-Goog-Api-Format-Version': '1',
      'X-YouTube-Client-Name': clientHeaderName,
      'X-YouTube-Client-Version': resolvedClientVersion,
      'X-Goog-AuthUser': _normalizeYtMusicAuthUser(_ytMusicAuthUser),
      'X-Goog-Visitor-Id': _ytMusicVisitorData,
      HttpHeaders.acceptHeader: '*/*',
      HttpHeaders.acceptEncodingHeader: 'gzip, deflate',
      HttpHeaders.acceptLanguageHeader: _ytMusicHl(),
      'Origin': 'https://music.youtube.com',
      'x-origin': 'https://music.youtube.com',
      'Referer': 'https://music.youtube.com/',
      HttpHeaders.userAgentHeader: userAgent,
    };

    final rawCookie = _effectiveYtMusicCookie();
    if (_ytMusicSessionValid && rawCookie.isNotEmpty) {
      headers[HttpHeaders.cookieHeader] = rawCookie;
      headers['X-YouTube-Bootstrap-Logged-In'] = 'true';
    } else if (rawCookie.isNotEmpty) {
      headers[HttpHeaders.cookieHeader] = rawCookie;
    }

    final authHeader = _ytMusicAuthorizationHeader();
    if (authHeader != null && authHeader.isNotEmpty) {
      headers[HttpHeaders.authorizationHeader] = authHeader;
    }

    // retry once after refreshing visitorData on empty/bad response
    // then parse responseContext.visitorData back into local state
  } catch (e) {
    debugPrint('[YTM] POST $endpoint error: $e');
    return null;
  }
}
```

## 8) Feed parser: how the app extracts shelves from the home response

### 8.1) Source buckets

`_ytMusicHomeContentItems(response)` pulls candidate shelf buckets from:

1. `contents.singleColumnBrowseResultsRenderer.tabs[*].tabRenderer.content.sectionListRenderer.contents`
2. `continuationContents.sectionListContinuation.contents`
3. the first `sectionListRenderer` found anywhere in the response
4. the raw response itself if none of the above exist

Then it deep-scans those buckets for:

- `musicCarouselShelfRenderer`
- `musicShelfRenderer`

Current implementation:

```dart
List<dynamic> _ytMusicHomeContentItems(Map<String, dynamic> response) {
  final sourceBuckets = <dynamic>[];

  // selected tab contents
  // continuationContents.sectionListContinuation.contents
  // first sectionListRenderer anywhere
  // fallback to raw response

  final out = <dynamic>[];
  final seen = <String>{};

  void addShelf(String rendererKey, dynamic rendererValue) {
    final renderer = _jsonMap(rendererValue);
    if (renderer == null) return;
    final title = rendererKey == 'musicCarouselShelfRenderer'
        ? (_ytMusicTextValue(_jsonAt(renderer, const [
              'header',
              'musicCarouselShelfBasicHeaderRenderer',
              'title',
            ])) ??
            '')
        : (_ytMusicTextValue(renderer['title']) ??
            _ytMusicTextValue(_jsonAt(renderer, const [
              'header',
              'musicResponsiveHeaderRenderer',
              'title',
            ])) ??
            '');
    final signature =
        '$rendererKey:${title.trim().toLowerCase()}:${_jsonList(renderer['contents']).length}';
    if (!seen.add(signature)) return;
    out.add({rendererKey: renderer});
  }

  for (final source in sourceBuckets) {
    for (final carousel in _findJsonValuesByKey(
      source,
      'musicCarouselShelfRenderer',
      maxDepth: 20,
    )) {
      addShelf('musicCarouselShelfRenderer', carousel);
    }
    for (final shelf in _findJsonValuesByKey(
      source,
      'musicShelfRenderer',
      maxDepth: 20,
    )) {
      addShelf('musicShelfRenderer', shelf);
    }
  }

  if (out.isNotEmpty) return out;
  return sourceBuckets.isEmpty ? const <dynamic>[] : sourceBuckets;
}
```

### 8.2) Section extraction

Each candidate shelf is parsed through `_ytMusicHomeSection(raw)`.

That function:

- finds either `musicCarouselShelfRenderer` or `musicShelfRenderer`
- extracts title/subtitle
- extracts items through `_ytMusicSectionContentItems(renderer)`
- turns supported items into `Video` via `_ytMusicHomeVideo(content)`
- turns playlist-ish rows into `_YtMusicMixRef` via `_ytMusicHomeMixRef(content)`

Important current behavior:

- a section is dropped if it has no parsed videos and no parsed mixes
- each section keeps at most 24 videos
- mix refs are collected separately from videos

Shape:

```dart
return _YtMusicHomeSection(
  title: title.trim(),
  subtitle: subtitle.trim(),
  videos: videos.take(24).toList(),
  mixes: mixes,
);
```

## 9) Home browse + continuation fetch

The app fetches the home feed like this:

```dart
Future<List<_YtMusicHomeSection>> _fetchYtMusicHomeSections({
  int maxSections = 10,
  int maxContinuations = 2,
  String clientHeaderName = _ytMusicClientHeaderName,
  String clientName = _ytMusicClientName,
  String? clientVersion,
  String userAgent = _ytMusicUserAgent,
}) async {
  final out = <_YtMusicHomeSection>[];
  final seenTitles = <String>{};

  void collect(dynamic contents) {
    for (final item in _jsonList(contents)) {
      final section = _ytMusicHomeSection(item);
      if (section == null) continue;
      final key = _normalizeSignalKey(section.title);
      if (key.isEmpty || !seenTitles.add(key)) continue;
      out.add(section);
      if (out.length >= maxSections) return;
    }
  }

  Map<String, dynamic>? response = await _ytMusicPostJson(
    'browse',
    body: {
      ..._ytMusicContextBody(
        clientName: clientName,
        clientVersion: clientVersion,
      ),
      'browseId': 'FEmusic_home',
    },
    clientHeaderName: clientHeaderName,
    clientName: clientName,
    clientVersion: clientVersion,
    userAgent: userAgent,
  );
  if (response == null) return const <_YtMusicHomeSection>[];

  collect(_ytMusicHomeContentItems(response));
  var continuation = _ytMusicHomeContinuationToken(response);

  var pass = 0;
  while (continuation != null &&
      continuation.isNotEmpty &&
      out.length < maxSections &&
      pass < maxContinuations) {
    // try body continuation first
    // then retry with query continuation/ctoken/type=next
    // collect more shelves and continue
  }

  return out;
}
```

Two fallback/home flatteners exist:

```dart
_fetchYtMusicHomeSongs(...)
_ytMusicQuickCandidatesFromHome(...)
```

Both flatten videos from parsed sections rather than preserving raw shelf JSON.

The feed-score helper now logs each probe result:

```dart
debugPrint(
  '[YTM Feed Score] ${quickPicks.length} videos -> score=${score.toStringAsFixed(2)} | top3: ${quickPicks.take(3).map((v) => _cleanTitle(v.title)).join(', ')}',
);
```

## 10) Quick-picks shelf selection logic

This is the exact logic now used to choose which shelf becomes Quick Picks:

```dart
String _normalizeYtQuickShelfTitle(String rawTitle) {
  return rawTitle
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();
}

int _ytMusicQuickShelfScore(String rawTitle) {
  final normalized = _normalizeYtQuickShelfTitle(rawTitle);
  if (normalized.contains('quick picks') ||
      normalized.contains('quickpicks')) {
    return 6;
  }
  if (normalized.contains('picked for you') ||
      normalized.contains('recommended for you') ||
      normalized.contains('start here')) {
    return 4;
  }
  if (normalized.contains('listen again')) {
    return 2;
  }
  return 0;
}

bool _isLikelyYtMusicQuickPicksTitle(String rawTitle) {
  return _ytMusicQuickShelfScore(rawTitle) > 0;
}

_YtMusicHomeSection? _pickPrimaryYtMusicQuickSection(
  List<_YtMusicHomeSection> sections,
) {
  _YtMusicHomeSection? bestMatch;
  var bestScore = 0;
  for (final section in sections) {
    if (section.videos.isEmpty) continue;
    final score = _ytMusicQuickShelfScore(section.title);
    if (score > bestScore) {
      bestScore = score;
      bestMatch = section;
    }
  }
  if (bestMatch != null) return bestMatch;
  for (final section in sections) {
    if (section.videos.length >= 8) return section;
  }
  for (final section in sections) {
    if (section.videos.isNotEmpty) return section;
  }
  return null;
}
```

Meaning:

- exact `Quick picks` shelf is preferred
- then `Picked for you` / `Recommended for you` / `Start here`
- then `Listen again`
- if nothing matches, fallback is first shelf with at least 8 videos
- then fallback is first non-empty shelf

## 11) Home builder: how Quick Picks + shelves + mixes are assembled

Current implementation:

```dart
Future<({
  List<Video> quickPicks,
  String quickPicksLabel,
  bool quickPicksFromOfficialShelf,
  List<_YtMusicHomeSection> shelves,
  List<BeastPlaylist> mixes,
})> _buildYtMusicHomeExperience() async {
  final sections = await _fetchYtMusicHomeSections(
    maxSections: _ytMusicSessionValid ? 14 : 10,
    maxContinuations: 3,
  );

  debugPrint('[YTM Quick Debug] Received ${sections.length} sections:');
  for (final section in sections.take(6)) {
    debugPrint(
      '  -> "${section.title}" (${section.videos.length} songs) | ${section.subtitle}',
    );
  }

  final quickSection = _pickPrimaryYtMusicQuickSection(sections);
  final quickPicksFromOfficialShelf = quickSection != null &&
      _isLikelyYtMusicQuickPicksTitle(quickSection.title);

  final quickPicks = <Video>[];
  var quickPicksLabel = 'From your YouTube Music Quick Picks';
  if (quickSection != null && quickSection.videos.isNotEmpty) {
    quickPicks.addAll(quickSection.videos.take(15));
    if (quickSection.subtitle.trim().isNotEmpty) {
      quickPicksLabel = quickSection.subtitle.trim();
    }
  } else {
    quickPicks.addAll(await _fetchYtMusicHomeSongs(limit: 15));
    quickPicksLabel = _ytMusicSessionValid
        ? 'From your YouTube Music home'
        : 'From YouTube Music guest feed';
  }

  final maxShelves = _ytMusicSessionValid ? 8 : 5;
  final songShelves = sections
      .where((section) =>
          !identical(section, quickSection) && section.videos.length >= 4)
      .take(maxShelves)
      .toList();

  // mix refs are collected from section.mixes, filtered through
  // _looksLikeYtMusicMixRef(...), then expanded by _fetchYtMusicPlaylistSongs
  // and stored as BeastPlaylist objects in ytHome.mixes

  return (
    quickPicks: quickPicks,
    quickPicksLabel: quickPicksLabel,
    quickPicksFromOfficialShelf: quickPicksFromOfficialShelf,
    shelves: songShelves,
    mixes: mixes.take(4).toList(),
  );
}
```

Important:

- `quickPicks` is taken from `quickSection.videos.take(15)`
- `quickPicksFromOfficialShelf` is only true when the chosen shelf title
  matches the quick-like scoring function
- other shelves are filtered to `section.videos.length >= 4`

## 12) Final home assembly in `_loadHome()`

This is where the final Quick Picks list shown in UI is chosen.

### 12.1) Primary load path

```dart
Future<void> _loadHome() async {
  if (mounted) setState(() => _homeLoading = true);

  var usingYtMusicHome = false;
  try {
    final ytHome = await _buildYtMusicHomeExperience();
    usingYtMusicHome = _hasYtMusicHomeContent(ytHome);

    var selectedQuickPicks = ytHome.quickPicks.take(15).toList();
    var quickLabel = ytHome.quickPicksLabel.trim().isNotEmpty
        ? ytHome.quickPicksLabel.trim()
        : (_ytMusicSessionValid
            ? 'From your YouTube Music home feed'
            : 'From YouTube Music guest home feed');
    var preserveOfficialYtOrder =
        usingYtMusicHome && ytHome.quickPicksFromOfficialShelf;

    if (!preserveOfficialYtOrder &&
        selectedQuickPicks.length < 8 &&
        selectedQuickPicks.isNotEmpty) {
      selectedQuickPicks = _rankPersonalizedRecommendations(
        selectedQuickPicks,
        '',
      ).take(15).toList();
    }

    if (selectedQuickPicks.isEmpty &&
        usingYtMusicHome &&
        !preserveOfficialYtOrder) {
      selectedQuickPicks =
          _ytMusicQuickCandidatesFromHome(ytHome, target: 24);
    }

    if (selectedQuickPicks.isEmpty) {
      final ytFallback = await _fetchYtMusicHomeSongs(limit: 24);
      selectedQuickPicks =
          _filterBlockedRecommendations(ytFallback, limit: 24);
      if (selectedQuickPicks.isNotEmpty) {
        usingYtMusicHome = true;
        preserveOfficialYtOrder = false;
        quickLabel = _ytMusicSessionValid
            ? 'From your YouTube Music home feed'
            : 'From YouTube Music guest home feed';
      }
    }

    if (selectedQuickPicks.isEmpty && _strictYtMusicFeedMode) {
      final ytSeededQuick = await _buildYtMusicSeededQuickPicks(target: 24);
      if (ytSeededQuick.isNotEmpty) {
        selectedQuickPicks = ytSeededQuick;
        usingYtMusicHome = true;
        preserveOfficialYtOrder = false;
        quickLabel = _ytMusicSessionValid
            ? 'From your YouTube Music recommendations'
            : 'From YouTube Music recommendations';
      }
    }

    if (selectedQuickPicks.isEmpty) {
      if (usingYtMusicHome) {
        quickLabel = _ytMusicSessionValid
            ? 'From your YouTube Music home feed'
            : 'From YouTube Music guest home feed';
      } else {
        selectedQuickPicks = _quickPicksFallback(target: 24);
        preserveOfficialYtOrder = false;
        quickLabel = 'Made for you';
      }
    }

    if (!_strictYtMusicFeedMode && !preserveOfficialYtOrder) {
      final hybridQuick = _buildHybridQuickPicks(...);
      if (hybridQuick.videos.isNotEmpty) {
        selectedQuickPicks = hybridQuick.videos;
        if (hybridQuick.label.trim().isNotEmpty) {
          quickLabel = hybridQuick.label.trim();
        }
      }
    }

    if (selectedQuickPicks.isNotEmpty) {
      _markQuickPicksServed(selectedQuickPicks);
    }

    setState(() {
      _usingYtMusicHomeFeed = usingYtMusicHome;
      _quickRow1 = selectedQuickPicks;
      _quickRow1Label = quickLabel;
      _ytMusicHomeShelves = usingYtMusicHome ? ytHome.shelves : [];
      _ytHomeMixes = usingYtMusicHome ? ytHome.mixes : [];
      _becauseYouLiked = [];
      _becauseYouLikedLabel = '';
      _becauseYouLikedLoading = false;
      _newReleases = [];
      _hindiHits = [];
      _moodChill = [];
      _homeLoading = false;
    });
  } catch (e) {
    // catch path falls back to _buildYtMusicSeededQuickPicks or _quickPicksFallback
  }
}
```

### 12.2) Current fallback order

Current Quick Picks fallback order is:

1. `ytHome.quickPicks.take(15)`
2. if non-official and too short: `_rankPersonalizedRecommendations(...)`
3. if empty and YT home exists: `_ytMusicQuickCandidatesFromHome(...)`
4. if still empty: `_fetchYtMusicHomeSongs(limit: 24)`
5. if still empty and strict mode: `_buildYtMusicSeededQuickPicks(target: 24)`
6. if still empty: local `_quickPicksFallback(target: 24)`
7. if strict mode is disabled and order is not pinned: optional
   `_buildHybridQuickPicks(...)`

Important current rule:

- official YT Music shelf order is preserved only when
  `preserveOfficialYtOrder == true`
- that means the chosen quick section must be both non-empty and recognized as
  a quick-like shelf by `_ytMusicQuickShelfScore(...)`

## 13) What the UI actually renders

The Quick Picks UI uses `_quickRow1` directly.

There is no extra sort in the widget layer:

```dart
final allQuick = _quickRow1;
```

Then `_buildQuickPicksGrid(allQuick, isPlaying)` renders those tracks in the
stored order.

Home shelves are rendered from:

```dart
_ytMusicHomeShelves
_ytHomeMixes
```

So the last mutation point before UI is `_loadHome()`.

## 14) Current places where the app can drift away from raw YT Music

These are the active divergence points in the current implementation:

1. Wrong `authuser` / `visitorData` pairing:
   even with a valid cookie, the home request depends on the winner chosen in
   `_resolveBestYtMusicAuthUser()`.

2. Parser shape mismatch:
   `_ytMusicHomeContentItems()` only extracts shelves it can find through
   `musicCarouselShelfRenderer` or `musicShelfRenderer` deep scans.

3. Quick-shelf detection mismatch:
   `_pickPrimaryYtMusicQuickSection()` is still title-based. It does not use a
   shelf ID, endpoint, or renderer-structure signature.

4. Video extraction mismatch:
   `_ytMusicHomeSection()` only keeps items that parse through
   `_ytMusicHomeVideo()` or `_ytMusicHomeMixRef()`.

5. Section filtering:
   non-quick shelves with fewer than 4 parsed videos are dropped from
   `songShelves`.

6. Fallback promotion:
   if no official quick shelf is recognized, `_loadHome()` can promote flattened
   home songs, seeded YT recs, or fully local fallback picks.

7. Flattening:
   `_fetchYtMusicHomeSongs()` and `_ytMusicQuickCandidatesFromHome()` flatten
   multiple shelves together and do not preserve raw YT shelf boundaries.

## 15) Short summary

Today the app does **not** simply render the raw `FEmusic_home` response.

The implemented path is:

```text
cookie/authuser/visitorData
  -> account verification + authuser probing
  -> YT Music browse(FEmusic_home)
  -> parse shelves from response
  -> select one section as Quick Picks
  -> maybe preserve that order, maybe re-rank/fallback
  -> save result into _quickRow1 / _ytMusicHomeShelves / _ytHomeMixes
  -> UI renders those lists directly
```

If you want to give a fix, the most relevant functions are:

- `_resolveBestYtMusicAuthUser`
- `_fetchFreshYtMusicVisitorData`
- `_ytMusicPostJson`
- `_ytMusicHomeContentItems`
- `_ytMusicHomeSection`
- `_pickPrimaryYtMusicQuickSection`
- `_buildYtMusicHomeExperience`
- `_loadHome`
