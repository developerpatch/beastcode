// ---
// pubspec.yaml additions needed:
//   just_audio_background: ^0.0.1-beta.12
//   audio_service: ^0.18.15
//
// AndroidManifest.xml inside <application> tag:
//   <service android:name="com.ryanheise.audioservice.AudioServiceFragment"
//       android:exported="false"/>
//   <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
//   <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/>
//
// For downloads to /storage/emulated/0/Music/BeastMusic (Android 9 and below):
//   <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"
//       android:maxSdkVersion="28"/>
//   <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"
//       android:maxSdkVersion="32"/>
// Android 10+ (API 29+): no storage permission needed for that path.
// ---
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:beastclient/beastclient.dart' as beast;
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:crypto/crypto.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:oauth2/oauth2.dart' as oauth2;
import 'package:app_links/app_links.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart' show AudioService;
import 'package:just_audio_background/just_audio_background.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

part 'src/wrapped_story.part.dart';
part 'src/equalizer_bars.part.dart';
part 'src/dot_pattern_painter.part.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint('Unhandled Flutter error: ${details.exceptionAsString()}');
  };
  // Keep transient async media failures from tearing down the app.
  ui.PlatformDispatcher.instance.onError = (Object error, StackTrace stackTrace) {
    debugPrint('Unhandled async error: $error');
    debugPrintStack(stackTrace: stackTrace);
    return true;
  };
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.beastcode.music.channel.audio',
    androidNotificationChannelName: 'Beast Music Playback',
    androidNotificationOngoing: true,
  );
  runApp(const MyApp());
}

// ---
// Playlist model
// ---
class BeastPlaylist {
  final String id;
  String name;
  final List<Video> videos;
  final bool isSystem;
  final DateTime createdAt;

  BeastPlaylist({
    required this.id,
    required this.name,
    List<Video>? videos,
    this.isSystem = false,
    DateTime? createdAt,
  })  : videos = videos ?? [],
        createdAt = createdAt ?? DateTime.now();

  String? get coverUrl =>
      videos.isNotEmpty ? videos.first.thumbnails.mediumResUrl : null;
}

class _YtMusicMixRef {
  final String title;
  final String subtitle;
  final String playlistId;

  const _YtMusicMixRef({
    required this.title,
    required this.subtitle,
    required this.playlistId,
  });
}

class _YtMusicHomeSection {
  final String title;
  final String subtitle;
  final List<Video> videos;
  final List<_YtMusicMixRef> mixes;

  const _YtMusicHomeSection({
    required this.title,
    required this.subtitle,
    this.videos = const <Video>[],
    this.mixes = const <_YtMusicMixRef>[],
  });
}

typedef _YtMusicClientProfile = ({
  String clientHeaderName,
  String clientName,
  String clientVersion,
  String userAgent,
  bool isWebRemix,
});

class _YtMusicCookieDialogResult {
  const _YtMusicCookieDialogResult._({
    this.cookie,
    this.authUser,
    this.visitorData,
    this.clear = false,
  });

  const _YtMusicCookieDialogResult.save({
    required String cookie,
    required String authUser,
    required String visitorData,
  }) : this._(
          cookie: cookie,
          authUser: authUser,
          visitorData: visitorData,
        );

  const _YtMusicCookieDialogResult.clear() : this._(clear: true);

  final String? cookie;
  final String? authUser;
  final String? visitorData;
  final bool clear;
}

class _YtMusicCookieDialog extends StatefulWidget {
  const _YtMusicCookieDialog({
    required this.initialCookie,
    required this.initialAuthUser,
    required this.initialVisitorData,
    required this.showClear,
    required this.normalizeCookieInput,
    required this.extractAuthUser,
    required this.extractVisitorData,
  });

  final String initialCookie;
  final String initialAuthUser;
  final String initialVisitorData;
  final bool showClear;
  final String Function(String rawInput) normalizeCookieInput;
  final String? Function(String rawInput) extractAuthUser;
  final String? Function(String rawInput) extractVisitorData;

  @override
  State<_YtMusicCookieDialog> createState() => _YtMusicCookieDialogState();
}

class _YtMusicCookieDialogState extends State<_YtMusicCookieDialog> {
  late final TextEditingController _cookieCtrl;
  late final TextEditingController _authUserCtrl;
  late final TextEditingController _visitorDataCtrl;

  @override
  void initState() {
    super.initState();
    _cookieCtrl = TextEditingController(text: widget.initialCookie.trim());
    _authUserCtrl = TextEditingController(
        text: widget.initialAuthUser.trim().isEmpty
            ? '0'
            : widget.initialAuthUser.trim());
    _visitorDataCtrl =
        TextEditingController(text: widget.initialVisitorData.trim());
  }

  @override
  void dispose() {
    _cookieCtrl.dispose();
    _authUserCtrl.dispose();
    _visitorDataCtrl.dispose();
    super.dispose();
  }

  Future<void> _importCookieFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    if (!mounted) return;
    final raw = data?.text?.trim() ?? '';
    if (raw.isEmpty) return;
    final authUser = widget.extractAuthUser(raw)?.trim();
    if (authUser != null && authUser.isNotEmpty) {
      _authUserCtrl.text = authUser;
    }
    final visitorData = widget.extractVisitorData(raw)?.trim();
    if (visitorData != null && visitorData.isNotEmpty) {
      _visitorDataCtrl.text = visitorData;
    }
    final normalized = widget.normalizeCookieInput(raw);
    if (normalized.isNotEmpty) {
      _cookieCtrl.text = normalized;
    }
  }

  String _buildCookieString() =>
      widget.normalizeCookieInput(_cookieCtrl.text.trim());

  String _buildAuthUser() {
    final digits = _authUserCtrl.text.replaceAll(RegExp(r'[^0-9]'), '').trim();
    return digits.isEmpty ? '0' : digits;
  }

  String _buildVisitorData() => _visitorDataCtrl.text.trim();

  void _closeDialog([_YtMusicCookieDialogResult? result]) {
    FocusManager.instance.primaryFocus?.unfocus();
    if (!mounted) return;
    final navigator = Navigator.of(context);
    if (!navigator.canPop()) return;
    navigator.pop(result);
  }

  InputDecoration _fieldDecoration(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: Colors.grey[700], fontSize: 11),
        filled: true,
        fillColor: const Color(0xFF252525),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Colors.greenAccent),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      );

  Widget _cookieField(
    String label,
    TextEditingController controller, {
    required String hint,
    required double width,
    int maxLines = 1,
  }) {
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            maxLines: maxLines,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontFamily: 'monospace',
            ),
            decoration: _fieldDecoration(hint),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dialogWidth = min(MediaQuery.sizeOf(context).width * 0.92, 560.0);
    final narrowFieldWidth =
        dialogWidth > 500 ? (dialogWidth - 12) / 2 : dialogWidth;

    return AlertDialog(
      backgroundColor: const Color(0xFF151515),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('YouTube Music Cookie',
          style: TextStyle(color: Colors.white, fontSize: 16)),
      content: SizedBox(
        width: dialogWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Paste the full Cookie header, X-Goog-Visitor-Id, and AuthUser exactly as copied from YT Music. You can still edit individual cookie rows below if needed.',
                style: TextStyle(
                  color: Colors.grey[400],
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: dialogWidth,
                child: OutlinedButton.icon(
                  onPressed: _importCookieFromClipboard,
                  icon: const Icon(Icons.content_paste_rounded,
                      color: Colors.greenAccent, size: 18),
                  label: const Text('Import From Clipboard',
                      style: TextStyle(color: Colors.greenAccent)),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.greenAccent),
                    foregroundColor: Colors.greenAccent,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _cookieField('Cookie (paste entire string)', _cookieCtrl,
                      hint:
                          'LOGIN_INFO=...; VISITOR_INFO1_LIVE=...; HSID=...; SSID=...; APISID=...; SAPISID=...; ...',
                      width: dialogWidth,
                      maxLines: 6),
                  _cookieField('AuthUser', _authUserCtrl,
                      hint: 'Usually 0', width: narrowFieldWidth),
                  _cookieField('X-Goog-Visitor-Id', _visitorDataCtrl,
                      hint: 'CgtIVTVENS10dGQyZyiw2LnNBjIKCgJJThIEGgAgXA%3D%3D',
                      width: dialogWidth),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'Paste exactly these three values only: Cookie, X-Goog-Visitor-Id, and AuthUser.',
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 10,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _closeDialog,
          child: Text('Cancel', style: TextStyle(color: Colors.grey[500])),
        ),
        if (widget.showClear)
          TextButton(
            onPressed: () =>
                _closeDialog(const _YtMusicCookieDialogResult.clear()),
            child: const Text('Clear',
                style: TextStyle(color: Colors.orangeAccent)),
          ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.greenAccent,
            foregroundColor: Colors.black,
          ),
          onPressed: () => _closeDialog(
            _YtMusicCookieDialogResult.save(
              cookie: _buildCookieString(),
              authUser: _buildAuthUser(),
              visitorData: _buildVisitorData(),
            ),
          ),
          child:
              const Text('Save', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}

// ---
// Global theme notifier
// ---
final ValueNotifier<bool> _isDarkNotifier = ValueNotifier(true);

class _BeastScrollBehavior extends MaterialScrollBehavior {
  const _BeastScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    final platform = getPlatform(context);
    if (platform == TargetPlatform.iOS || platform == TargetPlatform.macOS) {
      return const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      );
    }
    return const ClampingScrollPhysics(
      parent: AlwaysScrollableScrollPhysics(),
    );
  }
}

// ---
// App root
// ---
enum _DownloadTaskState { queued, downloading, paused, failed }

class _DownloadTask {
  _DownloadTask({
    required this.video,
    this.silent = false,
  }) : id = '${video.id.value}_${DateTime.now().microsecondsSinceEpoch}';

  final String id;
  final Video video;
  final bool silent;
  _DownloadTaskState state = _DownloadTaskState.queued;
  double progress = 0;
  String? error;

  String get videoId => video.id.value;
}

class _DownloadInterrupted implements Exception {
  const _DownloadInterrupted({required this.paused});
  final bool paused;
}

class _TrackFeatures {
  const _TrackFeatures({
    required this.idKey,
    required this.title,
    required this.author,
    required this.text,
    required this.normalizedTitle,
    required this.authorKey,
    required this.language,
    required this.tags,
    required this.tokens,
    required this.mood,
    required this.trackKey,
  });

  final String idKey;
  final String title;
  final String author;
  final String text;
  final String normalizedTitle;
  final String authorKey;
  final String language;
  final Set<String> tags;
  final List<String> tokens;
  final String? mood;
  final String trackKey;
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _isDarkNotifier,
      builder: (context, isDark, _) => MaterialApp(
        title: 'Beast Music',
        debugShowCheckedModeBanner: false,
        theme: _buildTheme(isDark),
        scrollBehavior: const _BeastScrollBehavior(),
        themeAnimationDuration: const Duration(milliseconds: 260),
        themeAnimationCurve: Curves.easeInOutCubic,
        builder: (context, child) {
          final media = MediaQuery.of(context);
          return MediaQuery(
            data: media.copyWith(
              textScaler: media.textScaler.clamp(maxScaleFactor: 1.0),
            ),
            child: child ?? const SizedBox.shrink(),
          );
        },
        home: const HomeScreen(),
      ),
    );
  }

  ThemeData _buildTheme(bool isDark) {
    if (isDark) {
      return ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: Colors.black,
        appBarTheme:
            const AppBarTheme(backgroundColor: Colors.black, elevation: 0),
      );
    } else {
      return ThemeData.light(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFFF5F5F5),
        appBarTheme:
            const AppBarTheme(backgroundColor: Color(0xFFF5F5F5), elevation: 0),
        colorScheme: ColorScheme.light(
          primary: Colors.green.shade600,
          secondary: Colors.green.shade400,
        ),
      );
    }
  }
}

// ---
// Home screen
// ---
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const String _notificationEventSkipNext = 'skip_next_requested';
  static const String _notificationEventSkipPrevious =
      'skip_previous_requested';
  static const String _notificationEventToggleLike = 'toggle_like_requested';
  static const MethodChannel _downloadKeepAliveChannel =
      MethodChannel('beastcode/download_keep_alive');
  static const String _ytMusicApiBase = 'music.youtube.com';
  static const String _ytMusicApiPrefix = '/youtubei/v1';
  static const String _ytMusicApiKey =
      'AIzaSyAOghZGza2MQSZkY_zfZ370N-PUdXEo8AI';
  static const String _ytMusicClientHeaderName = '21';
  static const String _ytMusicClientName = 'ANDROID_MUSIC';
  static const String _ytMusicAndroidClientVersion = '7.30.52';
  static const String _ytMusicDefaultVisitorData =
      'CgtsZG1ySnZiQWtSbyiMjuGSBg%3D%3D';
  static const String _ytMusicUserAgent =
      'com.google.android.apps.youtube.music/7.30.52 (Linux; U; Android 12) gzip';
  static const String _ytMusicWebUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';
  static const String _ytMusicWebRemixClientHeaderName = '67';
  static const String _ytMusicWebRemixClientName = 'WEB_REMIX';
  static const String _ytMusicWebRemixClientVersion = '1.20250305.01.00';
  static const String _ytMusicBackendUrl = String.fromEnvironment(
    'YTM_BACKEND_URL',
    defaultValue: 'https://beastcode-ytmusic-proxy.onrender.com',
  );
  static const String _ytMusicBackendApiKey = String.fromEnvironment(
    'YTM_BACKEND_API_KEY',
    defaultValue: 'aadhya',
  );
  // ignore: prefer_final_fields
  bool _strictYtMusicFeedMode = true;
  static const String _googleCloudConsoleUrl =
      'https://console.cloud.google.com';
  static const String _googleCloudYouTubeApiUrl =
      'https://console.cloud.google.com/apis/library/youtube.googleapis.com';
  static const String _googleCloudCredentialsUrl =
      'https://console.cloud.google.com/apis/credentials';
  static const String _googleCloudConsentUrl =
      'https://console.cloud.google.com/apis/credentials/consent';
  static const String _androidApplicationId = 'com.beastmusic.app';

  // Audio engine (EQ + bass boost pipeline)
  final AndroidEqualizer _androidEqualizer = AndroidEqualizer();
  final AndroidLoudnessEnhancer _androidLoudnessEnhancer =
      AndroidLoudnessEnhancer();
  late final AudioPlayer _player;
  late final AudioPlayer _playerB;
  beast.BeastClient? _beastClient;
  bool _beastClientReady = false;
  final _searchController = TextEditingController();
  Timer? _searchSuggestDebounce;
  int _searchRequestSeq = 0;
  bool _lastPlayerPlaying = false;
  ProcessingState? _lastPlayerProcessingState;
  bool _lastPlayerBPlaying = false;

  List<Video> _searchResults = [];
  List<String> _searchSuggestions = [];
  String? _searchDidYouMean;
  final List<String> _searchHistory = [];
  List<Video> _playQueue = [];
  final ValueNotifier<int> _queueChangeNotifier = ValueNotifier(0);
  void _notifyQueueChanged() {
    _queueChangeNotifier.value++;
    _ensureRollingPrefetchWindow();
  }

  void _ensureRollingPrefetchWindow() {
    if (_isDownloadPlayback) return;
    final currentId = _currentVideoId;
    if (currentId == null || currentId.isEmpty) return;
    if (_currentIndex < 0 || _currentIndex >= _playQueue.length) return;
    if (_playQueue[_currentIndex].id.value != currentId) return;
    unawaited(_prefetchNext(_currentIndex, currentId));
  }

  bool _isLoading = false;

  bool _isSearchMode = false;
  String _searchResultView = 'top';
  bool _homeLoading = true;
  bool _appBooting = true;
  List<Video> _newReleases = [];
  List<Video> _hindiHits = [];
  List<Video> _moodChill = [];
  List<_YtMusicHomeSection> _ytMusicHomeShelves = [];
  List<BeastPlaylist> _ytHomeMixes = [];
  bool _usingYtMusicHomeFeed = false;

  bool _isBuffering = false;
  double _bufferProgress = 0;
  String _bufferLabel = '';
  bool _youtubeDnsBlocked = false;

  bool _isDownloading = false;
  double _downloadProgress = 0;
  final List<_DownloadTask> _downloadTasks = [];
  static const int _maxConcurrentDownloads = 3;
  final Set<String> _runningDownloadTaskIds = {};
  final Set<String> _downloadPauseRequestedTaskIds = {};
  final Set<String> _downloadCancelRequestedTaskIds = {};
  final Map<String, Completer<void>> _downloadAbortByTaskId = {};
  final Map<String, StreamSubscription<List<int>>> _downloadStreamSubByTaskId =
      {};
  bool _downloadQueuePumpScheduled = false;
  Timer? _downloadKeepAliveSyncTimer;
  String? _downloadKeepAliveTaskId;
  int _downloadKeepAliveProgressBucket = -1;

  Video? _nowPlaying;
  int _currentIndex = -1;

  // FIX: captured once per _play() call to detect stale async callbacks
  String? _currentVideoId;
  int _currentDownloadIndex = -1;
  StreamSubscription<List<int>>? _activeDl;
  StreamSubscription<dynamic>? _notificationEventSub;
  YoutubeExplode? _playYt;

  final Map<String, String> _tmpFiles = {};

  static const int _prefetchAhead = 5;
  bool _prefetchRunning = false;
  String? _prefetchForVideoId;
  final Set<String> _prefetching = {};

  bool _radioMode = false;
  bool _radioFetching = false;
  bool _radioQueueFilling = false;
  final Set<String> _radioSeenIds = {};

  bool _shuffleOn = false;
  List<Video> _unshuffledQueue = [];

  int _repeatMode = 0;

  Timer? _sleepTimer;
  DateTime? _sleepAt;
  Timer? _sleepCountdown;

  bool _crossfadeOn = false;
  double _crossfadeSecs = 3.0;
  bool _smartTransitionsOn = true;
  bool _loudnessNormalizationOn = true;
  double _loudnessNormalizationStrength = 0.7;
  bool _crossfading = false;

  double _playbackSpeed = 1.0;

  bool _showNowPlaying = false;

  int _selectedTab = 0;

  final List<Video> _history = [];
  final List<Map<String, String>> _downloads = [];
  final List<int> _downloadQueue = [];
  final List<int> _unshuffledDownloadQueue = [];
  int _currentDownloadQueuePos = -1;
  bool _downloadShuffleOn = false;
  final List<Video> _likedAutoDownloadQueue = [];
  bool _autoDownloadingLiked = false;
  final List<Map<String, dynamic>> _listeningLogs = [];
  int _wrappedPeriod = 0; // 0=weekly, 1=monthly, 2=annual
  static const List<String> _wrappedPeriodLabels = [
    'Weekly',
    'Monthly',
    'Annual',
  ];
  static const List<String> _wrappedPeriodWindows = [
    'Last 7 days',
    'Last 30 days',
    'Last 365 days',
  ];
  static const List<String> _wrappedPeriodEmoji = ['365D', '30D', '7D'];
  static const int _quickPicksItemsPerPage = 4;
  static const int _quickPicksMaxPages = 8;
  static const int _quickPicksMaxItems =
      _quickPicksItemsPerPage * _quickPicksMaxPages;

  List<Video> _quickRow1 = [];
  String _quickRow1Label = 'Made for you';
  int _quickPicksPage = 0;
  String _lastQuickUiDebugSignature = '';
  late final PageController _quickPicksCtrl;
  final List<Video> _homeCacheQuick = [];
  String _homeCacheQuickLabel = '';
  DateTime? _homeCacheAt;
  bool _ytFeedWarnShown = false;
  DateTime? _ytFeedWarnAt;
  final List<Video> _speedDialPins = [];
  int _speedDialPage = 0;
  late final PageController _speedDialCtrl;
  static const int _maxSpeedDialPins = 30;

  final List<String> _genres = [
    'Hip-Hop',
    'Romance',
    'Bollywood',
    'Pop',
    'EDM',
    'Lo-fi',
    'Punjabi',
    'Tamil',
    'R&B',
    'Rock',
    'Jazz',
  ];
  String? _selectedGenre;
  List<Video> _exploreResults = [];
  bool _exploreLoading = false;

  final Set<String> _likedVideoIds = {};
  late final BeastPlaylist _likedPlaylist;
  final List<BeastPlaylist> _playlists = [];
  BeastPlaylist? _openPlaylist;

  String? _artistPageName;
  List<Video> _artistVideos = [];
  bool _artistLoading = false;

  final TextEditingController _playlistSearchCtrl = TextEditingController();
  String _playlistSearchQuery = '';

  int _librarySortMode = 0;
  bool _libraryReorderMode = false;

  // NEW: Trending by country
  final List<String> _trendingCountries = [
    'Global',
    'India',
    'USA',
    'UK',
    'K-Pop',
    'Brazil',
    'Pakistan',
  ];
  int _selectedCountryIdx = 1; // default India
  List<Video> _trendingVideos = [];
  bool _trendingLoading = false;

  // NEW: "Because you liked" row
  List<Video> _becauseYouLiked = [];
  String _becauseYouLikedLabel = '';
  bool _becauseYouLikedLoading = false;

  // NEW: Daily mix playlists (up to 3, auto-generated from history)
  final List<BeastPlaylist> _dailyMixes = [];
  bool _dailyMixGenerated = false;

  // NEW: Related artists in full player
  List<String> _relatedArtists = [];
  final Map<String, double> _artistActionBoost = {};
  final Map<String, double> _genreActionBoost = {};
  final Map<String, double> _langActionBoost = {};
  final Map<String, double> _queryActionBoost = {};
  final Map<String, double> _videoActionBoost = {};
  final Map<String, double> _quickPickExposurePenalty = {};
  final Set<String> _blockedVideoIds = {};
  final Set<String> _blockedArtistKeys = {};
  final Map<String, _TrackFeatures> _trackFeaturesCache = {};

  // NEW: Lyrics
  String? _cachedLyricsVideoId;
  String? _cachedLyrics;

  // NEW: Artist bio
  final Map<String, Map<String, dynamic>> _artistBioCache = {};

  // YouTube Account (OAuth via browser + deep-link callback).
  static const String _oauthAuthorizationEndpoint =
      'https://accounts.google.com/o/oauth2/v2/auth';
  static const String _oauthTokenEndpoint =
      'https://oauth2.googleapis.com/token';
  static const String _oauthRedirectUri =
      'com.googleusercontent.apps.123593193663-vkqoqia8r3f98lbblvedi135vmtta7r7:/oauth2redirect';
  static const String _oauthClientId =
      '123593193663-vkqoqia8r3f98lbblvedi135vmtta7r7.apps.googleusercontent.com';
  static const List<String> _ytOauthScopes = [
    'openid',
    'email',
    'profile',
    'https://www.googleapis.com/auth/youtube',
    'https://www.googleapis.com/auth/youtube.readonly',
    'https://www.googleapis.com/auth/drive.appdata',
  ];
  static const List<String> _ytGoogleSignInScopes = [
    'https://www.googleapis.com/auth/youtube',
    'https://www.googleapis.com/auth/youtube.readonly',
    'https://www.googleapis.com/auth/drive.appdata',
  ];
  static const String _ytOauthCredentialsPrefKey = 'yt_oauth_credentials_json';
  static const String _debugModePrefKey = 'debug_mode_enabled';
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: _ytGoogleSignInScopes,
    forceCodeForRefreshToken: false,
  );
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _oauthLinkSub;
  oauth2.AuthorizationCodeGrant? _ytAuthGrant;
  oauth2.Client? _ytClient;
  String? _ytAccountEmail;
  String? _ytAccountName;
  String? _ytAccountPhoto;
  String? _ytAccessToken;
  String? _ytRefreshToken;
  String? _ytMusicCookie;
  String _ytMusicAuthUser = '0';
  String _ytMusicVisitorData = _ytMusicDefaultVisitorData;
  String? _ytMusicResolvedWebRemixClientVersion;
  DateTime? _ytMusicBackendRetryAfter;
  bool _ytMusicSessionChecking = false;
  bool _ytMusicSessionValid = false;
  String? _ytMusicSessionName;
  String? _ytMusicSessionEmail;
  String? _ytMusicSessionHandle;
  String? _ytMusicSessionError;
  WebViewController? _ytMusicQuickPicksWebViewController;
  int _ytMusicQuickPicksWebViewRequestId = 0;
  bool _ytSigningIn = false;
  List<Video> _ytLikedVideos = []; // liked songs from YT account
  bool _ytDataLoading = false;

  // Persistence
  Timer? _saveDebounce;
  bool _dataLoaded = false;
  Timer? _cloudSaveDebounce;
  String? _pendingCloudBackupJson;
  String? _cloudBackupFileId;
  DateTime? _cloudLastSyncAt;
  String? _cloudSyncError;
  bool _cloudSyncing = false;
  bool _cloudWritesPausedForRestore = false;
  int _lastPersistedDataSavedAtMs = 0;
  static const String _cloudBackupFileName = 'beast_data_cloud.json';

  // Debug mode for detailed logging
  bool _debugModeEnabled = false;

  // Settings state
  /// 0 = Low, 1 = Medium, 2 = High
  int _audioQuality = 2;
  String _downloadPath = '';
  bool _ytMusicPhoneOnlyMode = true;
  String _ytMusicBackendUrlOverride = '';
  String _ytMusicBackendApiKeyOverride = '';
  bool _eqEnabled = false;
  bool _bassBoostEnabled = false;
  double _bassBoostGain = 0.39;
  AndroidEqualizerParameters? _eqParams;
  final Map<int, double> _savedEqBandGains = {};
  Map<String, dynamic>? _pendingPlaybackRestore;
  String? _skipOutcomeUpdateForVideoId;
  Duration _lastKnownPlayerPosition = Duration.zero;
  bool _lastKnownPlayerPlaying = false;
  StreamSubscription<Duration>? _playerPositionSub;

  static const List<String> _audioQualityLabels = ['Low', 'Medium', 'High'];

  String _deviceId = '';
  bool _experimentsEnabled = true;
  String _qpVariant = 'bandit';
  final Map<String, Map<String, dynamic>> _banditQuickArms = {};
  String _qpArmLastServed = '';
  final Map<String, num> _quickMetrics = {
    'exposures': 0,
    'clicks': 0,
    'skipsEarly': 0,
    'completions': 0,
  };
  final Map<String, Map<String, double>> _cfCounts = {};
  bool _currentFromQuick = false;
  int _sessionPositiveEvents = 0;
  DateTime? _sessionStartAt;

  // ---
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _quickPicksCtrl = PageController();
    _speedDialCtrl = PageController();
    _player = AudioPlayer(
      audioPipeline: AudioPipeline(
        androidAudioEffects: [_androidEqualizer, _androidLoudnessEnhancer],
      ),
    );
    _playerB = AudioPlayer();
    _beastClient = beast.BeastClient(
      engine: beast.JustAudioEngine(player: _player),
      config: const beast.BeastClientConfig(
        startupTarget: Duration(milliseconds: 900),
        prebufferTrackCount: 1,
        enablePredictiveLoading: false,
        maxRetries: 2,
        retryBackoff: Duration(milliseconds: 180),
      ),
    );
    _likedPlaylist = BeastPlaylist(
      id: '__liked__',
      name: 'Liked Songs',
      isSystem: true,
    );
    _player.playerStateStream.listen((state) {
      final changed = state.playing != _lastPlayerPlaying ||
          state.processingState != _lastPlayerProcessingState;
      if (!changed) return;
      _lastPlayerPlaying = state.playing;
      _lastKnownPlayerPlaying = state.playing;
      _lastPlayerProcessingState = state.processingState;
      if (mounted) setState(() {});
    });
    _playerPositionSub = _player.positionStream.listen((position) {
      _lastKnownPlayerPosition = position;
    });
    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed && !_isBuffering) {
        _onTrackCompleted();
      }
    });
    _playerB.playerStateStream.listen((state) {
      if (state.playing == _lastPlayerBPlaying) return;
      _lastPlayerBPlaying = state.playing;
      if (mounted) setState(() {});
    });
    // ignore: deprecated_member_use
    _notificationEventSub = AudioService.customEventStream.listen(
      _handleNotificationEvent,
      onError: (Object e, StackTrace st) {
        debugPrint('[Notification] customEvent error: $e');
      },
    );
    _setupDeepLink();
    _initDownloadPath();
    _loadEqParams();
    unawaited(_initAndLoad());
  }

  Future<void> _initAndLoad() async {
    await _initDownloadPath();
    await _loadData();
    await _restorePlaybackFromSavedState();
    await _applySavedAudioEffects();

    // Load debug mode preference
    try {
      final prefs = await SharedPreferences.getInstance();
      _debugModeEnabled = prefs.getBool(_debugModePrefKey) ?? false;
    } catch (e) {
      debugPrint('[Debug] Failed to load debug mode: $e');
    }
    await _ensureDeviceId();
    _initExperiments();

    unawaited(_restoreGoogleSignInSession());
    final hasYtMusicCookie = (_ytMusicCookie ?? '').trim().isNotEmpty;

    debugPrint('[YTM] initAndLoad: hasCookie=$hasYtMusicCookie');

    if (hasYtMusicCookie) {
      debugPrint('[YTM] Starting session refresh with home reload...');
      unawaited(_refreshYtMusicSession(reloadHome: true, showToast: true));
    } else {
      debugPrint('[YTM] No cookie, loading home without session...');
      unawaited(_refreshYtMusicSession());
      unawaited(_loadHome());
    }
  }

  Future<void> _ensureDeviceId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = (prefs.getString('device_id') ?? '').trim();
      if (saved.isNotEmpty) {
        _deviceId = saved;
        return;
      }
      final r = Random.secure();
      final bytes = List<int>.generate(16, (_) => r.nextInt(256));
      final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      _deviceId = 'dev_$hex';
      await prefs.setString('device_id', _deviceId);
    } catch (_) {}
  }

  void _initExperiments() {
    final assigned = _hashToVariant('qp_algo', ['control', 'bandit']);
    _qpVariant = assigned;
  }

  String _hashToVariant(String name, List<String> variants) {
    if (variants.isEmpty) return 'control';
    final input = utf8.encode('$_deviceId|$name');
    final digest = sha1.convert(input).bytes;
    var x = 0;
    for (int i = 0; i < min(4, digest.length); i++) {
      x = (x << 8) ^ digest[i];
    }
    final idx = x.abs() % variants.length;
    return variants[idx];
  }

  String _selectQuickPicksArm(bool usingYtMusicHome, bool preserveOfficial) {
    if (!_experimentsEnabled || _qpVariant == 'control') {
      if (usingYtMusicHome && preserveOfficial) return 'official';
      return 'smart';
    }
    final arms = <String>[
      if (usingYtMusicHome) 'official',
      'hybrid',
      'smart',
      'cf',
      'fallback',
    ];
    if (arms.isEmpty) return 'smart';
    var total = 0.0;
    for (final a in arms) {
      final s = _banditQuickArms[a];
      total += (s?['count'] as num? ?? 0).toDouble();
    }
    final ucbScores = <String, double>{};
    const c = 1.6;
    for (final a in arms) {
      final s = _banditQuickArms[a] ?? {};
      final count = (s['count'] as num? ?? 0).toDouble();
      final reward = (s['sum'] as num? ?? 0).toDouble();
      final mean = count > 0 ? (reward / count) : 0.0;
      final bonus = count > 0 && total > 0
          ? c * sqrt(log(total + 1.0) / (count + 1.0))
          : 1.0;
      ucbScores[a] = mean + bonus;
    }
    final best = ucbScores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return best.first.key;
  }

  Future<({List<Video> videos, String label})> _applyBanditOnQuickPicks({
    required List<Video> selectedQuickPicks,
    required String quickLabel,
    required bool usingYtMusicHome,
    required ({
      List<Video> quickPicks,
      String quickPicksLabel,
      bool quickPicksFromOfficialShelf,
      List<_YtMusicHomeSection> shelves,
      List<BeastPlaylist> mixes,
    }) ytHome,
    required bool preserveOfficialYtOrder,
  }) async {
    if (usingYtMusicHome) {
      final officialBase =
          selectedQuickPicks.where(_isQuickPickAllowed).toList();
      final merged = <Video>[];
      final seenIds = <String>{};
      final seenSig = <String>{};

      void addFrom(Iterable<Video> source, {int maxAdds = 1 << 30}) {
        var added = 0;
        for (final video in source) {
          if (merged.length >= _quickPicksMaxItems) break;
          if (added >= maxAdds) break;
          if (!seenIds.add(video.id.value)) continue;
          final sig = _trackSignature(video);
          if (!seenSig.add(sig)) continue;
          if (!_isMusicCandidate(video, strictSingles: true)) continue;
          merged.add(video);
          added++;
        }
      }

      final officialKeep = min(
        officialBase.length,
        min(10, max(6, _quickPicksMaxItems ~/ 2)),
      );
      addFrom(officialBase.take(officialKeep), maxAdds: officialKeep);
      addFrom(ytHome.quickPicks.where(_isQuickPickAllowed));
      for (final shelf in ytHome.shelves.take(10)) {
        addFrom(shelf.videos.where(_isQuickPickAllowed));
      }
      for (final mix in ytHome.mixes.take(4)) {
        addFrom(mix.videos.where(_isQuickPickAllowed));
      }
      addFrom(officialBase.skip(officialKeep));
      final labelBase = ytHome.quickPicksLabel.trim().isNotEmpty
          ? ytHome.quickPicksLabel.trim()
          : 'From your YouTube Music home feed';
      _recordQuickExposureArm('yt_home_blend');
      return (
        videos: _dedupeByTrackSignature(merged, maxPerSignature: 1)
            .take(_quickPicksMaxItems)
            .toList(),
        label: '$labelBase + AI tune'
      );
    }

    final arm = _selectQuickPicksArm(usingYtMusicHome, preserveOfficialYtOrder);
    List<Video> out = selectedQuickPicks;
    String label = quickLabel;
    if (arm == 'smart') {
      final ai = await _buildQuickPicksSmart(target: _quickPicksMaxItems);
      if (ai.videos.isNotEmpty) {
        out = ai.videos.take(_quickPicksMaxItems).toList();
        label = ai.label.isNotEmpty ? ai.label : 'Made for you';
      }
    } else if (arm == 'hybrid') {
      final hybrid = _buildHybridQuickPicks(
          usingYtMusicHome: usingYtMusicHome,
          ytHome: ytHome,
          target: _quickPicksMaxItems);
      if (hybrid.videos.isNotEmpty) {
        out = hybrid.videos.take(_quickPicksMaxItems).toList();
        label = hybrid.label.isNotEmpty ? hybrid.label : 'Made for you';
      }
    } else if (arm == 'cf') {
      final cf = _buildCfQuickPicks(target: _quickPicksMaxItems);
      if (cf.isNotEmpty) {
        out = cf.take(_quickPicksMaxItems).toList();
        label = 'Based on your recent plays';
      }
    } else if (arm == 'fallback') {
      final fb = _quickPicksFallback(target: _quickPicksMaxItems);
      if (fb.isNotEmpty) {
        out = fb.take(_quickPicksMaxItems).toList();
        label = 'Made for you';
      }
    }
    _recordQuickExposureArm(arm);
    return (videos: out, label: label);
  }

  void _recordQuickExposureArm(String arm) {
    _qpArmLastServed = arm;
    _quickMetrics['exposures'] = (_quickMetrics['exposures'] ?? 0) + 1;
    final s = _banditQuickArms[arm] ?? {'count': 0, 'sum': 0.0};
    s['count'] = ((s['count'] as num?)?.toInt() ?? 0) + 1;
    _banditQuickArms[arm] = s;
    _scheduleSave();
  }

  void _recordQuickClick() {
    _quickMetrics['clicks'] = (_quickMetrics['clicks'] ?? 0) + 1;
    if (_qpArmLastServed.isNotEmpty) {
      final s = _banditQuickArms[_qpArmLastServed] ?? {'count': 0, 'sum': 0.0};
      s['sum'] = ((s['sum'] as num?)?.toDouble() ?? 0.0) + 1.0;
      _banditQuickArms[_qpArmLastServed] = s;
    }
    _scheduleSave();
  }

  void _recordQuickSkipEarly() {
    _quickMetrics['skipsEarly'] = (_quickMetrics['skipsEarly'] ?? 0) + 1;
    if (_qpArmLastServed.isNotEmpty) {
      final s = _banditQuickArms[_qpArmLastServed] ?? {'count': 0, 'sum': 0.0};
      s['sum'] = ((s['sum'] as num?)?.toDouble() ?? 0.0) - 0.5;
      _banditQuickArms[_qpArmLastServed] = s;
    }
    _scheduleSave();
  }

  void _recordQuickCompletion() {
    _quickMetrics['completions'] = (_quickMetrics['completions'] ?? 0) + 1;
    if (_qpArmLastServed.isNotEmpty) {
      final s = _banditQuickArms[_qpArmLastServed] ?? {'count': 0, 'sum': 0.0};
      s['sum'] = ((s['sum'] as num?)?.toDouble() ?? 0.0) + 0.5;
      _banditQuickArms[_qpArmLastServed] = s;
    }
    _scheduleSave();
  }

  void _cfObserveTransition(String fromId, String toId, {double weight = 1.0}) {
    final a = fromId.trim();
    final b = toId.trim();
    if (a.isEmpty || b.isEmpty || a == b) return;
    final m = _cfCounts[a] ?? {};
    m[b] = (m[b] ?? 0.0) + weight;
    _cfCounts[a] = m;
    if (m.length > 600) {
      final entries = m.entries.toList()
        ..sort((x, y) => y.value.compareTo(x.value));
      m
        ..clear()
        ..addEntries(entries.take(600));
      _cfCounts[a] = m;
    }
    if (_cfCounts.length > 4000) {
      final keys = _cfCounts.keys.toList()..shuffle();
      for (final k in keys.skip(3500)) {
        _cfCounts.remove(k);
      }
    }
  }

  List<Video> _buildCfQuickPicks({int target = 24}) {
    final seeds = _collectQuickPickSeeds(maxSeeds: 12);
    final seen = <String>{};
    final scores = <String, double>{};
    for (final s in seeds) {
      final id = s.id.value;
      final neighbors = _cfCounts[id];
      if (neighbors == null) continue;
      for (final e in neighbors.entries) {
        if (!seen.add('$id-${e.key}')) {}
        scores[e.key] = (scores[e.key] ?? 0.0) + e.value;
      }
    }
    if (scores.isEmpty) return const <Video>[];
    final idToVideo = <String, Video>{};
    void addSrc(Iterable<Video> src) {
      for (final v in src) {
        idToVideo[v.id.value] = v;
      }
    }

    addSrc(_history.take(200));
    addSrc(_likedPlaylist.videos.take(400));
    addSrc(_ytLikedVideos.take(400));
    final ranked = <({Video v, double score})>[];
    for (final entry in scores.entries) {
      final v = idToVideo[entry.key];
      if (v == null) continue;
      if (_isRecommendationBlocked(v)) continue;
      if (!_isMusicCandidate(v, strictSingles: true)) continue;
      ranked.add((v: v, score: entry.value));
    }
    ranked.sort((a, b) => b.score.compareTo(a.score));
    final seedsIds = seeds.map((v) => v.id.value).toSet();
    final seedArtists = seeds.map((v) => _primaryArtistKey(v.author)).toSet();
    final diverse = _pickDiverseQuickPicks(
      ranked,
      target: target,
      seedIds: seedsIds,
      seedArtists: seedArtists,
      profile: _buildTasteProfile(),
    );
    if (diverse.isEmpty) {
      final simple = ranked.take(target).map((e) => e.v).toList();
      return simple;
    }
    return diverse;
  }

  Future<void> _initDownloadPath() async {
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        if (mounted) setState(() => _downloadPath = ext.path);
        return;
      }
    } catch (_) {}
    final app = await getApplicationDocumentsDirectory();
    if (mounted) setState(() => _downloadPath = app.path);
  }

  Future<void> _loadEqParams() async {
    try {
      final params = await _androidEqualizer.parameters;
      _eqParams = params;
      await _applyEqBandGains();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('[EQ] params: $e');
    }
  }

  void _capturePlaybackSnapshot() {
    try {
      _lastKnownPlayerPosition = _player.position;
      _lastKnownPlayerPlaying = _player.playing;
    } catch (_) {}
  }

  static const double _bassBoostMaxDb = 5.0;
  static const double _bassBoostMaxTargetGain = _bassBoostMaxDb * 100.0;
  static final double _bassBoostMaxNormalized =
      pow(_bassBoostMaxTargetGain / 1800.0, 1 / 1.35).toDouble();

  double _clampedBassBoostGain(double value) {
    return value.clamp(0.0, _bassBoostMaxNormalized).toDouble();
  }

  double _bassBoostTargetGain(double value) {
    final clamped = _clampedBassBoostGain(value);
    return min(
        _bassBoostMaxTargetGain, (1800.0 * pow(clamped, 1.35)).toDouble());
  }

  double _bassBoostDisplayDb(double value) {
    return _bassBoostTargetGain(value) / 100.0;
  }

  Future<void> _applyBassBoostGain(double value) async {
    final clamped = _clampedBassBoostGain(value);
    _bassBoostGain = clamped;
    try {
      await _androidLoudnessEnhancer.setTargetGain(
        _bassBoostTargetGain(clamped),
      );
    } catch (e) {
      debugPrint('[Bass gain] $e');
    }
  }

  Future<void> _applyEqBandGains() async {
    final params = _eqParams;
    if (params == null || _savedEqBandGains.isEmpty) return;
    for (final band in params.bands) {
      final freq = band.centerFrequency.toInt();
      final savedGain = _savedEqBandGains[freq];
      if (savedGain == null) continue;
      final target = savedGain.clamp(params.minDecibels, params.maxDecibels);
      try {
        await band.setGain(target);
      } catch (_) {}
    }
  }

  Future<void> _applySavedAudioEffects() async {
    try {
      await _androidEqualizer.setEnabled(_eqEnabled);
    } catch (e) {
      debugPrint('[EQ apply] $e');
    }
    try {
      await _androidLoudnessEnhancer.setEnabled(_bassBoostEnabled);
    } catch (e) {
      debugPrint('[Bass apply] $e');
    }
    await _applyBassBoostGain(_bassBoostGain);
    await _applyEqBandGains();
  }

  Future<void> _restorePlaybackFromSavedState() async {
    final restore = _pendingPlaybackRestore;
    if (restore == null) return;
    _pendingPlaybackRestore = null;

    final nowMap = _jsonMap(restore['nowPlaying']);
    if (nowMap == null) return;
    final nowVideo = _videoFromMap(nowMap);
    if (!VideoId.validateVideoId(nowVideo.id.value)) return;

    final queueRaw = _jsonList(restore['queue']);
    final queue = queueRaw
        .map((raw) => _jsonMap(raw))
        .whereType<Map<String, dynamic>>()
        .map(_videoFromMap)
        .where((v) => VideoId.validateVideoId(v.id.value))
        .toList();
    final hasNowInQueue = queue.any((v) => v.id.value == nowVideo.id.value);
    final restoredQueue = hasNowInQueue ? queue : <Video>[nowVideo, ...queue];
    if (restoredQueue.isEmpty) {
      restoredQueue.add(nowVideo);
    }

    var restoredIndex = (restore['currentIndex'] as num?)?.toInt() ?? -1;
    if (restoredIndex < 0 || restoredIndex >= restoredQueue.length) {
      restoredIndex =
          restoredQueue.indexWhere((v) => v.id.value == nowVideo.id.value);
      if (restoredIndex < 0) restoredIndex = 0;
    }
    final positionMs =
        ((restore['positionMs'] as num?)?.toInt() ?? 0).clamp(0, 36000000);
    final wasPlaying = restore['wasPlaying'] == true;

    _playQueue = List<Video>.from(restoredQueue);
    _currentIndex = restoredIndex;
    _nowPlaying = restoredQueue[restoredIndex];
    _skipOutcomeUpdateForVideoId = _nowPlaying?.id.value;
    if (mounted) setState(() {});

    await _play(
      _playQueue[restoredIndex],
      restoredIndex,
      autoPlay: false,
      seekPosition: Duration(milliseconds: positionMs),
      restoringSession: true,
    );
    _lastKnownPlayerPosition = Duration(milliseconds: positionMs);
    _lastKnownPlayerPlaying = false;
    if (wasPlaying) {
      _bufferLabel = 'Tap play to resume';
      if (mounted) setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _capturePlaybackSnapshot();
      if (_dataLoaded) {
        unawaited(_saveData());
      }
    }
  }

  // Audio quality stream selector
  AudioOnlyStreamInfo _selectStream(List<AudioOnlyStreamInfo> streams) {
    if (streams.isEmpty) throw Exception('No audio streams available');
    var candidates = List<AudioOnlyStreamInfo>.from(streams);

    // Android decoders are generally more reliable with MP4/M4A audio-only
    // streams than WEBM/OPUS on some devices.
    if (Platform.isAndroid) {
      final mp4Like = candidates.where((s) {
        final name = s.container.name.toLowerCase();
        return name.contains('mp4') || name.contains('m4a');
      }).toList();
      if (mp4Like.isNotEmpty) {
        candidates = mp4Like;
      }
    }

    final sorted = candidates
      ..sort(
          (a, b) => a.bitrate.bitsPerSecond.compareTo(b.bitrate.bitsPerSecond));
    switch (_audioQuality) {
      case 0:
        return sorted.first;
      case 1:
        return sorted[sorted.length ~/ 2];
      case 2:
        return sorted.last;
      default:
        return sorted.last;
    }
  }

  List<AudioOnlyStreamInfo> _orderStreamsByQuality(
      List<AudioOnlyStreamInfo> streams) {
    final sorted = List<AudioOnlyStreamInfo>.from(streams)
      ..sort(
          (a, b) => a.bitrate.bitsPerSecond.compareTo(b.bitrate.bitsPerSecond));
    if (sorted.length <= 1) return sorted;
    switch (_audioQuality) {
      case 0:
        return sorted;
      case 2:
        return sorted.reversed.toList();
      default:
        final out = <AudioOnlyStreamInfo>[];
        final used = <int>{};
        var left = (sorted.length ~/ 2);
        var right = left + 1;
        while (out.length < sorted.length) {
          if (left >= 0 && used.add(left)) out.add(sorted[left]);
          if (right < sorted.length && used.add(right)) out.add(sorted[right]);
          left--;
          right++;
        }
        return out;
    }
  }

  List<AudioOnlyStreamInfo> _downloadStreamCandidates(
      List<AudioOnlyStreamInfo> streams) {
    if (streams.isEmpty) return const <AudioOnlyStreamInfo>[];
    final preferred = <AudioOnlyStreamInfo>[];
    final fallback = <AudioOnlyStreamInfo>[];
    for (final s in streams) {
      final name = s.container.name.toLowerCase();
      final isMp4Like = name.contains('mp4') || name.contains('m4a');
      if (Platform.isAndroid && isMp4Like) {
        preferred.add(s);
      } else {
        fallback.add(s);
      }
    }
    // On Android, prefer decoder-friendly MP4/M4A and avoid falling back to
    // WEBM when MP4-like streams are available (WEBM can be unplayable on some devices).
    final ordered = <AudioOnlyStreamInfo>[
      ..._orderStreamsByQuality(preferred),
      if (!(Platform.isAndroid && preferred.isNotEmpty))
        ..._orderStreamsByQuality(fallback),
    ];
    final out = <AudioOnlyStreamInfo>[];
    final seen = <String>{};
    for (final s in ordered) {
      final key =
          '${s.container.name}_${s.bitrate.bitsPerSecond}_${s.size.totalBytes}';
      if (!seen.add(key)) continue;
      out.add(s);
    }
    return out;
  }


  double _targetVolumeForVideo(Video? video) {
    if (!_loudnessNormalizationOn || video == null) return 1.0;
    final text = '${_cleanTitle(video.title)} ${_cleanAuthor(video.author)}'
        .toLowerCase();
    var loudnessScore = 0.0;
    if (RegExp(
            r'\b(remaster(?:ed)?|8d|bass\s*boost(?:ed)?|boosted|phonk|hardstyle|trap)\b')
        .hasMatch(text)) {
      loudnessScore += 1.0;
    }
    if (RegExp(
            r'\b(live|concert|acoustic|unplugged|session|lofi|chill|ambient)\b')
        .hasMatch(text)) {
      loudnessScore -= 0.8;
    }
    if (RegExp(r'\b(remix|edit|mashup)\b').hasMatch(text)) {
      loudnessScore += 0.35;
    }
    final secs = video.duration?.inSeconds ?? 0;
    if (secs > 0 && secs < 95) loudnessScore += 0.25;
    if (secs >= 420) loudnessScore -= 0.15;
    final gainReduction = (loudnessScore.clamp(-1.2, 1.8) * 0.08) *
        _loudnessNormalizationStrength;
    return (1.0 - gainReduction).clamp(0.72, 1.0);
  }

  Future<void> _applyNormalizationForPlayer(
    AudioPlayer player,
    Video? video,
  ) async {
    try {
      await player.setVolume(_targetVolumeForVideo(video));
    } catch (e) {
      debugPrint('[Normalize] $e');
    }
  }

  Future<void> _syncCurrentTrackVolume() async {
    await _applyNormalizationForPlayer(_player, _nowPlaying);
  }

  double _effectiveCrossfadeSeconds(Video nextVideo) {
    if (!_smartTransitionsOn) return _crossfadeSecs;
    var fade = _crossfadeSecs;
    final currentSecs = _nowPlaying?.duration?.inSeconds ?? 0;
    final nextSecs = nextVideo.duration?.inSeconds ?? 0;
    final knownDurations = <int>[
      if (currentSecs > 0) currentSecs,
      if (nextSecs > 0) nextSecs,
    ];
    if (knownDurations.isNotEmpty) {
      final shortest = knownDurations.reduce(min).toDouble();
      final cap = (shortest * 0.18).clamp(1.0, 6.0);
      fade = fade.clamp(1.0, cap);
    }
    return fade;
  }

  bool _isCrossfadeEligible(
    Video nextVideo, {
    bool userInitiated = false,
  }) {
    if (!_crossfadeOn || _isBuffering || _crossfading) return false;
    if (!_tmpFiles.containsKey(nextVideo.id.value)) return false;
    if (!_smartTransitionsOn) return true;
    if (userInitiated) return false;
    final currentSecs = _nowPlaying?.duration?.inSeconds ?? 0;
    final nextSecs = nextVideo.duration?.inSeconds ?? 0;
    if ((currentSecs > 0 && currentSecs < 75) ||
        (nextSecs > 0 && nextSecs < 75)) {
      return false;
    }
    return true;
  }

  bool _shouldDoGaplessHandoff(
    Video nextVideo, {
    bool userInitiated = false,
  }) {
    if (!_smartTransitionsOn || _isBuffering || _crossfading) return false;
    if (!_tmpFiles.containsKey(nextVideo.id.value)) return false;
    if (_isCrossfadeEligible(nextVideo, userInitiated: userInitiated)) {
      return false;
    }
    return true;
  }

  Future<void> _playGaplessFromCache(Video video, int index) async {
    final videoId = video.id.value;
    final cached = _tmpFiles[videoId];
    if (cached == null || !await File(cached).exists()) {
      await _play(video, index);
      return;
    }

    final previous = _nowPlaying;
    if (previous != null && previous.id.value != videoId) {
      final prevSecs = _player.position.inSeconds;
      if (prevSecs >= 6) {
        _updateListeningOutcomeForVideo(
          previous.id.value,
          playedSecs: prevSecs,
          completed: false,
        );
      }
    }

    _currentVideoId = videoId;
    _currentDownloadIndex = -1;
    _prefetchForVideoId = videoId;
    _activeDl?.cancel();
    _activeDl = null;
    _playYt?.close();
    _playYt = null;
    await _cancelActiveSecondaryPlayback();
    await _player.stop();
    if (_currentVideoId != videoId) return;

    _history.removeWhere((v) => v.id == video.id);
    _history.insert(0, video);
    if (_history.length > 50) _history.removeLast();
    _recordListeningEvent(video, isDownload: false);
    _radioSeenIds.add(videoId);
    _scheduleSave();

    if (mounted) {
      setState(() {
        _nowPlaying = video;
        _currentIndex = index;
        _isBuffering = false;
        _bufferProgress = 0;
        _bufferLabel = '';
      });
    } else {
      _nowPlaying = video;
      _currentIndex = index;
      _isBuffering = false;
      _bufferProgress = 0;
      _bufferLabel = '';
    }

    _updateRelatedArtists();
    if (!_dailyMixGenerated &&
        (_ytLikedVideos.isNotEmpty ||
            _likedPlaylist.videos.length >= 2 ||
            _history.length >= 3)) {
      unawaited(_generateDailyMixes());
    }
    if (_radioMode) {
      final upcoming = _playQueue.length - index - 1;
      if (upcoming < 4) {
        unawaited(_appendRadioCandidates(video, minAdds: 10 - upcoming));
      }
    }

    try {
      await _setPlayerSource(
        AudioSource.uri(
          Uri.file(cached),
          tag: _mediaItemForVideo(video, cached),
        ),
      );
      await _player.setSpeed(_playbackSpeed);
      await _applyNormalizationForPlayer(_player, video);
      await _startPrimaryPlayback();
      unawaited(_prefetchNext(index, videoId));
    } catch (e) {
      debugPrint('[Gapless] $e');
      await _play(video, index);
    }
  }

  // Set audio source + media session metadata
  Future<void> _setPlayerSource(
    AudioSource source,
  ) =>
      _player.setAudioSource(source);

  Future<void> _ensureBeastClientReady() async {
    if (_beastClientReady || _beastClient == null) return;
    await _beastClient!.initialize();
    _beastClientReady = true;
  }

  Future<bool> _tryPlayViaBeastClientStream(
    Video video, {
    required Uri streamUri,
    Map<String, String>? headers,
    required bool autoPlay,
    Duration? seekPosition,
  }) async {
    final client = _beastClient;
    if (client == null) return false;
    try {
      await _ensureBeastClientReady();
      final track = beast.AudioTrack(
        id: video.id.value,
        uri: streamUri,
        title: _cleanTitle(video.title),
        artist: _cleanAuthor(video.author),
        durationHint: video.duration,
        headers: headers ?? const <String, String>{},
      );
      await client.setQueue(<beast.AudioTrack>[track]);
      await client.playTrack(track);
      await _player.setSpeed(_playbackSpeed);
      await _applyNormalizationForPlayer(_player, video);
      await _waitForPrimaryPlaybackStart();
      if (seekPosition != null) {
        await _player.seek(seekPosition);
      }
      if (!autoPlay) {
        await client.pause();
      }
      return true;
    } catch (e) {
      debugPrint('[BeastClient playback] $e');
      return false;
    }
  }

  Future<void> _startPrimaryPlayback() async {
    // just_audio `play()` can complete when playback ends; do not block control flow on it.
    unawaited(
      _player.play().catchError((Object e) {
        debugPrint('[Player play] $e');
      }),
    );
    await _waitForPrimaryPlaybackStart();
  }

  Future<void> _waitForPrimaryPlaybackStart({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final state = _player.playerState;
    if (state.playing && state.processingState == ProcessingState.ready) {
      return;
    }
    await _player.playerStateStream
        .firstWhere(
          (state) =>
              state.playing && state.processingState == ProcessingState.ready,
        )
        .timeout(timeout);
  }

  Future<bool> _tryPlayViaBackendProxy(
    Video video, {
    required bool autoPlay,
    Duration? seekPosition,
  }) async {
    if (!_shouldUseYtMusicBackend()) return false;
    final baseUrl = _ytMusicBackendBaseUrl().trim();
    if (baseUrl.isEmpty) return false;
    final streamUri = _backendAudioProxyUriForVideo(video.id.value);
    if (streamUri == null) return false;
    final apiKey = _effectiveYtMusicBackendApiKey();
    final rawCookie = _effectiveYtMusicCookie();
    final backendHeaders = <String, String>{};
    if (apiKey.isNotEmpty) {
      backendHeaders['x-api-key'] = apiKey;
    }
    if (rawCookie.isNotEmpty) {
      backendHeaders['x-ytmusic-cookie'] = rawCookie;
    }
    final headers = backendHeaders.isEmpty ? null : backendHeaders;
    try {
      await _wakeYtMusicBackendIfNeeded(
        baseUrl,
        headers: headers,
        timeout: const Duration(seconds: 12),
      );
      await _warmYtMusicBackendStream(
        baseUrl,
        video.id.value,
        headers: headers,
      );
      final beastPlayed = await _tryPlayViaBeastClientStream(
        video,
        streamUri: streamUri,
        headers: headers,
        autoPlay: autoPlay,
        seekPosition: seekPosition,
      );
      if (beastPlayed) return true;
      await _setPlayerSource(
        AudioSource.uri(
          streamUri,
          headers: headers,
          tag: _mediaItemForVideo(video, ''),
        ),
      );
      await _player.setSpeed(_playbackSpeed);
      await _applyNormalizationForPlayer(_player, video);
      if (seekPosition != null) {
        await _player.seek(seekPosition);
      }
      if (autoPlay) {
        await _startPrimaryPlayback();
      } else {
        await _player.pause();
      }
      return true;
    } catch (e) {
      debugPrint('[Proxy playback] $e');
      return false;
    }
  }

  Map<String, String> _directPlaybackHeaders() {
    return <String, String>{
      HttpHeaders.userAgentHeader: _ytMusicUserAgent,
      HttpHeaders.acceptHeader: '*/*',
    };
  }

  bool _isRecoverableSourceError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('response code: 500') ||
        text.contains('response code: 502') ||
        text.contains('response code: 503') ||
        text.contains('response code: 504') ||
        text.contains('httpdatasource') ||
        text.contains('type_source');
  }

  bool _isDnsLookupError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('failed host lookup') ||
        text.contains('no address associated with hostname') ||
        text.contains('socketexception');
  }

  bool _isBotVerificationError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('sign in to confirm you') ||
        text.contains('not a bot') ||
        text.contains('videounplayableexception') ||
        text.contains('streams are not available for this video') ||
        text.contains('unplayable');
  }

  bool _isManifestTimeoutOrUnavailable(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('timeoutexception') ||
        text.contains('future not completed') ||
        text.contains('playback stream unavailable');
  }

  Future<bool> _recoverSourceAndPlay(
    Video video, {
    required bool autoPlay,
    Duration? seekPosition,
  }) async {
    final videoId = video.id.value;
    final result = await _fetchManifest(videoId, silent: true, fast: true);
    if (result == null) return false;
    final selected = _selectStream(result.manifest.audioOnly.toList());
    final candidates = <AudioOnlyStreamInfo>[
      selected,
      ..._downloadStreamCandidates(result.manifest.audioOnly.toList())
          .where((s) => s.url.toString() != selected.url.toString()),
    ];
    _playYt?.close();
    _playYt = result.yt;
    for (final stream in candidates.take(4)) {
      if (_currentVideoId != videoId) return false;
      try {
        await _player.stop();
        await _setPlayerSource(
          AudioSource.uri(
            Uri.parse(stream.url.toString()),
            headers: _directPlaybackHeaders(),
            tag: _mediaItemForVideo(video, ''),
          ),
        );
        await _player.setSpeed(_playbackSpeed);
        await _applyNormalizationForPlayer(_player, video);
        if (seekPosition != null) {
          await _player.seek(seekPosition);
        }
        if (autoPlay) {
          await _startPrimaryPlayback();
        } else {
          await _player.pause();
        }
        return true;
      } catch (e) {
        debugPrint('[Play recovery] stream retry failed: $e');
      }
    }
    // Last-resort recovery: materialize audio to a temp file and play locally.
    return _recoverSourceViaTempFile(
      video,
      autoPlay: autoPlay,
      seekPosition: seekPosition,
    );
  }

  Future<bool> _recoverSourceViaTempFile(
    Video video, {
    required bool autoPlay,
    Duration? seekPosition,
  }) async {
    final videoId = video.id.value;
    try {
      final result = await _fetchManifest(videoId, silent: true, fast: true);
      if (result == null) return false;
      final stream = _selectStream(result.manifest.audioOnly.toList());
      final tmpDir = await getTemporaryDirectory();
      final ext = stream.container.name.trim().isEmpty ? 'm4a' : stream.container.name;
      final tmpPath = '${tmpDir.path}/recover_$videoId.$ext';
      final sink = File(tmpPath).openWrite();
      try {
        final bytes = result.yt.videos.streamsClient.get(stream);
        await for (final chunk in bytes) {
          if (_currentVideoId != videoId) {
            await sink.close();
            return false;
          }
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      final outFile = File(tmpPath);
      if (!await outFile.exists()) return false;
      final size = await outFile.length();
      if (size < 48 * 1024) return false;
      _tmpFiles[videoId] = tmpPath;
      await _player.stop();
      await _setPlayerSource(
        AudioSource.uri(
          Uri.file(tmpPath),
          tag: _mediaItemForVideo(video, tmpPath),
        ),
      );
      await _player.setSpeed(_playbackSpeed);
      await _applyNormalizationForPlayer(_player, video);
      if (seekPosition != null) {
        await _player.seek(seekPosition);
      }
      if (autoPlay) {
        await _startPrimaryPlayback();
      } else {
        await _player.pause();
      }
      return true;
    } catch (e) {
      debugPrint('[Play recovery temp-file] failed: $e');
      return false;
    }
  }

  Future<void> _cancelActiveSecondaryPlayback() async {
    _crossfading = false;
    try {
      await _playerB.stop();
    } catch (e) {
      debugPrint('[PlayerB stop] $e');
    }
    try {
      await _playerB.setVolume(1.0);
    } catch (_) {}
  }

  MediaItem _mediaItemForVideo(Video video, String filePath) {
    return MediaItem(
      id: video.id.value,
      title: _cleanTitle(video.title, author: video.author),
      artist: _cleanAuthor(video.author),
      album: 'Beast Music',
      artUri: Uri.tryParse(video.thumbnails.mediumResUrl),
      extras: {
        'filePath': filePath,
        'showLikeControl': true,
        'liked': _likedVideoIds.contains(video.id.value),
        'hasPrevious': true,
        'hasNext': true,
      },
    );
  }

  MediaItem _mediaItemForDownloadedTrack(
      Map<String, String> download, String filePath, int downloadIndex) {
    final hasPrevious = _downloadPreviousIndex != null || downloadIndex > 0;
    final hasNext = _downloadNextIndex != null ||
        (downloadIndex >= 0 && downloadIndex < _downloads.length - 1);
    return MediaItem(
      id: 'download:$filePath',
      title: _cleanTitle(download['title'] ?? 'Unknown'),
      artist: _cleanAuthor(download['author'] ?? 'Unknown'),
      album: 'Downloads',
      artUri: Uri.tryParse(download['thumbnailUrl'] ?? ''),
      extras: {
        'filePath': filePath,
        'showLikeControl': false,
        'hasPrevious': hasPrevious,
        'hasNext': hasNext,
      },
    );
  }

  // Track completion smart next
  void _onTrackCompleted() {
    final current = _nowPlaying;
    if (current != null) {
      final fullSecs =
          _player.duration?.inSeconds ?? current.duration?.inSeconds;
      _updateListeningOutcomeForVideo(
        current.id.value,
        playedSecs: fullSecs,
        completed: true,
      );
      if (_currentFromQuick) {
        _recordQuickCompletion();
      }
      if (!_isDownloadPlayback) {
        _registerFeedback(current, weight: 0.36, source: 'track_completed');
      }
      _maybeConsolidateSessionTaste();
    }
    if (_isDownloadPlayback) {
      if (_repeatMode == 2) {
        _player.seek(Duration.zero);
        _player.play();
        return;
      }
      final nextDownload = _downloadNextIndex;
      if (nextDownload != null) {
        unawaited(_playDownloadedAt(nextDownload));
      }
      return;
    }
    if (_repeatMode == 2) {
      _player.seek(Duration.zero);
      _player.play();
      return;
    }
    if (current != null) {
      _ensureQueueBackfilledWithYtMusicAi(
        current,
        localMinUpcoming: 5,
        networkMinUpcoming: 10,
      );
    }
    if (_currentIndex < _playQueue.length - 1) {
      _playNext();
    } else if (_repeatMode == 1 && _playQueue.isNotEmpty) {
      _play(_playQueue[0], 0);
    } else {
      unawaited(_playRadioNext());
    }
  }

  // Radio
  Future<void> _playRadioNext() async {
    if (_nowPlaying == null || _radioFetching) return;
    _radioFetching = true;
    _radioMode = true;
    if (mounted) {
      setState(() {
        _bufferLabel = 'Finding similar songs...';
        _isBuffering = true;
      });
    }

    try {
      await _appendRadioCandidates(_nowPlaying!, minAdds: 10);
      if (_currentIndex + 1 >= _playQueue.length) {
        if (mounted) setState(() => _isBuffering = false);
        return;
      }
      if (mounted) {
        await _play(_playQueue[_currentIndex + 1], _currentIndex + 1);
      }
    } catch (e) {
      debugPrint('[Radio] error: $e');
      if (mounted) setState(() => _isBuffering = false);
    } finally {
      _radioFetching = false;
    }
  }

  List<String> _radioQueriesFor(Video seed) {
    final profile = _buildTasteProfile();
    final topArtists = profile['topArtists'] as List<String>? ?? [];
    final topGenres = profile['topGenres'] as List<String>? ?? [];
    final song = _cleanTitle(seed.title);
    final artist = _cleanAuthor(seed.author);
    final seedText = '${seed.title} ${seed.author}'.toLowerCase();
    final seedLanguage = _detectLanguageTag(seedText);
    final seedTags = _extractMusicTags(seedText);
    final seedMood = _primaryMoodTag(seedTags);
    final topLanguage = profile['topLanguage'] as String? ?? seedLanguage;
    final transitionArtists =
        _topTransitionArtistLabelsForSeed(seed, profile, limit: 2);
    final transitionTags =
        _topTransitionTagsForSeeds([seed], profile, limit: 2);

    final out = <String>[];
    void add(String q) {
      final trimmed = q.trim();
      if (trimmed.isEmpty) return;
      if (out.any((x) => x.toLowerCase() == trimmed.toLowerCase())) return;
      out.add(trimmed);
    }

    add('$song $artist radio');
    add('$song $artist official audio');
    add('$song $artist topic');
    add('$artist $song');
    add('$artist topic');
    for (final nextArtist in transitionArtists) {
      if (_cleanAuthor(nextArtist).toLowerCase() == artist.toLowerCase()) {
        continue;
      }
      add('$nextArtist official songs');
      add('$song $nextArtist official audio');
    }
    add(_buildRadioQuery(seed));
    add(_moodQuery(seedText));
    if (seedMood != null) {
      add(_genreToQuery(seedMood));
      add('$seedLanguage ${seedMood.replaceAll('-', ' ')} songs official audio');
    }
    for (final tag in seedTags.take(2)) {
      add(_genreToQuery(tag));
    }
    for (final tag in transitionTags) {
      if (seedTags.contains(tag)) continue;
      add(_genreToQuery(tag));
    }
    add(_sceneDiscoveryQuery(seedLanguage, seedTags));
    add(_languageDiscoveryQuery(seedLanguage, seedText));
    add('$seedLanguage new songs official audio');
    if (seedLanguage != topLanguage) {
      add('$seedLanguage trending songs official audio');
    }
    if (seedTags.isEmpty && topGenres.isNotEmpty) {
      add(_genreToQuery(topGenres.first));
    }
    if (seedTags.isEmpty &&
        seedLanguage == topLanguage &&
        topArtists.isNotEmpty &&
        _cleanAuthor(topArtists.first).toLowerCase() != artist.toLowerCase()) {
      add('${topArtists.first} official songs');
      if (topArtists.length >= 2 &&
          _cleanAuthor(topArtists[1]).toLowerCase() != artist.toLowerCase()) {
        add('${topArtists[1]} official songs');
      }
    }
    return out;
  }

  String _ytMusicGl() {
    // If we have a verified session or OAuth, we should try to use a more neutral region
    // or let the server decide based on the IP/auth.
    final hasAuth = (_ytMusicCookie ?? '').trim().isNotEmpty ||
        (_ytAccessToken ?? '').trim().isNotEmpty;
    if (hasAuth && _ytMusicSessionValid) return 'US';
    return 'US'; // Default to US for more global/neutral guest content if auth fails
  }

  String _ytMusicHl() {
    return 'en';
  }

  String _ytMusicWebRemixClientVersionEffective() {
    final resolved = (_ytMusicResolvedWebRemixClientVersion ?? '').trim();
    if (resolved.isNotEmpty) return resolved;
    return _ytMusicWebRemixClientVersion;
  }

  _YtMusicClientProfile _ytMusicAndroidClientProfile() {
    return (
      clientHeaderName: _ytMusicClientHeaderName,
      clientName: _ytMusicClientName,
      clientVersion: _ytMusicAndroidClientVersion,
      userAgent: _ytMusicUserAgent,
      isWebRemix: false,
    );
  }

  _YtMusicClientProfile _ytMusicWebRemixClientProfile() {
    return (
      clientHeaderName: _ytMusicWebRemixClientHeaderName,
      clientName: _ytMusicWebRemixClientName,
      clientVersion: _ytMusicWebRemixClientVersionEffective(),
      userAgent: _ytMusicWebUserAgent,
      isWebRemix: true,
    );
  }

  _YtMusicClientProfile _ytMusicAndroidGenericClientProfile() {
    return (
      clientHeaderName: '3',
      clientName: 'ANDROID',
      clientVersion: '17.31.35',
      userAgent:
          'com.google.android.youtube/17.31.35 (Linux; U; Android 12) gzip',
      isWebRemix: false,
    );
  }

  _YtMusicClientProfile _resolveYtMusicClientProfile({
    bool? hasCookie,
    bool preferWebRemix = true,
    bool fallbackToAndroid = false,
  }) {
    final cookiePresent = hasCookie ?? (_ytMusicCookie ?? '').trim().isNotEmpty;

    // Web Remix (browser client) is best with cookies.
    // If we only have an OAuth Bearer token, ANDROID_MUSIC (client 21) is much more reliable
    // for fetching the personalized browse feed than WEB_REMIX (client 67).
    final useWebRemix = cookiePresent && preferWebRemix && !fallbackToAndroid;

    if (useWebRemix) return _ytMusicWebRemixClientProfile();
    return _ytMusicAndroidClientProfile();
  }

  Map<String, String> _ytMusicBrowserIdentityHeaders() {
    return {
      'sec-fetch-dest': 'empty',
      'sec-fetch-mode': 'same-origin',
      'sec-fetch-site': 'same-origin',
      'x-browser-channel': 'stable',
      'x-browser-year': DateTime.now().year.toString(),
      'x-client-data':
          'CJO2yQEIpbbJAQipncoBCKrvygEIk6HLAQiFoM0BCI2szwEIya/PAQidsc8BCNGxzwEIrrLPAQiDtM8BCNW3zwEYvqnKARixis8BGL2lzwE=',
    };
  }

  bool _supportsYtMusicQuickPicksWebView() =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  Future<void> _seedYtMusicWebViewCookies() async {
    final cookieMap = _cookieMapFromString(_effectiveYtMusicCookie());
    if (cookieMap.isEmpty) return;
    final manager = WebViewCookieManager();
    await manager.clearCookies();
    for (final entry in cookieMap.entries) {
      final name = entry.key.trim();
      final value = entry.value.trim();
      if (name.isEmpty || value.isEmpty) continue;
      await manager.setCookie(
        WebViewCookie(
          name: name,
          value: value,
          domain: _ytMusicApiBase,
          path: '/',
        ),
      );
    }
  }

  void _detachYtMusicQuickPicksWebView(WebViewController controller) {
    if (!identical(_ytMusicQuickPicksWebViewController, controller)) return;
    if (!mounted) {
      _ytMusicQuickPicksWebViewController = null;
      return;
    }
    setState(() {
      if (identical(_ytMusicQuickPicksWebViewController, controller)) {
        _ytMusicQuickPicksWebViewController = null;
      }
    });
  }

  String _ytMusicQuickPicksWebViewScript() => '''
(() => {
  try {
    const root = window.ytInitialData;
    if (!root) {
      QuickPicksExtractor.postMessage('[]');
      return;
    }

    const textValue = (node) => {
      if (!node) return '';
      if (typeof node === 'string') return node.trim();
      if (Array.isArray(node)) {
        return node
            .map((item) => textValue(item))
            .filter((item) => item)
            .join(' ')
            .trim();
      }
      if (typeof node === 'object') {
        if (typeof node.text === 'string') return node.text.trim();
        if (Array.isArray(node.runs)) {
          return node.runs
              .map((item) => textValue(item))
              .filter((item) => item)
              .join(' ')
              .trim();
        }
      }
      return '';
    };

    const pickThumb = (renderer) => {
      const thumbs =
          renderer?.thumbnailRenderer?.musicThumbnailRenderer?.thumbnail?.thumbnails ||
          renderer?.thumbnail?.musicThumbnailRenderer?.thumbnail?.thumbnails ||
          renderer?.thumbnail?.thumbnails ||
          [];
      if (!Array.isArray(thumbs) || !thumbs.length) return '';
      return thumbs[thumbs.length - 1]?.url || '';
    };

    const videoIdFor = (renderer) =>
        renderer?.overlay?.musicItemThumbnailOverlayRenderer?.content?.musicPlayButtonRenderer?.playNavigationEndpoint?.watchEndpoint?.videoId ||
        renderer?.navigationEndpoint?.watchEndpoint?.videoId ||
        renderer?.title?.runs?.[0]?.navigationEndpoint?.watchEndpoint?.videoId ||
        renderer?.flexColumns?.[0]?.musicResponsiveListItemFlexColumnRenderer?.text?.runs?.find((run) => run?.navigationEndpoint?.watchEndpoint?.videoId)?.navigationEndpoint?.watchEndpoint?.videoId ||
        '';

    const titleFor = (renderer) =>
        textValue(renderer?.title) ||
        textValue(renderer?.flexColumns?.[0]?.musicResponsiveListItemFlexColumnRenderer?.text) ||
        '';

    const artistFor = (renderer) =>
        textValue(renderer?.subtitle) ||
        textValue(renderer?.flexColumns?.[1]?.musicResponsiveListItemFlexColumnRenderer?.text) ||
        '';

    const videoFor = (raw) => {
      const renderer =
          raw?.musicTwoRowItemRenderer || raw?.musicResponsiveListItemRenderer;
      if (!renderer) return null;
      const id = videoIdFor(renderer);
      const title = titleFor(renderer);
      if (!id || !title) return null;
      return {
        id,
        title,
        artist: artistFor(renderer),
        thumbnail: pickThumb(renderer),
      };
    };

    const shelves = [];
    const seenShelves = new Set();
    const addShelf = (renderer, kind) => {
      if (!renderer) return;
      const title =
          kind === 'carousel'
              ? textValue(renderer?.header?.musicCarouselShelfBasicHeaderRenderer?.title)
              : textValue(renderer?.title) ||
                  textValue(renderer?.header?.musicResponsiveHeaderRenderer?.title) ||
                  textValue(renderer?.header?.musicCarouselShelfBasicHeaderRenderer?.title);
      const subtitle =
          textValue(renderer?.header?.musicCarouselShelfBasicHeaderRenderer?.strapline) ||
          textValue(renderer?.subtitle) ||
          '';
      const items = Array.isArray(renderer?.contents) ? renderer.contents : [];
      const videos = [];
      const seenVideos = new Set();
      for (const item of items) {
        const video = videoFor(item);
        if (!video || seenVideos.has(video.id)) continue;
        seenVideos.add(video.id);
        videos.push(video);
      }
      const shelfKey = `\${kind}:\${title.toLowerCase()}:\${videos.length}`;
      if (!videos.length || seenShelves.has(shelfKey)) return;
      seenShelves.add(shelfKey);
      shelves.push({title, subtitle, videos});
    };

    const walk = (node, depth = 0) => {
      if (!node || depth > 20) return;
      if (Array.isArray(node)) {
        for (const item of node) walk(item, depth + 1);
        return;
      }
      if (typeof node !== 'object') return;
      if (node.musicCarouselShelfRenderer) {
        addShelf(node.musicCarouselShelfRenderer, 'carousel');
      }
      if (node.musicShelfRenderer) {
        addShelf(node.musicShelfRenderer, 'shelf');
      }
      for (const value of Object.values(node)) {
        walk(value, depth + 1);
      }
    };

    walk(root);
    QuickPicksExtractor.postMessage(JSON.stringify(shelves));
  } catch (error) {
    QuickPicksExtractor.postMessage('[]');
  }
})();
''';

  List<Video> _parseQuickPicksFromWebData(dynamic data) {
    if (data is! List) return const <Video>[];
    final sections = <_YtMusicHomeSection>[];
    for (final rawSection in data) {
      final sectionMap = _jsonMap(rawSection);
      if (sectionMap == null) continue;
      final title = (sectionMap['title'] ?? '').toString().trim();
      final subtitle = (sectionMap['subtitle'] ?? '').toString().trim();
      final videos = <Video>[];
      final seen = <String>{};
      for (final rawVideo in _jsonList(sectionMap['videos'])) {
        final videoMap = _jsonMap(rawVideo);
        if (videoMap == null) continue;
        final id = (videoMap['id'] ?? '').toString().trim();
        final videoTitle = (videoMap['title'] ?? '').toString().trim();
        if (!VideoId.validateVideoId(id) || videoTitle.isEmpty) continue;
        if (!seen.add(id)) continue;
        videos.add(
          _videoFromMap({
            'id': id,
            'title': videoTitle,
            'author': (videoMap['artist'] ?? '').toString().trim(),
          }),
        );
      }
      if (videos.isEmpty) continue;
      sections.add(
        _YtMusicHomeSection(
          title: title,
          subtitle: subtitle,
          videos: videos.take(48).toList(),
        ),
      );
    }
    if (sections.isEmpty) return const <Video>[];
    debugPrint('[YTM WebView] Received ${sections.length} shelves:');
    for (final section in sections.take(6)) {
      debugPrint(
        '  -> "${section.title}" (${section.videos.length} songs) | ${section.subtitle}',
      );
    }
    final quickSection = _pickPrimaryYtMusicQuickSection(sections);
    if (quickSection != null && quickSection.videos.isNotEmpty) {
      debugPrint(
        '[YTM] WebView selected Quick Picks shelf: "${quickSection.title}" (${quickSection.videos.length} songs)',
      );
      return quickSection.videos.take(_quickPicksMaxItems).toList();
    }
    debugPrint('[YTM] WebView shelves found but no playable candidate shelf');
    return sections.first.videos.take(_quickPicksMaxItems).toList();
  }

  bool _hasExplicitYtMusicBackendUrl() {
    return _effectiveYtMusicBackendUrlSetting().trim().isNotEmpty ||
        _ytMusicBackendUrl.trim().isNotEmpty;
  }

  bool _shouldUseYtMusicBackend() {
    if (_hasExplicitYtMusicBackendUrl()) return true;
    return !_ytMusicPhoneOnlyMode;
  }

  String _effectiveYtMusicBackendUrlSetting() {
    final runtime = _ytMusicBackendUrlOverride.trim();
    if (runtime.isNotEmpty) return runtime;
    return _ytMusicBackendUrl.trim();
  }

  String _effectiveYtMusicBackendApiKey() {
    final runtime = _ytMusicBackendApiKeyOverride.trim();
    if (runtime.isNotEmpty) return runtime;
    return _ytMusicBackendApiKey.trim();
  }

  String _ytMusicBackendSettingsSubtitle() {
    if (_ytMusicPhoneOnlyMode) {
      return 'Disabled in phone-only mode';
    }
    final effective = _effectiveYtMusicBackendUrlSetting();
    if (effective.isNotEmpty) {
      final uri = Uri.tryParse(effective);
      final host = (uri?.host ?? '').trim();
      if (host.isNotEmpty) {
        final source = _ytMusicBackendUrlOverride.trim().isNotEmpty
            ? 'Custom'
            : 'Build';
        return '$source backend: $host';
      }
      return effective;
    }
    if (Platform.isAndroid) {
      return 'Local fallback: emulator only (10.0.2.2)';
    }
    if (Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isWindows ||
        Platform.isLinux) {
      return 'Local fallback: 127.0.0.1:8787';
    }
    return 'No backend configured';
  }

  String _ytMusicBackendBaseUrl() {
    if (!_shouldUseYtMusicBackend()) return '';
    final configured = _effectiveYtMusicBackendUrlSetting();
    if (configured.isNotEmpty) return configured;
    if (Platform.isAndroid) return 'http://10.0.2.2:8787';
    if (Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isWindows ||
        Platform.isLinux) {
      return 'http://127.0.0.1:8787';
    }
    return '';
  }

  Uri? _backendAudioProxyUriForVideo(String videoId) {
    final base = _ytMusicBackendBaseUrl().trim();
    if (base.isEmpty || videoId.isEmpty) return null;
    final baseUri = Uri.tryParse(base);
    if (baseUri == null) return null;
    final cleanBasePath = baseUri.path.endsWith('/')
        ? baseUri.path.substring(0, baseUri.path.length - 1)
        : baseUri.path;
    return baseUri.replace(path: '$cleanBasePath/ytmusic/stream/$videoId');
  }

  Uri? _backendAudioResolveUriForVideo(String baseUrl, String videoId) {
    if (videoId.isEmpty) return null;
    final baseUri = Uri.tryParse(baseUrl.trim());
    if (baseUri == null || baseUri.host.isEmpty) return null;
    final cleanBasePath = baseUri.path.endsWith('/')
        ? baseUri.path.substring(0, baseUri.path.length - 1)
        : baseUri.path;
    return baseUri.replace(path: '$cleanBasePath/ytmusic/resolve/$videoId');
  }

  Uri? _ytMusicBackendHealthUri(String baseUrl) {
    final baseUri = Uri.tryParse(baseUrl.trim());
    if (baseUri == null || baseUri.host.isEmpty) return null;
    final cleanBasePath = baseUri.path.endsWith('/')
        ? baseUri.path.substring(0, baseUri.path.length - 1)
        : baseUri.path;
    return baseUri.replace(path: '$cleanBasePath/healthz');
  }

  bool _isProbablyLocalBackend(Uri uri) {
    final host = uri.host.toLowerCase();
    return host == '127.0.0.1' ||
        host == 'localhost' ||
        host == '10.0.2.2' ||
        host == '::1';
  }

  Future<void> _wakeYtMusicBackendIfNeeded(
    String baseUrl, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final baseUri = Uri.tryParse(baseUrl.trim());
    final healthUri = _ytMusicBackendHealthUri(baseUrl);
    if (baseUri == null || healthUri == null || _isProbablyLocalBackend(baseUri)) {
      return;
    }
    try {
      final response = await http
          .get(healthUri, headers: headers)
          .timeout(timeout);
      debugPrint('[YTM BACKEND] wake ping ${response.statusCode} $healthUri');
    } catch (e) {
      debugPrint('[YTM BACKEND] wake ping failed: $e');
    }
  }

  Future<void> _warmYtMusicBackendStream(
    String baseUrl,
    String videoId, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 35),
  }) async {
    final resolveUri = _backendAudioResolveUriForVideo(baseUrl, videoId);
    if (resolveUri == null) return;
    try {
      final response = await http
          .get(resolveUri, headers: headers)
          .timeout(timeout);
      debugPrint(
        '[YTM BACKEND] resolve warm ${response.statusCode} $resolveUri',
      );
    } catch (e) {
      debugPrint('[YTM BACKEND] resolve warm failed: $e');
    }
  }

  Future<http.Response?> _postYtMusicHomeWithWake({
    required String baseUrl,
    required Uri uri,
    required Map<String, String> headers,
    required Map<String, dynamic> body,
  }) async {
    final wakeHeaders = headers['x-api-key']?.trim().isNotEmpty == true
        ? <String, String>{'x-api-key': headers['x-api-key']!.trim()}
        : null;
    const attemptTimeouts = <Duration>[
      Duration(seconds: 8),
      Duration(seconds: 16),
      Duration(seconds: 28),
    ];
    const retryDelays = <Duration>[
      Duration.zero,
      Duration(seconds: 4),
      Duration(seconds: 10),
    ];
    await _wakeYtMusicBackendIfNeeded(
      baseUrl,
      headers: wakeHeaders,
      timeout: const Duration(seconds: 10),
    );
    for (var attempt = 0; attempt < attemptTimeouts.length; attempt++) {
      if (retryDelays[attempt] > Duration.zero) {
        await Future.delayed(retryDelays[attempt]);
        await _wakeYtMusicBackendIfNeeded(
          baseUrl,
          headers: wakeHeaders,
          timeout: const Duration(seconds: 15),
        );
      }
      try {
        final response = await http
            .post(uri, headers: headers, body: jsonEncode(body))
            .timeout(attemptTimeouts[attempt]);
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return response;
        }
        debugPrint(
          '[YTM BACKEND] attempt ${attempt + 1} failed ${response.statusCode}',
        );
        if (response.statusCode < 500 && response.statusCode != 429) {
          return response;
        }
      } catch (e) {
        debugPrint('[YTM BACKEND] attempt ${attempt + 1} error: $e');
      }
    }
    return null;
  }

  Video? _ytMusicVideoFromBackendPayload(dynamic raw) {
    final map = _jsonMap(raw);
    if (map == null) return null;
    final id = (map['id'] ?? map['videoId'] ?? '').toString().trim();
    final title = (map['title'] ?? '').toString().trim();
    final author = (map['author'] ?? map['artist'] ?? '').toString().trim();
    final durationRaw = map['durationSecs'];
    final durationSecs = durationRaw is int
        ? durationRaw
        : (durationRaw is num ? durationRaw.toInt() : null);
    if (id.isEmpty || title.isEmpty) return null;
    return _ytMusicVideoFromMap({
      'id': id,
      'title': title,
      'author': author,
      'durationSecs': durationSecs,
    });
  }

  _YtMusicHomeSection? _ytMusicSectionFromBackendPayload(dynamic raw) {
    final map = _jsonMap(raw);
    if (map == null) return null;
    final title = (map['title'] ?? '').toString().trim();
    if (title.isEmpty) return null;
    final subtitle = (map['subtitle'] ?? '').toString().trim();
    final videos = <Video>[];
    final seenIds = <String>{};
    for (final item in _jsonList(map['videos'])) {
      final video = _ytMusicVideoFromBackendPayload(item);
      if (video == null) continue;
      if (!seenIds.add(video.id.value)) continue;
      videos.add(video);
    }
    final mixes = <_YtMusicMixRef>[];
    final seenMixes = <String>{};
    for (final item in _jsonList(map['mixes'])) {
      final mixMap = _jsonMap(item);
      if (mixMap == null) continue;
      final playlistId =
          (mixMap['playlistId'] ?? mixMap['id'] ?? '').toString().trim();
      final mixTitle =
          (mixMap['title'] ?? mixMap['name'] ?? '').toString().trim();
      if (playlistId.isEmpty || mixTitle.isEmpty) continue;
      if (!seenMixes.add(playlistId)) continue;
      mixes.add(
        _YtMusicMixRef(
          title: mixTitle,
          subtitle: (mixMap['subtitle'] ?? '').toString().trim(),
          playlistId: playlistId,
        ),
      );
    }
    if (videos.isEmpty && mixes.isEmpty) return null;
    return _YtMusicHomeSection(
      title: title,
      subtitle: subtitle,
      videos: videos.take(24).toList(),
      mixes: mixes,
    );
  }

  Future<
      ({
        List<Video> quickPicks,
        String quickPicksLabel,
        bool quickPicksFromOfficialShelf,
        List<_YtMusicHomeSection> shelves,
        List<BeastPlaylist> mixes,
      })?> _fetchYtMusicHomeViaBackend() async {
    final retryAfter = _ytMusicBackendRetryAfter;
    if (retryAfter != null && DateTime.now().isBefore(retryAfter)) {
      return null;
    }
    final baseUrl = _ytMusicBackendBaseUrl().trim();
    if (baseUrl.isEmpty) return null;
    final rawCookie = _effectiveYtMusicCookie();
    if (rawCookie.isEmpty) return null;
    try {
      final uri = Uri.parse('$baseUrl/ytmusic/home');
      final headers = <String, String>{
        HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
        HttpHeaders.acceptHeader: 'application/json',
        HttpHeaders.userAgentHeader: _ytMusicWebUserAgent,
      };
      final apiKey = _effectiveYtMusicBackendApiKey();
      if (apiKey.isNotEmpty) {
        headers['x-api-key'] = apiKey;
      }
      final body = <String, dynamic>{
        'cookie': rawCookie,
        'authUser': _normalizeYtMusicAuthUser(_ytMusicAuthUser),
        'visitorData': _ytMusicVisitorData,
        'hl': _ytMusicHl(),
        'gl': _ytMusicGl(),
        'maxShelves': 18,
        'maxVideosPerShelf': 24,
      };
      final response = await _postYtMusicHomeWithWake(
        baseUrl: baseUrl,
        uri: uri,
        headers: headers,
        body: body,
      );
      if (response == null) {
        _ytMusicBackendRetryAfter =
            DateTime.now().add(const Duration(seconds: 20));
        return null;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint(
          '[YTM BACKEND] POST failed ${response.statusCode}: ${response.body.length > 220 ? response.body.substring(0, 220) : response.body}',
        );
        _ytMusicBackendRetryAfter =
            DateTime.now().add(const Duration(seconds: 20));
        return null;
      }
      final json = _jsonMap(jsonDecode(response.body));
      if (json == null) return null;
      final quickPicks = <Video>[];
      final quickSeen = <String>{};
      for (final item in _jsonList(json['quickPicks'])) {
        final video = _ytMusicVideoFromBackendPayload(item);
        if (video == null) continue;
        if (!quickSeen.add(video.id.value)) continue;
        quickPicks.add(video);
      }
      final shelves = <_YtMusicHomeSection>[];
      final shelfSeen = <String>{};
      for (final item in _jsonList(json['shelves'])) {
        final section = _ytMusicSectionFromBackendPayload(item);
        if (section == null) continue;
        final key = _normalizeSignalKey(section.title);
        if (key.isEmpty || !shelfSeen.add(key)) continue;
        shelves.add(section);
      }
      final quickSection =
          shelves.isNotEmpty ? _pickPrimaryYtMusicQuickSection(shelves) : null;
      if (quickPicks.isEmpty && quickSection != null) {
        quickPicks.addAll(quickSection.videos.take(_quickPicksMaxItems));
      }
      if (quickPicks.length < _quickPicksMaxItems) {
        final seenQuickIds = quickPicks.map((v) => v.id.value).toSet();
        final seenQuickSig = quickPicks.map(_trackSignature).toSet();
        for (final shelf in shelves) {
          for (final video in shelf.videos) {
            if (quickPicks.length >= _quickPicksMaxItems) break;
            if (_isRecommendationBlocked(video)) continue;
            if (!_isMusicCandidate(video, strictSingles: true)) continue;
            if (!seenQuickIds.add(video.id.value)) continue;
            final sig = _trackSignature(video);
            if (!seenQuickSig.add(sig)) continue;
            quickPicks.add(video);
          }
          if (quickPicks.length >= _quickPicksMaxItems) break;
        }
      }
      final quickPicksFromOfficialShelf =
          (json['quickPicksFromOfficialShelf'] == true) ||
              (quickSection != null &&
                  _ytMusicQuickShelfScore(quickSection.title) > 0);
      var quickPicksLabel = (json['quickPicksLabel'] ?? '').toString().trim();
      if (quickPicksLabel.isEmpty) {
        quickPicksLabel = quickSection?.subtitle.trim().isNotEmpty == true
            ? quickSection!.subtitle.trim()
            : 'From your YouTube Music Quick Picks';
      }
      final mixes = <BeastPlaylist>[];
      if (quickPicks.isEmpty && shelves.isEmpty) return null;
      debugPrint(
        '[YTM BACKEND] Loaded quick=${quickPicks.length} shelves=${shelves.length} official=$quickPicksFromOfficialShelf',
      );
      _ytMusicBackendRetryAfter = null;
      return (
        quickPicks: quickPicks.take(_quickPicksMaxItems).toList(),
        quickPicksLabel: quickPicksLabel,
        quickPicksFromOfficialShelf: quickPicksFromOfficialShelf,
        shelves: shelves,
        mixes: mixes,
      );
    } catch (e) {
      debugPrint('[YTM BACKEND] fetch error: $e');
      _ytMusicBackendRetryAfter =
          DateTime.now().add(const Duration(seconds: 20));
      return null;
    }
  }

  Future<List<Video>> _fetchQuickPicksViaWebView() async {
    if (!_supportsYtMusicQuickPicksWebView()) {
      debugPrint(
        '[YTM] WebView Quick Picks unavailable on this platform - using Innertube fallback',
      );
      return const <Video>[];
    }
    final rawCookie = _effectiveYtMusicCookie();
    if (rawCookie.trim().isEmpty) return const <Video>[];

    final requestId = ++_ytMusicQuickPicksWebViewRequestId;
    final completer = Completer<List<Video>>();
    late final WebViewController controller;
    var finished = false;

    void finish(List<Video> videos, {String? logLine}) {
      if (finished) return;
      finished = true;
      if (logLine != null && logLine.trim().isNotEmpty) {
        debugPrint(logLine);
      }
      _detachYtMusicQuickPicksWebView(controller);
      if (!completer.isCompleted) completer.complete(videos);
    }

    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'QuickPicksExtractor',
        onMessageReceived: (msg) {
          if (requestId != _ytMusicQuickPicksWebViewRequestId) return;
          try {
            final data = jsonDecode(msg.message);
            final videos = _parseQuickPicksFromWebData(data);
            finish(
              videos,
              logLine:
                  '[YTM] WebView Quick Picks extraction returned ${videos.length} songs',
            );
          } catch (e) {
            finish(
              const <Video>[],
              logLine: '[YTM] WebView Quick Picks parse failed: $e',
            );
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) async {
            if (requestId != _ytMusicQuickPicksWebViewRequestId || finished) {
              return;
            }
            if (!url.contains(_ytMusicApiBase)) return;
            await Future<void>.delayed(const Duration(seconds: 2));
            if (requestId != _ytMusicQuickPicksWebViewRequestId || finished) {
              return;
            }
            try {
              await controller.runJavaScript(_ytMusicQuickPicksWebViewScript());
            } catch (e) {
              finish(
                const <Video>[],
                logLine: '[YTM] WebView Quick Picks script failed: $e',
              );
            }
          },
          onWebResourceError: (error) {
            if (requestId != _ytMusicQuickPicksWebViewRequestId || finished) {
              return;
            }
            if (error.isForMainFrame != true) return;
            finish(
              const <Video>[],
              logLine:
                  '[YTM] WebView Quick Picks load failed: ${error.errorCode} ${error.description}',
            );
          },
        ),
      );

    if (mounted) {
      setState(() {
        _ytMusicQuickPicksWebViewController = controller;
      });
      await WidgetsBinding.instance.endOfFrame;
    } else {
      _ytMusicQuickPicksWebViewController = controller;
    }

    try {
      await _seedYtMusicWebViewCookies();
      final url = Uri.https(_ytMusicApiBase, '/', {
        'authuser': _normalizeYtMusicAuthUser(_ytMusicAuthUser),
        'hl': _ytMusicHl(),
        'gl': _ytMusicGl(),
      });
      await controller.loadRequest(url);
    } catch (e) {
      finish(const <Video>[],
          logLine: '[YTM] WebView Quick Picks setup failed: $e');
    }

    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        finish(
          const <Video>[],
          logLine: '[YTM] WebView Quick Picks timed out after 15s',
        );
        return const <Video>[];
      },
    );
  }

  String _normalizeYtMusicAuthUser(String rawValue) {
    final digits = rawValue.replaceAll(RegExp(r'[^0-9]'), '').trim();
    return digits.isEmpty ? '0' : digits;
  }

  String _normalizeYtMusicVisitorData(String rawValue) {
    return rawValue.trim().replaceAll(RegExp(r'''^['"]+|['"]+$'''), '').trim();
  }

  // ignore: unused_element
  bool _hasCustomYtMusicVisitorData() {
    final visitor = _normalizeYtMusicVisitorData(_ytMusicVisitorData);
    return visitor.isNotEmpty && visitor != _ytMusicDefaultVisitorData;
  }

  bool _looksLikeCookieName(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return false;
    return RegExp(r'^[A-Za-z0-9_.\-]+$').hasMatch(trimmed);
  }

  static const List<String> _ytMusicCookieFieldOrder = [
    'SAPISID',
    '__Secure-3PAPISID',
    '__Secure-1PAPISID',
    'APISID',
    'SID',
    'HSID',
    'SSID',
    '__Secure-3PSID',
    '__Secure-1PSID',
    'LOGIN_INFO',
    'SIDCC',
    'PREF',
  ];

  void _appendCookiePair(
    Map<String, String> out,
    String name,
    String value,
  ) {
    final cookieName = name.trim();
    var cookieValue = value.trim();
    if (!_looksLikeCookieName(cookieName) || cookieValue.isEmpty) return;
    cookieValue = cookieValue
        .replaceAll(RegExp(r'''^['"]+|['"]+$'''), '')
        .replaceAll(RegExp(r';+$'), '')
        .trim();
    if (cookieValue.isEmpty) return;
    out[cookieName] = cookieValue;
  }

  Map<String, String> _cookieMapFromString(String rawCookie) {
    final out = <String, String>{};
    for (final part in rawCookie.split(';')) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;
      final idx = trimmed.indexOf('=');
      if (idx <= 0) continue;
      final key = trimmed.substring(0, idx).trim();
      final value = trimmed.substring(idx + 1).trim();
      if (key.isEmpty || value.isEmpty) continue;
      out[key] = value;
    }
    return out;
  }

  String _serializeCookieMap(Map<String, String> cookies) {
    if (cookies.isEmpty) return '';
    final orderedKeys = <String>[];
    for (final key in _ytMusicCookieFieldOrder) {
      final value = (cookies[key] ?? '').trim();
      if (value.isNotEmpty) orderedKeys.add(key);
    }
    final remainingKeys = cookies.keys
        .where((key) =>
            !_ytMusicCookieFieldOrder.contains(key) &&
            (cookies[key] ?? '').trim().isNotEmpty)
        .toList()
      ..sort();
    orderedKeys.addAll(remainingKeys);
    return orderedKeys.map((key) => '$key=${cookies[key]!.trim()}').join('; ');
  }

  String? _extractCookieHeaderValue(String rawInput) {
    for (final line in rawInput.split(RegExp(r'[\r\n]+'))) {
      final lower = line.toLowerCase();
      final idx = lower.indexOf('cookie:');
      if (idx < 0) continue;
      var value = line.substring(idx + 7).trim();
      value = value.replaceFirst(
        RegExp(r'''^-h\s+['"]?''', caseSensitive: false),
        '',
      );
      value = value.replaceAll(RegExp(r'''^['"]+|['"]+$'''), '').trim();
      value = value.replaceFirst(RegExp(r'\\$'), '').trim();
      if (value.isNotEmpty) return value;
    }

    final curlMatch = RegExp(
      r'''-H\s+['"]cookie:\s*(.+?)['"]''',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(rawInput);
    if (curlMatch != null) {
      final value = (curlMatch.group(1) ?? '').trim();
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  String? _extractYtMusicAuthUser(String rawInput) {
    for (final line in rawInput.split(RegExp(r'[\r\n]+'))) {
      final match = RegExp(
        r'^\s*x-goog-authuser\s*:\s*([0-9]+)\s*$',
        caseSensitive: false,
      ).firstMatch(line);
      if (match != null) {
        return _normalizeYtMusicAuthUser(match.group(1) ?? '0');
      }
    }

    final curlMatch = RegExp(
      r'''-H\s+['"]x-goog-authuser:\s*([0-9]+)['"]''',
      caseSensitive: false,
    ).firstMatch(rawInput);
    if (curlMatch != null) {
      return _normalizeYtMusicAuthUser(curlMatch.group(1) ?? '0');
    }
    return null;
  }

  Future<String?> _fetchFreshYtMusicVisitorData() async {
    try {
      final profile = _ytMusicWebRemixClientProfile();
      final rawCookie = _effectiveYtMusicCookie();
      final headers = <String, String>{
        HttpHeaders.userAgentHeader: profile.userAgent,
        HttpHeaders.acceptHeader: 'text/html,application/xhtml+xml',
        HttpHeaders.acceptLanguageHeader: _ytMusicHl(),
        'Origin': 'https://music.youtube.com',
        'Referer': 'https://music.youtube.com/',
        'X-Goog-AuthUser': _normalizeYtMusicAuthUser(_ytMusicAuthUser),
        'X-YouTube-Client-Name': profile.clientHeaderName,
        'X-YouTube-Client-Version': profile.clientVersion,
        ..._ytMusicBrowserIdentityHeaders(),
      };

      if (rawCookie.isNotEmpty) {
        headers[HttpHeaders.cookieHeader] = rawCookie;
        headers['X-YouTube-Bootstrap-Logged-In'] = 'true';
        debugPrint('[YTM] Using real cookie for personalized feed');
        final authHeader = _ytMusicAuthorizationHeader();
        if (authHeader != null && authHeader.isNotEmpty) {
          headers[HttpHeaders.authorizationHeader] = authHeader;
        }
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
          _ytMusicResolvedWebRemixClientVersion = value;
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

  Future<void> _ensureFreshYtMusicVisitorData() async {
    final oauthToken = (_ytAccessToken ?? '').trim();
    final hasCookie = (_ytMusicCookie ?? '').trim().isNotEmpty;

    // If we're using OAuth and don't have a verified visitorData,
    // it's better to let InnerTube assign one via the responseContext
    // instead of forcing a guest one from a static HTML fetch.
    if (oauthToken.isNotEmpty &&
        !hasCookie &&
        (_ytMusicVisitorData == _ytMusicDefaultVisitorData ||
            _ytMusicVisitorData.isEmpty)) {
      debugPrint(
          '[YTM] Letting InnerTube assign visitorData for OAuth session');
      _ytMusicVisitorData = ''; // Clear to let server assign
      return;
    }

    final freshVisitorData = await _fetchFreshYtMusicVisitorData();
    if (freshVisitorData == null || freshVisitorData.trim().isEmpty) return;
    _ytMusicVisitorData = freshVisitorData.trim();
  }

  void _collectCookiesFromJson(dynamic raw, Map<String, String> out) {
    if (raw is List) {
      for (final item in raw) {
        _collectCookiesFromJson(item, out);
      }
      return;
    }
    if (raw is! Map) return;

    final map = raw.map((key, value) => MapEntry(key.toString(), value));
    final name = map['name'] ?? map['Name'];
    final value = map['value'] ?? map['Value'];
    if (name != null && value != null) {
      _appendCookiePair(out, name.toString(), value.toString());
      return;
    }

    if (map['cookies'] != null) {
      _collectCookiesFromJson(map['cookies'], out);
      return;
    }

    const reservedKeys = {
      'domain',
      'path',
      'secure',
      'httpOnly',
      'sameSite',
      'expirationDate',
      'hostOnly',
      'session',
      'storeId',
    };
    final canTreatAsCookieMap = map.isNotEmpty &&
        map.keys.every((key) => !reservedKeys.contains(key)) &&
        map.values.every((value) => value is String);
    if (!canTreatAsCookieMap) return;

    for (final entry in map.entries) {
      _appendCookiePair(out, entry.key, entry.value.toString());
    }
  }

  void _collectCookiesFromLines(String rawInput, Map<String, String> out) {
    for (var line in rawInput.split(RegExp(r'[\r\n]+'))) {
      line = line.trim();
      if (line.isEmpty) continue;
      line = line.replaceAll(RegExp(r'''^['"]+|['"]+$'''), '').trim();
      if (line.isEmpty) continue;

      if (line.contains(';') && line.contains('=')) {
        final parsed = _cookieMapFromString(line);
        if (parsed.isNotEmpty) {
          out.addAll(parsed);
          continue;
        }
      }

      if (RegExp(r'^(name|value|domain|path)\b', caseSensitive: false)
          .hasMatch(line)) {
        continue;
      }

      if (line.contains('\t')) {
        final parts = line.split('\t').map((part) => part.trim()).toList();
        if (parts.length >= 2) {
          _appendCookiePair(out, parts[0], parts[1]);
          continue;
        }
      }

      final equalsIdx = line.indexOf('=');
      if (equalsIdx > 0) {
        _appendCookiePair(
          out,
          line.substring(0, equalsIdx),
          line.substring(equalsIdx + 1),
        );
        continue;
      }

      final wsMatch =
          RegExp(r'^([A-Za-z0-9_.\-]+)\s+([^\s]+)$').firstMatch(line);
      if (wsMatch != null) {
        _appendCookiePair(
          out,
          wsMatch.group(1) ?? '',
          wsMatch.group(2) ?? '',
        );
      }
    }
  }

  String _normalizeYtMusicCookieInput(String rawInput) {
    final raw = rawInput.trim();
    if (raw.isEmpty) return '';

    final cookies = <String, String>{};

    final extractedHeader = _extractCookieHeaderValue(raw);
    if (extractedHeader != null && extractedHeader.isNotEmpty) {
      cookies.addAll(_cookieMapFromString(extractedHeader));
    }

    if (cookies.isEmpty && (raw.startsWith('{') || raw.startsWith('['))) {
      try {
        _collectCookiesFromJson(jsonDecode(raw), cookies);
      } catch (_) {}
    }

    if (cookies.isEmpty) {
      cookies.addAll(_cookieMapFromString(raw));
    }

    if (cookies.isEmpty) {
      _collectCookiesFromLines(raw, cookies);
    }

    final looksLikeBareToken = !raw.contains('=') &&
        !raw.contains(';') &&
        !raw.contains('\n') &&
        !raw.contains('\r') &&
        !raw.contains('\t') &&
        raw.length >= 12;
    if (cookies.isEmpty && looksLikeBareToken) {
      cookies['SAPISID'] = raw;
    }

    return _serializeCookieMap(cookies);
  }

  String _effectiveYtMusicCookie() {
    final raw = (_ytMusicCookie ?? '').trim();
    final normalized = _normalizeYtMusicCookieInput(raw);
    final rawKeys = _cookieMapFromString(raw).keys.toList()..sort();
    final normalizedKeys = _cookieMapFromString(normalized).keys.toList()
      ..sort();
    debugPrint(
      '[YTM COOKIE DEBUG] _effectiveYtMusicCookie rawLen=${raw.length} normalizedLen=${normalized.length} rawKeys=$rawKeys normalizedKeys=$normalizedKeys',
    );
    return normalized;
  }

  String? _ytMusicCookieValue(String name) {
    final rawCookie = _effectiveYtMusicCookie();
    if (rawCookie.trim().isEmpty) return null;
    final prefix = '$name=';
    for (final part in rawCookie.split(';')) {
      final trimmed = part.trim();
      if (!trimmed.startsWith(prefix)) continue;
      final value = trimmed.substring(prefix.length).trim();
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  String? _ytMusicAuthorizationHeader() {
    final rawCookie = _effectiveYtMusicCookie();
    final hasCookie = rawCookie.trim().isNotEmpty;

    // If we have an OAuth access token, we can use it as a Bearer token.
    // This is preferred if the cookie session is invalid or not provided.
    final oauthToken = (_ytAccessToken ?? '').trim();
    if (oauthToken.isNotEmpty && (!hasCookie || !_ytMusicSessionValid)) {
      debugPrint('[YTM] Using Bearer token for authorization (OAuth session)');
      return 'Bearer $oauthToken';
    }

    if (!hasCookie) return null;

    final sapisid = _ytMusicCookieValue('SAPISID');
    final sapisid1p = _ytMusicCookieValue('__Secure-1PAPISID');
    final sapisid3p = _ytMusicCookieValue('__Secure-3PAPISID');
    final hasSapisid = sapisid != null && sapisid.isNotEmpty;
    final hasSapisid1p = sapisid1p != null && sapisid1p.isNotEmpty;
    final hasSapisid3p = sapisid3p != null && sapisid3p.isNotEmpty;
    if (!hasSapisid && !hasSapisid1p && !hasSapisid3p) {
      debugPrint(
        '[YTM] No SAPISID/APISID variants in cookie - auth header cannot be generated',
      );
      return null;
    }

    final timestamp =
        (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    const origin = 'https://music.youtube.com';

    String makeHash(String sid) {
      final payload = '$timestamp $sid $origin';
      return '${timestamp}_${sha1.convert(utf8.encode(payload))}';
    }

    final parts = <String>[
      if (hasSapisid) 'SAPISIDHASH ${makeHash(sapisid)}',
      if (hasSapisid1p) 'SAPISID1PHASH ${makeHash(sapisid1p)}',
      if (hasSapisid3p) 'SAPISID3PHASH ${makeHash(sapisid3p)}',
    ];
    if (parts.isEmpty) return null;

    final previewSource = sapisid ?? sapisid1p ?? sapisid3p ?? '';
    if (previewSource.isEmpty) return null;
    final previewLength = min(8, previewSource.length);
    debugPrint(
      '[YTM] SAPISID auth generated (ts=$timestamp sid=${previewSource.substring(0, previewLength)}... sapisid=$hasSapisid 1p=$hasSapisid1p 3p=$hasSapisid3p)',
    );
    return parts.join(' ');
  }

  String _ytMusicSessionSubtitle() {
    final hasCookie = (_ytMusicCookie ?? '').trim().isNotEmpty;
    final hasOAuth = (_ytAccessToken ?? '').trim().isNotEmpty;

    if (!hasCookie && !hasOAuth) {
      return 'Paste a music.youtube.com cookie or sign in with Google for real personalized home/mixes';
    }

    if (hasOAuth && !hasCookie) {
      final name = (_ytAccountName ?? '').trim();
      if (name.isNotEmpty) return 'Logged in as $name';
      return 'Logged in via Google account';
    }

    final cookies = _cookieMapFromString(_effectiveYtMusicCookie());
    final hasSecure3pApisid =
        (cookies['__Secure-3PAPISID'] ?? '').trim().isNotEmpty;
    if (_ytMusicSessionChecking) return 'Verifying logged-in YT Music session';
    if (_ytMusicSessionValid) {
      final name = (_ytMusicSessionName ?? '').trim();
      if (name.isNotEmpty) return 'Logged in as $name';
      return 'Logged-in YT Music session verified';
    }
    if ((_ytMusicSessionError ?? '').trim().isNotEmpty) {
      return 'Cookie saved, but session could not be verified';
    }
    if (!hasSecure3pApisid) {
      return 'Cookie saved - add __Secure-3PAPISID and AuthUser for best verification';
    }
    return 'Cookie saved - session check pending';
  }

  bool _isTruthyJsonFlag(dynamic value) {
    if (value == true) return true;
    final text = (value ?? '').toString().trim().toLowerCase();
    return text == 'true' || text == '1';
  }

  String _normalizeYtIdentity(String? raw) {
    return (raw ?? '').trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }

  bool _isGenericYtMusicIdentity({
    required String name,
    String? email,
    String? handle,
  }) {
    final normalizedName = _normalizeYtIdentity(name);
    if (_normalizeYtIdentity(email).isNotEmpty) return false;
    if (_normalizeYtIdentity(handle).isNotEmpty) return false;
    return normalizedName.isEmpty ||
        normalizedName == 'youtube music' ||
        normalizedName == 'youtube' ||
        normalizedName == 'authenticated' ||
        normalizedName == 'signed in' ||
        normalizedName == 'signed-in' ||
        normalizedName == 'account';
  }

  int _scoreYtMusicAccountCandidate(
    ({String name, String? email, String? handle}) account, {
    required String targetEmail,
    required String targetName,
    required String candidateAuthUser,
    required String initialAuthUser,
  }) {
    final accountEmail = _normalizeYtIdentity(account.email);
    final accountName = _normalizeYtIdentity(account.name);
    final accountHandle = _normalizeYtIdentity(account.handle);
    final hasStrongIdentity = !_isGenericYtMusicIdentity(
      name: account.name,
      email: account.email,
      handle: account.handle,
    );

    var score = 0;
    if (accountEmail.isNotEmpty) score += 2;
    if (accountHandle.isNotEmpty) score += 1;
    if (hasStrongIdentity) {
      score += 1;
    }
    if (targetEmail.isNotEmpty && accountEmail == targetEmail) score += 12;
    if (targetEmail.isNotEmpty &&
        accountEmail.isNotEmpty &&
        accountEmail != targetEmail) {
      score -= 12;
    }
    if (targetName.isNotEmpty) {
      if (accountName == targetName) {
        score += 6;
      } else if (accountName.contains(targetName) ||
          targetName.contains(accountName)) {
        score += 3;
      } else if (accountName.isNotEmpty && hasStrongIdentity) {
        score -= 4;
      }
    }
    if (candidateAuthUser == initialAuthUser) score += 1;
    if (!hasStrongIdentity && accountEmail.isEmpty && accountHandle.isEmpty) {
      score -= 8;
    }
    return score;
  }

  String _normalizeYtQuickShelfTitle(String rawTitle) {
    return rawTitle.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  }

  int _ytMusicQuickShelfScore(String rawTitle) {
    final normalized = _normalizeYtQuickShelfTitle(rawTitle);
    if (normalized.contains('quick picks') ||
        normalized.contains('quickpicks') ||
        normalized.contains('picked for you') ||
        normalized.contains('listen again') ||
        normalized.contains('your favorites') ||
        normalized.contains('your mix')) {
      return 10;
    }
    if (normalized.contains('recent') ||
        normalized.contains('your top') ||
        normalized.contains('made for you')) {
      return 8;
    }
    if (normalized.contains('recommended') ||
        normalized.contains('start here') ||
        normalized.contains('suggested')) {
      return 6;
    }
    if (normalized.contains('mixed for you') || normalized.contains('my mix')) {
      return 4;
    }
    return 0;
  }

  // ignore: unused_element
  bool _isLikelyYtMusicQuickPicksTitle(String rawTitle) {
    return _ytMusicQuickShelfScore(rawTitle) > 0;
  }

  _YtMusicHomeSection? _pickOfficialYtMusicQuickSection(
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
    return bestMatch;
  }

  _YtMusicHomeSection? _pickPrimaryYtMusicQuickSection(
    List<_YtMusicHomeSection> sections,
  ) {
    final bestMatch = _pickOfficialYtMusicQuickSection(sections);
    if (bestMatch != null) return bestMatch;
    for (final section in sections) {
      if (section.videos.length >= 8) return section;
    }
    for (final section in sections) {
      if (section.videos.isNotEmpty) return section;
    }
    return null;
  }

  String? _extractYtMusicVisitorData(String rawInput) {
    for (final line in rawInput.split(RegExp(r'[\r\n]+'))) {
      final match = RegExp(
        r'^\s*x-goog-visitor-id\s*:\s*(.+?)\s*$',
        caseSensitive: false,
      ).firstMatch(line);
      if (match != null) {
        final value = _normalizeYtMusicVisitorData(match.group(1) ?? '');
        if (value.isNotEmpty) return value;
      }
    }

    final curlMatch = RegExp(
      r'''-H\s+['"]x-goog-visitor-id:\s*([^'"]+)['"]''',
      caseSensitive: false,
    ).firstMatch(rawInput);
    if (curlMatch != null) {
      final value = _normalizeYtMusicVisitorData(curlMatch.group(1) ?? '');
      if (value.isNotEmpty) return value;
    }

    final jsonMatch =
        RegExp(r'''"visitorData"\s*:\s*"([^"]+)"''').firstMatch(rawInput);
    if (jsonMatch != null) {
      final value = _normalizeYtMusicVisitorData(jsonMatch.group(1) ?? '');
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  double _scoreYtMusicFeedCandidate(List<Video> quickPicks) {
    double score;
    if (quickPicks.isEmpty) {
      score = -8.0;
    } else if (quickPicks.length >= 12) {
      score = 4.0;
    } else if (quickPicks.length >= 8) {
      score = 2.0;
    } else if (quickPicks.length >= 4) {
      score = 0.0;
    } else {
      score = -4.0;
    }
    debugPrint(
      '[YTM Feed Score] ${quickPicks.length} videos -> score=${score.toStringAsFixed(2)} | top3: ${quickPicks.take(3).map((v) => _cleanTitle(v.title)).join(', ')}',
    );
    return score;
  }

  List<Map<String, dynamic>> _findYtMusicAccountLikeNodes(
    dynamic raw, {
    int maxDepth = 14,
  }) {
    final out = <Map<String, dynamic>>[];

    void walk(dynamic node, int depth) {
      if (depth < 0 || node == null) return;
      final map = _jsonMap(node);
      if (map != null) {
        final hasIdentitySignals = map.containsKey('accountName') ||
            map.containsKey('accountByline') ||
            map.containsKey('email') ||
            map.containsKey('channelHandle') ||
            map.containsKey('accountPhoto');
        if (hasIdentitySignals) out.add(map);
        for (final value in map.values) {
          walk(value, depth - 1);
        }
        return;
      }
      if (node is List) {
        for (final item in node) {
          walk(item, depth - 1);
        }
      }
    }

    walk(raw, maxDepth);
    return out;
  }

  Future<({String name, String? email, String? handle})?>
      _fetchYtMusicAccountInfo({
    bool allowAmbiguousAuthenticated = true,
  }) async {
    final preferredProfile = _resolveYtMusicClientProfile(
      preferWebRemix: true,
    );
    var response = await _ytMusicPostJson(
      'account/account_menu',
      body: _ytMusicContextBody(profile: preferredProfile),
      profile: preferredProfile,
    );
    if (response == null && preferredProfile.isWebRemix) {
      final fallbackProfile = _resolveYtMusicClientProfile(
        hasCookie: true,
        preferWebRemix: true,
        fallbackToAndroid: true,
      );
      response = await _ytMusicPostJson(
        'account/account_menu',
        body: _ytMusicContextBody(profile: fallbackProfile),
        profile: fallbackProfile,
      );
    }
    if (response == null) return null;
    final topLevelHeader = _jsonAt(response, const [
      'header',
      'activeAccountHeaderRenderer',
    ]);
    final directHeader = _jsonAt(response, const [
      'actions',
      0,
      'openPopupAction',
      'popup',
      'multiPageMenuRenderer',
      'header',
      'activeAccountHeaderRenderer',
    ]);
    final sections = _jsonList(_jsonAt(response, const [
      'actions',
      0,
      'openPopupAction',
      'popup',
      'multiPageMenuRenderer',
      'sections',
    ]));
    var hasCompactAccountLink = false;
    for (final section in sections) {
      final items = _jsonList(
        _jsonAt(
          _jsonMap(section),
          const ['multiPageMenuSectionRenderer', 'items'],
        ),
      );
      for (final item in items) {
        final compactLink =
            _jsonMap(_jsonAt(_jsonMap(item), const ['compactLinkRenderer']));
        if (compactLink != null) {
          hasCompactAccountLink = true;
          break;
        }
      }
      if (hasCompactAccountLink) break;
    }
    final header = _jsonMap(topLevelHeader) ??
        _jsonMap(directHeader) ??
        _jsonMap(
            _findFirstJsonValueByKey(response, 'activeAccountHeaderRenderer'));
    final accountCandidates = _findYtMusicAccountLikeNodes(
      response,
      maxDepth: 18,
    );
    Map<String, dynamic>? selectedAccountCandidate;
    for (final candidate in accountCandidates) {
      if (_isTruthyJsonFlag(candidate['isSelected']) ||
          _isTruthyJsonFlag(candidate['selected']) ||
          _isTruthyJsonFlag(candidate['isActive'])) {
        selectedAccountCandidate = candidate;
        break;
      }
    }
    selectedAccountCandidate ??=
        accountCandidates.isNotEmpty ? accountCandidates.first : null;
    final identitySource = header ?? selectedAccountCandidate;
    final loggedOutValue = _jsonAt(
      response,
      const ['responseContext', 'mainAppWebResponseContext', 'loggedOut'],
    );
    final loggedOut = loggedOutValue == true ||
        loggedOutValue?.toString().toLowerCase() == 'true';
    final hasSignInEndpoint =
        _findFirstJsonValueByKey(response, 'signInEndpoint') != null;
    final hasSignOutEndpoint =
        _findFirstJsonValueByKey(response, 'signOutEndpoint') != null;
    final responseText = response.toString();
    final hasAccountContent = hasCompactAccountLink ||
        responseText.contains('accountName') ||
        responseText.contains('accountEmail') ||
        responseText.contains('signedIn');
    final appearsAuthenticated = !loggedOut ||
        (hasSignOutEndpoint && !hasSignInEndpoint) ||
        hasAccountContent;

    final name = identitySource != null
        ? _ytMusicTextValue(identitySource['accountName']) ??
            _ytMusicTextValue(identitySource['name']) ??
            _ytMusicTextValue(identitySource['title']) ??
            _ytMusicTextValue(identitySource['accountByline'])
        : _ytMusicTextValue(
                _findFirstJsonValueByKey(response, 'accountName')) ??
            _ytMusicTextValue(_findFirstJsonValueByKey(response, 'title'));
    final email = identitySource != null
        ? _ytMusicTextValue(identitySource['email']) ??
            _ytMusicTextValue(identitySource['accountByline'])
        : _ytMusicTextValue(_findFirstJsonValueByKey(response, 'email'));
    final handle = identitySource != null
        ? _ytMusicTextValue(identitySource['channelHandle']) ??
            _ytMusicTextValue(identitySource['handle'])
        : _ytMusicTextValue(
            _findFirstJsonValueByKey(response, 'channelHandle'));
    final photoUrl = identitySource != null
        ? _stringAt(
            identitySource,
            const ['accountPhoto', 'thumbnails', 0, 'url'],
          )
        : (_jsonAt(
                  _findFirstJsonValueByKey(response, 'accountPhoto'),
                  const ['thumbnails', 0, 'url'],
                ) ??
                '')
            .toString()
            .trim();

    if (!appearsAuthenticated) {
      debugPrint(
        '[YTM] account_menu indicates signed-out session (loggedOut=$loggedOut, signIn=$hasSignInEndpoint, signOut=$hasSignOutEndpoint)',
      );
      return null;
    }

    if (header == null) {
      debugPrint(
        '[YTM] account_menu missing activeAccountHeaderRenderer, but response looks authenticated',
      );
      if (!allowAmbiguousAuthenticated) {
        return null;
      }
      if (hasCompactAccountLink) {
        debugPrint(
          '[YTM] Found account via compactLinkRenderer - session authenticated',
        );
        return (name: 'authenticated', email: null, handle: null);
      }
      if (hasAccountContent) {
        debugPrint(
          '[YTM] account_menu: treating as authenticated based on response content',
        );
        return (name: 'authenticated', email: null, handle: null);
      }
    }

    final resolvedName = (name ?? '').trim().isNotEmpty
        ? name!.trim()
        : (handle ?? '').trim().isNotEmpty
            ? handle!.trim()
            : (email ?? '').trim().isNotEmpty
                ? email!.trim()
                : (photoUrl ?? '').isNotEmpty
                    ? 'YouTube Music'
                    : 'YouTube Music';
    final hasStrongIdentity = !_isGenericYtMusicIdentity(
          name: resolvedName,
          email: email,
          handle: handle,
        ) ||
        (email ?? '').trim().isNotEmpty ||
        (handle ?? '').trim().isNotEmpty;
    if (!allowAmbiguousAuthenticated && !hasStrongIdentity) {
      debugPrint(
        '[YTM] account_menu identity is ambiguous (strict mode) - rejecting candidate',
      );
      return null;
    }
    if (!hasStrongIdentity && !hasSignOutEndpoint) {
      debugPrint(
        '[YTM] account_menu authenticated but identity is ambiguous; waiting for a better authUser match',
      );
      return null;
    }
    debugPrint(
      '[YTM] Account detected: name="$resolvedName" email="${email ?? ''}" handle="${handle ?? ''}"',
    );
    return (
      name: resolvedName,
      email: email?.trim().isEmpty == true ? null : email?.trim(),
      handle: handle?.trim().isEmpty == true ? null : handle?.trim(),
    );
  }

  Future<String> _resolveBestYtMusicAuthUser({
    int maxCandidates = 9,
  }) async {
    final initialAuthUser = _normalizeYtMusicAuthUser(_ytMusicAuthUser);
    final pinnedVisitorData = _hasCustomYtMusicVisitorData();
    final targetEmail = _normalizeYtIdentity(_ytAccountEmail);
    final targetName = _normalizeYtIdentity(_ytAccountName);
    final initialVisitorData =
        _normalizeYtMusicVisitorData(_ytMusicVisitorData);
    final hasInitialVisitorData = initialVisitorData.isNotEmpty;
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
      if (hasInitialVisitorData) {
        _ytMusicVisitorData = initialVisitorData;
      }
      await _ensureFreshYtMusicVisitorData();
      final account = await _fetchYtMusicAccountInfo(
        allowAmbiguousAuthenticated: false,
      );
      final accountLabel = account?.email?.trim().isNotEmpty == true
          ? account!.email!
          : account?.name ?? 'null';
      debugPrint(
        '[YTM] authUser=$candidateAuthUser account=$accountLabel activeHeader=${account != null}',
      );
      final identityScore = account == null
          ? -16
          : _scoreYtMusicAccountCandidate(
              account,
              targetEmail: targetEmail,
              targetName: targetName,
              candidateAuthUser: candidateAuthUser,
              initialAuthUser: initialAuthUser,
            );
      final normalizedAccountEmail = _normalizeYtIdentity(account?.email);
      final normalizedAccountName = _normalizeYtIdentity(account?.name);
      final hasStrongAccountIdentity = account != null &&
          !_isGenericYtMusicIdentity(
            name: account.name,
            email: account.email,
            handle: account.handle,
          );
      final hasTargetIdentityHit = (targetEmail.isNotEmpty &&
              normalizedAccountEmail.isNotEmpty &&
              normalizedAccountEmail == targetEmail) ||
          (targetName.isNotEmpty &&
              normalizedAccountName.isNotEmpty &&
              (normalizedAccountName == targetName ||
                  normalizedAccountName.contains(targetName) ||
                  targetName.contains(normalizedAccountName)));

      var feedScore = -8.0;
      List<Video> candidateQuickPicks = const <Video>[];
      try {
        final probeProfile = _ytMusicWebRemixClientProfile();
        final sections = await _fetchYtMusicHomeSections(
          maxSections: 6,
          maxContinuations: 0,
          profile: probeProfile,
        );
        final quickSection = _pickPrimaryYtMusicQuickSection(sections);
        if (quickSection != null) {
          candidateQuickPicks = quickSection.videos.take(15).toList();
        }
        feedScore = _scoreYtMusicFeedCandidate(candidateQuickPicks);
      } catch (e) {
        debugPrint('[YTM] authUser $candidateAuthUser feed probe failed: $e');
      }
      final candidateVisitorData =
          _normalizeYtMusicVisitorData(_ytMusicVisitorData);
      final totalScore = identityScore.toDouble() + (feedScore * 2.0);
      var adjustedScore = totalScore;
      if (pinnedVisitorData &&
          candidateAuthUser == initialAuthUser &&
          (hasStrongAccountIdentity || hasTargetIdentityHit)) {
        adjustedScore += 10.0;
      }
      if (pinnedVisitorData &&
          candidateAuthUser != initialAuthUser &&
          !hasStrongAccountIdentity &&
          !hasTargetIdentityHit) {
        adjustedScore -= 10.0;
      }

      final preview = candidateQuickPicks
          .take(3)
          .map((v) => _cleanTitle(v.title))
          .where((t) => t.trim().isNotEmpty)
          .join(' | ');
      final accountName = account?.name ?? '';
      final accountEmail = account?.email ?? '';
      final accountHandle = account?.handle ?? '';
      debugPrint(
        '[YTM] authUser=$candidateAuthUser score=${adjustedScore.toStringAsFixed(2)} raw=${totalScore.toStringAsFixed(2)} identity=$identityScore feed=${feedScore.toStringAsFixed(2)} pinned=${pinnedVisitorData && candidateAuthUser == initialAuthUser} strong=$hasStrongAccountIdentity targetHit=$hasTargetIdentityHit account="$accountName" email="$accountEmail" handle="$accountHandle" quick=${candidateQuickPicks.length}${preview.isNotEmpty ? ' | $preview' : ''}',
      );

      if (adjustedScore > bestScore ||
          (adjustedScore == bestScore &&
              candidateAuthUser == initialAuthUser)) {
        bestScore = adjustedScore;
        bestAuthUser = candidateAuthUser;
        if (candidateVisitorData.isNotEmpty) {
          bestVisitorData = candidateVisitorData;
        }
      }
    }

    _ytMusicAuthUser = bestAuthUser;
    if (bestVisitorData.isNotEmpty) {
      _ytMusicVisitorData = bestVisitorData;
    }
    if (bestScore > double.negativeInfinity) {
      final visitorPreview = _ytMusicVisitorData.length <= 20
          ? _ytMusicVisitorData
          : _ytMusicVisitorData.substring(0, 20);
      debugPrint(
        '[YTM] Resolved X-Goog-AuthUser=$bestAuthUser (score=${bestScore.toStringAsFixed(2)}) visitorData=$visitorPreview...',
      );
    }
    return bestAuthUser;
  }

  Future<void> _refreshYtMusicSession({
    bool reloadHome = false,
    bool showToast = false,
  }) async {
    final oauthToken = (_ytAccessToken ?? '').trim();
    if (oauthToken.isNotEmpty) {
      // Try to get a fresh token if we're using Google login
      try {
        await _getFreshGoogleAccessToken(interactive: false);
      } catch (e) {
        debugPrint('[YTM] OAuth token refresh failed: $e');
      }
    }

    final rawCookie = (_ytMusicCookie ?? '').trim();

    if (rawCookie.isEmpty && oauthToken.isEmpty) {
      if (!mounted) return;
      setState(() {
        _ytMusicSessionChecking = false;
        _ytMusicSessionValid = false;
        _ytMusicSessionName = null;
        _ytMusicSessionEmail = null;
        _ytMusicSessionHandle = null;
        _ytMusicSessionError = null;
      });
      if (reloadHome) {
        _maybeReloadHomeAuto();
      }
      return;
    }

    final cookieMap = _cookieMapFromString(_effectiveYtMusicCookie());
    final hasSecure3pApisid =
        (cookieMap['__Secure-3PAPISID'] ?? '').trim().isNotEmpty;

    if (mounted) {
      setState(() {
        _ytMusicSessionChecking = true;
        _ytMusicSessionError = null;
      });
    }

    try {
      final hasOAuth = oauthToken.isNotEmpty;

      final authUserBefore = _normalizeYtMusicAuthUser(_ytMusicAuthUser);
      final visitorDataBefore =
          _normalizeYtMusicVisitorData(_ytMusicVisitorData);

      // If we have an OAuth token, we can be much more aggressive with skipping
      // the expensive multi-authUser cookie probe if it's already failing.
      final resolvedAuthUser = hasOAuth
          ? authUserBefore
          : await _resolveBestYtMusicAuthUser(maxCandidates: 3);

      final authUserChanged = authUserBefore != resolvedAuthUser;
      var shouldPersistSessionState = authUserChanged ||
          visitorDataBefore !=
              _normalizeYtMusicVisitorData(_ytMusicVisitorData);
      if (authUserChanged) {
        debugPrint(
          '[YTM] Updated AuthUser for session check: $authUserBefore -> $resolvedAuthUser',
        );
      }
      await _ensureFreshYtMusicVisitorData();
      var account = await _fetchYtMusicAccountInfo();
      if (account == null) {
        await _ensureFreshYtMusicVisitorData();
        account = await _fetchYtMusicAccountInfo();
      }
      if (!mounted) return;
      if (account == null) {
        debugPrint('[YTM] Session valid=false');
        final hasOAuth = oauthToken.isNotEmpty;
        final failureMessage = hasSecure3pApisid
            ? 'Could not verify YT Music session'
            : 'Could not verify YT Music session; add __Secure-3PAPISID and correct AuthUser from copied request headers';

        setState(() {
          _ytMusicSessionChecking = false;
          _ytMusicSessionValid = hasOAuth; // Consider valid if we have OAuth
          _ytMusicSessionName = hasOAuth ? _ytAccountName : null;
          _ytMusicSessionEmail = hasOAuth ? _ytAccountEmail : null;
          _ytMusicSessionHandle = null;
          _ytMusicSessionError = hasOAuth ? null : failureMessage;
        });

        if (showToast && !hasOAuth) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                hasSecure3pApisid
                    ? 'YT Music cookie saved, but login could not be verified'
                    : 'Need __Secure-3PAPISID and the right AuthUser from copied request headers',
              ),
            ),
          );
        }
        if (reloadHome) {
          _maybeReloadHomeAuto();
        }
        if (shouldPersistSessionState) _scheduleSave();
        return;
      }
      final verifiedAccount = account;

      setState(() {
        _ytMusicSessionChecking = false;
        _ytMusicSessionValid = true;
        _ytMusicSessionName = verifiedAccount.name;
        _ytMusicSessionEmail = verifiedAccount.email;
        _ytMusicSessionHandle = verifiedAccount.handle;
        _ytMusicSessionError = null;
      });
      debugPrint('[YTM] Session valid=$_ytMusicSessionValid');
      if (_ytMusicSessionValid && rawCookie.isNotEmpty) {
        debugPrint(
          '[YTM] Re-fetching visitorData post-validation (session confirmed)...',
        );
        final postValidationVisitorBefore =
            _normalizeYtMusicVisitorData(_ytMusicVisitorData);
        await _ensureFreshYtMusicVisitorData();
        final postValidationVisitorAfter =
            _normalizeYtMusicVisitorData(_ytMusicVisitorData);
        if (postValidationVisitorAfter != postValidationVisitorBefore) {
          shouldPersistSessionState = true;
        }
        final visitorPreviewLength = min(24, _ytMusicVisitorData.length);
        final visitorPreview =
            _ytMusicVisitorData.substring(0, visitorPreviewLength);
        debugPrint('[YTM] Post-validation visitorData: $visitorPreview...');
      }
      if (shouldPersistSessionState) _scheduleSave();
      if (!mounted) return;
      if (showToast) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text('YT Music session verified for ${verifiedAccount.name}'),
          ),
        );
      }
      if (reloadHome) {
        _maybeReloadHomeAuto();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ytMusicSessionChecking = false;
        _ytMusicSessionValid = false;
        _ytMusicSessionName = null;
        _ytMusicSessionEmail = null;
        _ytMusicSessionHandle = null;
        _ytMusicSessionError = e.toString();
      });
      if (showToast) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('YT Music session check failed'),
          ),
        );
      }
      if (reloadHome) {
        _maybeReloadHomeAuto();
      }
    }
  }

  Map<String, dynamic> _ytMusicContextBody({
    _YtMusicClientProfile? profile,
  }) {
    final resolvedProfile =
        profile ?? _resolveYtMusicClientProfile(preferWebRemix: true);
    return _ytMusicBodyWithProfile(null, resolvedProfile);
  }

  Map<String, dynamic> _ytMusicBodyWithProfile(
    Map<String, dynamic>? body,
    _YtMusicClientProfile profile,
  ) {
    final root = <String, dynamic>{
      if (body != null) ...body,
    };
    final context = <String, dynamic>{
      ...(_jsonMap(root['context']) ?? const <String, dynamic>{}),
    };
    final client = <String, dynamic>{
      ...(_jsonMap(context['client']) ?? const <String, dynamic>{}),
    };
    client['clientName'] = profile.clientName;
    client['clientVersion'] = profile.clientVersion;
    client['gl'] = _ytMusicGl();
    client['hl'] = _ytMusicHl();
    if (_ytMusicVisitorData.isNotEmpty) {
      client['visitorData'] = _ytMusicVisitorData;
    } else {
      client.remove('visitorData');
    }
    client['userAgent'] = profile.userAgent;
    if (profile.isWebRemix) {
      client.remove('androidSdkVersion');
      client['platform'] = 'DESKTOP';
      client['browserName'] = 'Chrome';
      client['browserVersion'] = '134.0.0.0';
    } else {
      client['androidSdkVersion'] = 30;
      client.remove('platform');
      client.remove('browserName');
      client.remove('browserVersion');
    }
    context['client'] = client;
    final user = <String, dynamic>{
      ...(_jsonMap(context['user']) ?? const <String, dynamic>{}),
    };
    user['authUser'] = _normalizeYtMusicAuthUser(_ytMusicAuthUser);
    context['user'] = user;
    root['context'] = context;
    return {
      ...root,
    };
  }

  Map<String, dynamic>? _jsonMap(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    return null;
  }

  List<dynamic> _jsonList(dynamic raw) {
    return raw is List ? raw : const <dynamic>[];
  }

  dynamic _jsonAt(dynamic raw, List<Object> path) {
    dynamic current = raw;
    for (final segment in path) {
      if (segment is int) {
        final list = _jsonList(current);
        if (segment < 0 || segment >= list.length) return null;
        current = list[segment];
      } else {
        final map = _jsonMap(current);
        if (map == null || !map.containsKey(segment)) return null;
        current = map[segment];
      }
    }
    return current;
  }

  String? _stringAt(dynamic raw, List<Object> path) {
    final value = _jsonAt(raw, path);
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  String? _ytMusicContinuation(dynamic raw) {
    return _stringAt(raw, const ['nextContinuationData', 'continuation']) ??
        _stringAt(raw, const ['reloadContinuationData', 'continuation']) ??
        _stringAt(
          raw,
          const ['continuationEndpoint', 'continuationCommand', 'token'],
        ) ??
        _stringAt(
          raw,
          const ['buttonRenderer', 'command', 'continuationCommand', 'token'],
        ) ??
        _stringAt(raw, const ['continuationCommand', 'token']) ??
        _stringAt(raw, const ['continuation']);
  }

  String? _ytMusicRunsText(
    dynamic rawRuns, {
    bool stopAtSeparator = false,
  }) {
    final runs = _jsonList(rawRuns);
    if (runs.isEmpty) return null;
    final parts = <String>[];
    for (final item in runs) {
      final text = (_jsonMap(item)?['text'] ?? '').toString();
      if (text.trim().isEmpty) continue;
      final isSeparator = text.trim() == '•' || text.trim() == '·';
      if (stopAtSeparator && isSeparator) break;
      if (!isSeparator) {
        parts.add(text.trim());
      }
    }
    if (parts.isEmpty) return null;
    final joined = parts.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return joined.isEmpty ? null : joined;
  }

  String? _ytMusicTextValue(
    dynamic raw, {
    bool stopAtSeparator = false,
  }) {
    if (raw == null) return null;
    if (raw is String) {
      final text = raw.trim();
      return text.isEmpty ? null : text;
    }
    final map = _jsonMap(raw);
    if (map != null) {
      final simpleText = (map['simpleText'] ?? '').toString().trim();
      if (simpleText.isNotEmpty) return simpleText;
      final runsText = _ytMusicRunsText(
        map['runs'],
        stopAtSeparator: stopAtSeparator,
      );
      if (runsText != null && runsText.isNotEmpty) return runsText;
    }
    final runsText = _ytMusicRunsText(raw, stopAtSeparator: stopAtSeparator);
    if (runsText != null && runsText.isNotEmpty) return runsText;
    return null;
  }

  dynamic _findFirstJsonValueByKey(
    dynamic raw,
    String key, {
    int maxDepth = 12,
  }) {
    if (maxDepth < 0 || raw == null) return null;
    final map = _jsonMap(raw);
    if (map != null) {
      if (map.containsKey(key)) return map[key];
      for (final value in map.values) {
        final found =
            _findFirstJsonValueByKey(value, key, maxDepth: maxDepth - 1);
        if (found != null) return found;
      }
      return null;
    }
    if (raw is List) {
      for (final item in raw) {
        final found =
            _findFirstJsonValueByKey(item, key, maxDepth: maxDepth - 1);
        if (found != null) return found;
      }
    }
    return null;
  }

  void _collectJsonValuesByKey(
    dynamic raw,
    String key,
    List<dynamic> out, {
    int maxDepth = 12,
  }) {
    if (maxDepth < 0 || raw == null) return;
    final map = _jsonMap(raw);
    if (map != null) {
      if (map.containsKey(key)) {
        out.add(map[key]);
      }
      for (final value in map.values) {
        _collectJsonValuesByKey(value, key, out, maxDepth: maxDepth - 1);
      }
      return;
    }
    if (raw is List) {
      for (final item in raw) {
        _collectJsonValuesByKey(item, key, out, maxDepth: maxDepth - 1);
      }
    }
  }

  List<dynamic> _findJsonValuesByKey(
    dynamic raw,
    String key, {
    int maxDepth = 12,
  }) {
    final out = <dynamic>[];
    _collectJsonValuesByKey(raw, key, out, maxDepth: maxDepth);
    return out;
  }

  Duration? _parseClockDuration(String? text) {
    if (text == null) return null;
    final clean = text.trim();
    if (clean.isEmpty) return null;
    final parts = clean.split(':').map((part) => int.tryParse(part)).toList();
    if (parts.any((part) => part == null)) return null;
    if (parts.length == 2) {
      return Duration(minutes: parts[0]!, seconds: parts[1]!);
    }
    if (parts.length == 3) {
      return Duration(
        hours: parts[0]!,
        minutes: parts[1]!,
        seconds: parts[2]!,
      );
    }
    return null;
  }

  Video? _ytMusicVideoFromMap(Map<String, dynamic> data) {
    final id = (data['id'] as String? ?? '').trim();
    final title = (data['title'] as String? ?? '').trim();
    final author = (data['author'] as String? ?? '').trim();
    final resolvedAuthor = author.isEmpty ? 'YouTube Music' : author;
    if (!VideoId.validateVideoId(id) || title.isEmpty) {
      return null;
    }
    final cleanTitle = _cleanTitle(title);
    final cleanAuthor = _cleanAuthor(resolvedAuthor);
    final normTitle = _normalizeSignalKey(cleanTitle);
    final artistKey = _primaryArtistKey(cleanAuthor);
    if (normTitle.isEmpty || normTitle == artistKey) {
      return null;
    }
    return _videoFromMap({
      'id': id,
      'title': title,
      'author': resolvedAuthor,
      'durationSecs': (data['durationSecs'] as int?),
    });
  }

  String? _ytMusicWatchField(
    Map<String, dynamic> renderer,
    String field,
  ) {
    final direct = _stringAt(
      renderer,
      ['navigationEndpoint', 'watchEndpoint', field],
    );
    if (direct != null && direct.isNotEmpty) return direct;

    final overlay = _stringAt(renderer, [
      'overlay',
      'musicItemThumbnailOverlayRenderer',
      'content',
      'musicPlayButtonRenderer',
      'playNavigationEndpoint',
      'watchEndpoint',
      field,
    ]);
    if (overlay != null && overlay.isNotEmpty) return overlay;

    final flex = _stringAt(renderer, [
      'flexColumns',
      0,
      'musicResponsiveListItemFlexColumnRenderer',
      'text',
      'runs',
      0,
      'navigationEndpoint',
      'watchEndpoint',
      field,
    ]);
    if (flex != null && flex.isNotEmpty) return flex;

    if (field == 'videoId') {
      final playlistItem =
          _stringAt(renderer, const ['playlistItemData', 'videoId']);
      if (playlistItem != null && playlistItem.isNotEmpty) return playlistItem;
    }

    return null;
  }

  String? _ytMusicResponsiveColumnText(
    Map<String, dynamic> renderer,
    int columnIndex, {
    bool stopAtSeparator = false,
  }) {
    return _ytMusicRunsText(
      _jsonAt(renderer, [
        'flexColumns',
        columnIndex,
        'musicResponsiveListItemFlexColumnRenderer',
        'text',
        'runs',
      ]),
      stopAtSeparator: stopAtSeparator,
    );
  }

  String? _ytMusicPlaylistIdFromRenderer(Map<String, dynamic> renderer) {
    final watchPlaylistId = _stringAt(renderer, [
      'thumbnailOverlay',
      'musicItemThumbnailOverlayRenderer',
      'content',
      'musicPlayButtonRenderer',
      'playNavigationEndpoint',
      'watchPlaylistEndpoint',
      'playlistId',
    ]);
    if (watchPlaylistId != null && watchPlaylistId.isNotEmpty) {
      return watchPlaylistId;
    }

    final directWatchPlaylistId = _stringAt(
      renderer,
      const ['navigationEndpoint', 'watchPlaylistEndpoint', 'playlistId'],
    );
    if (directWatchPlaylistId != null && directWatchPlaylistId.isNotEmpty) {
      return directWatchPlaylistId;
    }

    final browseId = _stringAt(
      renderer,
      const ['navigationEndpoint', 'browseEndpoint', 'browseId'],
    );
    if (browseId != null && browseId.startsWith('VL') && browseId.length > 2) {
      return browseId.substring(2);
    }
    return null;
  }

  _YtMusicMixRef? _ytMusicHomeMixRef(dynamic raw) {
    final renderer = _jsonMap(_jsonAt(raw, const ['musicTwoRowItemRenderer']));
    if (renderer == null) return null;
    final playlistId = _ytMusicPlaylistIdFromRenderer(renderer);
    if (playlistId == null || playlistId.isEmpty) return null;
    final title = _ytMusicTextValue(renderer['title']);
    if (title == null || title.trim().isEmpty) return null;
    final subtitle = _ytMusicTextValue(renderer['subtitle']) ?? '';
    return _YtMusicMixRef(
      title: title.trim(),
      subtitle: subtitle.trim(),
      playlistId: playlistId,
    );
  }

  List<dynamic> _ytMusicSectionContentItems(Map<String, dynamic> renderer) {
    final directContents = _jsonList(renderer['contents']);
    if (directContents.isNotEmpty) return directContents;

    final gridItems = _jsonList(
        _jsonAt(renderer, const ['content', 'gridRenderer', 'items']));
    if (gridItems.isNotEmpty) return gridItems;

    final nestedShelfItems = _jsonList(
      _jsonAt(renderer, const ['content', 'musicShelfRenderer', 'contents']),
    );
    if (nestedShelfItems.isNotEmpty) return nestedShelfItems;

    return <dynamic>[
      ..._findJsonValuesByKey(
        renderer,
        'musicResponsiveListItemRenderer',
        maxDepth: 10,
      ).map((value) => <String, dynamic>{
            'musicResponsiveListItemRenderer':
                _jsonMap(value) ?? const <String, dynamic>{},
          }),
      ..._findJsonValuesByKey(
        renderer,
        'musicMultiRowListItemRenderer',
        maxDepth: 10,
      ).map((value) => <String, dynamic>{
            'musicMultiRowListItemRenderer':
                _jsonMap(value) ?? const <String, dynamic>{},
          }),
      ..._findJsonValuesByKey(
        renderer,
        'musicTwoRowItemRenderer',
        maxDepth: 10,
      ).map((value) => <String, dynamic>{
            'musicTwoRowItemRenderer':
                _jsonMap(value) ?? const <String, dynamic>{},
          }),
    ];
  }

  _YtMusicHomeSection? _ytMusicHomeSection(dynamic raw) {
    final carousel =
        _jsonMap(_jsonAt(raw, const ['musicCarouselShelfRenderer'])) ??
            _jsonMap(
              _findFirstJsonValueByKey(
                raw,
                'musicCarouselShelfRenderer',
                maxDepth: 10,
              ),
            );
    final card = carousel == null
        ? _jsonMap(_jsonAt(raw, const ['musicCardShelfRenderer'])) ??
            _jsonMap(
              _findFirstJsonValueByKey(
                raw,
                'musicCardShelfRenderer',
                maxDepth: 10,
              ),
            )
        : null;
    final shelf = (carousel == null && card == null)
        ? _jsonMap(_jsonAt(raw, const ['musicShelfRenderer'])) ??
            _jsonMap(
              _findFirstJsonValueByKey(
                raw,
                'musicShelfRenderer',
                maxDepth: 10,
              ),
            )
        : null;
    final renderer = carousel ?? card ?? shelf;
    if (renderer == null) return null;

    final title = (carousel != null || card != null)
        ? (_ytMusicTextValue(_jsonAt(renderer, const [
              'header',
              'musicCarouselShelfBasicHeaderRenderer',
              'title',
            ])) ??
            _ytMusicTextValue(renderer['title']) ??
            _ytMusicTextValue(_jsonAt(renderer, const [
              'header',
              'musicResponsiveHeaderRenderer',
              'title',
            ])))
        : _ytMusicTextValue(shelf?['title']) ??
            _ytMusicTextValue(_jsonAt(shelf, const [
              'header',
              'musicResponsiveHeaderRenderer',
              'title',
            ]));
    if (title == null || title.trim().isEmpty) return null;
    final subtitle = (carousel != null || card != null)
        ? (_ytMusicTextValue(_jsonAt(renderer, const [
              'header',
              'musicCarouselShelfBasicHeaderRenderer',
              'strapline',
            ])) ??
            _ytMusicTextValue(renderer['subtitle']) ??
            _ytMusicTextValue(_jsonAt(renderer, const [
              'header',
              'musicResponsiveHeaderRenderer',
              'subtitle',
            ])) ??
            '')
        : (_ytMusicTextValue(shelf?['bottomText']) ??
            _ytMusicTextValue(_jsonAt(shelf, const [
              'header',
              'musicResponsiveHeaderRenderer',
              'subtitle',
            ])) ??
            '');

    final videos = <Video>[];
    final videoIds = <String>{};
    final mixes = <_YtMusicMixRef>[];
    final mixIds = <String>{};

    for (final content in _ytMusicSectionContentItems(renderer)) {
      final video = _ytMusicHomeVideo(content);
      if (video != null && videoIds.add(video.id.value)) {
        videos.add(video);
      }

      final mix = _ytMusicHomeMixRef(content);
      if (mix != null && mixIds.add(mix.playlistId)) {
        mixes.add(mix);
      }
    }

    if (videos.isEmpty && mixes.isEmpty) return null;
    return _YtMusicHomeSection(
      title: title.trim(),
      subtitle: subtitle.trim(),
      videos: videos.take(24).toList(),
      mixes: mixes,
    );
  }

  Video? _ytMusicHomeVideo(dynamic raw) {
    final responsive =
        _jsonMap(_jsonAt(raw, const ['musicResponsiveListItemRenderer'])) ??
            _jsonMap(_jsonAt(raw, const ['musicMultiRowListItemRenderer']));
    if (responsive != null) {
      final videoId = _ytMusicWatchField(responsive, 'videoId');
      if (videoId == null || !VideoId.validateVideoId(videoId)) return null;

      final title = _ytMusicResponsiveColumnText(responsive, 0);
      final author = _ytMusicResponsiveColumnText(
            responsive,
            1,
            stopAtSeparator: true,
          ) ??
          _ytMusicTextValue(
            _jsonAt(responsive, const ['subtitle']),
            stopAtSeparator: true,
          ) ??
          _ytMusicRunsText(
            _jsonAt(responsive, const ['shortBylineText', 'runs']),
            stopAtSeparator: true,
          ) ??
          _ytMusicTextValue(
            _findFirstJsonValueByKey(
              responsive,
              'subtitle',
              maxDepth: 8,
            ),
            stopAtSeparator: true,
          );
      final duration = _parseClockDuration(
        _ytMusicRunsText(_jsonAt(responsive, const [
              'fixedColumns',
              0,
              'musicResponsiveListItemFixedColumnRenderer',
              'text',
              'runs',
            ])) ??
            _ytMusicRunsText(_jsonAt(responsive, const ['lengthText', 'runs'])),
      );
      return _ytMusicVideoFromMap({
        'id': videoId,
        'title': title,
        'author': author,
        'durationSecs': duration?.inSeconds,
      });
    }

    final renderer = _jsonMap(_jsonAt(raw, const ['musicTwoRowItemRenderer']));
    if (renderer == null) return null;
    final videoId = _ytMusicWatchField(renderer, 'videoId');
    if (videoId == null || !VideoId.validateVideoId(videoId)) return null;

    final title = _ytMusicRunsText(_jsonAt(renderer, const ['title', 'runs']));
    final author = _ytMusicRunsText(
          _jsonAt(renderer, const ['subtitle', 'runs']),
          stopAtSeparator: true,
        ) ??
        _ytMusicTextValue(
          _jsonAt(renderer, const ['subtitle']),
          stopAtSeparator: true,
        ) ??
        _ytMusicTextValue(
          _findFirstJsonValueByKey(renderer, 'subtitle', maxDepth: 6),
          stopAtSeparator: true,
        );
    return _ytMusicVideoFromMap({
      'id': videoId,
      'title': title,
      'author': author,
      'durationSecs': null,
    });
  }

  Video? _ytMusicNextVideo(dynamic raw) {
    final renderer =
        _jsonMap(_jsonAt(raw, const ['playlistPanelVideoRenderer']));
    if (renderer == null) return null;
    final videoId = (renderer['videoId'] ?? '').toString().trim();
    if (!VideoId.validateVideoId(videoId)) return null;
    if (_stringAt(renderer, const ['unplayableText', 'runs', 0, 'text']) !=
        null) {
      return null;
    }

    final title = _ytMusicRunsText(_jsonAt(renderer, const ['title', 'runs']));
    final author = _ytMusicRunsText(
          _jsonAt(renderer, const ['shortBylineText', 'runs']),
          stopAtSeparator: true,
        ) ??
        _ytMusicRunsText(
          _jsonAt(renderer, const ['longBylineText', 'runs']),
          stopAtSeparator: true,
        );
    final duration = _parseClockDuration(
      _ytMusicRunsText(_jsonAt(renderer, const ['lengthText', 'runs'])),
    );
    return _ytMusicVideoFromMap({
      'id': videoId,
      'title': title,
      'author': author,
      'durationSecs': duration?.inSeconds,
    });
  }

  Future<Map<String, dynamic>?> _ytMusicPostJson(
    String endpoint, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
    _YtMusicClientProfile? profile,
  }) async {
    try {
      final resolvedProfile =
          profile ?? _resolveYtMusicClientProfile(preferWebRemix: true);
      if (_ytMusicVisitorData.trim().isEmpty ||
          _ytMusicVisitorData == _ytMusicDefaultVisitorData) {
        await _ensureFreshYtMusicVisitorData();
      }
      final resolvedClientVersion = resolvedProfile.clientVersion.trim();
      final authHeader = _ytMusicAuthorizationHeader();
      final isOAuthBearer =
          authHeader != null && authHeader.startsWith('Bearer ');

      final params = <String, String>{
        'key': _ytMusicApiKey,
        'prettyPrint': 'false',
        'authuser': _normalizeYtMusicAuthUser(_ytMusicAuthUser),
        if (query != null) ...query,
      };
      final uri = Uri.https(
        _ytMusicApiBase,
        '$_ytMusicApiPrefix/$endpoint',
        params,
      );

      final headers = <String, String>{
        HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
        'X-Goog-Api-Format-Version': '1',
        'X-YouTube-Client-Name': resolvedProfile.clientHeaderName,
        'X-YouTube-Client-Version': resolvedClientVersion,
        'X-Goog-AuthUser': _normalizeYtMusicAuthUser(_ytMusicAuthUser),
        if (_ytMusicVisitorData.isNotEmpty)
          'X-Goog-Visitor-Id': _ytMusicVisitorData,
        HttpHeaders.acceptHeader: 'application/json',
        HttpHeaders.acceptEncodingHeader: 'gzip, deflate',
        HttpHeaders.acceptLanguageHeader: _ytMusicHl(),
        HttpHeaders.userAgentHeader: resolvedProfile.userAgent,
      };

      if (resolvedProfile.isWebRemix) {
        headers['Origin'] = 'https://music.youtube.com';
        headers['X-Origin'] = 'https://music.youtube.com';
        headers['Referer'] = 'https://music.youtube.com/';
        headers.addAll(_ytMusicBrowserIdentityHeaders());
      }
      final rawCookie = _effectiveYtMusicCookie();

      // If we're using an OAuth Bearer token AND the cookie session is not verified,
      // it's better to NOT send the cookie header at all to avoid auth conflicts on the server.
      final shouldSendCookie =
          rawCookie.isNotEmpty && (!isOAuthBearer || _ytMusicSessionValid);

      if (shouldSendCookie) {
        headers[HttpHeaders.cookieHeader] = rawCookie;
        headers['X-YouTube-Bootstrap-Logged-In'] = 'true';
        debugPrint('[YTM] Using real cookie for personalized feed');
      }

      if (authHeader != null && authHeader.isNotEmpty) {
        headers[HttpHeaders.authorizationHeader] = authHeader;
        debugPrint(
            '[YTM] Auth header present for $endpoint (${isOAuthBearer ? "Bearer" : "SAPISIDHASH"})');
      } else {
        final cookie = _effectiveYtMusicCookie();
        final hasSapisid = cookie.contains('SAPISID=') ||
            cookie.contains('__Secure-1PAPISID=') ||
            cookie.contains('__Secure-3PAPISID=');
        debugPrint(
          '[YTM] WARNING NO auth header for $endpoint | hasSAPISID=$hasSapisid | cookieLen=${cookie.length}',
        );
      }
      var effectiveProfile = resolvedProfile;
      var payload = jsonEncode(_ytMusicBodyWithProfile(body, effectiveProfile));
      var response = await http
          .post(
            uri,
            headers: headers,
            body: payload,
          )
          .timeout(const Duration(seconds: 14));
      var text = response.body;
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          text.trim().isEmpty) {
        // If it's a 403 Forbidden (insufficient scopes), retrying won't help.
        if (response.statusCode == 403) {
          debugPrint(
            '[YTM] POST $endpoint failed with 403 (Forbidden). Skipping retry.',
          );
          return null;
        }
        if (response.statusCode == 400 &&
            text.toLowerCase().contains('failedprecondition')) {
          await _ensureFreshYtMusicVisitorData();
          final androidProfile = _ytMusicAndroidGenericClientProfile();
          final altHeaders = Map<String, String>.from(headers)
            ..['X-YouTube-Client-Name'] = androidProfile.clientHeaderName
            ..['X-YouTube-Client-Version'] = androidProfile.clientVersion
            ..[HttpHeaders.userAgentHeader] = androidProfile.userAgent;
          altHeaders.remove(HttpHeaders.cookieHeader);
          altHeaders['X-YouTube-Bootstrap-Logged-In'] = 'false';
          final altPayload =
              jsonEncode(_ytMusicBodyWithProfile(body, androidProfile));
          final altResp = await http
              .post(uri, headers: altHeaders, body: altPayload)
              .timeout(const Duration(seconds: 14));
          final altText = altResp.body;
          if (altResp.statusCode >= 200 &&
              altResp.statusCode < 300 &&
              altText.trim().isNotEmpty) {
            return _jsonMap(jsonDecode(altText));
          }
        }

        await _ensureFreshYtMusicVisitorData();
        if (effectiveProfile.isWebRemix) {
          effectiveProfile = _ytMusicWebRemixClientProfile();
        }
        headers['X-Goog-Visitor-Id'] = _ytMusicVisitorData;
        headers['X-YouTube-Client-Version'] = effectiveProfile.clientVersion;
        headers['X-YouTube-Client-Name'] = effectiveProfile.clientHeaderName;
        headers[HttpHeaders.userAgentHeader] = effectiveProfile.userAgent;
        if (effectiveProfile.isWebRemix) {
          headers['Referer'] = 'https://music.youtube.com/';
          headers.addAll(_ytMusicBrowserIdentityHeaders());
        }
        payload = jsonEncode(_ytMusicBodyWithProfile(body, effectiveProfile));
        response = await http
            .post(
              uri,
              headers: headers,
              body: payload,
            )
            .timeout(const Duration(seconds: 14));
        text = response.body;
      }
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          text.trim().isEmpty) {
        debugPrint(
          '[YTM] POST $endpoint failed: ${response.statusCode} ${text.length > 240 ? text.substring(0, 240) : text}',
        );
        return null;
      }
      final json = _jsonMap(jsonDecode(text));
      if (json == null) {
        debugPrint('[YTM] POST $endpoint returned a non-object payload');
        return null;
      }
      final visitorData =
          _stringAt(json, const ['responseContext', 'visitorData']);
      if (visitorData != null && visitorData.isNotEmpty) {
        _ytMusicVisitorData = visitorData;
      }
      return json;
    } on TimeoutException catch (e) {
      debugPrint('[YTM] POST $endpoint timeout: $e');
      return null;
    } on FormatException catch (e) {
      debugPrint('[YTM] POST $endpoint invalid JSON: $e');
      return null;
    } catch (e) {
      debugPrint('[YTM] POST $endpoint error: $e');
      return null;
    }
  }

  List<dynamic> _ytMusicHomeContentItems(Map<String, dynamic> response) {
    final sourceBuckets = <dynamic>[];
    final tabs = _jsonList(_jsonAt(response, const [
      'contents',
      'singleColumnBrowseResultsRenderer',
      'tabs',
    ]));
    if (tabs.isNotEmpty) {
      Map<String, dynamic>? selectedTab;
      for (final tab in tabs) {
        final renderer = _jsonMap(_jsonAt(tab, const ['tabRenderer']));
        if (renderer == null) continue;
        if (renderer['selected'] == true) {
          selectedTab = renderer;
          break;
        }
        selectedTab ??= renderer;
      }
      final selectedContents = _jsonList(
        _jsonAt(
            selectedTab, const ['content', 'sectionListRenderer', 'contents']),
      );
      if (selectedContents.isNotEmpty) {
        sourceBuckets.addAll(selectedContents);
      }
    }

    final continuationContents = _jsonList(_jsonAt(response, const [
      'continuationContents',
      'sectionListContinuation',
      'contents',
    ]));
    if (continuationContents.isNotEmpty) {
      sourceBuckets.addAll(continuationContents);
    }

    final sectionListRenderer =
        _jsonMap(_findFirstJsonValueByKey(response, 'sectionListRenderer'));
    final sectionContents = _jsonList(sectionListRenderer?['contents']);
    if (sectionContents.isNotEmpty) {
      sourceBuckets.addAll(sectionContents);
    }

    if (sourceBuckets.isEmpty) {
      sourceBuckets.add(response);
    }

    final out = <dynamic>[];
    final seen = <String>{};

    void addShelf(String rendererKey, dynamic rendererValue) {
      final renderer = _jsonMap(rendererValue);
      if (renderer == null) return;
      final title = (rendererKey == 'musicCarouselShelfRenderer' ||
              rendererKey == 'musicCardShelfRenderer')
          ? (_ytMusicTextValue(_jsonAt(renderer, const [
                'header',
                'musicCarouselShelfBasicHeaderRenderer',
                'title',
              ])) ??
              _ytMusicTextValue(renderer['title']) ??
              _ytMusicTextValue(_jsonAt(renderer, const [
                'header',
                'musicResponsiveHeaderRenderer',
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
      final contents = _jsonList(renderer['contents']);
      final signature =
          '$rendererKey:${title.trim().toLowerCase()}:${contents.length}';
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
      for (final card in _findJsonValuesByKey(
        source,
        'musicCardShelfRenderer',
        maxDepth: 20,
      )) {
        addShelf('musicCardShelfRenderer', card);
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

  String? _ytMusicHomeContinuationToken(Map<String, dynamic> response) {
    final tabs = _jsonList(_jsonAt(response, const [
      'contents',
      'singleColumnBrowseResultsRenderer',
      'tabs',
    ]));
    if (tabs.isNotEmpty) {
      Map<String, dynamic>? selectedTab;
      for (final tab in tabs) {
        final renderer = _jsonMap(_jsonAt(tab, const ['tabRenderer']));
        if (renderer == null) continue;
        if (renderer['selected'] == true) {
          selectedTab = renderer;
          break;
        }
        selectedTab ??= renderer;
      }
      final selectedToken = _ytMusicContinuation(_jsonAt(selectedTab, const [
        'content',
        'sectionListRenderer',
        'continuations',
        0,
      ]));
      if (selectedToken != null && selectedToken.isNotEmpty) {
        return selectedToken;
      }
    }

    final continuationToken = _ytMusicContinuation(_jsonAt(response, const [
      'continuationContents',
      'sectionListContinuation',
      'continuations',
      0,
    ]));
    if (continuationToken != null && continuationToken.isNotEmpty) {
      return continuationToken;
    }

    final continuationCandidates = <dynamic>[
      ..._findJsonValuesByKey(response, 'nextContinuationData', maxDepth: 18),
      ..._findJsonValuesByKey(response, 'reloadContinuationData', maxDepth: 18),
      ..._findJsonValuesByKey(
        response,
        'continuationItemRenderer',
        maxDepth: 18,
      ),
    ];
    for (final candidate in continuationCandidates) {
      final token = _ytMusicContinuation(candidate);
      if (token != null && token.isNotEmpty) return token;
    }
    return null;
  }

  Future<List<Video>> _fetchYtMusicHomeSongs({
    int limit = 40,
    int maxContinuations = 2,
  }) async {
    final preferredProfile = _resolveYtMusicClientProfile(
      preferWebRemix: true,
    );
    var sections = await _fetchYtMusicHomeSections(
      maxSections: max((limit / 4).ceil() + 2, 10),
      maxContinuations: maxContinuations,
      profile: preferredProfile,
    );
    if (sections.isEmpty && preferredProfile.isWebRemix) {
      final fallbackProfile = _resolveYtMusicClientProfile(
        hasCookie: true,
        preferWebRemix: true,
        fallbackToAndroid: true,
      );
      sections = await _fetchYtMusicHomeSections(
        maxSections: max((limit / 4).ceil() + 2, 10),
        maxContinuations: maxContinuations,
        profile: fallbackProfile,
      );
    }
    if (sections.isEmpty) return const <Video>[];

    final out = <Video>[];
    final seen = <String>{};
    for (final section in sections) {
      for (final video in section.videos) {
        if (!seen.add(video.id.value)) continue;
        if (_isRecommendationBlocked(video)) continue;
        out.add(video);
        if (out.length >= limit) {
          return _filterMusicResults(out, limit: limit, strictSingles: true);
        }
      }
    }
    return _filterMusicResults(out, limit: limit, strictSingles: true);
  }

  Future<List<Video>> _fetchYtMusicNextSongs(
    Video seed, {
    int limit = 50,
  }) async {
    final response = await _ytMusicPostJson(
      'next',
      body: {
        ..._ytMusicContextBody(),
        'videoId': seed.id.value,
      },
    );
    if (response == null) return const <Video>[];

    final playlistContents = _jsonAt(response, const [
      'contents',
      'singleColumnMusicWatchNextResultsRenderer',
      'tabbedRenderer',
      'watchNextTabbedResultsRenderer',
      'tabs',
      0,
      'tabRenderer',
      'content',
      'musicQueueRenderer',
      'content',
      'playlistPanelRenderer',
      'contents',
    ]);

    final out = <Video>[];
    final seen = <String>{};
    for (final item in _jsonList(playlistContents)) {
      final video = _ytMusicNextVideo(item);
      if (video == null) continue;
      if (!seen.add(video.id.value)) continue;
      if (_isRecommendationBlocked(video)) continue;
      out.add(video);
      if (out.length >= limit) break;
    }
    return _filterMusicResults(out, limit: limit, strictSingles: true);
  }

  Future<List<_YtMusicHomeSection>> _fetchYtMusicHomeSections({
    int maxSections = 10,
    int maxContinuations = 2,
    _YtMusicClientProfile? profile,
  }) async {
    final oauthToken = (_ytAccessToken ?? '').trim();
    final hasCookie = (_ytMusicCookie ?? '').trim().isNotEmpty;
    final resolvedProfile =
        profile ?? _resolveYtMusicClientProfile(preferWebRemix: true);
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

    debugPrint('[YTM] gl=${_ytMusicGl()} hl=${_ytMusicHl()}');
    Map<String, dynamic>? response = await _ytMusicPostJson(
      'browse',
      body: {
        ..._ytMusicContextBody(
          profile: resolvedProfile,
        ),
        'browseId': 'FEmusic_home',
      },
      profile: resolvedProfile,
    );
    if (response == null) return const <_YtMusicHomeSection>[];

    final responseStr = jsonEncode(response);
    final isGuestResponse = !responseStr.contains('accountName') &&
        !responseStr.contains('email"') &&
        !responseStr.contains('"accountByline"');

    if (isGuestResponse && (oauthToken.isNotEmpty || hasCookie)) {
      debugPrint(
          '[YTM] Home feed returned guest content despite auth - retrying with ANDROID client');
      final androidGenericProfile = _ytMusicAndroidGenericClientProfile();
      response = await _ytMusicPostJson(
        'browse',
        body: {
          ..._ytMusicContextBody(
            profile: androidGenericProfile,
          ),
          'browseId': 'FEmusic_home',
        },
        profile: androidGenericProfile,
      );
      if (response == null) return const <_YtMusicHomeSection>[];
    }

    final items = _ytMusicHomeContentItems(response);
    debugPrint('[YTM RAW] Content items found: ${items.length}');
    for (final item in items.take(3)) {
      debugPrint('[YTM RAW] Item keys: ${_jsonMap(item)?.keys.toList()}');
    }

    collect(items);

    var continuation = _ytMusicHomeContinuationToken(response);

    var pass = 0;
    while (continuation != null &&
        continuation.isNotEmpty &&
        out.length < maxSections &&
        pass < maxContinuations) {
      var continuationResponse = await _ytMusicPostJson(
        'browse',
        body: {
          ..._ytMusicContextBody(
            profile: resolvedProfile,
          ),
          'continuation': continuation,
        },
        profile: resolvedProfile,
      );

      var continuationItems = continuationResponse == null
          ? const <dynamic>[]
          : _ytMusicHomeContentItems(continuationResponse);

      if (continuationResponse == null || continuationItems.isEmpty) {
        continuationResponse = await _ytMusicPostJson(
          'browse',
          body: _ytMusicContextBody(profile: resolvedProfile),
          query: {
            'continuation': continuation,
            'ctoken': continuation,
            'type': 'next',
          },
          profile: resolvedProfile,
        );
        continuationItems = continuationResponse == null
            ? const <dynamic>[]
            : _ytMusicHomeContentItems(continuationResponse);
      }

      if (continuationResponse == null) break;
      collect(continuationItems);
      continuation = _ytMusicHomeContinuationToken(continuationResponse);
      pass++;
    }

    return out;
  }

  String _ytMusicMixPlaylistId(Video seed) => 'RDAMVM${seed.id.value}';

  Future<List<Video>> _fetchYtMusicPlaylistSongs(
    String playlistId, {
    int limit = 72,
  }) async {
    final normalized = playlistId.trim();
    if (normalized.isEmpty) return const <Video>[];
    final response = await _ytMusicPostJson(
      'music/get_queue',
      body: {
        ..._ytMusicContextBody(),
        'playlistId': normalized,
      },
    );
    if (response == null) return const <Video>[];

    final out = <Video>[];
    final seen = <String>{};
    for (final item in _jsonList(response['queueDatas'])) {
      final video = _ytMusicNextVideo(_jsonAt(item, const ['content']) ?? item);
      if (video == null) continue;
      if (!seen.add(video.id.value)) continue;
      if (_isRecommendationBlocked(video)) continue;
      out.add(video);
      if (out.length >= limit) break;
    }
    return _filterMusicResults(out, limit: limit, strictSingles: true);
  }

  Future<List<Video>> _fetchYtMusicMixSongs(
    Video seed, {
    int limit = 72,
  }) async {
    final queue = await _fetchYtMusicPlaylistSongs(
      _ytMusicMixPlaylistId(seed),
      limit: max(limit + 1, 24),
    );
    return queue
        .where((video) => video.id.value != seed.id.value)
        .take(limit)
        .toList();
  }

  Future<List<Video>> _fetchYoutubeRelated(
    Video seed, {
    int limit = 60,
  }) async {
    final yt = YoutubeExplode();
    try {
      final related = await yt.videos
          .getRelatedVideos(seed)
          .timeout(const Duration(seconds: 14));
      if (related == null) return <Video>[];

      final raw = <Video>[...related];
      var page = related;
      while (raw.length < limit) {
        final next = await page.nextPage().timeout(const Duration(seconds: 10));
        if (next == null || next.isEmpty) break;
        raw.addAll(next);
        page = next;
      }
      final filtered = _filterMusicResults(
        raw,
        limit: limit * 2,
        strictSingles: true,
      );
      return _filterBlockedRecommendations(filtered, limit: limit);
    } catch (_) {
      return <Video>[];
    } finally {
      try {
        yt.close();
      } catch (_) {}
    }
  }

  Future<void> _appendRadioCandidates(Video seed, {int minAdds = 8}) async {
    if (_radioQueueFilling) return;
    _radioQueueFilling = true;
    try {
      final existingIds = _playQueue.map((v) => v.id.value).toSet();
      final strictYtMusic = _strictYtMusicFeedMode;
      final bestById = <String, ({Video v, double sourceBoost})>{};
      final profile = _buildTasteProfile();
      final radioSeeds = _buildContextualRadioSeeds(seed, profile);
      final seedText = '${seed.title} ${seed.author}'.toLowerCase();
      final seedTags = _extractMusicTags(seedText);
      final seedLanguage = _detectLanguageTag(seedText);
      final queueArtistCount = <String, int>{};
      for (final qv in _playQueue) {
        final k = _primaryArtistKey(qv.author);
        queueArtistCount[k] = (queueArtistCount[k] ?? 0) + 1;
      }
      final playedTail = _currentIndex >= 0
          ? _playQueue
              .take(_currentIndex + 1)
              .toList()
              .reversed
              .take(6)
              .toList()
          : <Video>[seed];
      if (playedTail.isEmpty) {
        playedTail.add(seed);
      }
      final tailTags = <String>{};
      final tailArtists = <String>{};
      for (final v in playedTail) {
        final text = '${v.title} ${v.author}'.toLowerCase();
        tailTags.addAll(_extractMusicTags(text));
        final a = _primaryArtistKey(v.author);
        if (a.isNotEmpty) tailArtists.add(a);
      }
      final tailMood = _primaryMoodTag(tailTags);
      final tailLanguage = _detectLanguageTag(
          playedTail.map((v) => '${v.title} ${v.author}').join(' ').toLowerCase());
      final tailLastArtist = playedTail.isNotEmpty
          ? _primaryArtistKey(playedTail.first.author)
          : _primaryArtistKey(seed.author);
      final longSessionTightening = _currentIndex >= 10 ? 1.0 : 0.0;
      final topLanguage = profile['topLanguage'] as String? ?? seedLanguage;
      final strongContext = seedTags.isNotEmpty || seedLanguage != topLanguage;

      void addCandidate(Video v, double sourceBoost) {
        if (existingIds.contains(v.id.value)) return;
        if (_radioSeenIds.contains(v.id.value)) return;
        if (_isRecommendationBlocked(v)) return;
        final prev = bestById[v.id.value];
        if (prev == null || sourceBoost > prev.sourceBoost) {
          bestById[v.id.value] = (v: v, sourceBoost: sourceBoost);
        }
      }

      final ytMix = await _fetchYtMusicMixSongs(seed, limit: 96);
      final ytNext = await _fetchYtMusicNextSongs(seed, limit: 96);

      if (strictYtMusic) {
        final ordered = <Video>[];
        final seen = <String>{};
        final sourceBoostById = <String, double>{};
        void addOrdered(Iterable<Video> source) {
          var index = 0;
          for (final video in source) {
            if (existingIds.contains(video.id.value)) continue;
            if (_radioSeenIds.contains(video.id.value)) continue;
            if (_isRecommendationBlocked(video)) continue;
            if (!_isMusicCandidate(video, strictSingles: true)) continue;
            final qualityText =
                '${_cleanTitle(video.title)} ${_cleanAuthor(video.author)}';
            if (_looksLikeCompilation(_cleanTitle(video.title))) continue;
            if (_looksLikeShortForm(qualityText.toLowerCase())) continue;
            if (!_isDurationMusicFriendly(video.duration,
                strictSingles: true)) {
              continue;
            }
            if (!seen.add(video.id.value)) continue;
            ordered.add(video);
            sourceBoostById[video.id.value] =
                max(0.0, 2.3 - (index * 0.04)) + (sourceBoostById[video.id.value] ?? 0.0);
            index++;
          }
        }

        // Keep queue order close to YT Music: next queue first, then mix/home.
        addOrdered(ytNext);
        addOrdered(ytMix);

        if (ordered.length < minAdds) {
          final homeFallback =
              await _fetchYtMusicHomeSongs(limit: max(24, minAdds * 5));
          addOrdered(homeFallback);
        }
        if (ordered.length < minAdds) {
          final relatedFallback =
              await _fetchYoutubeRelated(seed, limit: max(24, minAdds * 4));
          addOrdered(relatedFallback);
        }
        if (ordered.length < minAdds) {
          final searchFallback = await _searchMusic(
            _buildRadioQuery(seed),
            limit: max(20, minAdds * 3),
            strictSingles: true,
            personalize: false,
            excludeBlocked: true,
          );
          addOrdered(searchFallback);
        }

        final rankedOrdered = ordered
            .asMap()
            .entries
            .map((entry) {
              final idx = entry.key;
              final v = entry.value;
              final candText = '${v.title} ${v.author}'.toLowerCase();
              final candTags = _extractMusicTags(candText);
              final candMood = _primaryMoodTag(candTags);
              final candArtist = _primaryArtistKey(v.author);
              final candLanguage = _detectLanguageTag(candText);
              final tailAffinity = playedTail
                      .take(4)
                      .map((anchor) =>
                          _contextualSeedAffinity(anchor, v, profile, strict: true) * 0.55 +
                          _transitionAffinityScore(anchor, v, profile, strict: true) * 0.35)
                      .fold<double>(0.0, (sum, x) => sum + x) /
                  max(1, min(4, playedTail.length));
              final tailPenalty = (candArtist == tailLastArtist ? 1.15 : 0.0) +
                  (tailArtists.contains(candArtist) ? 0.55 : 0.0);
              final moodPenalty = tailMood != null && candMood != null && candMood != tailMood
                  ? _vibeClashPenalty(tailTags, candTags, strict: false) * 0.5
                  : 0.0;
              final langPenalty = tailLanguage != candLanguage ? 0.45 : 0.0;
              final score = _radioRelevanceScore(seed, v, profile) +
                  tailAffinity +
                  (tailMood != null && candMood == tailMood ? 0.75 : 0.0) +
                  (sourceBoostById[v.id.value] ?? 0.0) +
                  max(0.0, 0.9 - (idx * 0.05)) -
                  tailPenalty -
                  moodPenalty -
                  langPenalty;
              return (v: v, score: score);
            })
            .toList()
          ..sort((a, b) => b.score.compareTo(a.score));
        final fresh = _pickDiverseRadioCandidates(
          rankedOrdered,
          seed: seed,
          minAdds: minAdds,
          strongContext: true,
        );
        if (fresh.isEmpty && rankedOrdered.isNotEmpty) {
          final baseCut = _currentIndex >= 10 ? 4.2 : 3.4;
          final safe = rankedOrdered.where((x) => x.score >= baseCut).map((x) => x.v).toList();
          fresh.addAll(
            (safe.isNotEmpty ? safe : rankedOrdered.map((x) => x.v))
                .take(max(1, minAdds)),
          );
        }
        for (final video in fresh) {
          existingIds.add(video.id.value);
          _radioSeenIds.add(video.id.value);
        }
        if (fresh.isNotEmpty && mounted) {
          setState(() => _playQueue = [..._playQueue, ...fresh]);
          _notifyQueueChanged();
          _updateRelatedArtists();
        }
        if (fresh.isEmpty) {
          _seedUpcomingFromLocalTaste(seed, minUpcoming: max(2, minAdds));
          _notifyQueueChanged();
        }
        return;
      }

      for (final v in ytMix) {
        addCandidate(v, 3.75);
      }

      for (final v in ytNext) {
        addCandidate(v, 3.2);
      }

      final related = await _fetchYoutubeRelated(seed, limit: 72);
      for (final v in related) {
        addCandidate(v, 2.55);
      }

      for (final q in _radioQueriesFor(seed)) {
        if (bestById.length >= 160) break;
        final batch = await _searchMusic(
          q,
          limit: 28,
          strictSingles: true,
          personalize: false,
          excludeBlocked: true,
        );
        for (final v in batch) {
          addCandidate(v, 0.0);
        }
      }

      final ranked = bestById.values
          .map((item) => (
                v: item.v,
                score: () {
                  final candText = '${item.v.title} ${item.v.author}'.toLowerCase();
                  final candTags = _extractMusicTags(candText);
                  final candMood = _primaryMoodTag(candTags);
                  final candArtist = _primaryArtistKey(item.v.author);
                  final candLanguage = _detectLanguageTag(candText);
                  final tailAffinity = playedTail
                          .take(4)
                          .map((anchor) =>
                              _contextualSeedAffinity(anchor, item.v, profile, strict: true) * 0.52 +
                              _transitionAffinityScore(anchor, item.v, profile, strict: true) * 0.34)
                          .fold<double>(0.0, (sum, x) => sum + x) /
                      max(1, min(4, playedTail.length));
                  final queueArtistPenalty =
                      max(0, (queueArtistCount[candArtist] ?? 0) - 1) * (0.75 + longSessionTightening * 0.45);
                  final tailArtistPenalty =
                      candArtist == tailLastArtist ? (1.05 + longSessionTightening * 0.4) : 0.0;
                  final tailSeenPenalty = tailArtists.contains(candArtist)
                      ? (0.45 + longSessionTightening * 0.25)
                      : 0.0;
                  final moodPenalty = tailMood != null && candMood != null && candMood != tailMood
                      ? _vibeClashPenalty(tailTags, candTags, strict: false) *
                          (0.45 + longSessionTightening * 0.2)
                      : 0.0;
                  final langPenalty = tailLanguage != candLanguage
                      ? (0.4 + longSessionTightening * 0.25)
                      : 0.0;
                  return _radioRelevanceScore(seed, item.v, profile) +
                      tailAffinity +
                      (tailMood != null && candMood == tailMood ? 0.7 : 0.0) +
                      (_seedAffinityScore(item.v, radioSeeds) * 1.15) +
                      (_contextualSeedAffinity(
                            seed,
                            item.v,
                            profile,
                            strict: true,
                          ) *
                          1.8) +
                      item.sourceBoost -
                      queueArtistPenalty -
                      tailArtistPenalty -
                      tailSeenPenalty -
                      moodPenalty -
                      langPenalty;
                }()
              ))
          .toList()
        ..sort((a, b) => b.score.compareTo(a.score));

      final fresh = _pickDiverseRadioCandidates(
        ranked,
        seed: seed,
        minAdds: minAdds,
        strongContext: strongContext,
      );

      // Last fallback: avoid empty queue if network/query quality is low.
      if (fresh.isEmpty && ranked.isNotEmpty) {
        final qualityFloor = _currentIndex >= 10 ? 4.4 : 3.2;
        final safe = ranked.where((x) => x.score >= qualityFloor).map((x) => x.v).toList();
        fresh.addAll(
          (safe.isNotEmpty ? safe : ranked.map((x) => x.v)).take(minAdds),
        );
      }

      for (final v in fresh) {
        existingIds.add(v.id.value);
        _radioSeenIds.add(v.id.value);
      }
      if (fresh.isNotEmpty && mounted) {
        setState(() => _playQueue = [..._playQueue, ...fresh]);
        _notifyQueueChanged();
        _updateRelatedArtists();
      }
    } catch (e) {
      debugPrint('[Radio] append error: $e');
    } finally {
      _radioQueueFilling = false;
    }
  }

  int _radioStrategyIndex = 0; // cycles through strategies each call

  List<Video> _pickDiverseRadioCandidates(
    List<({Video v, double score})> ranked, {
    required Video seed,
    required int minAdds,
    bool strongContext = false,
  }) {
    final out = <Video>[];
    final outIds = <String>{};
    final existingCountByArtist = <String, int>{};
    for (final qv in _playQueue) {
      final k = _primaryArtistKey(qv.author);
      existingCountByArtist[k] = (existingCountByArtist[k] ?? 0) + 1;
    }

    final seedArtist = _primaryArtistKey(seed.author);
    final seedText =
        '${_cleanTitle(seed.title)} ${_cleanAuthor(seed.author)}'.toLowerCase();
    final seedTags = _extractMusicTags(seedText);
    final seedMood = _primaryMoodTag(seedTags);
    final seedLang = _detectLanguageTag(seedText);
    final longSessionTightening = _currentIndex >= 10 ? 1.0 : 0.0;
    final addedArtists = <String>{};
    final familiarityBias = strongContext
        ? (0.48 + (_behaviorTasteConfidence() * 0.14)).clamp(0.48, 0.66)
        : (0.70 + (_behaviorTasteConfidence() * 0.14)).clamp(0.70, 0.86);
    final familiarTarget =
        (minAdds * familiarityBias).round().clamp(1, minAdds);
    final minUniqueArtists =
        strongContext ? (minAdds >= 8 ? 4 : 3) : (minAdds >= 8 ? 3 : 2);
    final seedArtistCap =
        strongContext ? (minAdds >= 8 ? 2 : 1) : (minAdds >= 8 ? 3 : 2);
    final otherArtistCap = strongContext ? 1 : 2;

    bool canAdd(
      Video v, {
      required int seedCap,
      required int otherCap,
      bool requireNewArtist = false,
    }) {
      if (outIds.contains(v.id.value)) return false;
      final k = _primaryArtistKey(v.author);
      final current = (existingCountByArtist[k] ?? 0);
      final cap = (k == seedArtist) ? seedCap : otherCap;
      if (current >= cap) return false;
      if (requireNewArtist && addedArtists.contains(k)) return false;
      if (k == seedArtist && addedArtists.length < minUniqueArtists) {
        return false;
      }
      existingCountByArtist[k] = current + 1;
      addedArtists.add(k);
      outIds.add(v.id.value);
      out.add(v);
      return true;
    }

    final adjusted = ranked.map((x) {
      final title = _cleanTitle(x.v.title);
      final text = '${x.v.title} ${x.v.author}'.toLowerCase();
      final tags = _extractMusicTags(text);
      final mood = _primaryMoodTag(tags);
      final lang = _detectLanguageTag(text);
      var tuned = x.score;
      tuned -=
          (_quickPickExposurePenalty[x.v.id.value.toLowerCase()] ?? 0.0) * 0.58;
      if (_looksLikeCompilation(title)) tuned -= 2.15;
      if (_looksLikeShortForm(text)) tuned -= 1.7;
      if (!_isDurationMusicFriendly(x.v.duration, strictSingles: true)) {
        tuned -= 1.45;
      } else if (x.v.duration != null) {
        final secs = x.v.duration!.inSeconds;
        if (secs >= 130 && secs <= 370) tuned += 0.55;
        if (secs > 520) tuned -= 0.55;
      }
      if (longSessionTightening > 0) {
        final clash = _vibeClashPenalty(seedTags, tags, strict: true);
        if (seedMood != null && mood != null && mood != seedMood) {
          tuned -= 1.6;
        }
        if (seedLang.isNotEmpty && lang.isNotEmpty && seedLang != lang) {
          tuned -= 1.1;
        }
        tuned -= clash * 1.05;
      }
      return (v: x.v, score: tuned);
    }).toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    final familiarFloor = longSessionTightening > 0 ? 5.1 : 4.35;
    final broadFloor = longSessionTightening > 0 ? 3.25 : 2.35;
    final familiar = adjusted.where((x) => x.score >= familiarFloor).toList();
    final broad = adjusted.where((x) => x.score >= broadFloor).toList();

    // Pass 1: fill mostly with familiar tracks.
    for (final item in familiar) {
      if (out.length >= familiarTarget) break;
      canAdd(item.v, seedCap: seedArtistCap, otherCap: otherArtistCap);
    }

    // Pass 2: ensure at least a few unique artists.
    if (addedArtists.length < minUniqueArtists) {
      for (final item in familiar) {
        if (out.length >= familiarTarget) break;
        if (canAdd(
          item.v,
          seedCap: seedArtistCap,
          otherCap: otherArtistCap,
          requireNewArtist: true,
        )) {
          if (addedArtists.length >= minUniqueArtists) break;
        }
      }
    }

    // Pass 3: fill with broader but still related tracks.
    for (final item in broad) {
      if (out.length >= minAdds) break;
      canAdd(item.v, seedCap: seedArtistCap, otherCap: otherArtistCap);
    }

    // Pass 4: relaxed fill if still short.
    for (final item in adjusted) {
      if (out.length >= minAdds) break;
      canAdd(item.v, seedCap: seedArtistCap + 1, otherCap: otherArtistCap + 1);
    }

    return out;
  }

  // ---
  // BEAST AI v2 Full taste profile from ALL liked songs + history
  // ---

  double _listeningLogWeight(int index, int startedAtMs) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final ageHours = ((nowMs - startedAtMs) / (1000 * 60 * 60))
        .clamp(0, 24 * 365)
        .toDouble();
    final freshness = 1.0 / (1.0 + (ageHours / 96.0));
    final depth = 1.0 / (1.0 + (index * 0.035));
    return (freshness * depth).clamp(0.04, 1.0).toDouble();
  }

  Map<String, dynamic> _buildListeningBehaviorSignals({int limit = 420}) {
    final artistBoost = <String, double>{};
    final recentArtistBoost = <String, double>{};
    final videoBoost = <String, double>{};
    final genreBoost = <String, double>{};
    final langBoost = <String, double>{};
    final hourGenreBoost = <String, double>{};
    final skipVideoPenalty = <String, double>{};
    final skipArtistPenalty = <String, double>{};
    final recentPlayCount = <String, int>{};
    final contextSignals = <String>[];

    final now = DateTime.now();
    final nowHour = now.hour;
    final logs = _listeningLogs.take(limit).toList();

    for (int i = 0; i < logs.length; i++) {
      final e = logs[i];
      final startedAtMs = (e['startedAtMs'] as num?)?.toInt() ?? 0;
      if (startedAtMs <= 0) continue;
      final features = _trackFeaturesFromLogEntry(e, strictSingles: true);
      if (features == null || _isBlockedTrackFeatures(features)) continue;

      var w = _listeningLogWeight(i, startedAtMs);
      final artistKey = features.authorKey;
      final lang = features.language;
      final tags = features.tags;
      final completionRatio =
          ((e['completionRatio'] as num?)?.toDouble() ?? 0.0)
              .clamp(0.0, 1.5)
              .toDouble();
      final completed = e['completed'] == true;

      if (completionRatio > 0) {
        if (completionRatio >= 0.92 || completed) {
          w *= 1.28;
        } else if (completionRatio < 0.25) {
          w *= 0.42;
        } else if (completionRatio < 0.45) {
          w *= 0.72;
        }
      }

      if (artistKey.isNotEmpty) {
        artistBoost[artistKey] = (artistBoost[artistKey] ?? 0.0) + (w * 2.0);
      }
      final videoId = features.idKey;
      if (videoId.isNotEmpty) {
        videoBoost[videoId] = (videoBoost[videoId] ?? 0.0) + (w * 1.7);
      }
      if (lang.isNotEmpty) {
        langBoost[lang] = (langBoost[lang] ?? 0.0) + (w * 1.15);
      }
      if (tags.isNotEmpty) {
        final perTag = (w * 1.5) / tags.length;
        for (final tag in tags) {
          genreBoost[tag] = (genreBoost[tag] ?? 0.0) + perTag;
        }
      }

      final startedAt = DateTime.fromMillisecondsSinceEpoch(startedAtMs);
      final age = now.difference(startedAt);
      if (age.inHours <= 96 && videoId.isNotEmpty) {
        recentPlayCount[videoId] = (recentPlayCount[videoId] ?? 0) + 1;
      }
      if (!completed && completionRatio > 0 && completionRatio < 0.3) {
        final penaltyWeight = ((0.35 - completionRatio).clamp(0.05, 0.35) * w);
        if (videoId.isNotEmpty) {
          skipVideoPenalty[videoId] =
              (skipVideoPenalty[videoId] ?? 0.0) + (penaltyWeight * 4.0);
        }
        if (artistKey.isNotEmpty) {
          skipArtistPenalty[artistKey] =
              (skipArtistPenalty[artistKey] ?? 0.0) + (penaltyWeight * 2.4);
        }
      }
      if (age.inHours <= 120 && artistKey.isNotEmpty) {
        recentArtistBoost[artistKey] =
            (recentArtistBoost[artistKey] ?? 0.0) + (w * 1.8);
      }
      if (age.inDays <= 30 && tags.isNotEmpty) {
        final rawDiff = (startedAt.hour - nowHour).abs();
        final hourDiff = rawDiff > 12 ? 24 - rawDiff : rawDiff;
        final timeMatch = ((4 - hourDiff).clamp(0, 4) / 4).toDouble();
        if (timeMatch > 0) {
          final perTag = (timeMatch * w * 1.1) / tags.length;
          for (final tag in tags) {
            hourGenreBoost[tag] = (hourGenreBoost[tag] ?? 0.0) + perTag;
          }
        }
      }

      if (w >= 0.42) {
        final signal =
            _normalizeSignalKey('${features.title} ${features.author}');
        if (signal.isNotEmpty) contextSignals.add(signal);
      }
    }

    _trimSignalMap(artistBoost, maxEntries: 160);
    _trimSignalMap(recentArtistBoost, maxEntries: 120);
    _trimSignalMap(videoBoost, maxEntries: 420);
    _trimSignalMap(genreBoost, maxEntries: 120);
    _trimSignalMap(langBoost, maxEntries: 20);
    _trimSignalMap(hourGenreBoost, maxEntries: 90);
    _trimSignalMap(skipVideoPenalty, maxEntries: 260);
    _trimSignalMap(skipArtistPenalty, maxEntries: 160);

    return {
      'artistBoost': artistBoost,
      'recentArtistBoost': recentArtistBoost,
      'videoBoost': videoBoost,
      'genreBoost': genreBoost,
      'langBoost': langBoost,
      'hourGenreBoost': hourGenreBoost,
      'skipVideoPenalty': skipVideoPenalty,
      'skipArtistPenalty': skipArtistPenalty,
      'recentPlayCount': recentPlayCount,
      'contextText': contextSignals.take(18).join(' '),
    };
  }

  Map<String, dynamic> _buildSessionMomentumSignals({int window = 42}) {
    final artistMomentum = <String, double>{};
    final genreMomentum = <String, double>{};
    final langMomentum = <String, double>{};
    final videoPenalty = <String, double>{};
    final seenIds = <String>{};

    final logs = _listeningLogs.take(window).toList();
    for (int i = 0; i < logs.length; i++) {
      final e = logs[i];
      final features = _trackFeaturesFromLogEntry(e, strictSingles: true);
      if (features == null || _isBlockedTrackFeatures(features)) continue;
      final videoId = features.idKey;
      if (videoId.isNotEmpty && i < 18) seenIds.add(videoId);

      final artistKey = features.authorKey;
      final tags = features.tags;
      final lang = features.language;
      final completionRatio =
          ((e['completionRatio'] as num?)?.toDouble() ?? 0.0)
              .clamp(0.0, 1.5)
              .toDouble();
      final completed = e['completed'] == true;
      final strongPositive = completed || completionRatio >= 0.72;
      final strongNegative = completionRatio > 0 && completionRatio <= 0.30;
      if (!strongPositive && !strongNegative) continue;

      final recency = (1.0 / (1.0 + (i * 0.24))).clamp(0.16, 1.0).toDouble();
      final signed = strongPositive
          ? recency * (0.85 + completionRatio.clamp(0.0, 1.2)) * 1.1
          : -recency *
              (0.75 + ((0.36 - completionRatio).clamp(0.08, 0.36) * 2.6));

      if (artistKey.isNotEmpty) {
        artistMomentum[artistKey] = (artistMomentum[artistKey] ?? 0.0) + signed;
      }
      if (lang.isNotEmpty) {
        langMomentum[lang] = (langMomentum[lang] ?? 0.0) + (signed * 0.52);
      }
      if (tags.isNotEmpty) {
        final perTag = (signed * 0.88) / tags.length;
        for (final tag in tags) {
          genreMomentum[tag] = (genreMomentum[tag] ?? 0.0) + perTag;
        }
      }
      if (strongNegative && videoId.isNotEmpty) {
        videoPenalty[videoId] =
            (videoPenalty[videoId] ?? 0.0) + (signed.abs() * 1.8);
      }
    }

    _trimSignalMap(artistMomentum, maxEntries: 140);
    _trimSignalMap(genreMomentum, maxEntries: 90);
    _trimSignalMap(langMomentum, maxEntries: 20);
    _trimSignalMap(videoPenalty, maxEntries: 180);

    return {
      'artistMomentum': artistMomentum,
      'genreMomentum': genreMomentum,
      'langMomentum': langMomentum,
      'videoPenalty': videoPenalty,
      'seenIds': seenIds.take(140).toSet(),
    };
  }

  Map<String, dynamic> _buildTransitionSignals({int limit = 720}) {
    final artistNextArtist = <String, Map<String, double>>{};
    final tagNextTag = <String, Map<String, double>>{};
    final langNextLang = <String, Map<String, double>>{};
    final trackNextArtist = <String, Map<String, double>>{};
    final trackNextTag = <String, Map<String, double>>{};
    final trackNextLang = <String, Map<String, double>>{};

    final logs = _listeningLogs.take(limit).toList().reversed.toList();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    Map<String, dynamic>? previous;
    _TrackFeatures? previousFeatures;

    for (final current in logs) {
      final currentFeatures =
          _trackFeaturesFromLogEntry(current, strictSingles: true);
      if (currentFeatures == null || _isBlockedTrackFeatures(currentFeatures)) {
        previous = null;
        previousFeatures = null;
        continue;
      }

      if (previous != null && previousFeatures != null) {
        final prevStartedAtMs = (previous['startedAtMs'] as num?)?.toInt() ?? 0;
        final currentStartedAtMs =
            (current['startedAtMs'] as num?)?.toInt() ?? 0;
        final gapMs = currentStartedAtMs - prevStartedAtMs;
        if (gapMs > 0 && gapMs <= const Duration(minutes: 70).inMilliseconds) {
          final prevCompletion =
              ((previous['completionRatio'] as num?)?.toDouble() ?? 0.0)
                  .clamp(0.0, 1.5)
                  .toDouble();
          final currentCompletion =
              ((current['completionRatio'] as num?)?.toDouble() ?? 0.0)
                  .clamp(0.0, 1.5)
                  .toDouble();
          final prevCompleted = previous['completed'] == true;
          final currentCompleted = current['completed'] == true;
          final prevPositive = prevCompleted || prevCompletion >= 0.48;
          final currentPositive = currentCompleted || currentCompletion >= 0.18;

          if (prevPositive && currentPositive) {
            final ageHours = ((nowMs - currentStartedAtMs) / (1000 * 60 * 60))
                .clamp(0, 24 * 365)
                .toDouble();
            final freshness = 1.0 / (1.0 + (ageHours / 168.0));
            final gapRatio =
                (gapMs / const Duration(minutes: 70).inMilliseconds)
                    .clamp(0.0, 1.0)
                    .toDouble();
            final continuity = 1.0 - (gapRatio * 0.55);
            final prevStrength =
                prevCompleted ? 1.16 : (0.52 + prevCompletion.clamp(0.0, 1.0));
            final currentStrength = currentCompleted
                ? 1.06
                : (0.38 + currentCompletion.clamp(0.0, 1.0));
            final weight =
                (freshness * continuity * prevStrength * currentStrength)
                    .clamp(0.08, 2.8)
                    .toDouble();

            if (previousFeatures.authorKey.isNotEmpty &&
                currentFeatures.authorKey.isNotEmpty) {
              _bumpNestedSignal(
                artistNextArtist,
                previousFeatures.authorKey,
                currentFeatures.authorKey,
                weight * 1.18,
              );
            }
            if (previousFeatures.trackKey.isNotEmpty &&
                currentFeatures.authorKey.isNotEmpty) {
              _bumpNestedSignal(
                trackNextArtist,
                previousFeatures.trackKey,
                currentFeatures.authorKey,
                weight,
              );
            }
            if (previousFeatures.language.isNotEmpty &&
                currentFeatures.language.isNotEmpty) {
              _bumpNestedSignal(
                langNextLang,
                previousFeatures.language,
                currentFeatures.language,
                weight * 0.82,
              );
            }
            if (previousFeatures.trackKey.isNotEmpty &&
                currentFeatures.language.isNotEmpty) {
              _bumpNestedSignal(
                trackNextLang,
                previousFeatures.trackKey,
                currentFeatures.language,
                weight * 0.72,
              );
            }
            if (previousFeatures.tags.isNotEmpty &&
                currentFeatures.tags.isNotEmpty) {
              final pairCount = max(1,
                  previousFeatures.tags.length * currentFeatures.tags.length);
              final perPair = (weight * 0.72) / pairCount;
              for (final sourceTag in previousFeatures.tags) {
                for (final targetTag in currentFeatures.tags) {
                  _bumpNestedSignal(
                    tagNextTag,
                    sourceTag,
                    targetTag,
                    perPair,
                  );
                }
              }
            }
            if (previousFeatures.trackKey.isNotEmpty &&
                currentFeatures.tags.isNotEmpty) {
              final perTag = (weight * 0.62) / currentFeatures.tags.length;
              for (final tag in currentFeatures.tags) {
                _bumpNestedSignal(
                  trackNextTag,
                  previousFeatures.trackKey,
                  tag,
                  perTag,
                );
              }
            }
          }
        }
      }

      previous = current;
      previousFeatures = currentFeatures;
    }

    _trimNestedSignalMap(artistNextArtist, maxParents: 160, maxChildren: 8);
    _trimNestedSignalMap(tagNextTag, maxParents: 70, maxChildren: 6);
    _trimNestedSignalMap(langNextLang, maxParents: 16, maxChildren: 5);
    _trimNestedSignalMap(trackNextArtist, maxParents: 200, maxChildren: 6);
    _trimNestedSignalMap(trackNextTag, maxParents: 200, maxChildren: 5);
    _trimNestedSignalMap(trackNextLang, maxParents: 200, maxChildren: 4);

    return {
      'artistNextArtist': artistNextArtist,
      'tagNextTag': tagNextTag,
      'langNextLang': langNextLang,
      'trackNextArtist': trackNextArtist,
      'trackNextTag': trackNextTag,
      'trackNextLang': trackNextLang,
    };
  }

  /// Builds a rich taste profile from liked songs + history, like Spotify/YT Music.
  /// Returns: top artists, top genres, language mix, energy level, mood
  Map<String, dynamic> _buildTasteProfile() {
    final allVideos = [
      ..._ytLikedVideos, // ALL liked songs (up to 1000)
      ..._likedPlaylist.videos, // locally liked songs
      ..._history, // recently played
      ..._quickRow1.take(72), // active YT/home quick picks
      ..._ytMusicHomeShelves
          .take(5)
          .expand((section) => section.videos.take(16)),
      ..._ytHomeMixes.take(5).expand((playlist) => playlist.videos.take(20)),
    ]
        .where((video) =>
            _isMusicCandidate(video) && !_isRecommendationBlocked(video))
        .toList();
    final logSignals = _buildListeningBehaviorSignals(limit: 420);
    final sessionSignals = _buildSessionMomentumSignals(window: 42);
    final transitionSignals = _buildTransitionSignals(limit: 720);
    final logArtistBoost = logSignals['artistBoost'] as Map<String, double>? ??
        const <String, double>{};
    final recentArtistBoost =
        logSignals['recentArtistBoost'] as Map<String, double>? ??
            const <String, double>{};
    final logVideoBoost = logSignals['videoBoost'] as Map<String, double>? ??
        const <String, double>{};
    final logGenreBoost = logSignals['genreBoost'] as Map<String, double>? ??
        const <String, double>{};
    final hourGenreBoost =
        logSignals['hourGenreBoost'] as Map<String, double>? ??
            const <String, double>{};
    final logLangBoost = logSignals['langBoost'] as Map<String, double>? ??
        const <String, double>{};
    final skipVideoPenalty =
        logSignals['skipVideoPenalty'] as Map<String, double>? ??
            const <String, double>{};
    final skipArtistPenalty =
        logSignals['skipArtistPenalty'] as Map<String, double>? ??
            const <String, double>{};
    final recentPlayCount =
        logSignals['recentPlayCount'] as Map<String, int>? ??
            const <String, int>{};
    final logContextText = logSignals['contextText'] as String? ?? '';
    final sessionArtistMomentum =
        sessionSignals['artistMomentum'] as Map<String, double>? ??
            const <String, double>{};
    final sessionGenreMomentum =
        sessionSignals['genreMomentum'] as Map<String, double>? ??
            const <String, double>{};
    final sessionLangMomentum =
        sessionSignals['langMomentum'] as Map<String, double>? ??
            const <String, double>{};
    final sessionVideoPenalty =
        sessionSignals['videoPenalty'] as Map<String, double>? ??
            const <String, double>{};
    final sessionSeenIds =
        sessionSignals['seenIds'] as Set<String>? ?? <String>{};

    if (allVideos.isEmpty &&
        _listeningLogs.isEmpty &&
        _artistActionBoost.isEmpty &&
        _genreActionBoost.isEmpty &&
        _langActionBoost.isEmpty &&
        sessionArtistMomentum.isEmpty &&
        sessionGenreMomentum.isEmpty &&
        sessionLangMomentum.isEmpty) {
      return {};
    }

    // Artist frequency (Spotify-style "top artists")
    final artistAffinity = <String, int>{};
    final artistLabelByKey = <String, String>{};
    for (final v in allVideos) {
      final a = _cleanAuthor(v.author).trim();
      if (a.isEmpty) continue;
      final key = _primaryArtistKey(a);
      if (key.isEmpty) continue;
      artistAffinity[key] = (artistAffinity[key] ?? 0) + 1;
      artistLabelByKey.putIfAbsent(key, () => a);
    }
    for (final entry in _artistActionBoost.entries) {
      final key = _primaryArtistKey(entry.key);
      if (key.isEmpty) continue;
      final delta = (entry.value * 1.9).round();
      if (delta == 0) continue;
      final next = (artistAffinity[key] ?? 0) + delta;
      if (next <= 0) {
        artistAffinity.remove(key);
      } else {
        artistAffinity[key] = next;
      }
      artistLabelByKey.putIfAbsent(key, () => _cleanAuthor(entry.key));
    }
    for (final entry in logArtistBoost.entries) {
      final key = _primaryArtistKey(entry.key);
      if (key.isEmpty) continue;
      final delta = (entry.value * 2.2).round();
      if (delta == 0) continue;
      artistAffinity[key] = (artistAffinity[key] ?? 0) + delta;
      artistLabelByKey.putIfAbsent(key, () => _cleanAuthor(entry.key));
    }
    for (final entry in recentArtistBoost.entries) {
      final key = _primaryArtistKey(entry.key);
      if (key.isEmpty) continue;
      final delta = (entry.value * 2.6).round();
      if (delta == 0) continue;
      artistAffinity[key] = (artistAffinity[key] ?? 0) + delta;
      artistLabelByKey.putIfAbsent(key, () => _cleanAuthor(entry.key));
    }
    for (final entry in sessionArtistMomentum.entries) {
      final key = _primaryArtistKey(entry.key);
      if (key.isEmpty) continue;
      final delta = (entry.value * 3.2).round();
      if (delta == 0) continue;
      final next = (artistAffinity[key] ?? 0) + delta;
      if (next <= 0) {
        artistAffinity.remove(key);
      } else {
        artistAffinity[key] = next;
      }
      artistLabelByKey.putIfAbsent(key, () => _cleanAuthor(entry.key));
    }
    final topArtists = (artistAffinity.entries.toList()
          ..removeWhere((e) => e.value <= 0)
          ..sort((a, b) => b.value.compareTo(a.value)))
        .take(15)
        .map((e) => artistLabelByKey[e.key] ?? e.key)
        .toList();

    // Genre frequency from titles + authors
    final allText =
        allVideos.map((v) => '${v.title} ${v.author}').join(' ').toLowerCase();
    final behaviorText = (_queryActionBoost.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value)))
        .where((e) => e.value > 0.4)
        .take(12)
        .map((e) => e.key)
        .join(' ');

    const genreKeywords = <String, String>{
      'lofi': 'lofi',
      'lo-fi': 'lofi',
      'study': 'lofi',
      'chill': 'chill',
      'relax': 'chill',
      'sad': 'sad',
      'heartbreak': 'sad',
      'breakup': 'sad',
      'happy': 'happy',
      'party': 'happy',
      'upbeat': 'happy',
      'love': 'romantic',
      'romantic': 'romantic',
      'dil': 'romantic',
      'ishq': 'romantic',
      'pyaar': 'romantic',
      'mohabbat': 'romantic',
      'hustle': 'motivational',
      'grind': 'motivational',
      'motivat': 'motivational',
      'workout': 'workout',
      'gym': 'workout',
      'sleep': 'sleep',
      'meditation': 'sleep',
      'calm': 'sleep',
      'acoustic': 'acoustic',
      'unplugged': 'acoustic',
      'ukulele': 'acoustic',
      'anuv jain': 'acoustic',
      'prateek kuhad': 'acoustic',
      'aditya rikhari': 'acoustic',
      'punjabi': 'punjabi',
      'bhangra': 'punjabi',
      'diljit': 'punjabi',
      'hindi': 'hindi',
      'bollywood': 'hindi',
      'yaar': 'hindi',
      'tamil': 'tamil',
      'kollywood': 'tamil',
      'telugu': 'telugu',
      'tollywood': 'telugu',
      'rap': 'hip-hop',
      'hip hop': 'hip-hop',
      'hip-hop': 'hip-hop',
      'trap': 'hip-hop',
      'kr\$na': 'hip-hop',
      'krsna': 'hip-hop',
      'divine': 'hip-hop',
      'emiway': 'hip-hop',
      'raftaar': 'hip-hop',
      'karma': 'hip-hop',
      'seedhe maut': 'hip-hop',
      'edm': 'edm',
      'electronic': 'edm',
      'house': 'edm',
      'techno': 'edm',
      'jazz': 'jazz',
      'blues': 'jazz',
      'rock': 'rock',
      'metal': 'rock',
      'guitar': 'rock',
      'pop': 'pop',
      'indie': 'pop',
      'bedroom pop': 'pop',
      'r&b': 'r&b',
      'rnb': 'r&b',
      'soul': 'r&b',
      'classical': 'classical',
      'orchestra': 'classical',
      'folk': 'folk',
      'sufi': 'folk',
      'reggae': 'reggae',
      'kpop': 'kpop',
      'k-pop': 'kpop',
      'bts': 'kpop',
      'blackpink': 'kpop',
    };

    final genreCounts = <String, int>{};
    for (final v in allVideos) {
      final text = '${v.title} ${v.author}'.toLowerCase();
      for (final entry in genreKeywords.entries) {
        if (text.contains(entry.key)) {
          genreCounts[entry.value] = (genreCounts[entry.value] ?? 0) + 1;
        }
      }
    }
    for (final entry in _genreActionBoost.entries) {
      final delta = (entry.value * 2.0).round();
      if (delta == 0) continue;
      final next = (genreCounts[entry.key] ?? 0) + delta;
      if (next <= 0) {
        genreCounts.remove(entry.key);
      } else {
        genreCounts[entry.key] = next;
      }
    }
    for (final entry in logGenreBoost.entries) {
      final delta = (entry.value * 2.1).round();
      if (delta == 0) continue;
      genreCounts[entry.key] = (genreCounts[entry.key] ?? 0) + delta;
    }
    for (final entry in hourGenreBoost.entries) {
      final delta = (entry.value * 2.5).round();
      if (delta == 0) continue;
      genreCounts[entry.key] = (genreCounts[entry.key] ?? 0) + delta;
    }
    for (final entry in sessionGenreMomentum.entries) {
      final delta = (entry.value * 3.0).round();
      if (delta == 0) continue;
      final next = (genreCounts[entry.key] ?? 0) + delta;
      if (next <= 0) {
        genreCounts.remove(entry.key);
      } else {
        genreCounts[entry.key] = next;
      }
    }
    final topGenres = (genreCounts.entries.toList()
          ..removeWhere((e) => e.value <= 0)
          ..sort((a, b) => b.value.compareTo(a.value)))
        .take(5)
        .map((e) => e.key)
        .toList();

    // Language detection
    final langCounts = <String, int>{};
    for (final v in allVideos) {
      final text = '${v.title} ${v.author}'.toLowerCase();
      if (text.contains('punjabi') ||
          text.contains('diljit') ||
          text.contains('sidhu')) {
        langCounts['punjabi'] = (langCounts['punjabi'] ?? 0) + 1;
      } else if (text.contains('hindi') ||
          text.contains('bollywood') ||
          text.contains('arijit') ||
          text.contains('yaar') ||
          text.contains('dil')) {
        langCounts['hindi'] = (langCounts['hindi'] ?? 0) + 1;
      } else if (text.contains('tamil') || text.contains('anirudh')) {
        langCounts['tamil'] = (langCounts['tamil'] ?? 0) + 1;
      } else if (text.contains('telugu') || text.contains('sid sriram')) {
        langCounts['telugu'] = (langCounts['telugu'] ?? 0) + 1;
      } else if (text.contains('kpop') ||
          text.contains('bts') ||
          text.contains('blackpink') ||
          text.contains('twice')) {
        langCounts['kpop'] = (langCounts['kpop'] ?? 0) + 1;
      } else {
        langCounts['english'] = (langCounts['english'] ?? 0) + 1;
      }
    }
    for (final entry in _langActionBoost.entries) {
      final delta = (entry.value * 1.8).round();
      if (delta == 0) continue;
      final next = (langCounts[entry.key] ?? 0) + delta;
      if (next <= 0) {
        langCounts.remove(entry.key);
      } else {
        langCounts[entry.key] = next;
      }
    }
    for (final entry in logLangBoost.entries) {
      final delta = (entry.value * 1.9).round();
      if (delta == 0) continue;
      langCounts[entry.key] = (langCounts[entry.key] ?? 0) + delta;
    }
    for (final entry in sessionLangMomentum.entries) {
      final delta = (entry.value * 2.6).round();
      if (delta == 0) continue;
      final next = (langCounts[entry.key] ?? 0) + delta;
      if (next <= 0) {
        langCounts.remove(entry.key);
      } else {
        langCounts[entry.key] = next;
      }
    }
    final topLanguage = langCounts.isEmpty
        ? 'hindi'
        : (langCounts.entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value)))
            .first
            .key;

    return {
      'topArtists': topArtists,
      'topGenres': topGenres,
      'topLanguage': topLanguage,
      'artistLabels': artistLabelByKey,
      'artistAffinity': artistAffinity,
      'genreAffinity': genreCounts,
      'langAffinity': langCounts,
      'allText': '$allText $behaviorText $logContextText'.trim(),
      'logArtistBoost': logArtistBoost,
      'recentArtistBoost': recentArtistBoost,
      'logVideoBoost': logVideoBoost,
      'logGenreBoost': logGenreBoost,
      'hourGenreBoost': hourGenreBoost,
      'logLangBoost': logLangBoost,
      'skipVideoPenalty': skipVideoPenalty,
      'skipArtistPenalty': skipArtistPenalty,
      'recentPlayCount': recentPlayCount,
      'sessionArtistMomentum': sessionArtistMomentum,
      'sessionGenreMomentum': sessionGenreMomentum,
      'sessionLangMomentum': sessionLangMomentum,
      'sessionVideoPenalty': sessionVideoPenalty,
      'sessionSeenIds': sessionSeenIds,
      ...transitionSignals,
      'ytLikedIds': _ytLikedVideos.map((v) => v.id.value).toSet(),
      'totalSongs': allVideos.length + _videoActionBoost.length.clamp(0, 60),
    };
  }

  Set<String> _stringSetFromDynamic(
    dynamic raw, {
    int maxEntries = 220,
  }) {
    if (raw is! Iterable) return <String>{};
    final out = <String>{};
    for (final item in raw) {
      final key = (item ?? '').toString().trim().toLowerCase();
      if (key.isEmpty) continue;
      out.add(key);
      if (out.length >= maxEntries) break;
    }
    return out;
  }

  double _sessionMomentumScore({
    required String videoId,
    required String artistKey,
    required Set<String> tags,
    required String language,
    required Map<String, dynamic> profile,
    bool penalizeSeen = true,
  }) {
    final artistMomentum =
        (profile['sessionArtistMomentum'] as Map<String, double>?) ??
            const <String, double>{};
    final genreMomentum =
        (profile['sessionGenreMomentum'] as Map<String, double>?) ??
            const <String, double>{};
    final langMomentum =
        (profile['sessionLangMomentum'] as Map<String, double>?) ??
            const <String, double>{};
    final sessionVideoPenalty =
        (profile['sessionVideoPenalty'] as Map<String, double>?) ??
            const <String, double>{};
    final sessionSeenIds =
        _stringSetFromDynamic(profile['sessionSeenIds'], maxEntries: 220);

    double score = 0.0;
    if (artistKey.isNotEmpty) score += (artistMomentum[artistKey] ?? 0.0) * 1.7;
    for (final tag in tags.take(6)) {
      score += (genreMomentum[tag] ?? 0.0) * 0.92;
    }
    if (language.isNotEmpty) score += (langMomentum[language] ?? 0.0) * 0.85;
    score -= (sessionVideoPenalty[videoId] ?? 0.0) * 1.2;
    if (penalizeSeen && sessionSeenIds.contains(videoId)) score -= 1.15;
    return score.clamp(-6.5, 7.5).toDouble();
  }

  double _nestedSignalLookup(
    Map<String, Map<String, double>> signals,
    String sourceKey,
    String targetKey,
  ) {
    final source = _normalizeSignalKey(sourceKey);
    final target = _normalizeSignalKey(targetKey);
    if (source.isEmpty || target.isEmpty) return 0.0;
    return signals[source]?[target] ?? 0.0;
  }

  double _transitionAffinityScore(
    Video seed,
    Video candidate,
    Map<String, dynamic> profile, {
    bool strict = false,
  }) {
    final seedFeatures = _trackFeaturesForVideo(seed);
    final candidateFeatures = _trackFeaturesForVideo(candidate);
    final artistNextArtist = _nestedSignalMap(profile['artistNextArtist']);
    final tagNextTag = _nestedSignalMap(profile['tagNextTag']);
    final langNextLang = _nestedSignalMap(profile['langNextLang']);
    final trackNextArtist = _nestedSignalMap(profile['trackNextArtist']);
    final trackNextTag = _nestedSignalMap(profile['trackNextTag']);
    final trackNextLang = _nestedSignalMap(profile['trackNextLang']);

    double score = 0.0;
    if (seedFeatures.authorKey.isNotEmpty &&
        candidateFeatures.authorKey.isNotEmpty) {
      score += _nestedSignalLookup(
            artistNextArtist,
            seedFeatures.authorKey,
            candidateFeatures.authorKey,
          ) *
          1.55;
    }
    if (seedFeatures.trackKey.isNotEmpty &&
        candidateFeatures.authorKey.isNotEmpty) {
      score += _nestedSignalLookup(
            trackNextArtist,
            seedFeatures.trackKey,
            candidateFeatures.authorKey,
          ) *
          1.2;
    }
    if (seedFeatures.language.isNotEmpty &&
        candidateFeatures.language.isNotEmpty) {
      score += _nestedSignalLookup(
            langNextLang,
            seedFeatures.language,
            candidateFeatures.language,
          ) *
          0.95;
      score += _nestedSignalLookup(
            trackNextLang,
            seedFeatures.trackKey,
            candidateFeatures.language,
          ) *
          0.8;
    }

    double tagScore = 0.0;
    for (final seedTag in seedFeatures.tags.take(4)) {
      for (final candidateTag in candidateFeatures.tags.take(4)) {
        tagScore +=
            _nestedSignalLookup(tagNextTag, seedTag, candidateTag) * 0.78;
      }
    }
    for (final candidateTag in candidateFeatures.tags.take(4)) {
      tagScore += _nestedSignalLookup(
            trackNextTag,
            seedFeatures.trackKey,
            candidateTag,
          ) *
          0.62;
    }
    score += tagScore;

    if (strict &&
        score < 0.35 &&
        seedFeatures.authorKey != candidateFeatures.authorKey &&
        seedFeatures.language != candidateFeatures.language &&
        seedFeatures.tags.isNotEmpty &&
        candidateFeatures.tags.isNotEmpty &&
        seedFeatures.tags.intersection(candidateFeatures.tags).isEmpty) {
      score -= 0.85;
    }

    return score.clamp(-2.2, 8.6).toDouble();
  }

  double _multiSeedTransitionScore(
    Video candidate,
    List<Video> seeds,
    Map<String, dynamic> profile,
  ) {
    if (seeds.isEmpty) return 0.0;

    double weighted = 0.0;
    double best = 0.0;
    final maxSeeds = min(5, seeds.length);
    for (int i = 0; i < maxSeeds; i++) {
      final local = _transitionAffinityScore(
        seeds[i],
        candidate,
        profile,
        strict: i == 0,
      );
      if (local <= 0) continue;
      final decay = 1.0 / (1.0 + (i * 0.45));
      weighted += local * decay;
      if (local > best) best = local;
    }
    return (best * 0.72 + weighted * 0.36).clamp(0.0, 8.8).toDouble();
  }

  List<String> _topTransitionArtistLabelsForSeed(
    Video seed,
    Map<String, dynamic> profile, {
    int limit = 2,
  }) {
    final seedFeatures = _trackFeaturesForVideo(seed);
    final artistLabels = (profile['artistLabels'] as Map<String, String>?) ??
        const <String, String>{};
    final seen = <String>{};
    final out = <String>[];

    void collectFrom(dynamic raw, String sourceKey, {int take = 2}) {
      if (sourceKey.isEmpty) return;
      final signals = _nestedSignalMap(raw);
      final bucket = signals[_normalizeSignalKey(sourceKey)];
      if (bucket == null || bucket.isEmpty) return;
      final ranked = bucket.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final entry in ranked.take(take)) {
        final key = entry.key;
        if (!seen.add(key)) continue;
        final label = (artistLabels[key] ?? _cleanAuthor(key)).trim();
        if (label.isEmpty) continue;
        out.add(label);
        if (out.length >= limit) return;
      }
    }

    collectFrom(profile['trackNextArtist'], seedFeatures.trackKey, take: 2);
    if (out.length < limit) {
      collectFrom(profile['artistNextArtist'], seedFeatures.authorKey, take: 3);
    }
    return out.take(limit).toList();
  }

  List<String> _topTransitionTagsForSeeds(
    List<Video> seeds,
    Map<String, dynamic> profile, {
    int limit = 2,
  }) {
    if (seeds.isEmpty) return const <String>[];
    final tagSignals = _nestedSignalMap(profile['tagNextTag']);
    final trackSignals = _nestedSignalMap(profile['trackNextTag']);
    final scoreByTag = <String, double>{};

    final maxSeeds = min(4, seeds.length);
    for (int i = 0; i < maxSeeds; i++) {
      final features = _trackFeaturesForVideo(seeds[i]);
      final decay = 1.0 / (1.0 + (i * 0.5));
      for (final tag in features.tags.take(4)) {
        final bucket = tagSignals[tag];
        if (bucket == null) continue;
        for (final entry in bucket.entries) {
          scoreByTag[entry.key] =
              (scoreByTag[entry.key] ?? 0.0) + (entry.value * decay);
        }
      }
      final trackBucket = trackSignals[features.trackKey];
      if (trackBucket == null) continue;
      for (final entry in trackBucket.entries) {
        scoreByTag[entry.key] =
            (scoreByTag[entry.key] ?? 0.0) + (entry.value * decay * 0.92);
      }
    }

    final ranked = scoreByTag.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return ranked.take(limit).map((e) => e.key).toList();
  }

  double _seedAffinityScore(Video candidate, List<Video> seeds) {
    if (seeds.isEmpty) return 0.0;
    final candText =
        '${_cleanTitle(candidate.title)} ${_cleanAuthor(candidate.author)}';
    final candTokens = _tokenizeSearchText(candText, dropCommonWords: true);
    if (candTokens.isEmpty) return 0.0;
    final candArtist = _primaryArtistKey(candidate.author);
    final candLang = _detectLanguageTag(candText.toLowerCase());

    double weighted = 0.0;
    double best = 0.0;
    final maxSeeds = min(6, seeds.length);
    for (int i = 0; i < maxSeeds; i++) {
      final seed = seeds[i];
      final seedText =
          '${_cleanTitle(seed.title)} ${_cleanAuthor(seed.author)}';
      final seedTokens = _tokenizeSearchText(seedText, dropCommonWords: true);
      if (seedTokens.isEmpty) continue;

      double local = _fuzzyTokenOverlapScore(seedTokens, candTokens) * 0.35;
      if (_primaryArtistKey(seed.author) == candArtist &&
          candArtist.isNotEmpty) {
        local += 1.1;
      }
      if (_detectLanguageTag(seedText.toLowerCase()) == candLang) {
        local += 0.22;
      }
      if (seed.id.value == candidate.id.value) local += 1.5;

      local = local.clamp(0.0, 3.8).toDouble();
      final decay = 1.0 / (1.0 + (i * 0.55));
      weighted += local * decay;
      if (local > best) best = local;
    }

    return (best * 0.9 + weighted * 0.38).clamp(0.0, 5.2).toDouble();
  }

  double _contextualSeedAffinity(
    Video seed,
    Video candidate,
    Map<String, dynamic> profile, {
    bool strict = false,
  }) {
    final seedText = '${_cleanTitle(seed.title)} ${_cleanAuthor(seed.author)}';
    final candText =
        '${_cleanTitle(candidate.title)} ${_cleanAuthor(candidate.author)}';
    final seedTextLower = seedText.toLowerCase();
    final candTextLower = candText.toLowerCase();
    final seedArtist = _primaryArtistKey(seed.author);
    final candArtist = _primaryArtistKey(candidate.author);
    final seedLang = _detectLanguageTag(seedTextLower);
    final candLang = _detectLanguageTag(candTextLower);
    final seedTags = _extractMusicTags(seedTextLower);
    final candTags = _extractMusicTags(candTextLower);
    final topLanguage = profile['topLanguage'] as String? ?? seedLang;
    final seedMood = _primaryMoodTag(seedTags);
    final candMood = _primaryMoodTag(candTags);
    final seedTokens = _tokenizeSearchText(seedText, dropCommonWords: true);
    final candTokens = _tokenizeSearchText(candText, dropCommonWords: true);
    final overlap = candTags.where(seedTags.contains).length;
    final clashPenalty = _vibeClashPenalty(seedTags, candTags, strict: strict);

    double score = 0.0;
    if (seedArtist.isNotEmpty && candArtist == seedArtist) score += 2.4;

    if (seedLang == candLang) {
      score += 2.1;
    } else if (seedLang != topLanguage) {
      score -= strict ? 2.1 : 1.3;
    } else {
      score -= strict ? 1.1 : 0.6;
    }

    score += overlap * 2.2;

    if (seedMood != null) {
      if (candMood == seedMood) {
        score += 1.9;
      } else if (candMood != null) {
        score -= strict ? 2.8 : 1.9;
      } else {
        score -= strict ? 1.0 : 0.35;
      }
    }

    if (seedTags.isNotEmpty && overlap == 0) {
      score -= strict ? 2.2 : 1.2;
    }

    if (seedTokens.isNotEmpty && candTokens.isNotEmpty) {
      score += _fuzzyTokenOverlapScore(seedTokens, candTokens) * 0.5;
    }

    if (candArtist != seedArtist && candLang != seedLang && overlap == 0) {
      score -= strict ? 1.8 : 0.9;
    }
    score -= clashPenalty;

    return score.clamp(-8.0, 9.0).toDouble();
  }

  List<Video> _buildContextualRadioSeeds(
    Video seed,
    Map<String, dynamic> profile,
  ) {
    final out = <Video>[seed];
    final seenIds = <String>{seed.id.value};

    for (final v in _history.take(10)) {
      if (!seenIds.add(v.id.value)) continue;
      if (!_isMusicCandidate(v, strictSingles: true)) continue;
      if (_isRecommendationBlocked(v)) continue;
      if (_contextualSeedAffinity(seed, v, profile) < 1.15) continue;
      out.add(v);
      if (out.length >= 4) break;
    }

    if (_currentIndex + 1 < _playQueue.length) {
      for (final v in _playQueue.skip(_currentIndex + 1).take(10)) {
        if (!seenIds.add(v.id.value)) continue;
        if (!_isMusicCandidate(v, strictSingles: true)) continue;
        if (_isRecommendationBlocked(v)) continue;
        if (_contextualSeedAffinity(seed, v, profile) < 0.98) continue;
        out.add(v);
        if (out.length >= 6) break;
      }
    }

    if (out.length < 6) {
      for (final v in _collectQuickPickSeeds(maxSeeds: 10)) {
        if (!seenIds.add(v.id.value)) continue;
        if (_contextualSeedAffinity(seed, v, profile) < 0.85) continue;
        out.add(v);
        if (out.length >= 6) break;
      }
    }

    return out;
  }

  /// Generates smart search query like YT Music/Spotify "Radio" but from your taste profile
  String _buildRadioQuery(Video v) {
    final profile = _buildTasteProfile();
    final topArtists = profile['topArtists'] as List<String>? ?? [];
    final topGenres = profile['topGenres'] as List<String>? ?? [];
    final topLanguage = profile['topLanguage'] as String? ?? 'hindi';
    final allText = profile['allText'] as String? ?? '';

    final cleanSong = _cleanTitle(v.title);
    final currentText = '$cleanSong ${v.author}'.toLowerCase();

    // Song-first pool (avoid charts/playlist-heavy results).
    final queries = <String>[];

    // Strategy 1: track radio based on currently playing song.
    queries.add('$cleanSong ${v.author} song radio');

    // Strategy 2: top artist from taste profile (different from current artist).
    for (final a in topArtists) {
      if (a.toLowerCase() != v.author.toLowerCase()) {
        queries.add('$a official audio songs');
        break;
      }
    }

    // Strategy 3: top genre from taste profile.
    if (topGenres.isNotEmpty) {
      queries.add(_genreToQuery(topGenres.first));
    }

    // Strategy 4: 2nd genre for exploration.
    if (topGenres.length >= 2) {
      queries.add(_genreToQuery(topGenres[1]));
    }

    // Strategy 5: mood of current track.
    queries.add(_moodQuery(currentText));

    // Strategy 6: language-aware discovery.
    queries.add(_languageDiscoveryQuery(topLanguage, currentText));

    // Strategy 7: third artist signal for diversity.
    if (topArtists.length >= 3) {
      queries.add('${topArtists[2]} latest official songs');
    }

    // Strategy 8: era signal from history.
    queries.add(_eraQuery(allText));

    // Strategy 9: vibe signal.
    queries.add(_vibeQuery(allText + currentText));

    // Strategy 10: cross-language discovery.
    queries.add(_crossLanguageQuery(currentText));

    // Rotate strategy each call so radio remains fresh.
    _radioStrategyIndex = (_radioStrategyIndex + 1) % queries.length;
    return queries[_radioStrategyIndex];
  }

  String _genreToQuery(String genre) {
    const genreQueries = <String, String>{
      'lofi': 'lofi chill beats official audio',
      'chill': 'chill relaxing songs official audio',
      'sad': 'emotional sad songs official audio',
      'happy': 'happy upbeat songs official audio',
      'romantic': 'romantic love songs official audio',
      'motivational': 'motivational hustle songs official audio',
      'workout': 'gym workout high energy songs official audio',
      'sleep': 'calm sleep songs official audio',
      'acoustic': 'acoustic unplugged songs official audio',
      'indie': 'indie acoustic romantic songs official audio',
      'punjabi': 'new punjabi songs official audio',
      'hindi': 'new hindi songs official audio',
      'tamil': 'new tamil songs official audio',
      'telugu': 'new telugu songs official audio',
      'hip-hop': 'hip hop rap songs official audio',
      'edm': 'edm electronic dance songs official audio',
      'jazz': 'jazz smooth soul songs',
      'rock': 'rock guitar songs official audio',
      'pop': 'pop songs official audio',
      'r&b': 'r&b soul neo-soul official audio',
      'classical': 'classical orchestral relaxing music',
      'folk': 'folk acoustic sufi songs official audio',
      'kpop': 'kpop songs official audio',
    };
    return genreQueries[genre] ?? 'latest songs official audio';
  }

  String _languageDiscoveryQuery(String language, String currentText) {
    // Discover songs in your primary language (with official uploads).
    switch (language) {
      case 'hindi':
        return 'new hindi bollywood songs official audio';
      case 'punjabi':
        return 'new punjabi songs official audio';
      case 'tamil':
        return 'new tamil songs official audio';
      case 'telugu':
        return 'new telugu songs official audio';
      case 'kpop':
        return 'new kpop songs official audio';
      default:
        return 'new english songs official audio';
    }
  }

  String _moodQuery(String text) {
    if (text.contains('sad') ||
        text.contains('breakup') ||
        text.contains('miss')) {
      return 'emotional sad songs official audio';
    }
    if (text.contains('happy') ||
        text.contains('party') ||
        text.contains('dance')) {
      return 'happy upbeat dance songs official audio';
    }
    if (text.contains('love') ||
        text.contains('romantic') ||
        text.contains('dil')) {
      return 'romantic love songs official audio';
    }
    if (text.contains('hustle') ||
        text.contains('grind') ||
        text.contains('motivat')) {
      return 'motivational hustle songs official audio';
    }
    if (text.contains('night') ||
        text.contains('midnight') ||
        text.contains('dark')) {
      return 'late night chill songs official audio';
    }
    return 'feel good songs official audio';
  }

  String _crossLanguageQuery(String text) {
    if (text.contains('hindi') ||
        text.contains('bollywood') ||
        text.contains('yaar') ||
        text.contains('dil')) {
      return 'punjabi pop songs official audio';
    }
    if (text.contains('punjabi') || text.contains('bhangra')) {
      return 'hindi romantic songs official audio';
    }
    if (text.contains('tamil') || text.contains('telugu')) {
      return 'hindi pop songs official audio';
    }
    if (text.contains('rap') ||
        text.contains('hip hop') ||
        text.contains('kr\$na') ||
        text.contains('krsna') ||
        text.contains('divine')) {
      return 'international hip hop songs official audio';
    }
    return 'world music songs official audio';
  }

  String _vibeQuery(String text) {
    if (text.contains('lofi') ||
        text.contains('chill') ||
        text.contains('study')) {
      return 'lofi hip hop study music official audio';
    }
    if (text.contains('acoustic') ||
        text.contains('unplugged') ||
        text.contains('ukulele') ||
        text.contains('anuv jain') ||
        text.contains('prateek kuhad') ||
        text.contains('aditya rikhari')) {
      return 'indie acoustic romantic songs official audio';
    }
    if (text.contains('workout') ||
        text.contains('gym') ||
        text.contains('run')) {
      return 'high energy workout songs official audio';
    }
    if (text.contains('meditation') ||
        text.contains('sleep') ||
        text.contains('calm')) {
      return 'calm meditation songs official audio';
    }
    return 'indie pop songs official audio';
  }

  String _eraQuery(String text) {
    if (text.contains('90') ||
        text.contains('classic') ||
        text.contains('old')) {
      return '90s classic songs official audio';
    }
    if (text.contains('2000') ||
        text.contains('retro') ||
        text.contains('2010')) {
      return '2010s throwback songs official audio';
    }
    return 'latest songs official audio';
  }

  void _markQuickPicksServed(List<Video> picks) {
    if (picks.isEmpty) return;

    for (final key in _quickPickExposurePenalty.keys.toList()) {
      final decayed = (_quickPickExposurePenalty[key] ?? 0.0) * 0.76;
      if (decayed < 0.2) {
        _quickPickExposurePenalty.remove(key);
      } else {
        _quickPickExposurePenalty[key] = decayed;
      }
    }

    for (int i = 0; i < picks.length; i++) {
      final id = picks[i].id.value.toLowerCase();
      final bump = i < 4 ? 2.7 : (i < 8 ? 2.1 : 1.35);
      _bumpSignal(_quickPickExposurePenalty, id, bump, min: 0.0, max: 16.0);
    }
    _trimSignalMap(_quickPickExposurePenalty, maxEntries: 900);
    _scheduleSave();
  }

  void _rewardQuickPickSelection(Video video, {double strength = 3.2}) {
    final id = video.id.value.toLowerCase();
    final next = ((_quickPickExposurePenalty[id] ?? 0.0) - strength)
        .clamp(0.0, 16.0)
        .toDouble();
    if (next < 0.15) {
      _quickPickExposurePenalty.remove(id);
    } else {
      _quickPickExposurePenalty[id] = next;
    }
    _recordQuickClick();
    _scheduleSave();
  }

  void _registerManualSkipFeedbackForCurrent() {
    if (_isDownloadPlayback) return;
    final current = _nowPlaying;
    if (current == null) return;

    final playedSecs = _player.position.inSeconds;
    if (playedSecs < 6) return;
    _updateListeningOutcomeForVideo(
      current.id.value,
      playedSecs: playedSecs,
      completed: false,
    );

    final totalSecs =
        _player.duration?.inSeconds ?? current.duration?.inSeconds ?? 0;
    final ratio = totalSecs > 0 ? (playedSecs / totalSecs) : 0.0;

    if (playedSecs <= 35 || ratio <= 0.22) {
      if (_currentFromQuick) {
        _recordQuickSkipEarly();
      }
      _registerFeedback(current, weight: -0.42, source: 'manual_skip_early');
      return;
    }
    if (playedSecs <= 95 || ratio <= 0.45) {
      _registerFeedback(current, weight: -0.18, source: 'manual_skip_mid');
    }
  }

  // ---

  // Load home sections
  List<Video> _collectQuickPickSeeds({int maxSeeds = 14}) {
    final seeds = <Video>[];
    final seenIds = <String>{};

    void add(Video? v) {
      if (v == null) return;
      if (!_isMusicCandidate(v, strictSingles: true)) return;
      if (_isRecommendationBlocked(v)) return;
      if (!seenIds.add(v.id.value)) return;
      seeds.add(v);
    }

    add(_nowPlaying);
    for (final v in _history.take(20)) {
      add(v);
      if (seeds.length >= maxSeeds) break;
    }
    if (seeds.length < maxSeeds) {
      for (final v in _ytLikedVideos.take(80)) {
        add(v);
        if (seeds.length >= maxSeeds) break;
      }
    }
    if (seeds.length < maxSeeds) {
      for (final v in _likedPlaylist.videos.take(80)) {
        add(v);
        if (seeds.length >= maxSeeds) break;
      }
    }
    if (seeds.length < maxSeeds) {
      for (final v in _becauseYouLiked.take(30)) {
        add(v);
        if (seeds.length >= maxSeeds) break;
      }
    }
    return seeds;
  }

  List<Video> _takeArtistDiverse(
    Iterable<Video> source, {
    required int target,
    int artistCap = 2,
    int relaxedArtistCap = 4,
  }) {
    if (target <= 0) return const <Video>[];
    final candidates = <Video>[];
    final candidateIds = <String>{};
    for (final video in source) {
      if (!_isMusicCandidate(video, strictSingles: true)) continue;
      if (_isRecommendationBlocked(video)) continue;
      if (!candidateIds.add(video.id.value)) continue;
      candidates.add(video);
    }
    if (candidates.isEmpty) return const <Video>[];

    final picks = <Video>[];
    final pickedIds = <String>{};
    final artistUsage = <String, int>{};

    void addWithCap(int cap) {
      if (picks.length >= target) return;
      for (final video in candidates) {
        if (picks.length >= target) return;
        if (!pickedIds.add(video.id.value)) continue;
        final rawArtist = _primaryArtistKey(video.author);
        final artist = rawArtist.isEmpty ? '__unknown_artist__' : rawArtist;
        final used = artistUsage[artist] ?? 0;
        if (used >= cap) {
          pickedIds.remove(video.id.value);
          continue;
        }
        artistUsage[artist] = used + 1;
        picks.add(video);
      }
    }

    final startCap = artistCap.clamp(1, 10);
    final endCap = max(startCap, relaxedArtistCap.clamp(startCap, 14));
    for (int cap = startCap; cap <= endCap && picks.length < target; cap++) {
      addWithCap(cap);
    }

    if (picks.length < target) {
      for (final video in candidates) {
        if (picks.length >= target) break;
        if (!pickedIds.add(video.id.value)) continue;
        picks.add(video);
      }
    }
    return picks.take(target).toList();
  }

  // ignore: unused_element
  Future<List<Video>> _buildYtMusicSeededQuickPicks({
    int target = 24,
    int maxSeeds = 4,
  }) async {
    if (target <= 0) return const <Video>[];

    final seeds = <Video>[];
    final seedIds = <String>{};
    final seedArtists = <String>{};

    void addSeed(
      Video? video, {
      bool enforceArtistDiversity = true,
    }) {
      if (video == null) return;
      if (!_isMusicCandidate(video, strictSingles: true)) return;
      if (_isRecommendationBlocked(video)) return;
      if (!seedIds.add(video.id.value)) return;
      final artistKey = _primaryArtistKey(video.author);
      if (enforceArtistDiversity && artistKey.isNotEmpty) {
        if (seedArtists.contains(artistKey)) return;
        seedArtists.add(artistKey);
      }
      seeds.add(video);
    }

    addSeed(_nowPlaying, enforceArtistDiversity: false);
    for (final video in _history.take(24)) {
      addSeed(video);
      if (seeds.length >= maxSeeds) break;
    }
    if (seeds.length < maxSeeds) {
      for (final video in _ytLikedVideos.take(240)) {
        addSeed(video);
        if (seeds.length >= maxSeeds) break;
      }
    }
    if (seeds.length < maxSeeds) {
      for (final video in _likedPlaylist.videos.take(180)) {
        addSeed(video);
        if (seeds.length >= maxSeeds) break;
      }
    }
    if (seeds.length < maxSeeds) {
      for (final video in _quickRow1.take(120)) {
        addSeed(video);
        if (seeds.length >= maxSeeds) break;
      }
    }
    if (seeds.isEmpty) return const <Video>[];

    final recentArtists =
        _history.take(20).map((v) => _primaryArtistKey(v.author)).toSet();
    final recentIds = _history.take(24).map((v) => v.id.value).toSet();

    final futures = <Future<List<Video>>>[
      _fetchYtMusicHomeSongs(limit: max(48, target * 2)),
      ...seeds.take(maxSeeds).map((seed) => _fetchYtMusicNextSongs(seed,
          limit: max(32, (target * 3) ~/ max(1, maxSeeds)))),
      ...seeds.take(maxSeeds).map((seed) => _fetchYtMusicMixSongs(seed,
          limit: max(36, (target * 4) ~/ max(1, maxSeeds)))),
    ];

    final batches = await Future.wait<List<Video>>(futures);
    final pool = <Video>[...seeds];
    for (final batch in batches) {
      pool.addAll(batch);
    }

    final candidateLimit = max(220, target * 10);
    final filtered = _filterBlockedRecommendations(
      _filterMusicResults(
        pool,
        limit: candidateLimit,
        strictSingles: true,
      ),
      limit: candidateLimit,
    );
    if (filtered.isEmpty) return const <Video>[];

    final profile = _buildTasteProfile();
    final leadSeed = seeds.first;
    final intentText = (profile['allText'] as String? ?? '').toLowerCase();
    final intentTags = _extractMusicTags(intentText);
    final intentLanguage = _detectLanguageTag(intentText);
    final ranked = filtered
        .map((video) => (
              v: video,
              score: _quickPickScore(
                    video,
                    profile: profile,
                    seedIds: seedIds,
                    seedArtists: seedArtists,
                    recentArtists: recentArtists,
                    recentIds: recentIds,
                    leadSeed: leadSeed,
                    intentTags: intentTags,
                    intentLanguage: intentLanguage,
                  ) +
                  (_seedAffinityScore(video, seeds) * 0.9) +
                  (_contextualSeedAffinity(
                        leadSeed,
                        video,
                        profile,
                        strict: true,
                      ) *
                      0.62) +
                  (seedIds.contains(video.id.value) ? -0.9 : 0.45)
            ))
        .toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    final picks = _pickDiverseQuickPicks(
      ranked,
      target: target,
      seedIds: seedIds,
      seedArtists: seedArtists,
      profile: profile,
    );
    if (picks.length >= target) {
      return picks.take(target).toList();
    }

    final merged = <Video>[...picks, ...ranked.map((item) => item.v)];
    return _takeArtistDiverse(
      merged,
      target: target,
      artistCap: 2,
      relaxedArtistCap: 4,
    );
  }

  String _quickPicksContextLabel(
    List<Video> seeds,
    Map<String, dynamic> profile,
  ) {
    return 'Made for you';
  }

  double _quickPickScore(
    Video v, {
    required Map<String, dynamic> profile,
    required Set<String> seedIds,
    required Set<String> seedArtists,
    required Set<String> recentArtists,
    required Set<String> recentIds,
    Video? leadSeed,
    Set<String> intentTags = const <String>{},
    String intentLanguage = '',
  }) {
    if (_isRecommendationBlocked(v)) return -999.0;
    final id = v.id.value;
    final idKey = id.toLowerCase();
    final title = _cleanTitle(v.title);
    final author = _cleanAuthor(v.author);
    final authorKey = _primaryArtistKey(author);
    final text = '$title $author'.toLowerCase();
    final tags = _extractMusicTags(text);
    final lang = _detectLanguageTag(text);

    final topArtists = (profile['topArtists'] as List<String>? ?? [])
        .take(14)
        .map(_primaryArtistKey)
        .toSet();
    final topGenres = (profile['topGenres'] as List<String>? ?? []).toSet();
    final topLanguage = profile['topLanguage'] as String? ?? 'english';
    final artistAffinity = (profile['artistAffinity'] as Map<String, int>?) ??
        const <String, int>{};
    final genreAffinity = (profile['genreAffinity'] as Map<String, int>?) ??
        const <String, int>{};
    final langAffinity =
        (profile['langAffinity'] as Map<String, int>?) ?? const <String, int>{};
    final logArtistBoost =
        (profile['logArtistBoost'] as Map<String, double>?) ??
            const <String, double>{};
    final recentArtistBoost =
        (profile['recentArtistBoost'] as Map<String, double>?) ??
            const <String, double>{};
    final logVideoBoost = (profile['logVideoBoost'] as Map<String, double>?) ??
        const <String, double>{};
    final logGenreBoost = (profile['logGenreBoost'] as Map<String, double>?) ??
        const <String, double>{};
    final hourGenreBoost =
        (profile['hourGenreBoost'] as Map<String, double>?) ??
            const <String, double>{};
    final logLangBoost = (profile['logLangBoost'] as Map<String, double>?) ??
        const <String, double>{};
    final skipVideoPenalty =
        (profile['skipVideoPenalty'] as Map<String, double>?) ??
            const <String, double>{};
    final skipArtistPenalty =
        (profile['skipArtistPenalty'] as Map<String, double>?) ??
            const <String, double>{};
    final recentPlayCount = (profile['recentPlayCount'] as Map<String, int>?) ??
        const <String, int>{};
    final ytLikedIds =
        (profile['ytLikedIds'] as Set<String>?) ?? const <String>{};
    final totalSongs = (profile['totalSongs'] as int?)?.clamp(1, 3000) ?? 1;

    double score = 0.0;
    if (seedIds.contains(id)) score += 2.1;
    if (topArtists.contains(authorKey)) score += 3.1;
    if (seedArtists.contains(authorKey)) score += 2.2;
    if (recentArtists.contains(authorKey)) score += 1.0;
    score += ((artistAffinity[authorKey] ?? 0) / totalSongs) * 26.0;

    final overlapTaste = tags.where(topGenres.contains).length;
    score += overlapTaste * 1.45;
    for (final tag in tags) {
      score += (genreAffinity[tag] ?? 0) * 0.05;
      score += (_genreActionBoost[tag] ?? 0.0) * 0.30;
    }

    if (lang == topLanguage) {
      score += 2.4;
    } else if ((langAffinity[lang] ?? 0) == 0) {
      score -= 1.4;
    } else {
      score -= 0.45;
    }

    score += (_artistActionBoost[authorKey] ?? 0.0) * 2.0;
    score += (_langActionBoost[lang] ?? 0.0) * 1.2;
    score += (_videoActionBoost[idKey] ?? 0.0) * 2.1;
    score += (logArtistBoost[authorKey] ?? 0.0) * 1.6;
    score += (recentArtistBoost[authorKey] ?? 0.0) * 1.9;
    score += (logVideoBoost[idKey] ?? 0.0) * 1.35;
    score += (logLangBoost[lang] ?? 0.0) * 0.95;
    for (final tag in tags) {
      score += (logGenreBoost[tag] ?? 0.0) * 0.85;
      score += (hourGenreBoost[tag] ?? 0.0) * 0.9;
    }
    score += _sessionMomentumScore(
      videoId: idKey,
      artistKey: authorKey,
      tags: tags,
      language: lang,
      profile: profile,
      penalizeSeen: true,
    );
    if (leadSeed != null) {
      score +=
          _contextualSeedAffinity(leadSeed, v, profile, strict: false) * 0.22;
      score += _transitionAffinityScore(leadSeed, v, profile) * 0.18;
    }
    if (intentTags.isNotEmpty) {
      final intentOverlap = tags.where(intentTags.contains).length;
      score += intentOverlap * 1.15;
      if (intentOverlap == 0 && tags.isNotEmpty) score -= 0.55;
    }
    if (intentLanguage.trim().isNotEmpty) {
      if (lang == intentLanguage.trim()) {
        score += 0.85;
      } else {
        score -= 0.35;
      }
    }
    score += _queryAffinityForText(text) * 1.1;
    // Penalize coincidental title matches for seed artist names on other artists.
    if (seedArtists.isNotEmpty) {
      final titleTokens =
          _tokenizeSearchText(title, dropCommonWords: true).toSet();
      for (final sa in seedArtists) {
        final key = _primaryArtistKey(sa);
        if (key.isEmpty || key == authorKey) continue;
        if (titleTokens.contains(key)) {
          score -= 2.2;
        }
      }
    }
    score -= (_quickPickExposurePenalty[idKey] ?? 0.0) * 1.15;
    score -= (skipVideoPenalty[idKey] ?? 0.0) * 1.7;
    score -= (skipArtistPenalty[authorKey] ?? 0.0) * 1.1;

    if (_likedVideoIds.contains(id)) score += 1.5;
    if (ytLikedIds.contains(id)) score += 1.25;
    if (_looksOfficialMusicChannel(author)) score += 0.9;
    if (_looksLikeDerivativeVersion(text)) score -= 4.2;
    if (_looksLikeCompilation(title)) score -= 3.2;
    if (_looksLikeShortForm(text)) score -= 1.4;

    final repeatCount = recentPlayCount[idKey] ?? 0;
    if (repeatCount >= 2) score -= (repeatCount - 1) * 1.4;
    final artistDensity = (artistAffinity[authorKey] ?? 0) / totalSongs;
    if (artistDensity < 0.006 &&
        !topArtists.contains(authorKey) &&
        !recentArtists.contains(authorKey)) {
      score += 1.05;
    } else if (artistDensity > 0.085 && !seedArtists.contains(authorKey)) {
      score -= 0.95;
    }

    if (_nowPlaying?.id.value == id) score -= 6.0;
    if (recentIds.contains(id)) score -= 2.8;
    if (_history.take(2).any((x) => x.id.value == id)) score -= 1.7;

    return score;
  }

  List<Video> _pickDiverseQuickPicks(
    List<({Video v, double score})> ranked, {
    required int target,
    required Set<String> seedIds,
    required Set<String> seedArtists,
    required Map<String, dynamic> profile,
  }) {
    final out = <Video>[];
    final outIds = <String>{};
    final artistCount = <String, int>{};
    final minUniqueArtists = target >= 20 ? 7 : (target >= 12 ? 5 : 4);
    final familiarTarget = (target * 0.72).round().clamp(1, target);
    final maxSeedSongs = target >= 20 ? 4 : (target >= 12 ? 3 : 2);
    int seedSongCount = 0;

    final artistAffinity = (profile['artistAffinity'] as Map<String, int>?) ??
        const <String, int>{};
    final logArtistBoost =
        (profile['logArtistBoost'] as Map<String, double>?) ??
            const <String, double>{};
    final recentArtistBoost =
        (profile['recentArtistBoost'] as Map<String, double>?) ??
            const <String, double>{};
    final skipArtistPenalty =
        (profile['skipArtistPenalty'] as Map<String, double>?) ??
            const <String, double>{};
    final momentum = (profile['artistMomentum'] as Map<String, double>?) ??
        const <String, double>{};
    final totalSongs = (profile['totalSongs'] as int?)?.clamp(1, 3000) ?? 1;

    final authorScores = <String, double>{};
    for (final item in ranked.take(80)) {
      final a = _primaryArtistKey(item.v.author);
      if (a.isEmpty) continue;
      authorScores[a] =
          (authorScores[a] ?? 0.0) + (item.score > 0 ? item.score : 0.0);
    }
    final authorWeights = <String, double>{};
    for (final entry in authorScores.entries) {
      final a = entry.key;
      final base = (artistAffinity[a] ?? 0) / totalSongs;
      final mom = momentum[a] ?? 0.0;
      final boost = (logArtistBoost[a] ?? 0.0) + (recentArtistBoost[a] ?? 0.0);
      final pen = skipArtistPenalty[a] ?? 0.0;
      var w = (base * 0.6) +
          (mom * 0.25) +
          (boost * 0.15) +
          (entry.value * 0.02) -
          (pen * 0.45);
      if (seedArtists.contains(a)) w += 0.30;
      if (w < 0) w = 0;
      authorWeights[a] = w;
    }
    var sumW = 0.0;
    for (final w in authorWeights.values) {
      sumW += w;
    }
    if (sumW <= 0) {
      for (final a in authorScores.keys) {
        authorWeights[a] = 1.0;
      }
      sumW = authorWeights.length.toDouble();
    }
    final quotas = <String, int>{};
    for (final entry in authorWeights.entries) {
      final share = entry.value / sumW;
      var q = (share * target).round();
      if (q < 1) q = 1;
      quotas[entry.key] = q;
    }
    var sumQ = 0;
    for (final q in quotas.values) {
      sumQ += q;
    }
    if (sumQ > target) {
      final scale = target / sumQ;
      sumQ = 0;
      for (final k in quotas.keys.toList()) {
        final q0 = quotas[k] ?? 1;
        final q = (q0 * scale).floor().clamp(1, target);
        quotas[k] = q;
        sumQ += q;
      }
    }
    if (sumQ < target) {
      final ordered = authorWeights.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      var i = 0;
      while (sumQ < target && ordered.isNotEmpty) {
        final k = ordered[i % ordered.length].key;
        quotas[k] = (quotas[k] ?? 1) + 1;
        sumQ++;
        i++;
      }
    }

    bool add(Video v, {required bool requireNewArtist}) {
      if (out.length >= target) return false;
      if (!outIds.add(v.id.value)) return false;
      if (seedIds.contains(v.id.value) && seedSongCount >= maxSeedSongs) {
        return false;
      }

      final artist = _primaryArtistKey(v.author);
      final count = artistCount[artist] ?? 0;
      final cap = (quotas[artist] ?? 2).clamp(1, target);
      if (count >= cap) return false;
      if (requireNewArtist && count > 0) return false;

      artistCount[artist] = count + 1;
      if (seedIds.contains(v.id.value)) seedSongCount++;
      out.add(v);
      return true;
    }

    final familiar = ranked.where((x) => x.score >= 4.8).toList();

    for (final item in familiar) {
      if (out.length >= familiarTarget) break;
      add(item.v, requireNewArtist: false);
    }

    if (artistCount.length < minUniqueArtists) {
      for (final item in familiar) {
        if (artistCount.length >= minUniqueArtists ||
            out.length >= familiarTarget) {
          break;
        }
        add(item.v, requireNewArtist: true);
      }
    }

    for (final item in ranked) {
      if (out.length >= target) break;
      add(item.v, requireNewArtist: false);
    }

    if (out.length < target) {
      for (final item in ranked) {
        if (out.length >= target) break;
        add(item.v, requireNewArtist: false);
      }
    }

    return out;
  }

  List<Video> _quickPicksFallback({int target = 24}) {
    final out = <Video>[];
    final seen = <String>{};
    final candidateLimit = max(120, target * 5);

    void addFrom(Iterable<Video> source, {bool strictSingles = true}) {
      if (out.length >= candidateLimit) return;
      for (final v in source) {
        if (!_isMusicCandidate(v, strictSingles: strictSingles)) continue;
        if (_isRecommendationBlocked(v)) continue;
        if (!seen.add(v.id.value)) continue;
        out.add(v);
        if (out.length >= candidateLimit) return;
      }
    }

    for (final shelf in _ytMusicHomeShelves.take(6)) {
      addFrom(shelf.videos.take(20));
      if (out.length >= candidateLimit) break;
    }
    for (final mix in _ytHomeMixes.take(4)) {
      addFrom(mix.videos.take(24));
      if (out.length >= candidateLimit) break;
    }

    addFrom(_buildSpeedDialPool(limit: max(target * 2, 40)));
    addFrom(_history.take(90));
    addFrom(_likedPlaylist.videos.take(140));
    addFrom(_ytLikedVideos.take(180));
    addFrom(_becauseYouLiked.take(80));
    addFrom(_trendingVideos.take(80));
    addFrom(_newReleases.take(80));
    addFrom(_hindiHits.take(80));
    addFrom(_moodChill.take(80));
    addFrom(_quickRow1.take(80));

    return _takeArtistDiverse(
      out,
      target: target,
      artistCap: 2,
      relaxedArtistCap: 4,
    );
  }

  // ignore: unused_element
  ({List<Video> videos, String label}) _buildHybridQuickPicks({
    required bool usingYtMusicHome,
    required ({
      List<Video> quickPicks,
      String quickPicksLabel,
      bool quickPicksFromOfficialShelf,
      List<_YtMusicHomeSection> shelves,
      List<BeastPlaylist> mixes,
    }) ytHome,
    int target = 24,
  }) {
    final profile = _buildTasteProfile();
    final seeds = _collectQuickPickSeeds(maxSeeds: 14);
    final leadSeed = seeds.isNotEmpty ? seeds.first : null;
    final intentText =
        '${ytHome.quickPicksLabel} ${(profile['allText'] as String? ?? '')}'
            .toLowerCase();
    final intentTags = _extractMusicTags(intentText);
    final intentLanguage = _detectLanguageTag(intentText);
    final seedIds = seeds.map((v) => v.id.value).toSet();
    final seedArtists = seeds.map((v) => _primaryArtistKey(v.author)).toSet();
    final recentArtists =
        _history.take(16).map((v) => _primaryArtistKey(v.author)).toSet();
    final recentIds = _history.take(18).map((v) => v.id.value).toSet();
    final knownIds = <String>{
      ..._likedVideoIds,
      ..._likedPlaylist.videos.take(280).map((v) => v.id.value),
      ..._ytLikedVideos.take(360).map((v) => v.id.value),
      ..._history.take(260).map((v) => v.id.value),
      ..._quickRow1.take(80).map((v) => v.id.value),
      ..._becauseYouLiked.take(80).map((v) => v.id.value),
    };

    final candidateById =
        <String, ({Video v, double sourceBoost, int hits, bool fromYtMusic})>{};

    void addCandidate(
      Video v,
      double boost, {
      required bool fromYtMusic,
    }) {
      if (!_isMusicCandidate(v, strictSingles: true)) return;
      if (_isRecommendationBlocked(v)) return;
      final prev = candidateById[v.id.value];
      if (prev == null) {
        candidateById[v.id.value] = (
          v: v,
          sourceBoost: boost,
          hits: 1,
          fromYtMusic: fromYtMusic,
        );
        return;
      }
      final mergedBoost = boost > prev.sourceBoost ? boost : prev.sourceBoost;
      candidateById[v.id.value] = (
        v: prev.v,
        sourceBoost: mergedBoost,
        hits: prev.hits + 1,
        fromYtMusic: prev.fromYtMusic || fromYtMusic,
      );
    }

    for (final v in ytHome.quickPicks.take(max(target * 2, 40))) {
      addCandidate(v, 2.8, fromYtMusic: true);
    }
    for (final shelf in ytHome.shelves.take(8)) {
      for (final v in shelf.videos.take(10)) {
        addCandidate(v, 2.25, fromYtMusic: true);
      }
    }
    for (final mix in ytHome.mixes.take(5)) {
      for (final v in mix.videos.take(10)) {
        addCandidate(v, 2.0, fromYtMusic: true);
      }
    }
    for (final v in _quickPicksFallback(target: max(target * 3, 72))) {
      addCandidate(v, 1.25, fromYtMusic: false);
    }
    for (final v in seeds.take(14)) {
      addCandidate(v, 1.1, fromYtMusic: false);
    }

    if (candidateById.isEmpty) {
      final fallback = _quickPicksFallback(target: target);
      final fallbackLabel = usingYtMusicHome
          ? 'From YouTube Music + AI taste blend'
          : _quickPicksContextLabel(seeds, profile);
      return (videos: fallback, label: fallbackLabel);
    }

    final ranked = candidateById.values
        .map((item) => (
              v: item.v,
              fromYtMusic: item.fromYtMusic,
              score: _quickPickScore(
                    item.v,
                    profile: profile,
                    seedIds: seedIds,
                    seedArtists: seedArtists,
                    recentArtists: recentArtists,
                    recentIds: recentIds,
                    leadSeed: leadSeed,
                    intentTags: intentTags,
                    intentLanguage: intentLanguage,
                  ) +
                  (item.fromYtMusic ? 0.55 : 0.0) +
                  (!knownIds.contains(item.v.id.value) ? 1.1 : 0.0) +
                  (recentIds.contains(item.v.id.value) ? -0.95 : 0.0) +
                  (_seedAffinityScore(item.v, seeds) * 0.95) +
                  (_multiSeedTransitionScore(item.v, seeds, profile) * 0.9) +
                  item.sourceBoost +
                  (item.hits * 0.34)
            ))
        .toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    final picks = <Video>[];
    final pickIds = <String>{};
    final pickArtistCount = <String, int>{};

    bool addPick(Video v, {int capPerArtist = 3}) {
      if (picks.length >= target) return false;
      if (!pickIds.add(v.id.value)) return false;
      final artist = _primaryArtistKey(v.author);
      final count = pickArtistCount[artist] ?? 0;
      if (count >= capPerArtist) {
        pickIds.remove(v.id.value);
        return false;
      }
      pickArtistCount[artist] = count + 1;
      picks.add(v);
      return true;
    }

    final ytMin = usingYtMusicHome ? min(12, max(8, target ~/ 2)) : 0;
    int ytAdded = 0;
    if (ytMin > 0) {
      for (final item in ranked.where((x) => x.fromYtMusic)) {
        if (ytAdded >= ytMin || picks.length >= target) break;
        if (addPick(item.v, capPerArtist: 3)) ytAdded++;
      }
    }

    final aiMin = usingYtMusicHome ? min(8, max(5, target ~/ 3)) : 0;
    int aiAdded = 0;
    if (aiMin > 0) {
      for (final item in ranked.where((x) => !x.fromYtMusic)) {
        if (aiAdded >= aiMin || picks.length >= target) break;
        if (addPick(item.v, capPerArtist: 3)) aiAdded++;
      }
    }

    final diverseMain = _pickDiverseQuickPicks(
      ranked.map((item) => (v: item.v, score: item.score)).toList(),
      target: target,
      seedIds: seedIds,
      seedArtists: seedArtists,
      profile: profile,
    );
    for (final v in diverseMain) {
      if (picks.length >= target) break;
      addPick(v, capPerArtist: 4);
    }
    for (final item in ranked) {
      if (picks.length >= target) break;
      addPick(item.v, capPerArtist: 4);
    }
    if (picks.length < max(8, min(target, 14))) {
      for (final v in _quickPicksFallback(target: target * 2)) {
        if (picks.length >= target) break;
        addPick(v, capPerArtist: 4);
      }
    }

    final sanitized = _filterBlockedRecommendations(
      _filterMusicResults(
        picks,
        limit: target,
        strictSingles: true,
      ),
      limit: target,
    );
    final finalLabel = usingYtMusicHome
        ? '${ytHome.quickPicksLabel.trim().isNotEmpty ? ytHome.quickPicksLabel.trim() : 'From YouTube Music'} + AI taste blend'
        : _quickPicksContextLabel(seeds, profile);
    return (videos: sanitized, label: finalLabel);
  }

  // ignore: unused_element
  Future<({List<Video> videos, String label})> _buildQuickPicksSmart({
    int target = 24,
  }) async {
    final profile = _buildTasteProfile();
    final seeds = _collectQuickPickSeeds(maxSeeds: 14);
    final label = _quickPicksContextLabel(seeds, profile);
    final leadSeed = seeds.isNotEmpty ? seeds.first : null;
    final intentText =
        '$label ${(profile['allText'] as String? ?? '')}'.toLowerCase();
    final intentTags = _extractMusicTags(intentText);
    final intentLanguage = _detectLanguageTag(intentText);

    final topArtists = profile['topArtists'] as List<String>? ?? [];
    final topGenres = profile['topGenres'] as List<String>? ?? [];
    final topLanguage = profile['topLanguage'] as String? ?? 'hindi';
    final allText = profile['allText'] as String? ?? '';
    final transitionArtists = seeds.isEmpty
        ? const <String>[]
        : _topTransitionArtistLabelsForSeed(seeds.first, profile, limit: 2);
    final transitionTags = _topTransitionTagsForSeeds(seeds, profile, limit: 2);

    final queries = <String>[];
    void addQuery(String q) {
      final trimmed = q.trim();
      if (trimmed.isEmpty) return;
      if (queries.any((x) => x.toLowerCase() == trimmed.toLowerCase())) return;
      queries.add(trimmed);
    }

    for (final s in seeds.take(4)) {
      addQuery('${_cleanTitle(s.title)} ${_cleanAuthor(s.author)} song radio');
      addQuery('${_cleanAuthor(s.author)} official audio songs');
    }

    if (seeds.isNotEmpty) {
      addQuery(_buildRadioQuery(seeds.first));
      addQuery(
        _sceneDiscoveryQuery(topLanguage, _extractMusicTags(allText)),
      );
    }

    for (final artist in transitionArtists) {
      addQuery('$artist official audio songs');
    }
    for (final a in topArtists.take(4)) {
      addQuery('$a official audio songs');
    }
    for (final tag in transitionTags) {
      addQuery(_genreToQuery(tag));
    }
    for (final g in topGenres.take(2)) {
      addQuery(_genreToQuery(g));
    }
    addQuery(_languageDiscoveryQuery(topLanguage, allText));
    addQuery(_moodQuery(allText));

    if (queries.isEmpty) {
      addQuery('new songs official audio');
      addQuery('new hindi songs official audio');
      addQuery('new punjabi songs official audio');
      addQuery('new english pop songs official audio');
    }

    final candidateById = <String, ({Video v, double sourceBoost, int hits})>{};

    void addCandidate(Video v, double boost) {
      if (!_isMusicCandidate(v, strictSingles: true)) return;
      final prev = candidateById[v.id.value];
      if (prev == null) {
        candidateById[v.id.value] = (v: v, sourceBoost: boost, hits: 1);
      } else {
        final nextBoost = boost > prev.sourceBoost ? boost : prev.sourceBoost;
        candidateById[v.id.value] = (
          v: prev.v,
          sourceBoost: nextBoost,
          hits: prev.hits + 1,
        );
      }
    }

    for (final s in seeds.take(6)) {
      addCandidate(s, 2.0);
    }

    final relatedSeeds = seeds.take(3).toList();
    final relatedFutures = <Future<List<Video>>>[];
    for (final s in relatedSeeds) {
      relatedFutures.add(_fetchYoutubeRelated(s, limit: 28));
    }
    final ytMusicHomeFuture = _fetchYtMusicHomeSongs(limit: 42);
    final queryFutures = queries
        .take(10)
        .map((q) => _searchMusic(
              q,
              limit: 22,
              strictSingles: true,
              personalize: false,
              excludeBlocked: true,
            ))
        .toList();

    final relatedResults = relatedFutures.isEmpty
        ? <List<Video>>[]
        : await Future.wait(relatedFutures);
    final ytMusicHomeResults = await ytMusicHomeFuture;
    final queryResults = queryFutures.isEmpty
        ? <List<Video>>[]
        : await Future.wait(queryFutures);

    for (int i = 0; i < relatedResults.length; i++) {
      final boost = i == 0 ? 2.9 : 2.4 - (i * 0.25);
      for (final v in relatedResults[i]) {
        addCandidate(v, boost);
      }
    }
    for (final v in ytMusicHomeResults) {
      addCandidate(v, 2.35);
    }
    for (final batch in queryResults) {
      for (final v in batch) {
        addCandidate(v, 1.0);
      }
    }

    if (candidateById.isEmpty) {
      final fallback = _quickPicksFallback(target: target)
          .where((v) => _isMusicCandidate(v, strictSingles: true))
          .take(target)
          .toList();
      return (videos: fallback, label: label);
    }

    final seedIds = seeds.map((v) => v.id.value).toSet();
    final seedArtists = seeds.map((v) => _primaryArtistKey(v.author)).toSet();
    final recentArtists =
        _history.take(16).map((v) => _primaryArtistKey(v.author)).toSet();
    final recentIds = _history.take(18).map((v) => v.id.value).toSet();
    final knownIds = <String>{
      ..._likedVideoIds,
      ..._likedPlaylist.videos.take(280).map((v) => v.id.value),
      ..._ytLikedVideos.take(360).map((v) => v.id.value),
      ..._history.take(260).map((v) => v.id.value),
      ..._quickRow1.take(80).map((v) => v.id.value),
      ..._becauseYouLiked.take(80).map((v) => v.id.value),
    };

    final ranked = candidateById.values
        .map((item) => (
              v: item.v,
              score: _quickPickScore(
                    item.v,
                    profile: profile,
                    seedIds: seedIds,
                    seedArtists: seedArtists,
                    recentArtists: recentArtists,
                    recentIds: recentIds,
                    leadSeed: leadSeed,
                    intentTags: intentTags,
                    intentLanguage: intentLanguage,
                  ) +
                  (!knownIds.contains(item.v.id.value) ? 1.35 : 0.0) +
                  (recentIds.contains(item.v.id.value) ? -1.2 : 0.0) +
                  (_seedAffinityScore(item.v, seeds) * 1.05) +
                  (_multiSeedTransitionScore(item.v, seeds, profile) * 0.95) +
                  item.sourceBoost +
                  (item.hits * 0.38)
            ))
        .toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    final picks = <Video>[];
    final pickIds = <String>{};
    final pickArtistCount = <String, int>{};
    final freshTarget = (target * 0.42).round().clamp(5, max(5, target - 6));

    bool addPick(Video v, {int capPerArtist = 2}) {
      final id = v.id.value;
      if (!pickIds.add(id)) return false;
      final artist = _primaryArtistKey(v.author);
      final used = pickArtistCount[artist] ?? 0;
      if (used >= capPerArtist) {
        pickIds.remove(id);
        return false;
      }
      pickArtistCount[artist] = used + 1;
      picks.add(v);
      return true;
    }

    final rankedFresh = ranked
        .where((item) =>
            !knownIds.contains(item.v.id.value) &&
            !seedIds.contains(item.v.id.value) &&
            !recentIds.contains(item.v.id.value))
        .toList();
    for (final item in rankedFresh) {
      if (picks.length >= freshTarget) break;
      addPick(item.v, capPerArtist: 2);
    }

    final diverseMain = _pickDiverseQuickPicks(
      ranked,
      target: target,
      seedIds: seedIds,
      seedArtists: seedArtists,
      profile: profile,
    );
    for (final v in diverseMain) {
      if (picks.length >= target) break;
      addPick(v, capPerArtist: 3);
    }

    if (picks.length < target) {
      for (final item in ranked) {
        if (picks.length >= target) break;
        addPick(item.v, capPerArtist: 4);
      }
    }
    if (picks.length < max(8, min(target, 14))) {
      for (final v in _quickPicksFallback(target: target)) {
        if (picks.length >= target) break;
        addPick(v, capPerArtist: 4);
      }
    }
    final sanitized = picks
        .where((v) => _isMusicCandidate(v, strictSingles: true))
        .take(target)
        .toList();
    if (sanitized.length < max(8, min(target, 14))) {
      final seen = sanitized.map((v) => v.id.value).toSet();
      for (final v in _quickPicksFallback(target: target * 2)) {
        if (sanitized.length >= target) break;
        if (!seen.add(v.id.value)) continue;
        if (!_isMusicCandidate(v, strictSingles: true)) continue;
        sanitized.add(v);
      }
    }
    final deduped = _dedupeByTrackSignature(sanitized, maxPerSignature: 1);
    if (deduped.length < target) {
      final seenIds = deduped.map((v) => v.id.value).toSet();
      final seenSig = deduped.map(_trackSignature).toSet();
      for (final item in ranked) {
        if (deduped.length >= target) break;
        final v = item.v;
        if (!seenIds.add(v.id.value)) continue;
        if (!_isMusicCandidate(v, strictSingles: true)) continue;
        final sig = _trackSignature(v);
        if (!seenSig.add(sig)) continue;
        deduped.add(v);
      }
      if (deduped.length < target) {
        for (final v in _quickPicksFallback(target: target * 2)) {
          if (deduped.length >= target) break;
          if (!seenIds.add(v.id.value)) continue;
          if (!_isMusicCandidate(v, strictSingles: true)) continue;
          final sig = _trackSignature(v);
          if (!seenSig.add(sig)) continue;
          deduped.add(v);
        }
      }
    }
    return (videos: deduped.take(target).toList(), label: label);
  }

  Future<({List<Video> videos, String label})> _buildQuickPicksSmartBounded({
    int target = 24,
  }) async {
    try {
      return await _buildQuickPicksSmart(target: target)
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      return (videos: const <Video>[], label: '');
    }
  }

  bool _looksLikeYtMusicMixRef(_YtMusicMixRef mix) {
    final id = mix.playlistId.trim();
    if (id.isEmpty) return false;
    if (id.startsWith('RD') || id.startsWith('VL')) return true;
    final text = '${mix.title} ${mix.subtitle}'.toLowerCase();
    return text.contains('mix') ||
        text.contains('radio') ||
        text.contains('for you') ||
        text.contains('made for');
  }

  Future<
      ({
        List<Video> quickPicks,
        String quickPicksLabel,
        bool quickPicksFromOfficialShelf,
        List<_YtMusicHomeSection> shelves,
        List<BeastPlaylist> mixes,
      })> _buildYtMusicHomeExperience() async {
    final hasCookie = (_ytMusicCookie ?? '').trim().isNotEmpty;
    final oauthToken = (_ytAccessToken ?? '').trim();
    final hasAuth = hasCookie || oauthToken.isNotEmpty;

    if (hasCookie && !_ytMusicSessionChecking) {
      try {
        final resolvedAuthUser = await _resolveBestYtMusicAuthUser(
          maxCandidates: 9,
        );
        debugPrint(
          '[YTM] Home feed using resolved authUser=$resolvedAuthUser before quick-picks fetch',
        );
      } catch (e) {
        debugPrint('[YTM] authUser pre-resolve failed before home fetch: $e');
      }
    }
    if (_shouldUseYtMusicBackend()) {
      final backendHome = await _fetchYtMusicHomeViaBackend();
      if (backendHome != null && _hasYtMusicHomeContent(backendHome)) {
        debugPrint(
          '[YTM] Using backend home payload quick=${backendHome.quickPicks.length} shelves=${backendHome.shelves.length}',
        );
        return backendHome;
      }
    } else {
      debugPrint('[YTM] Phone-only mode active. Skipping backend home fetch.');
    }

    final webViewPicks = await _fetchQuickPicksViaWebView();
    if (webViewPicks.isNotEmpty) {
      debugPrint('[YTM] WebView Quick Picks: ${webViewPicks.length} songs');
    }

    List<_YtMusicHomeSection> sections;
    if (hasAuth) {
      final webRemixProfile = _resolveYtMusicClientProfile(
        hasCookie: hasCookie,
        preferWebRemix: true,
      );
      debugPrint(
        '[YTM] Home feed fetch starting - auth=${hasCookie ? 'Cookie' : 'OAuth'} client=${webRemixProfile.clientName} gl=${_ytMusicGl()}',
      );

      // Use a more conservative section count for OAuth sessions to speed up loading
      final sectionLimit = (_ytMusicSessionValid && hasCookie) ? 14 : 8;

      sections = await _fetchYtMusicHomeSections(
        maxSections: sectionLimit,
        maxContinuations: 1, // Reduce continuations for faster initial load
        profile: webRemixProfile,
      );
      if (sections.isEmpty && hasCookie) {
        debugPrint(
          '[YTM] WEB_REMIX returned empty - falling back to ANDROID_MUSIC',
        );
        final androidFallbackProfile = _resolveYtMusicClientProfile(
          hasCookie: true,
          preferWebRemix: true,
          fallbackToAndroid: true,
        );
        sections = await _fetchYtMusicHomeSections(
          maxSections: 8,
          maxContinuations: 1,
          profile: androidFallbackProfile,
        );
      }
    } else {
      final guestProfile = _resolveYtMusicClientProfile(
        hasCookie: false,
        preferWebRemix: false,
      );
      sections = await _fetchYtMusicHomeSections(
        maxSections: 10,
        maxContinuations: 3,
        profile: guestProfile,
      );
    }
    debugPrint('[YTM Quick Debug] Received ${sections.length} sections:');
    for (final section in sections.take(6)) {
      debugPrint(
        '  -> "${section.title}" (${section.videos.length} songs) | ${section.subtitle}',
      );
    }

    final quickSection = _pickPrimaryYtMusicQuickSection(sections);
    final quickPicksFromOfficialShelf =
        quickSection != null && _ytMusicQuickShelfScore(quickSection.title) > 0;

    final quickPicks = <Video>[];
    var quickPicksLabel = 'From your YouTube Music Quick Picks';
    if (webViewPicks.isNotEmpty) {
      quickPicks.addAll(webViewPicks.take(_quickPicksMaxItems));
      quickPicksLabel = 'From your YouTube Music Quick Picks';
      debugPrint('[YTM] Using WebView Quick Picks with Innertube shelves');
    } else if (quickSection != null && quickSection.videos.isNotEmpty) {
      quickPicks.addAll(quickSection.videos.take(_quickPicksMaxItems));
      if (quickSection.subtitle.trim().isNotEmpty) {
        quickPicksLabel = quickSection.subtitle.trim();
      }
      debugPrint(
        '[YTM] Using primary Quick Picks shelf: "${quickSection.title}" (${quickPicks.length} songs)',
      );
    } else {
      quickPicksLabel = 'Official YT Music Quick Picks unavailable';
      debugPrint('[YTM] No candidate Quick Picks shelf found');
    }

    // Top up from YT Music "next" recommendations for current quick-pick seeds.
    if (quickPicks.length < _quickPicksMaxItems && quickPicks.isNotEmpty) {
      final recSeenIds = quickPicks.map((v) => v.id.value).toSet();
      final recSeenSig = quickPicks.map(_trackSignature).toSet();
      for (final seed in quickPicks.take(4)) {
        if (quickPicks.length >= _quickPicksMaxItems) break;
        final recs = await _fetchYtMusicNextSongs(
          seed,
          limit: _quickPicksMaxItems,
        );
        for (final rec in recs) {
          if (quickPicks.length >= _quickPicksMaxItems) break;
          if (_isRecommendationBlocked(rec)) continue;
          if (!_isMusicCandidate(rec, strictSingles: true)) continue;
          if (!recSeenIds.add(rec.id.value)) continue;
          final sig = _trackSignature(rec);
          if (!recSeenSig.add(sig)) continue;
          quickPicks.add(rec);
        }
      }
    }

    final maxShelves = _ytMusicSessionValid ? 8 : 5;
    final songShelves = sections
        .where((section) =>
            !identical(section, quickSection) && section.videos.length >= 4)
        .take(maxShelves)
        .toList();
    if (quickPicks.length < _quickPicksMaxItems) {
      final seenQuickIds = quickPicks.map((v) => v.id.value).toSet();
      final seenQuickSig = quickPicks.map(_trackSignature).toSet();
      for (final section in sections) {
        for (final video in section.videos) {
          if (quickPicks.length >= _quickPicksMaxItems) break;
          if (_isRecommendationBlocked(video)) continue;
          if (!_isMusicCandidate(video, strictSingles: true)) continue;
          if (!seenQuickIds.add(video.id.value)) continue;
          final sig = _trackSignature(video);
          if (!seenQuickSig.add(sig)) continue;
          quickPicks.add(video);
        }
        if (quickPicks.length >= _quickPicksMaxItems) break;
      }
    }

    final mixRefs = <_YtMusicMixRef>[];
    final seenPlaylistIds = <String>{};
    for (final section in sections) {
      for (final mix in section.mixes) {
        if (!_looksLikeYtMusicMixRef(mix)) continue;
        if (!seenPlaylistIds.add(mix.playlistId)) continue;
        mixRefs.add(mix);
      }
    }

    final mixes = <BeastPlaylist>[];
    if (mixRefs.isNotEmpty) {
      final selectedRefs = mixRefs.take(4).toList();
      final queueSets = await Future.wait<List<Video>>(
        selectedRefs.map(
            (mix) => _fetchYtMusicPlaylistSongs(mix.playlistId, limit: 30)),
      );
      for (int i = 0; i < selectedRefs.length; i++) {
        final videos = queueSets[i];
        if (videos.isEmpty) continue;
        mixes.add(
          BeastPlaylist(
            id: '__ytmix_${selectedRefs[i].playlistId}',
            name: selectedRefs[i].title,
            videos: videos,
            isSystem: true,
          ),
        );
      }
    }

    return (
      quickPicks: _dedupeByTrackSignature(
        quickPicks,
        maxPerSignature: 1,
      ).take(_quickPicksMaxItems).toList(),
      quickPicksLabel: quickPicksLabel,
      quickPicksFromOfficialShelf: quickPicksFromOfficialShelf,
      shelves: songShelves,
      mixes: mixes.take(4).toList(),
    );
  }

  bool _hasYtMusicHomeContent(
    ({
      List<Video> quickPicks,
      String quickPicksLabel,
      bool quickPicksFromOfficialShelf,
      List<_YtMusicHomeSection> shelves,
      List<BeastPlaylist> mixes,
    }) home,
  ) {
    return home.quickPicks.isNotEmpty ||
        home.shelves.isNotEmpty ||
        home.mixes.isNotEmpty;
  }

  // ignore: unused_element
  List<Video> _ytMusicQuickCandidatesFromHome(
    ({
      List<Video> quickPicks,
      String quickPicksLabel,
      bool quickPicksFromOfficialShelf,
      List<_YtMusicHomeSection> shelves,
      List<BeastPlaylist> mixes,
    }) home, {
    int target = 24,
  }) {
    final out = <Video>[];
    final seen = <String>{};

    void addFrom(Iterable<Video> source) {
      if (out.length >= target) return;
      for (final video in source) {
        if (out.length >= target) return;
        if (!_isMusicCandidate(video, strictSingles: true)) continue;
        if (_isRecommendationBlocked(video)) continue;
        if (!seen.add(video.id.value)) continue;
        out.add(video);
      }
    }

    addFrom(home.quickPicks);
    for (final shelf in home.shelves.take(8)) {
      addFrom(shelf.videos);
      if (out.length >= target) break;
    }
    for (final mix in home.mixes.take(4)) {
      addFrom(mix.videos);
      if (out.length >= target) break;
    }
    return _takeArtistDiverse(
      out,
      target: target,
      artistCap: 2,
      relaxedArtistCap: 4,
    );
  }

  void _showYtMusicHomeSnackBar(String message) {
    debugPrint('[YTM SnackBar] $message');
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _maybeReloadHomeAuto() {
    if (_appBooting) {
      unawaited(_loadHome());
    }
  }

  Future<void> _loadHome() async {
    _appBooting = false;
    if (mounted) setState(() => _homeLoading = true);
    final cacheFresh = _homeCacheAt != null &&
        DateTime.now().difference(_homeCacheAt!).inHours <= 12;
    if (_quickRow1.isEmpty && _homeCacheQuick.isNotEmpty && cacheFresh) {
      if (mounted) {
        setState(() {
          _quickRow1 =
              List<Video>.from(_homeCacheQuick.take(_quickPicksMaxItems));
          _quickRow1Label = _homeCacheQuickLabel.trim().isNotEmpty
              ? _homeCacheQuickLabel
              : 'Made for you';
          _quickPicksPage = 0;
        });
      }
    }

    var usingYtMusicHome = false;
    try {
      final ytHome = await _buildYtMusicHomeExperience()
          .timeout(const Duration(seconds: 2));
      usingYtMusicHome = _hasYtMusicHomeContent(ytHome);
      var selectedQuickPicks =
          ytHome.quickPicks.take(_quickPicksMaxItems).toList();
      var quickLabel = ytHome.quickPicksLabel.trim().isNotEmpty
          ? ytHome.quickPicksLabel.trim()
          : ((_ytMusicSessionValid || (_ytAccessToken ?? '').isNotEmpty)
              ? 'From your YouTube Music home feed'
              : 'From YouTube Music guest home feed');
      final preserveOfficialYtOrder =
          usingYtMusicHome && ytHome.quickPicksFromOfficialShelf;
      debugPrint(
        '[YTM] Home quick picks selected=${selectedQuickPicks.length} preserveOfficial=$preserveOfficialYtOrder officialShelf=${ytHome.quickPicksFromOfficialShelf}',
      );
      final artistCounts = <String, int>{};
      for (final v in selectedQuickPicks) {
        final key = _primaryArtistKey(v.author);
        final artist = key.isEmpty ? '__unknown__' : key;
        artistCounts[artist] = (artistCounts[artist] ?? 0) + 1;
      }
      final maxArtistCount =
          artistCounts.values.isEmpty ? 0 : artistCounts.values.reduce(max);
      final needRebalance = selectedQuickPicks.isNotEmpty &&
          (maxArtistCount >= 5 ||
              (maxArtistCount / selectedQuickPicks.length) > 0.45);
      if (preserveOfficialYtOrder && needRebalance) {
        final aiQuick =
            await _buildQuickPicksSmartBounded(target: _quickPicksMaxItems);
        if (aiQuick.videos.isNotEmpty) {
          selectedQuickPicks =
              aiQuick.videos.take(_quickPicksMaxItems).toList();
          quickLabel = aiQuick.label.trim().isNotEmpty
              ? aiQuick.label.trim()
              : 'Made for you';
          debugPrint(
              '[YTM] Quick Picks switched to AI recommender due to artist dominance ($maxArtistCount/${selectedQuickPicks.length})');
        } else {
          final balanced = _ytMusicQuickCandidatesFromHome(ytHome,
                  target: _quickPicksMaxItems)
              .take(_quickPicksMaxItems)
              .toList();
          if (balanced.isNotEmpty) {
            selectedQuickPicks = balanced;
            quickLabel = ytHome.quickPicksLabel.trim().isNotEmpty
                ? ytHome.quickPicksLabel.trim()
                : ((_ytMusicSessionValid || (_ytAccessToken ?? '').isNotEmpty)
                    ? 'From your YouTube Music home feed'
                    : 'From YouTube Music guest home feed');
            debugPrint(
                '[YTM] Quick Picks rebalanced from home feed due to artist dominance ($maxArtistCount/${selectedQuickPicks.length})');
          }
        }
      }
      if (selectedQuickPicks.isEmpty) {
        final ai =
            await _buildQuickPicksSmartBounded(target: _quickPicksMaxItems);
        if (ai.videos.isNotEmpty) {
          selectedQuickPicks = ai.videos.take(_quickPicksMaxItems).toList();
          quickLabel =
              ai.label.trim().isNotEmpty ? ai.label.trim() : 'Made for you';
        } else {
          final homeCandidates = _ytMusicQuickCandidatesFromHome(ytHome,
              target: _quickPicksMaxItems);
          if (homeCandidates.isNotEmpty) {
            selectedQuickPicks =
                homeCandidates.take(_quickPicksMaxItems).toList();
            quickLabel =
                (_ytMusicSessionValid || (_ytAccessToken ?? '').isNotEmpty)
                    ? 'From your YouTube Music home feed'
                    : 'From YouTube Music guest home feed';
          } else {
            final fallback = _quickPicksFallback(target: _quickPicksMaxItems);
            selectedQuickPicks = fallback.take(_quickPicksMaxItems).toList();
            quickLabel = 'Made for you';
          }
        }
      }
      final adjusted = await _applyBanditOnQuickPicks(
        selectedQuickPicks: selectedQuickPicks,
        quickLabel: quickLabel,
        usingYtMusicHome: usingYtMusicHome,
        ytHome: ytHome,
        preserveOfficialYtOrder: preserveOfficialYtOrder,
      );
      selectedQuickPicks = adjusted.videos.where(_isQuickPickAllowed).toList();
      quickLabel = adjusted.label;
      if (selectedQuickPicks.isNotEmpty) {
        // Sanitize + enforce artist diversity like YT Music (cap 2 per artist).
        final filtered = _filterMusicResults(
          selectedQuickPicks.where(_isQuickPickAllowed).toList(),
          limit: min(40, selectedQuickPicks.length),
          strictSingles: true,
        );
        const cap = 2;
        final seen = <String, int>{};
        final diverse = <Video>[];
        for (final v in filtered) {
          final a = _primaryArtistKey(v.author);
          final used = seen[a] ?? 0;
          if (used >= cap) continue;
          seen[a] = used + 1;
          diverse.add(v);
          if (diverse.length >= _quickPicksMaxItems) break;
        }
        // Inject exploration: at least ~20% new artists not seen in likes/history.
        final seenArtists = _likedPlaylist.videos
            .take(400)
            .map((v) => _primaryArtistKey(v.author))
            .toSet()
          ..addAll(
              _ytLikedVideos.take(400).map((v) => _primaryArtistKey(v.author)))
          ..addAll(_history.take(200).map((v) => _primaryArtistKey(v.author)));
        final existingIds = diverse.map((v) => v.id.value).toSet();
        final explorePool = filtered.where((v) {
          if (existingIds.contains(v.id.value)) return false;
          final a = _primaryArtistKey(v.author);
          return a.isNotEmpty && !seenArtists.contains(a);
        }).toList();
        final exploreCount = max(2, (diverse.length * 0.2).floor());
        int injected = 0;
        for (final v in explorePool) {
          // Replace the second slot of artists that already have 2 items.
          final a = _primaryArtistKey(v.author);
          final idx =
              diverse.indexWhere((x) => _primaryArtistKey(x.author) == a);
          if (idx == -1) {
            diverse.insert(
              min(diverse.length, (_quickPicksMaxItems - 3) + injected),
              v,
            );
            injected++;
          }
          if (diverse.length > 18) {
            // Trim back to 15 later
          }
          if (injected >= exploreCount) break;
        }
        selectedQuickPicks = _avoidConsecutiveSameArtist(
            diverse.take(_quickPicksMaxItems).toList());
        selectedQuickPicks =
            selectedQuickPicks.where(_isQuickPickAllowed).toList();
        selectedQuickPicks = _dedupeByTrackSignature(
          selectedQuickPicks,
          maxPerSignature: 1,
        );
        if (selectedQuickPicks.length < _quickPicksMaxItems) {
          final seenIds = selectedQuickPicks.map((v) => v.id.value).toSet();
          final seenSig = selectedQuickPicks.map(_trackSignature).toSet();
          final refill = usingYtMusicHome
              ? _ytMusicQuickCandidatesFromHome(
                  ytHome,
                  target: _quickPicksMaxItems * 2,
                )
              : _quickPicksFallback(target: _quickPicksMaxItems * 2);
          for (final v in refill) {
            if (selectedQuickPicks.length >= _quickPicksMaxItems) break;
            if (!_isQuickPickAllowed(v)) continue;
            if (!seenIds.add(v.id.value)) continue;
            final sig = _trackSignature(v);
            if (!seenSig.add(sig)) continue;
            selectedQuickPicks.add(v);
          }
        }
        selectedQuickPicks = selectedQuickPicks
            .take(_quickPicksMaxItems)
            .toList(growable: false);
        _markQuickPicksServed(selectedQuickPicks);
      }

      if (!mounted) return;
      setState(() {
        _usingYtMusicHomeFeed = usingYtMusicHome;
        _quickRow1 = selectedQuickPicks;
        _quickRow1Label = quickLabel;
        _quickPicksPage = 0;
        _speedDialPage = 0;
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
      _homeCacheQuick
        ..clear()
        ..addAll(_quickRow1.take(_quickPicksMaxItems));
      _homeCacheQuickLabel = _quickRow1Label;
      _homeCacheAt = DateTime.now();
      _scheduleSave();
      if (!usingYtMusicHome &&
          (_ytMusicSessionValid || (_ytMusicCookie ?? '').trim().isNotEmpty)) {
        final suppress = _ytFeedWarnShown &&
            _ytFeedWarnAt != null &&
            DateTime.now().difference(_ytFeedWarnAt!).inMinutes < 15;
        if (!suppress) {
          _showYtMusicHomeSnackBar(
            'YouTube Music home feed is unavailable right now.',
          );
          _ytFeedWarnShown = true;
          _ytFeedWarnAt = DateTime.now();
        }
      }
      if (_quickPicksCtrl.hasClients) {
        _quickPicksCtrl.jumpToPage(0);
      }
      if (_speedDialCtrl.hasClients) {
        _speedDialCtrl.jumpToPage(0);
      }
    } on TimeoutException {
      try {
        var selectedQuickPicks = <Video>[];
        var quickLabel = 'Made for you';
        final ai =
            await _buildQuickPicksSmartBounded(target: _quickPicksMaxItems);
        if (ai.videos.isNotEmpty) {
          selectedQuickPicks = ai.videos
              .where(_isQuickPickAllowed)
              .take(_quickPicksMaxItems)
              .toList();
          quickLabel = ai.label.isNotEmpty ? ai.label : 'Made for you';
        } else {
          final fallback = _quickPicksFallback(target: _quickPicksMaxItems);
          selectedQuickPicks = fallback
              .where(_isQuickPickAllowed)
              .take(_quickPicksMaxItems)
              .toList();
        }
        if (selectedQuickPicks.isNotEmpty && mounted) {
          setState(() {
            _usingYtMusicHomeFeed = false;
            _quickRow1 = selectedQuickPicks;
            _quickRow1Label = quickLabel;
            _quickPicksPage = 0;
            _homeLoading = false;
          });
          _homeCacheQuick
            ..clear()
            ..addAll(_quickRow1.take(_quickPicksMaxItems));
          _homeCacheQuickLabel = _quickRow1Label;
          _homeCacheAt = DateTime.now();
          _scheduleSave();
        }
      } catch (_) {
        if (mounted) setState(() => _homeLoading = false);
      }
    } catch (e) {
      debugPrint('[Home] $e');
      if (mounted) {
        usingYtMusicHome = false;
        setState(() {
          _usingYtMusicHomeFeed = false;
          _ytMusicHomeShelves = [];
          _ytHomeMixes = [];
          _quickRow1 = [];
          _quickRow1Label = 'Official YT Music Quick Picks unavailable';
          _quickPicksPage = 0;
          _homeLoading = false;
        });
        _showYtMusicHomeSnackBar(
          'Failed to load YouTube Music home feed.',
        );
      }
    }

    if (!usingYtMusicHome) {
      unawaited(_loadTrendingByCountry(_selectedCountryIdx));
    }
    unawaited(_loadBecauseYouLiked());
  }

  List<Video> _avoidConsecutiveSameArtist(List<Video> items) {
    final list = List<Video>.from(items);
    String lastArtist = '';
    for (int i = 0; i < list.length - 1; i++) {
      final currArtist = _primaryArtistKey(list[i].author);
      final nextArtist = _primaryArtistKey(list[i + 1].author);
      if (currArtist.isNotEmpty &&
          nextArtist.isNotEmpty &&
          currArtist == nextArtist) {
        // find a later item with a different artist to swap in
        int swapIdx = -1;
        for (int j = i + 2; j < list.length; j++) {
          final a = _primaryArtistKey(list[j].author);
          if (a != currArtist && a != lastArtist) {
            swapIdx = j;
            break;
          }
        }
        if (swapIdx > 0) {
          final tmp = list[i + 1];
          list[i + 1] = list[swapIdx];
          list[swapIdx] = tmp;
        }
      }
      lastArtist = _primaryArtistKey(list[i].author);
    }
    return list;
  }

  String _trackSignature(Video v) {
    final title = _cleanTitle(v.title).toLowerCase();
    final author = _cleanAuthor(v.author).toLowerCase();
    final compactTitle = title
        .replaceAll(RegExp(r'[\(\)\[\]\{\}]'), ' ')
        .replaceAll(
          RegExp(
              r'\b(official|audio|video|lyrics?|lyrical|visualizer|feat|ft|prod|version|remix|edit|live)\b'),
          ' ',
        )
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final compactAuthor = author
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return '$compactTitle|$compactAuthor';
  }

  List<Video> _dedupeByTrackSignature(List<Video> items,
      {int maxPerSignature = 1}) {
    final out = <Video>[];
    final signatureCount = <String, int>{};
    for (final v in items) {
      final sig = _trackSignature(v);
      final used = signatureCount[sig] ?? 0;
      if (used >= maxPerSignature) continue;
      signatureCount[sig] = used + 1;
      out.add(v);
    }
    return out;
  }

  List<Video> _buildQuickPlayAllQueue(List<Video> source) {
    if (source.isEmpty) return const <Video>[];
    final uniqueSource = _dedupeByTrackSignature(List<Video>.from(source));
    final filtered = _filterMusicResults(
      uniqueSource.where(_isQuickPickAllowed).toList(),
      limit: max(20, min(80, source.length * 2)),
      strictSingles: true,
    );
    if (filtered.isEmpty) return List<Video>.from(source);

    final profile = _buildTasteProfile();
    final seed = filtered.first;
    final seedText = '${_cleanTitle(seed.title)} ${_cleanAuthor(seed.author)}';
    final seedTags = _extractMusicTags(seedText.toLowerCase());
    final seedMood = _primaryMoodTag(seedTags);
    final sourceArtistCount = <String, int>{};
    for (final v in filtered) {
      final artist = _primaryArtistKey(v.author);
      sourceArtistCount[artist] = (sourceArtistCount[artist] ?? 0) + 1;
    }

    final ranked = filtered
        .map((v) {
          final text = '${_cleanTitle(v.title)} ${_cleanAuthor(v.author)}';
          final tags = _extractMusicTags(text.toLowerCase());
          final mood = _primaryMoodTag(tags);
          final artist = _primaryArtistKey(v.author);
          final repeatedArtistPenalty =
              max(0, (sourceArtistCount[artist] ?? 1) - 1) * 1.15;
          final clashPenalty = seed.id.value == v.id.value
              ? 0.0
              : _vibeClashPenalty(seedTags, tags, strict: false);
          final score = _personalTasteScore(
                    v,
                    profile,
                    queryHint: 'quick play all mood taste queue',
                    penalizeRepeats: true,
                  ) +
              (_contextualSeedAffinity(seed, v, profile, strict: false) * 1.6) +
              (_transitionAffinityScore(seed, v, profile) * 1.1) +
              (seedMood != null && mood == seedMood ? 1.0 : 0.0) -
              (clashPenalty * 0.85) -
              repeatedArtistPenalty;
          return (v: v, score: score);
        })
        .toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    final diverse = _takeArtistDiverse(
      ranked.map((item) => item.v),
      target: min(32, max(16, filtered.length)),
      artistCap: 1,
      relaxedArtistCap: 2,
    );
    final ordered = _avoidConsecutiveSameArtist(diverse);
    final out = <Video>[seed];
    final outIds = <String>{seed.id.value};
    for (final v in ordered) {
      if (outIds.add(v.id.value)) out.add(v);
    }
    for (final v in filtered) {
      if (out.length >= min(40, max(20, filtered.length))) break;
      if (outIds.add(v.id.value)) out.add(v);
    }
    return out;
  }

  List<Video> _personalMixSeedPool({int limit = 240}) {
    final out = <Video>[];
    final seen = <String>{};

    void addAll(Iterable<Video> videos) {
      for (final video in videos) {
        if (out.length >= limit) return;
        if (!seen.add(video.id.value)) continue;
        if (_isRecommendationBlocked(video)) continue;
        if (!_isMusicCandidate(video, strictSingles: true)) continue;
        out.add(video);
      }
    }

    addAll(_likedPlaylist.videos.reversed);
    addAll(_ytLikedVideos);
    addAll(_history.take(180));
    addAll(_quickRow1.take(80));
    addAll(_becauseYouLiked.take(60));
    if (_nowPlaying != null) {
      addAll([_nowPlaying!]);
    }

    return out;
  }

  Video? _pickMixSeedVideo({
    required Iterable<Video> pool,
    String artist = '',
    String tag = '',
    Set<String> excludeIds = const <String>{},
  }) {
    final targetArtist = _primaryArtistKey(artist);
    final targetTag = _normalizeSignalKey(tag);

    for (final video in pool) {
      if (excludeIds.contains(video.id.value)) continue;
      final features = _trackFeaturesForVideo(video);
      if (_isBlockedTrackFeatures(features)) continue;
      if (targetArtist.isNotEmpty && features.authorKey == targetArtist) {
        return video;
      }
      if (targetTag.isNotEmpty && features.tags.contains(targetTag)) {
        return video;
      }
    }

    if (targetArtist.isEmpty && targetTag.isEmpty) {
      for (final video in pool) {
        if (!excludeIds.contains(video.id.value)) return video;
      }
    }

    return null;
  }

  List<Video> _rankYtMusicMixRecommendations(
    List<Video> candidates,
    Video seed, {
    int limit = 20,
    String queryHint = '',
  }) {
    final filtered = _filterBlockedRecommendations(
      _filterMusicResults(
        candidates,
        limit: max(limit * 4, 40),
        strictSingles: true,
      ),
      limit: max(limit * 4, 40),
    );
    final ranked = _rankPersonalizedRecommendations(
      filtered,
      queryHint.isNotEmpty
          ? queryHint
          : '${_cleanAuthor(seed.author)} ${_cleanTitle(seed.title)} mix',
    );
    return ranked
        .where((video) => video.id.value != seed.id.value)
        .take(limit)
        .toList();
  }

  bool _isSpeedDialPinned(Video video) {
    return _speedDialPins.any((v) => v.id.value == video.id.value);
  }

  void _toggleSpeedDialPin(Video video, {bool showToast = true}) {
    final existing =
        _speedDialPins.indexWhere((v) => v.id.value == video.id.value);
    final title = _cleanTitle(video.title);

    setState(() {
      if (existing >= 0) {
        _speedDialPins.removeAt(existing);
      } else {
        _speedDialPins.insert(0, video);
        if (_speedDialPins.length > _maxSpeedDialPins) {
          _speedDialPins.removeRange(_maxSpeedDialPins, _speedDialPins.length);
        }
      }
    });
    _scheduleSave();

    if (!showToast || !mounted) return;
    final pinned = existing < 0;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          pinned ? 'Pinned to Speed dial: $title' : 'Removed from Speed dial',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  double _personalTasteScore(
    Video v,
    Map<String, dynamic> profile, {
    String queryHint = '',
    bool penalizeRepeats = true,
  }) {
    if (_isRecommendationBlocked(v)) return -999.0;
    final id = v.id.value;
    final idKey = id.toLowerCase();
    final text = '${v.title} ${v.author}'.toLowerCase();
    final authorKey = _primaryArtistKey(v.author);
    final tags = _extractMusicTags(text);
    final lang = _detectLanguageTag(text);
    final topArtists = (profile['topArtists'] as List<String>? ?? [])
        .take(14)
        .map(_primaryArtistKey)
        .toSet();
    final topGenres = (profile['topGenres'] as List<String>? ?? []).toSet();
    final topLanguage = profile['topLanguage'] as String? ?? 'english';
    final artistAffinity = (profile['artistAffinity'] as Map<String, int>?) ??
        const <String, int>{};
    final genreAffinity = (profile['genreAffinity'] as Map<String, int>?) ??
        const <String, int>{};
    final langAffinity =
        (profile['langAffinity'] as Map<String, int>?) ?? const <String, int>{};
    final logArtistBoost =
        (profile['logArtistBoost'] as Map<String, double>?) ??
            const <String, double>{};
    final recentArtistBoost =
        (profile['recentArtistBoost'] as Map<String, double>?) ??
            const <String, double>{};
    final logVideoBoost = (profile['logVideoBoost'] as Map<String, double>?) ??
        const <String, double>{};
    final logGenreBoost = (profile['logGenreBoost'] as Map<String, double>?) ??
        const <String, double>{};
    final hourGenreBoost =
        (profile['hourGenreBoost'] as Map<String, double>?) ??
            const <String, double>{};
    final logLangBoost = (profile['logLangBoost'] as Map<String, double>?) ??
        const <String, double>{};
    final skipVideoPenalty =
        (profile['skipVideoPenalty'] as Map<String, double>?) ??
            const <String, double>{};
    final skipArtistPenalty =
        (profile['skipArtistPenalty'] as Map<String, double>?) ??
            const <String, double>{};
    final recentPlayCount = (profile['recentPlayCount'] as Map<String, int>?) ??
        const <String, int>{};
    final ytLikedIds =
        (profile['ytLikedIds'] as Set<String>?) ?? const <String>{};
    final totalSongs = (profile['totalSongs'] as int?)?.clamp(1, 3000) ?? 1;
    final queryText = queryHint.toLowerCase();

    double score = 0.0;
    if (topArtists.contains(authorKey)) score += 3.0;
    score += ((artistAffinity[authorKey] ?? 0) / totalSongs) * 22.0;
    score += (_artistActionBoost[authorKey] ?? 0.0) * 1.85;
    score += (_videoActionBoost[idKey] ?? 0.0) * 1.65;
    score += (_langActionBoost[lang] ?? 0.0) * 1.1;
    score += _queryAffinityForText(text) * 1.1;
    score += (logArtistBoost[authorKey] ?? 0.0) * 1.35;
    score += (recentArtistBoost[authorKey] ?? 0.0) * 1.5;
    score += (logVideoBoost[idKey] ?? 0.0) * 1.15;
    score += (logLangBoost[lang] ?? 0.0) * 0.8;

    final overlap = tags.where(topGenres.contains).length;
    score += overlap * 1.4;
    for (final t in tags) {
      score += (genreAffinity[t] ?? 0) * 0.04;
      score += (_genreActionBoost[t] ?? 0.0) * 0.25;
      score += (logGenreBoost[t] ?? 0.0) * 0.65;
      score += (hourGenreBoost[t] ?? 0.0) * 0.65;
    }
    score += _sessionMomentumScore(
      videoId: idKey,
      artistKey: authorKey,
      tags: tags,
      language: lang,
      profile: profile,
      penalizeSeen: penalizeRepeats,
    );

    if (lang == topLanguage) {
      score += 1.8;
    } else if ((langAffinity[lang] ?? 0) == 0) {
      score -= 1.3;
    } else {
      score -= 0.35;
    }

    if (_likedVideoIds.contains(id)) score += 1.4;
    if (ytLikedIds.contains(id)) score += 1.0;
    if (_looksOfficialMusicChannel(v.author)) score += 0.7;
    if (_looksLikeDerivativeVersion(text)) score -= 4.0;
    if (_looksLikeCompilation(_cleanTitle(v.title))) score -= 3.1;
    if (_quickPickExposurePenalty[idKey] != null) {
      score -= (_quickPickExposurePenalty[idKey] ?? 0.0) * 0.6;
    }
    score -= (skipVideoPenalty[idKey] ?? 0.0) * 1.35;
    score -= (skipArtistPenalty[authorKey] ?? 0.0) * 0.9;

    if (penalizeRepeats) {
      final repeatCount = recentPlayCount[idKey] ?? 0;
      if (repeatCount >= 2) score -= (repeatCount - 1) * 1.25;
      if (_history.take(2).any((x) => x.id.value == id)) score -= 1.8;
      if (_nowPlaying?.id.value == id) score -= 3.0;
    }
    if (queryText.isNotEmpty && queryText.contains(authorKey)) score += 0.8;
    return score;
  }

  List<Video> _buildSpeedDialPool({int limit = 48}) {
    final profile = _buildTasteProfile();
    final candidates = <String, ({Video v, double sourceBoost})>{};

    void add(Video? v, double boost) {
      if (v == null) return;
      if (!_isMusicCandidate(v, strictSingles: true)) return;
      if (_isRecommendationBlocked(v)) return;
      final prev = candidates[v.id.value];
      if (prev == null || boost > prev.sourceBoost) {
        candidates[v.id.value] = (v: v, sourceBoost: boost);
      }
    }

    for (final v in _speedDialPins.take(_maxSpeedDialPins)) {
      add(v, 8.8);
    }
    int i = 0;
    for (final v in _history.take(80)) {
      add(v, max(0.4, 4.8 - (i * 0.045)));
      i++;
    }
    i = 0;
    for (final v in _likedPlaylist.videos.take(140)) {
      add(v, max(0.35, 3.9 - (i * 0.028)));
      i++;
    }
    i = 0;
    for (final v in _ytLikedVideos.take(180)) {
      add(v, max(0.3, 3.7 - (i * 0.024)));
      i++;
    }
    i = 0;
    for (final v in _quickRow1.take(60)) {
      add(v, max(0.25, 2.8 - (i * 0.04)));
      i++;
    }
    i = 0;
    for (final section in _ytMusicHomeShelves.take(3)) {
      for (final v in section.videos.take(14)) {
        add(v, max(0.22, 2.6 - (i * 0.05)));
        i++;
      }
    }
    i = 0;
    for (final v in _becauseYouLiked.take(60)) {
      add(v, max(0.22, 2.5 - (i * 0.035)));
      i++;
    }
    i = 0;
    for (final v in _ytHomeMixes.expand((pl) => pl.videos).take(120)) {
      add(v, max(0.2, 2.2 - (i * 0.02)));
      i++;
    }

    final rankedPairs = candidates.values
        .map((item) => (
              v: item.v,
              score: _personalTasteScore(
                    item.v,
                    profile,
                    queryHint: 'speed dial personalized',
                  ) +
                  item.sourceBoost
            ))
        .toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    final diversified = _pickDiverseQuickPicks(
      rankedPairs,
      target: limit,
      seedIds: const <String>{},
      seedArtists: const <String>{},
      profile: profile,
    );
    return diversified.take(limit).toList();
  }

  void _playSpeedDialSong(List<Video> source, int index) {
    if (source.isEmpty || index < 0 || index >= source.length) return;
    final video = source[index];
    _rewardQuickPickSelection(video, strength: 1.8);
    setState(() {
      _playQueue = List<Video>.from(source);
      _radioMode = false;
    });
    _playFromUserAction(video, index,
        tasteWeight: 1.05, source: 'speed_dial_tap');
  }

  void _playSpeedDialRandom(List<Video> source) {
    if (source.isEmpty) return;
    final queue =
        _buildRandomQueueFromPool(source, target: max(24, source.length));
    final first = queue.first;
    _rewardQuickPickSelection(first, strength: 2.2);
    setState(() {
      _playQueue = queue;
      _radioMode = false;
    });
    _playFromUserAction(first, 0,
        tasteWeight: 1.15, source: 'speed_dial_random');
  }

  List<Video> _buildRandomQueueFromPool(List<Video> pool, {int target = 28}) {
    final profile = _buildTasteProfile();
    final seenIds = <String>{};
    final seenArtists = <String>{};

    final likedIds = _likedVideoIds;
    final histIds = _history.take(120).map((v) => v.id.value).toSet();

    final scored = pool
        .map((v) => (
              v: v,
              taste: _personalTasteScore(
                v,
                profile,
                queryHint: 'random',
                penalizeRepeats: true,
              ),
              tokens: _tokenizeSearchText(
                '${_cleanTitle(v.title)} ${_cleanAuthor(v.author)}',
                dropCommonWords: true,
              ).toSet(),
            ))
        .toList()
      ..shuffle();

    final int inTasteTarget = (target * 0.6).round();
    final int exploreTarget = (target * 0.3).round();
    final int nostalgiaTarget = target - inTasteTarget - exploreTarget;

    final inTaste = <Video>[];
    final explore = <Video>[];
    final nostalgia = <Video>[];

    // In-taste: highest taste score, cap 1 per artist.
    for (final s in (scored..sort((a, b) => b.taste.compareTo(a.taste)))) {
      if (inTaste.length >= inTasteTarget) break;
      final id = s.v.id.value;
      final artist = _primaryArtistKey(s.v.author);
      if (seenIds.contains(id) || seenArtists.contains(artist)) continue;
      inTaste.add(s.v);
      seenIds.add(id);
      seenArtists.add(artist);
    }

    // Explore: different artists not in likes/history, still somewhat relevant.
    for (final s in scored) {
      if (explore.length >= exploreTarget) break;
      final id = s.v.id.value;
      final artist = _primaryArtistKey(s.v.author);
      if (seenIds.contains(id)) continue;
      if (likedIds.contains(id) || histIds.contains(id)) continue;
      if (seenArtists.contains(artist)) continue;
      if (s.taste < 0.2) continue;
      explore.add(s.v);
      seenIds.add(id);
      seenArtists.add(artist);
    }

    // Nostalgia: from history that you completed before.
    for (final h in _history) {
      if (nostalgia.length >= nostalgiaTarget) break;
      final id = h.id.value;
      final artist = _primaryArtistKey(h.author);
      if (seenIds.contains(id) || seenArtists.contains(artist)) continue;
      nostalgia.add(h);
      seenIds.add(id);
      seenArtists.add(artist);
    }

    final mixed = <Video>[...inTaste, ...explore, ...nostalgia];
    // Avoid back-to-back same artist.
    return _avoidConsecutiveSameArtist(mixed);
  }

  Future<List<Video>> _searchMusic(
    String query, {
    int limit = 20,
    bool strictSingles = false,
    bool personalize = false,
    bool smartQuery = false,
    bool musicOnly = true,
    bool excludeBlocked = false,
    String? sourceQuery,
  }) async {
    final yt = YoutubeExplode();
    try {
      final results =
          await yt.search.search(query).timeout(const Duration(seconds: 15));
      final allVideos = results.whereType<Video>().toList();
      final filtered = musicOnly
          ? _filterMusicResults(
              allVideos,
              limit: limit * (smartQuery ? 5 : 3),
              strictSingles: strictSingles,
            )
          : allVideos.take(limit * (smartQuery ? 5 : 3)).toList();
      final visible =
          excludeBlocked ? _filterBlockedRecommendations(filtered) : filtered;

      if (visible.isEmpty) return <Video>[];

      if (smartQuery) {
        return _rankSearchResults(
          visible,
          sourceQuery ?? query,
          personalize: personalize,
          preferSongFirst: true,
        ).take(limit).toList();
      }

      if (!personalize || visible.length <= 1) {
        return visible.take(limit).toList();
      }
      return _rankPersonalizedRecommendations(visible, query)
          .take(limit)
          .toList();
    } catch (_) {
      return <Video>[];
    } finally {
      try {
        yt.close();
      } catch (_) {}
    }
  }

  // ignore: unused_element
  Future<List<Video>> _fetchSection(String query) async {
    return _searchMusic(
      query,
      limit: 15,
      strictSingles: true,
      personalize: true,
      excludeBlocked: true,
    );
  }

  // NEW: Trending by country
  static const _countryQueries = [
    'global trending songs official audio',
    'india trending songs official audio',
    'usa trending songs official audio',
    'uk trending songs official audio',
    'kpop trending songs official audio',
    'brazil trending songs official audio',
    'pakistan trending songs official audio',
  ];

  Future<void> _loadTrendingByCountry(int countryIdx) async {
    if (mounted) setState(() => _trendingLoading = true);
    final query = _countryQueries[countryIdx];
    try {
      final results = await _searchMusic(
        query,
        limit: 20,
        excludeBlocked: true,
      );
      if (mounted) {
        setState(() => _trendingVideos = results);
      }
    } catch (e) {
      debugPrint('[Trending] $e');
    } finally {
      if (mounted) setState(() => _trendingLoading = false);
    }
  }

  // "Because you liked" uses taste profile for smarter seeding
  Future<void> _loadBecauseYouLiked() async {
    if (_likedPlaylist.videos.isEmpty && _ytLikedVideos.isEmpty) return;
    if (mounted) setState(() => _becauseYouLikedLoading = true);

    final profile = _buildTasteProfile();
    final topArtists = profile['topArtists'] as List<String>? ?? [];
    final topGenres = profile['topGenres'] as List<String>? ?? [];

    // Build multi-artist seed set to avoid single-artist domination
    final nowArtist = _nowPlaying?.author ?? '';
    final allLiked = _filterBlockedRecommendations(
      [..._ytLikedVideos, ..._likedPlaylist.videos],
    );
    if (allLiked.isEmpty) {
      if (mounted) setState(() => _becauseYouLikedLoading = false);
      return;
    }

    final seeds = <Video>[];
    final seenArtists = <String>{_primaryArtistKey(nowArtist)};
    // Prefer top 3 artists (skip currently playing artist)
    for (final a in topArtists.take(3)) {
      final key = _primaryArtistKey(a);
      if (!seenArtists.add(key)) continue;
      final pick =
          allLiked.where((v) => _primaryArtistKey(v.author) == key).firstOrNull;
      if (pick != null) seeds.add(pick);
    }
    // Backfill with other liked songs by distinct artists
    for (final v in allLiked) {
      if (seeds.length >= 3) break;
      final key = _primaryArtistKey(v.author);
      if (!seenArtists.add(key)) continue;
      if (key.isEmpty) continue;
      seeds.add(v);
    }
    if (seeds.isEmpty) {
      if (mounted) setState(() => _becauseYouLikedLoading = false);
      return;
    }

    try {
      // Gather candidates from multiple seed radios + mixes
      final candidateSets = <Future<List<Video>>>[];
      for (final s in seeds) {
        candidateSets.add(_fetchYtMusicMixSongs(s, limit: 42));
        candidateSets.add(_fetchYtMusicNextSongs(s, limit: 24));
      }
      final gathered = await Future.wait<List<Video>>(candidateSets);
      final candidates = <Video>[];
      for (final batch in gathered) {
        for (final v in batch) {
          if (!_isMusicCandidate(v, strictSingles: true)) continue;
          if (_isRecommendationBlocked(v)) continue;
          candidates.add(v);
        }
      }
      for (final shelf in _ytMusicHomeShelves.take(4)) {
        for (final video in shelf.videos.take(14)) {
          if (!_isMusicCandidate(video, strictSingles: true)) continue;
          if (_isRecommendationBlocked(video)) continue;
          candidates.add(video);
        }
      }
      for (final mix in _ytHomeMixes.take(3)) {
        for (final video in mix.videos.take(12)) {
          if (!_isMusicCandidate(video, strictSingles: true)) continue;
          if (_isRecommendationBlocked(video)) continue;
          candidates.add(video);
        }
      }
      for (final video in _quickRow1.take(24)) {
        if (!_isMusicCandidate(video, strictSingles: true)) continue;
        if (_isRecommendationBlocked(video)) continue;
        candidates.add(video);
      }
      final uniqueCandidates = <String, Video>{};
      for (final video in candidates) {
        uniqueCandidates.putIfAbsent(video.id.value, () => video);
      }
      var results = _rankPersonalizedRecommendations(
        uniqueCandidates.values.toList(),
        topGenres.isNotEmpty
            ? _genreToQuery(topGenres.first)
            : 'because you liked',
      ).take(60).toList();

      if (results.isEmpty) {
        final homeFallback = await _fetchYtMusicHomeSongs(limit: 42);
        results = _rankPersonalizedRecommendations(
          homeFallback,
          topGenres.isNotEmpty
              ? _genreToQuery(topGenres.first)
              : 'because you liked',
        ).take(60).toList();
      }

      if (results.isEmpty && !_strictYtMusicFeedMode) {
        // Search fallback outside strict mode
        final query = topGenres.isNotEmpty
            ? _genreToQuery(topGenres.first)
            : 'official audio songs';

        final fallback = await _searchMusic(
          query,
          limit: 25,
          strictSingles: true,
          personalize: true,
          excludeBlocked: true,
        );
        results =
            _rankPersonalizedRecommendations(fallback, query).take(60).toList();
      }

      // Apply adaptive diversity so results aren't single-artist heavy
      final seedIds = seeds.map((v) => v.id.value).toSet();
      final seedArtists = seeds.map((v) => _primaryArtistKey(v.author)).toSet();
      final rankedPairs = results
          .map((v) => (v: v, score: _personalTasteScore(v, profile)))
          .toList()
        ..sort((a, b) => b.score.compareTo(a.score));
      final diversified = _pickDiverseQuickPicks(
        rankedPairs,
        target: 18,
        seedIds: seedIds,
        seedArtists: seedArtists,
        profile: profile,
      );
      final baseQueue = diversified.isNotEmpty
          ? diversified
          : results
              .where((v) => !_isRecommendationBlocked(v))
              .take(24)
              .toList();
      final knownIds = <String>{
        ..._likedVideoIds,
        ..._likedPlaylist.videos.take(350).map((v) => v.id.value),
        ..._ytLikedVideos.take(350).map((v) => v.id.value),
        ..._history.take(220).map((v) => v.id.value),
      };
      final knownArtists = <String>{
        ..._likedPlaylist.videos
            .take(260)
            .map((v) => _primaryArtistKey(v.author)),
        ..._ytLikedVideos.take(260).map((v) => _primaryArtistKey(v.author)),
        ..._history.take(160).map((v) => _primaryArtistKey(v.author)),
      };
      final familiarPool = <Video>[];
      final discoveryPool = <Video>[];
      for (final video in baseQueue) {
        final artist = _primaryArtistKey(video.author);
        final isFamiliar = knownIds.contains(video.id.value) ||
            seedArtists.contains(artist) ||
            knownArtists.contains(artist);
        if (isFamiliar) {
          familiarPool.add(video);
        } else {
          discoveryPool.add(video);
        }
      }
      final blended = <Video>[];
      final blendedIds = <String>{};
      var familiarIndex = 0;
      var discoveryIndex = 0;

      bool takeFrom(List<Video> pool, int index) {
        if (index < 0 || index >= pool.length) return false;
        final video = pool[index];
        if (!blendedIds.add(video.id.value)) return false;
        blended.add(video);
        return true;
      }

      while (blended.length < 15 &&
          (familiarIndex < familiarPool.length ||
              discoveryIndex < discoveryPool.length)) {
        for (int i = 0; i < 2 && blended.length < 15; i++) {
          while (familiarIndex < familiarPool.length &&
              !takeFrom(familiarPool, familiarIndex)) {
            familiarIndex++;
          }
          if (familiarIndex < familiarPool.length) familiarIndex++;
        }
        if (blended.length >= 15) break;
        while (discoveryIndex < discoveryPool.length &&
            !takeFrom(discoveryPool, discoveryIndex)) {
          discoveryIndex++;
        }
        if (discoveryIndex < discoveryPool.length) discoveryIndex++;
      }
      if (blended.length < 15) {
        for (final video in baseQueue) {
          if (blended.length >= 15) break;
          if (!blendedIds.add(video.id.value)) continue;
          blended.add(video);
        }
      }

      if (mounted) {
        final labelArtists = seeds
            .map((v) => _cleanAuthor(v.author))
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toSet()
            .take(3)
            .toList();
        final label = labelArtists.isEmpty
            ? (topGenres.isNotEmpty
                ? '${topGenres.first[0].toUpperCase()}${topGenres.first.substring(1)}'
                : 'your top picks')
            : (labelArtists.length == 1
                // ignore: unnecessary_string_interpolations
                ? '${labelArtists.first}'
                : '${labelArtists[0]}, ${labelArtists[1]}'
                    '${labelArtists.length > 2 ? ' + more' : ''}');
        setState(() {
          _becauseYouLiked = blended.take(15).toList();
          _becauseYouLikedLabel = label;
        });
      }
    } catch (e) {
      debugPrint('[BecauseYouLiked] $e');
    } finally {
      if (mounted) setState(() => _becauseYouLikedLoading = false);
    }
  }

  // Generate daily mixes from taste profile (like Spotify Daily Mix)
  Future<void> _generateDailyMixes() async {
    if (_dailyMixGenerated) return;
    final profile = _buildTasteProfile();
    final topArtists = profile['topArtists'] as List<String>? ?? [];
    final topGenres = profile['topGenres'] as List<String>? ?? [];

    if (topArtists.isEmpty && topGenres.isEmpty) return;
    _dailyMixGenerated = true;

    final seedPool = _personalMixSeedPool();
    final usedSeedIds = <String>{};
    final mixSeeds = <({String name, String query, Video? seed})>[];
    if (topArtists.isNotEmpty) {
      final artistSeed = _pickMixSeedVideo(
        pool: seedPool,
        artist: topArtists.first,
        excludeIds: usedSeedIds,
      );
      if (artistSeed != null) usedSeedIds.add(artistSeed.id.value);
      mixSeeds.add((
        name: topArtists.first,
        query: '${topArtists.first} songs official audio',
        seed: artistSeed,
      ));
    }
    if (topGenres.isNotEmpty) {
      final genreSeed = _pickMixSeedVideo(
        pool: seedPool,
        tag: topGenres.first,
        excludeIds: usedSeedIds,
      );
      if (genreSeed != null) usedSeedIds.add(genreSeed.id.value);
      mixSeeds.add((
        name: topGenres.first[0].toUpperCase() + topGenres.first.substring(1),
        query: _genreToQuery(topGenres.first),
        seed: genreSeed,
      ));
    }
    if (topArtists.length >= 2) {
      final artistSeed = _pickMixSeedVideo(
        pool: seedPool,
        artist: topArtists[1],
        excludeIds: usedSeedIds,
      );
      if (artistSeed != null) usedSeedIds.add(artistSeed.id.value);
      mixSeeds.add((
        name: topArtists[1],
        query: '${topArtists[1]} songs official audio',
        seed: artistSeed,
      ));
    } else if (topGenres.length >= 2) {
      final genreSeed = _pickMixSeedVideo(
        pool: seedPool,
        tag: topGenres[1],
        excludeIds: usedSeedIds,
      );
      if (genreSeed != null) usedSeedIds.add(genreSeed.id.value);
      mixSeeds.add((
        name: topGenres[1][0].toUpperCase() + topGenres[1].substring(1),
        query: _genreToQuery(topGenres[1]),
        seed: genreSeed,
      ));
    }

    var generatedCount = 0;
    for (int i = 0; i < mixSeeds.take(3).length; i++) {
      final seed = mixSeeds[i];
      try {
        List<Video> visible = const <Video>[];

        if (seed.seed != null) {
          final ytSources = await Future.wait<List<Video>>([
            _fetchYtMusicMixSongs(seed.seed!, limit: 52),
            _fetchYtMusicNextSongs(seed.seed!, limit: 24),
          ]);
          visible = _rankYtMusicMixRecommendations(
            [...ytSources[0], ...ytSources[1]],
            seed.seed!,
            limit: 20,
            queryHint: '${seed.name} mix',
          );
        }

        if (visible.isEmpty) {
          final homeFallback = await _fetchYtMusicHomeSongs(limit: 56);
          if (homeFallback.isNotEmpty) {
            if (seed.seed == null) {
              visible = homeFallback.take(20).toList();
            } else {
              visible = _rankYtMusicMixRecommendations(
                homeFallback,
                seed.seed!,
                limit: 20,
                queryHint: '${seed.name} yt music home',
              );
            }
          }
        }

        if (visible.isEmpty && !_strictYtMusicFeedMode) {
          final yt = YoutubeExplode();
          try {
            final results = await yt.search
                .search(seed.query)
                .timeout(const Duration(seconds: 15));
            final videos = _filterBlockedRecommendations(
              _filterMusicResults(
                results.whereType<Video>(),
                limit: 40,
                strictSingles: true,
              ),
              limit: 40,
            );
            final ranked = _rankPersonalizedRecommendations(videos, seed.query);
            visible = seed.seed == null
                ? ranked.take(20).toList()
                : ranked
                    .where((video) => video.id.value != seed.seed!.id.value)
                    .take(20)
                    .toList();
          } finally {
            try {
              yt.close();
            } catch (_) {}
          }
        }

        if (mounted && visible.isNotEmpty) {
          generatedCount += 1;
          setState(() {
            _dailyMixes.add(BeastPlaylist(
              id: '__dailymix_$i',
              name: 'Daily Mix ${i + 1}',
              videos: visible,
              isSystem: true,
            ));
          });
        }
      } catch (e) {
        debugPrint('[DailyMix] $e');
      }
    }

    if (generatedCount == 0) {
      _dailyMixGenerated = false;
    }
  }

  // NEW: Related artists for full-screen player
  void _updateRelatedArtists() {
    if (_nowPlaying == null) return;
    final now = _nowPlaying!;
    final currentArtist = _primaryArtistKey(now.author);
    final currentText = '${now.title} ${now.author}'.toLowerCase();
    final currentLang = _detectLanguageTag(currentText);
    final currentTags = _extractMusicTags(currentText);

    final pool = <Video>[
      ..._history.take(40),
      ..._playQueue.take(80),
      ..._becauseYouLiked.take(60),
      ..._likedPlaylist.videos.take(200),
      ..._ytLikedVideos.take(200),
    ];
    final seenVideoIds = <String>{};
    final scoreByArtist = <String, double>{};
    final labelByArtist = <String, String>{};

    for (int i = 0; i < pool.length; i++) {
      final v = pool[i];
      if (!seenVideoIds.add(v.id.value)) continue;
      if (!_isMusicCandidate(v)) continue;
      if (_isRecommendationBlocked(v)) continue;
      final artistLabel = _cleanAuthor(v.author);
      final artistKey = _primaryArtistKey(v.author);
      if (artistKey.isEmpty || artistKey == currentArtist) continue;

      final text = '${v.title} ${v.author}'.toLowerCase();
      final tags = _extractMusicTags(text);
      final overlap = tags.where(currentTags.contains).length;
      final lang = _detectLanguageTag(text);

      double score = 1.0;
      if (lang == currentLang) score += 2.2;
      score += overlap * 1.6;
      score += (_artistActionBoost[artistKey] ?? 0.0) * 1.6;
      score += (_langActionBoost[lang] ?? 0.0) * 0.9;
      score += (_videoActionBoost[v.id.value.toLowerCase()] ?? 0.0) * 0.35;
      score += _queryAffinityForText(text) * 0.4;
      for (final t in tags) {
        score += (_genreActionBoost[t] ?? 0.0) * 0.2;
      }
      if (_likedVideoIds.contains(v.id.value)) score += 0.9;
      if (i < 24) {
        score += 1.2;
      } else if (i < 80) {
        score += 0.6;
      }

      scoreByArtist[artistKey] = (scoreByArtist[artistKey] ?? 0) + score;
      labelByArtist[artistKey] = artistLabel;
    }

    var artists = scoreByArtist.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    var out = artists.take(6).map((e) => labelByArtist[e.key]!).toList();

    if (out.length < 3) {
      final topArtists =
          (_buildTasteProfile()['topArtists'] as List<String>? ?? [])
              .where((a) => _primaryArtistKey(a) != currentArtist)
              .map(_cleanAuthor)
              .toList();
      for (final a in topArtists) {
        if (!out.any((x) => x.toLowerCase() == a.toLowerCase())) {
          out.add(a);
          if (out.length >= 6) break;
        }
      }
    }

    if (mounted) setState(() => _relatedArtists = out.take(6).toList());
  }

  // Explore genre
  Future<void> _loadGenre(String genre) async {
    setState(() {
      _selectedGenre = genre;
      _exploreLoading = true;
      _exploreResults = [];
    });
    try {
      final results = await _searchMusic(
        '$genre songs official audio',
        limit: 20,
        strictSingles: true,
        excludeBlocked: true,
      );
      if (mounted) {
        setState(() => _exploreResults = results);
      }
    } catch (e) {
      debugPrint('[Explore] $e');
    } finally {
      if (mounted) setState(() => _exploreLoading = false);
    }
  }

  // Search
  void _onSearchInputChanged(String value) {
    final hasText = value.trim().isNotEmpty;
    _searchSuggestDebounce?.cancel();

    if (!hasText) {
      _searchRequestSeq++;
      setState(() {
        _isSearchMode = false;
        _isLoading = false;
        _searchResults = [];
        _searchSuggestions = [];
        _searchDidYouMean = null;
        _searchResultView = 'top';
      });
      return;
    }

    setState(() {
      _isSearchMode = true;
      _searchResults = [];
    });

    _searchSuggestDebounce = Timer(const Duration(milliseconds: 140), () {
      if (!mounted) return;
      final suggestions = _buildSearchSuggestions(value);
      if (!mounted) return;
      setState(() => _searchSuggestions = suggestions);
    });
  }

  void _applySearchSuggestion(String suggestion) {
    final text = suggestion.trim();
    if (text.isEmpty) return;
    _searchController
      ..text = text
      ..selection = TextSelection.collapsed(offset: text.length);
    _selectedTab = 0;
    _search(text);
  }

  void _resetSearchState() {
    _searchSuggestDebounce?.cancel();
    _searchRequestSeq++;
    _searchController.clear();
    setState(() {
      _isSearchMode = false;
      _isLoading = false;
      _searchResults = [];
      _searchSuggestions = [];
      _searchDidYouMean = null;
      _searchResultView = 'top';
    });
  }

  Future<void> _search(String query) async {
    final rawQuery = query.trim();
    if (rawQuery.isEmpty) return;

    final corrected = _correctSearchQuery(rawQuery);
    final requestId = ++_searchRequestSeq;

    _registerSearchFeedback(rawQuery, weight: 0.7);
    setState(() {
      _isLoading = true;
      _isSearchMode = true;
      _searchResults = [];
      _searchDidYouMean = corrected;
      _searchSuggestions = _buildSearchSuggestions(rawQuery);
      _searchResultView = 'top';
      final h = rawQuery;
      if (h.isNotEmpty) {
        _searchHistory.removeWhere(
            (x) => _normalizeSignalKey(x) == _normalizeSignalKey(h));
        _searchHistory.insert(0, h);
        if (_searchHistory.length > 50) {
          _searchHistory.removeLast();
        }
      }
    });
    _scheduleSave();

    try {
      final searchQueries = <String>[
        rawQuery,
        if (corrected != null &&
            corrected.trim().isNotEmpty &&
            _normalizeSignalKey(corrected) != _normalizeSignalKey(rawQuery))
          corrected.trim(),
      ];
      final batches = await Future.wait(
        searchQueries.map(
          (q) => _searchMusic(
            q,
            limit: 60,
            strictSingles: false,
            personalize: false,
            smartQuery: false,
            musicOnly: false,
            sourceQuery: rawQuery,
          ),
        ),
      );

      if (!mounted || requestId != _searchRequestSeq) return;

      final merged = <String, Video>{};
      for (final batch in batches) {
        for (final video in batch) {
          merged.putIfAbsent(video.id.value, () => video);
        }
      }

      var results = merged.values.toList();
      if (results.isEmpty) {
        final fallbackQuery = (corrected ?? rawQuery).trim();
        results = await _searchMusic(
          fallbackQuery,
          limit: 60,
          strictSingles: false,
          personalize: false,
          smartQuery: false,
          musicOnly: false,
          sourceQuery: rawQuery,
        );
      }

      if (!mounted || requestId != _searchRequestSeq) return;

      setState(() {
        _searchResults = results.take(60).toList();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Search failed: $e',
                maxLines: 2, overflow: TextOverflow.ellipsis)));
      }
    } finally {
      if (mounted && requestId == _searchRequestSeq) {
        setState(() => _isLoading = false);
      }
    }
  }

  // Open artist page
  Future<void> _openArtistPage(String artistName) async {
    _registerSearchFeedback(artistName, weight: 0.65);
    setState(() {
      _artistPageName = artistName;
      _artistVideos = [];
      _artistLoading = true;
      _showNowPlaying = false;
    });
    try {
      final results = await _searchMusic(
        '$artistName songs official audio',
        limit: 25,
      );
      if (mounted) {
        setState(() => _artistVideos = results);
      }
    } catch (e) {
      debugPrint('[Artist] $e');
    } finally {
      if (mounted) setState(() => _artistLoading = false);
    }
  }

  // Sorted playlists
  List<BeastPlaylist> get _sortedPlaylists {
    final list = List<BeastPlaylist>.from(_playlists);
    switch (_librarySortMode) {
      case 1:
        list.sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      case 2:
        list.sort((a, b) => b.videos.length.compareTo(a.videos.length));
      case 3:
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      default:
        break;
    }
    return list;
  }

  List<BeastPlaylist> _playlistMatchesForSearch(String query) {
    final q = _normalizeSignalKey(query);
    if (q.isEmpty) return const [];
    final out = <BeastPlaylist>[];
    final seen = <String>{};
    final pool = <BeastPlaylist>[
      _likedPlaylist,
      ..._ytHomeMixes,
      ..._dailyMixes,
      ..._sortedPlaylists,
    ];
    for (final pl in pool) {
      if (!seen.add(pl.id)) continue;
      final byName = _normalizeSignalKey(pl.name).contains(q);
      var bySong = false;
      if (!byName) {
        for (final video in pl.videos) {
          final haystack = _normalizeSignalKey('${video.title} ${video.author}');
          if (haystack.contains(q)) {
            bySong = true;
            break;
          }
        }
      }
      if (byName || bySong) {
        out.add(pl);
      }
      if (out.length >= 8) break;
    }
    return out;
  }

  void _openPlaylistFromSearch(BeastPlaylist playlist) {
    setState(() {
      _openPlaylist = playlist;
      _selectedTab = 2;
      _playlistSearchQuery = '';
      _playlistSearchCtrl.clear();
      _libraryReorderMode = false;
    });
  }

  Widget _buildSearchPlaylistMatchTile(BeastPlaylist playlist) {
    final subtitle = _playlistDownloadLabel(playlist);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF141414),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF252525)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _openPlaylistFromSearch(playlist),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: Colors.greenAccent.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.queue_music_rounded,
                      color: Colors.greenAccent, size: 22),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        playlist.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.grey[500], fontSize: 11),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded,
                    color: Colors.grey[500], size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Fetch manifest
  Future<({StreamManifest manifest, YoutubeExplode yt})?> _fetchManifest(
      String videoId,
      {bool silent = false, bool fast = false}) async {
    _youtubeDnsBlocked = false;
    final overallDeadline = fast
        ? const Duration(seconds: 22)
        : const Duration(seconds: 55);
    final perAttemptTimeout = fast
        ? const Duration(seconds: 6)
        : const Duration(seconds: 12);
    final started = Stopwatch()..start();
    final appNativeClients = Platform.isAndroid
        ? [
            YoutubeApiClient.androidMusic,
            YoutubeApiClient.android,
            YoutubeApiClient.androidVr,
          ]
        : (Platform.isIOS || Platform.isMacOS)
            ? [YoutubeApiClient.ios, YoutubeApiClient.mweb]
            : [YoutubeApiClient.mweb, YoutubeApiClient.tv];
    final strategies =
        <({List<YoutubeApiClient>? clients, String label, int retries, Duration timeout})>[
      // App-defined native strategy (primary).
      (
        clients: appNativeClients,
        label: 'nativePrimary',
        retries: 0,
        timeout: perAttemptTimeout,
      ),
      // Android VR often bypasses failures seen with other mobile clients.
      (
        clients: [YoutubeApiClient.androidVr, YoutubeApiClient.android],
        label: 'androidVr',
        retries: 2,
        timeout: perAttemptTimeout,
      ),
      // Web-ish fallback can work on some networks where native clients fail.
      (
        clients: [YoutubeApiClient.mweb, YoutubeApiClient.tv],
        label: 'mwebFallback',
        retries: 2,
        timeout: perAttemptTimeout,
      ),
      // Final rescue path so playback can still recover if both fail.
      (
        clients: null,
        label: 'autoRescue',
        retries: 1,
        timeout: perAttemptTimeout,
      ),
    ];
    Object? lastError;
    for (final strategy in strategies) {
      final maxAttempts = strategy.retries + 1;
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        if (started.elapsed > overallDeadline &&
            strategy.label != 'autoRescue') {
          debugPrint(
            '[Manifest] overall deadline reached before ${strategy.label}; '
            'moving to rescue strategy',
          );
          break;
        }
        if (!silent && mounted) {
          final retryText = attempt > 1 ? ' (retry $attempt/$maxAttempts)' : '';
          setState(() => _bufferLabel = 'Connecting via ${strategy.label}$retryText...');
        }

        final yt = YoutubeExplode();
        try {
          final manifest = strategy.clients == null
              ? await yt.videos.streamsClient
                  .getManifest(videoId)
                  .timeout(strategy.timeout)
              : await yt.videos.streamsClient
                  .getManifest(videoId, ytClients: strategy.clients)
                  .timeout(strategy.timeout);
          if (manifest.audioOnly.isEmpty) throw Exception('no audio streams');
          if (Platform.isAndroid) {
            final hasAndroidFriendlyAudio = manifest.audioOnly.any((s) {
              final name = s.container.name.toLowerCase();
              return name.contains('mp4') || name.contains('m4a');
            });
            if (!hasAndroidFriendlyAudio && strategy.label != 'autoRescue') {
              throw Exception('no mp4/m4a audio in ${strategy.label}');
            }
          }
          return (manifest: manifest, yt: yt);
        } catch (e) {
          lastError = e;
          debugPrint(
            '[Manifest] ${strategy.label} attempt $attempt/$maxAttempts failed: $e',
          );
          if (_isBotVerificationError(e)) {
            debugPrint(
              '[Manifest] Restricted/bot challenge detected. '
              'Switching to proxy/next fallback immediately.',
            );
            try {
              yt.close();
            } catch (_) {}
            return null;
          }
          if (_isDnsLookupError(e)) {
            _youtubeDnsBlocked = true;
            debugPrint('[Manifest] DNS/network lookup failure. Aborting retries.');
            if (!silent && mounted) {
              setState(() {
                _bufferLabel =
                    'AdGuard DNS blocked YouTube. Allow: youtube.com, music.youtube.com, googlevideo.com, ytimg.com, youtubei.googleapis.com';
              });
            }
            try {
              yt.close();
            } catch (_) {}
            return null;
          }
          try {
            yt.close();
          } catch (_) {}
          if (started.elapsed > overallDeadline &&
              strategy.label != 'autoRescue') {
            debugPrint(
              '[Manifest] deadline exceeded after ${strategy.label} failure; '
              'moving to rescue strategy',
            );
            break;
          }
          if (attempt < maxAttempts && e is! TimeoutException) {
            await Future<void>.delayed(Duration(milliseconds: 240 * attempt));
          }
        }
      }
    }
    debugPrint('[Manifest] all strategies exhausted: $lastError');
    return null;
  }

  // Play
  // FIX: Set _currentVideoId immediately (before any await) so stale
  // async callbacks from a previous _play() see the mismatch and bail.
  Future<void> _play(
    Video video,
    int index, {
    bool autoPlay = true,
    Duration? seekPosition,
    bool restoringSession = false,
  }) async {
    final videoId = video.id.value;
    final previous = _nowPlaying;
    if (previous != null && previous.id.value != videoId) {
      final shouldSkipOutcome =
          _skipOutcomeUpdateForVideoId == previous.id.value || restoringSession;
      if (shouldSkipOutcome) {
        if (_skipOutcomeUpdateForVideoId == previous.id.value) {
          _skipOutcomeUpdateForVideoId = null;
        }
      } else {
        final prevSecs = _player.position.inSeconds;
        if (prevSecs >= 6) {
          _updateListeningOutcomeForVideo(
            previous.id.value,
            playedSecs: prevSecs,
            completed: false,
          );
        }
      }
      _cfObserveTransition(previous.id.value, videoId, weight: 1.0);
    }
    if (_playQueue.isEmpty) {
      _playQueue = [video];
      index = 0;
    } else if (index < 0 ||
        index >= _playQueue.length ||
        _playQueue[index].id.value != videoId) {
      final existing = _playQueue.indexWhere((v) => v.id.value == videoId);
      if (existing >= 0) {
        index = existing;
      } else {
        final insertAt =
            (_currentIndex >= 0 && _currentIndex < _playQueue.length)
                ? _currentIndex + 1
                : _playQueue.length;
        _playQueue.insert(insertAt, video);
        index = insertAt;
      }
    }

    // CRITICAL: mark intent before any await
    _currentVideoId = videoId;
    _currentDownloadIndex = -1;
    _prefetchForVideoId = videoId;

    // Cancel previous download (fire-and-forget is fine)
    _activeDl?.cancel();
    _activeDl = null;
    _playYt?.close();
    _playYt = null;
    await _cancelActiveSecondaryPlayback();
    await _player.stop();

    // If another _play() was called while we were stopping, bail.
    if (_currentVideoId != videoId) return;

    if (!restoringSession) {
      _history.removeWhere((v) => v.id == video.id);
      _history.insert(0, video);
      if (_history.length > 50) _history.removeLast();
      _recordListeningEvent(video, isDownload: false);
    }
    _radioSeenIds.add(videoId);
    _scheduleSave();

    setState(() {
      _nowPlaying = video;
      _currentIndex = index;
      _isBuffering = true;
      _bufferProgress = 0;
      _bufferLabel = 'Loading...';
    });
    _notifyQueueChanged();

    _updateRelatedArtists();
    if (_radioMode) {
      final upcoming = _playQueue.length - index - 1;
      if (upcoming < 4) {
        unawaited(_appendRadioCandidates(video, minAdds: 10 - upcoming));
      }
    }
    _ensureQueueBackfilledWithYtMusicAi(
      video,
      localMinUpcoming: _radioMode ? 6 : 5,
      networkMinUpcoming: _radioMode ? 10 : 9,
    );

    // Auto-generate daily mixes once we have liked songs or enough history
    if (!_dailyMixGenerated &&
        (_ytLikedVideos.isNotEmpty ||
            _likedPlaylist.videos.length >= 2 ||
            _history.length >= 3)) {
      unawaited(_generateDailyMixes());
    }

    // Serve from cache
    final cached = _tmpFiles[videoId];
    if (cached != null && await File(cached).exists()) {
      if (_currentVideoId != videoId) return;
      if (mounted) setState(() => _bufferLabel = 'Starting...');
      bool cacheSuccess = true;
      try {
        await _setPlayerSource(
          AudioSource.uri(
            Uri.file(cached),
            tag: _mediaItemForVideo(video, cached),
          ),
        );
        await _player.setSpeed(_playbackSpeed);
        await _applyNormalizationForPlayer(_player, video);
        if (mounted && _currentVideoId == videoId) {
          setState(() => _isBuffering = false);
        }
        if (seekPosition != null) {
          await _player.seek(seekPosition);
        }
        if (_currentVideoId == videoId) {
          if (autoPlay) {
            await _startPrimaryPlayback();
          } else {
            await _player.pause();
          }
        }
        unawaited(_prefetchNext(index, videoId));
      } catch (e) {
        debugPrint('[Player cache] $e');
        _tmpFiles.remove(videoId);
        cacheSuccess = false;
        // Fall through to re-fetch
      }
      if (cacheSuccess) return;
    }
    _tmpFiles.remove(videoId);

    try {
      if (_shouldUseYtMusicBackend()) {
        if (mounted && _currentVideoId == videoId) {
          setState(() => _bufferLabel = 'Connecting via backend...');
        }
        final proxyPlayed = await _tryPlayViaBackendProxy(
          video,
          autoPlay: autoPlay,
          seekPosition: seekPosition,
        );
        if (_currentVideoId != videoId) return;
        if (proxyPlayed) {
          if (mounted && _currentVideoId == videoId) {
            setState(() => _isBuffering = false);
          }
          unawaited(_prefetchNext(index, videoId));
          return;
        }
      } else if (mounted && _currentVideoId == videoId) {
        setState(() => _bufferLabel = 'Resolving stream on device...');
      }

      final result = await _fetchManifest(videoId);
      if (_currentVideoId != videoId) return;
      if (result == null) {
        if (_youtubeDnsBlocked) {
          throw Exception(
            'AdGuard DNS is blocking YouTube hosts. Whitelist: youtube.com, '
            'music.youtube.com, googlevideo.com, ytimg.com, '
            'youtubei.googleapis.com, ggpht.com',
          );
        }
        throw Exception('Playback stream unavailable');
      }

      final audioStream = _selectStream(result.manifest.audioOnly.toList());
      _playYt = result.yt;

      if (mounted && _currentVideoId == videoId) {
        setState(() {
          _bufferLabel = 'Buffering...';
          _isBuffering = true;
        });
      }

      if (_currentVideoId != videoId) return;
      var startedViaBeast = false;
      final streamContainer = audioStream.container.name.toLowerCase();
      final androidFriendlyContainer =
          streamContainer.contains('mp4') || streamContainer.contains('m4a');
      if (!Platform.isAndroid || androidFriendlyContainer) {
        startedViaBeast = await _tryPlayViaBeastClientStream(
          video,
          streamUri: Uri.parse(audioStream.url.toString()),
          headers: _directPlaybackHeaders(),
          autoPlay: autoPlay,
          seekPosition: seekPosition,
        );
      }
      if (!startedViaBeast) {
        final source = AudioSource.uri(
          Uri.parse(audioStream.url.toString()),
          headers: _directPlaybackHeaders(),
          tag: _mediaItemForVideo(video, ''),
        );
        await _setPlayerSource(source);
        await _player.setSpeed(_playbackSpeed);
        await _applyNormalizationForPlayer(_player, video);
        if (seekPosition != null) {
          await _player.seek(seekPosition);
        }
        if (_currentVideoId == videoId) {
          if (autoPlay) {
            await _startPrimaryPlayback();
          } else {
            await _player.pause();
          }
        }
        startedViaBeast = true;
      }
      if (!startedViaBeast) {
        throw Exception('Playback could not start.');
      }
      if (mounted && _currentVideoId == videoId) {
        setState(() => _isBuffering = false);
      }

      unawaited(_prefetchNext(index, videoId));
    } catch (e) {
      debugPrint('[Play] failed: $e');
      if (_currentVideoId == videoId && _isRecoverableSourceError(e)) {
        if (mounted) {
          setState(() {
            _bufferLabel = 'Reconnecting stream...';
            _isBuffering = true;
          });
        }
        final recovered = await _recoverSourceAndPlay(
          video,
          autoPlay: autoPlay,
          seekPosition: seekPosition,
        );
        if (recovered) {
          if (mounted && _currentVideoId == videoId) {
            setState(() => _isBuffering = false);
          }
          unawaited(_prefetchNext(index, videoId));
          return;
        }
      }
      if (_currentVideoId == videoId && _shouldUseYtMusicBackend()) {
        final proxyPlayed = await _tryPlayViaBackendProxy(
          video,
          autoPlay: autoPlay,
          seekPosition: seekPosition,
        );
        if (proxyPlayed) {
          if (mounted && _currentVideoId == videoId) {
            setState(() => _isBuffering = false);
          }
          return;
        }
      }
      if (_currentVideoId == videoId &&
          _isBotVerificationError(e) &&
          _currentIndex < _playQueue.length - 1) {
        if (mounted) {
          setState(() {
            _bufferLabel = 'Track blocked, skipping...';
            _isBuffering = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('This track is restricted. Skipping to next song.'),
              duration: Duration(seconds: 3),
            ),
          );
        }
        _playNext();
        return;
      }
      if (_currentVideoId == videoId &&
          _isManifestTimeoutOrUnavailable(e) &&
          _currentIndex < _playQueue.length - 1) {
        if (mounted) {
          setState(() {
            _bufferLabel = 'Slow source, trying next...';
            _isBuffering = false;
          });
        }
        _playNext();
        return;
      }
      if (mounted && _currentVideoId == videoId) {
        setState(() => _isBuffering = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not play: $e'),
            duration: const Duration(seconds: 4)));
      }
    }
  }

  // Prefetch
  Future<void> _prefetchNext(int fromIndex, String forVideoId) async {
    if (_prefetchRunning) return;
    _prefetchRunning = true;
    _prefetchForVideoId = forVideoId;

    try {
      for (int i = 1; i <= _prefetchAhead; i++) {
        final idx = fromIndex + i;
        if (idx >= _playQueue.length) break;
        if (_prefetchForVideoId != forVideoId) break;

        final video = _playQueue[idx];
        final videoId = video.id.value;

        if (_tmpFiles.containsKey(videoId)) continue;
        if (_prefetching.contains(videoId)) continue;
        _prefetching.add(videoId);

        try {
          final result = await _fetchManifest(videoId, silent: true);
          if (result == null) {
            _prefetching.remove(videoId);
            continue;
          }
          if (_prefetchForVideoId != forVideoId) {
            result.yt.close();
            _prefetching.remove(videoId);
            break;
          }

          final audioStream = _selectStream(result.manifest.audioOnly.toList());
          final tmpDir = await getTemporaryDirectory();
          final tmpPath =
              '${tmpDir.path}/$videoId.${audioStream.container.name}';

          if (await File(tmpPath).exists()) {
            _tmpFiles[videoId] = tmpPath;
            _prefetching.remove(videoId);
            continue;
          }

          final sink = File(tmpPath).openWrite();
          try {
            await for (final chunk
                in result.yt.videos.streamsClient.get(audioStream)) {
              if (_prefetchForVideoId != forVideoId) break;
              sink.add(chunk);
            }
            await sink.flush();
            await sink.close();
            if (_prefetchForVideoId == forVideoId) {
              _tmpFiles[videoId] = tmpPath;
            } else {
              try {
                await File(tmpPath).delete();
              } catch (_) {}
            }
          } finally {
            try {
              result.yt.close();
            } catch (_) {}
            _prefetching.remove(videoId);
          }
        } catch (e) {
          debugPrint('[Prefetch] error: $e');
          _prefetching.remove(videoId);
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    } finally {
      _prefetchRunning = false;
    }
  }

  bool get _isDownloadPlayback =>
      _currentVideoId?.startsWith('download:') ?? false;
  bool get _shuffleActiveInCurrentContext =>
      _isDownloadPlayback ? _downloadShuffleOn : _shuffleOn;
  bool get _canSkipPreviousInCurrentContext =>
      _isDownloadPlayback ? _currentDownloadIndex >= 0 : _currentIndex > 0;

  bool _isValidDownloadQueue(List<int> queue) {
    if (queue.length != _downloads.length) return false;
    final seen = <int>{};
    for (final idx in queue) {
      if (idx < 0 || idx >= _downloads.length) return false;
      if (!seen.add(idx)) return false;
    }
    return true;
  }

  List<int> _allDownloadIndices() =>
      List<int>.generate(_downloads.length, (i) => i);

  void _ensureDownloadQueueForPlayback(int selectedIndex,
      {bool reset = false}) {
    if (_downloads.isEmpty ||
        selectedIndex < 0 ||
        selectedIndex >= _downloads.length) {
      _downloadQueue.clear();
      _unshuffledDownloadQueue.clear();
      _currentDownloadQueuePos = -1;
      return;
    }

    if (reset || !_isValidDownloadQueue(_downloadQueue)) {
      final all = _allDownloadIndices();
      if (_downloadShuffleOn) {
        _unshuffledDownloadQueue
          ..clear()
          ..addAll(all);
        final rest = all.where((i) => i != selectedIndex).toList()..shuffle();
        _downloadQueue
          ..clear()
          ..add(selectedIndex)
          ..addAll(rest);
      } else {
        _downloadQueue
          ..clear()
          ..addAll(all);
        _unshuffledDownloadQueue.clear();
      }
    }

    if (!_downloadQueue.contains(selectedIndex)) {
      _downloadQueue
        ..clear()
        ..addAll(_allDownloadIndices());
      _unshuffledDownloadQueue.clear();
      _downloadShuffleOn = false;
    }

    _currentDownloadQueuePos = _downloadQueue.indexOf(selectedIndex);
  }

  int? get _downloadNextIndex {
    if (_downloads.isEmpty ||
        _downloadQueue.isEmpty ||
        _currentDownloadQueuePos < 0) {
      return null;
    }
    final nextPos = _currentDownloadQueuePos + 1;
    if (nextPos < _downloadQueue.length) return _downloadQueue[nextPos];
    if (_repeatMode == 1 && _downloadQueue.isNotEmpty) return _downloadQueue[0];
    return null;
  }

  int? get _downloadPreviousIndex {
    if (_downloads.isEmpty ||
        _downloadQueue.isEmpty ||
        _currentDownloadQueuePos < 0) {
      return null;
    }
    final prevPos = _currentDownloadQueuePos - 1;
    if (prevPos >= 0) return _downloadQueue[prevPos];
    if (_repeatMode == 1 && _downloadQueue.isNotEmpty) {
      return _downloadQueue.last;
    }
    return null;
  }

  String _resolveDownloadVideoId(Map<String, String> download) {
    final sourceId = (download['sourceVideoId'] ?? '').trim();
    if (VideoId.validateVideoId(sourceId)) return sourceId;

    final thumbUrl = (download['thumbnailUrl'] ?? '').trim();
    if (thumbUrl.isNotEmpty) {
      final thumbMatch = RegExp(r'/vi(?:_webp)?/([0-9A-Za-z_-]{11})(?:/|$)')
          .firstMatch(thumbUrl);
      if (thumbMatch != null) return thumbMatch.group(1)!;

      final urlMatch =
          RegExp(r'(?:v=|youtu\.be/)([0-9A-Za-z_-]{11})(?:[&?/]|$)')
              .firstMatch(thumbUrl);
      if (urlMatch != null) return urlMatch.group(1)!;
    }

    // Neutral fallback for malformed legacy download metadata.
    return '00000000000';
  }

  int _findDownloadIndexByVideoId(String videoId) {
    return _downloads.indexWhere((d) => _resolveDownloadVideoId(d) == videoId);
  }

  bool _hasDownloadForVideoId(String videoId) =>
      _findDownloadIndexByVideoId(videoId) >= 0;

  bool _isVideoDownloaded(Video video) =>
      _hasDownloadForVideoId(video.id.value);

  _DownloadTask? _taskForVideoId(String videoId) {
    for (final t in _downloadTasks) {
      if (t.videoId == videoId) return t;
    }
    return null;
  }

  bool _isTaskActive(_DownloadTask task) =>
      _runningDownloadTaskIds.contains(task.id);

  String _downloadTaskLabel(_DownloadTask task) {
    switch (task.state) {
      case _DownloadTaskState.queued:
        return 'Queued';
      case _DownloadTaskState.downloading:
        if (task.progress >= 0.985) return 'Finalizing...';
        final p = (task.progress * 100).clamp(0, 100).toStringAsFixed(0);
        return 'Downloading $p%';
      case _DownloadTaskState.paused:
        return 'Paused';
      case _DownloadTaskState.failed:
        return 'Failed';
    }
  }

  int get _pendingDownloadTaskCount => _downloadTasks
      .where((t) =>
          t.state == _DownloadTaskState.queued ||
          t.state == _DownloadTaskState.downloading)
      .length;

  int get _pausedOrFailedDownloadTaskCount => _downloadTasks
      .where((t) =>
          t.state == _DownloadTaskState.paused ||
          t.state == _DownloadTaskState.failed)
      .length;

  _DownloadTask? get _activeDownloadTask {
    for (final task in _downloadTasks) {
      if (task.state == _DownloadTaskState.downloading) {
        return task;
      }
    }
    return null;
  }

  Set<String> _playlistDownloadableIds(BeastPlaylist pl) {
    final ids = <String>{};
    for (final video in pl.videos) {
      if (_isMusicCandidate(video, strictSingles: true)) {
        ids.add(video.id.value);
      }
    }
    return ids;
  }

  Map<String, int> _playlistDownloadStats(BeastPlaylist pl) {
    final ids = _playlistDownloadableIds(pl);
    var downloaded = 0;
    var queued = 0;
    var downloading = 0;
    var paused = 0;
    var failed = 0;

    for (final id in ids) {
      if (_hasDownloadForVideoId(id)) downloaded += 1;
    }
    for (final task in _downloadTasks) {
      if (!ids.contains(task.videoId)) continue;
      switch (task.state) {
        case _DownloadTaskState.queued:
          queued += 1;
          break;
        case _DownloadTaskState.downloading:
          downloading += 1;
          break;
        case _DownloadTaskState.paused:
          paused += 1;
          break;
        case _DownloadTaskState.failed:
          failed += 1;
          break;
      }
    }

    return {
      'total': ids.length,
      'downloaded': downloaded,
      'queued': queued,
      'downloading': downloading,
      'paused': paused,
      'failed': failed,
    };
  }

  String _playlistDownloadLabel(BeastPlaylist pl) {
    final stats = _playlistDownloadStats(pl);
    final total = stats['total'] ?? 0;
    if (total <= 0) return '${pl.videos.length} songs';
    final downloaded = stats['downloaded'] ?? 0;
    final queued = stats['queued'] ?? 0;
    final downloading = stats['downloading'] ?? 0;
    final paused = stats['paused'] ?? 0;
    final parts = <String>['$downloaded/$total downloaded'];
    if (downloading > 0) {
      parts.add('$downloading downloading');
    } else if (queued > 0) {
      parts.add('$queued queued');
    } else if (paused > 0) {
      parts.add('$paused paused');
    }
    return parts.join(' | ');
  }

  void _pauseDownloadsForVideoIds(
    Set<String> ids, {
    required String label,
  }) {
    var changed = false;
    for (final task in _downloadTasks) {
      if (!ids.contains(task.videoId)) continue;
      if (_isTaskActive(task) && task.state == _DownloadTaskState.downloading) {
        _requestPauseDownloadTask(task);
        changed = true;
      } else if (task.state == _DownloadTaskState.queued) {
        task.state = _DownloadTaskState.paused;
        task.error = null;
        changed = true;
      }
    }
    if (!changed) return;
    if (mounted) setState(() {});
    _scheduleDownloadKeepAliveSync(immediate: true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text('$label paused'), duration: const Duration(seconds: 2)),
    );
  }

  void _resumeDownloadsForVideoIds(
    Set<String> ids, {
    required String label,
  }) {
    var changed = false;
    for (final task in _downloadTasks) {
      if (!ids.contains(task.videoId)) continue;
      if (task.state == _DownloadTaskState.paused ||
          task.state == _DownloadTaskState.failed) {
        task.state = _DownloadTaskState.queued;
        task.error = null;
        task.progress = 0;
        changed = true;
      }
    }
    if (!changed) return;
    if (mounted) setState(() {});
    _scheduleDownloadKeepAliveSync(immediate: true);
    unawaited(_processDownloadQueue());
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text('$label resumed'),
          duration: const Duration(seconds: 2)),
    );
  }

  void _cancelDownloadsForVideoIds(
    Set<String> ids, {
    required String label,
  }) {
    var changed = false;
    final active = _activeDownloadTask;
    if (active != null && ids.contains(active.videoId)) {
      changed = true;
    }
    for (final task in _downloadTasks) {
      if (!ids.contains(task.videoId)) continue;
      if (_isTaskActive(task) && task.state == _DownloadTaskState.downloading) {
        _requestCancelDownloadTask(task);
        changed = true;
      }
    }
    final before = _downloadTasks.length;
    _downloadTasks.removeWhere((task) => ids.contains(task.videoId));
    if (_downloadTasks.length != before) changed = true;
    if (!changed) return;
    if (mounted) {
      setState(() {
        _isDownloading = false;
        _downloadProgress = 0;
      });
    } else {
      _isDownloading = false;
      _downloadProgress = 0;
    }
    _scheduleDownloadKeepAliveSync(immediate: true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text('$label cancelled'),
          duration: const Duration(seconds: 2)),
    );
  }

  void _pauseAllDownloads() {
    _pauseDownloadsForVideoIds(
      _downloadTasks.map((t) => t.videoId).toSet(),
      label: 'Downloads',
    );
  }

  void _resumeAllDownloads() {
    _resumeDownloadsForVideoIds(
      _downloadTasks.map((t) => t.videoId).toSet(),
      label: 'Downloads',
    );
  }

  void _cancelAllDownloads() {
    _cancelDownloadsForVideoIds(
      _downloadTasks.map((t) => t.videoId).toSet(),
      label: 'Downloads',
    );
  }

  void _pausePlaylistDownloads(BeastPlaylist pl) {
    _pauseDownloadsForVideoIds(
      _playlistDownloadableIds(pl),
      label: pl.name,
    );
  }

  void _resumePlaylistDownloads(BeastPlaylist pl) {
    _resumeDownloadsForVideoIds(
      _playlistDownloadableIds(pl),
      label: pl.name,
    );
  }

  void _cancelPlaylistDownloads(BeastPlaylist pl) {
    _cancelDownloadsForVideoIds(
      _playlistDownloadableIds(pl),
      label: pl.name,
    );
  }

  void _scheduleDownloadKeepAliveSync({bool immediate = false}) {
    if (immediate) {
      _downloadKeepAliveSyncTimer?.cancel();
      _downloadKeepAliveSyncTimer = null;
      unawaited(_syncDownloadKeepAliveState());
      return;
    }
    if (_downloadKeepAliveSyncTimer != null) return;
    _downloadKeepAliveSyncTimer =
        Timer(const Duration(milliseconds: 700), () async {
      _downloadKeepAliveSyncTimer = null;
      await _syncDownloadKeepAliveState();
    });
  }

  Future<void> _syncDownloadKeepAliveState() async {
    try {
      final activeTask = _activeDownloadTask;
      final pendingCount = _pendingDownloadTaskCount;
      if (pendingCount <= 0) {
        _downloadKeepAliveTaskId = null;
        _downloadKeepAliveProgressBucket = -1;
        await _downloadKeepAliveChannel.invokeMethod('sync', {
          'active': false,
        });
        return;
      }

      final title = activeTask != null
          ? _cleanTitle(activeTask.video.title)
          : 'Download queue active';
      final subtitleParts = <String>[
        if (activeTask != null) _cleanAuthor(activeTask.video.author),
        '$pendingCount item${pendingCount == 1 ? '' : 's'} in queue',
      ];
      final progress =
          ((activeTask?.progress ?? 0) * 100).clamp(0, 100).round();
      await _downloadKeepAliveChannel.invokeMethod('sync', {
        'active': true,
        'title': title,
        'subtitle': subtitleParts.join(' | '),
        'progress': progress,
        'indeterminate': activeTask == null || activeTask.progress <= 0,
      });
    } catch (_) {}
  }

  void _recordListeningEvent(
    Video video, {
    int? durationSecs,
    bool isDownload = false,
  }) {
    final estimated =
        (durationSecs ?? video.duration?.inSeconds ?? 210).clamp(30, 60 * 20);
    _listeningLogs.insert(0, {
      'videoId': video.id.value,
      'title': _cleanTitle(video.title),
      'artist': _cleanAuthor(video.author),
      'durationSecs': estimated,
      'startedAtMs': DateTime.now().millisecondsSinceEpoch,
      'playedSecs': 0,
      'completionRatio': 0.0,
      'completed': false,
      'isDownload': isDownload,
    });
    if (_listeningLogs.length > 6000) {
      _listeningLogs.removeRange(6000, _listeningLogs.length);
    }
  }

  void _updateListeningOutcomeForVideo(
    String videoId, {
    int? playedSecs,
    bool? completed,
  }) {
    final id = videoId.trim();
    if (id.isEmpty) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final raw in _listeningLogs.take(24)) {
      final e = raw;
      if ((e['videoId'] as String? ?? '') != id) continue;
      final startedAtMs = (e['startedAtMs'] as num?)?.toInt() ?? 0;
      if (startedAtMs <= 0) continue;
      if (nowMs - startedAtMs > const Duration(hours: 8).inMilliseconds) {
        continue;
      }

      final estimatedDuration =
          ((e['durationSecs'] as num?)?.toInt() ?? 210).clamp(30, 60 * 20);
      final autoPlayed = ((nowMs - startedAtMs) / 1000)
          .round()
          .clamp(0, estimatedDuration * 2);
      final listened =
          (playedSecs ?? autoPlayed).clamp(0, estimatedDuration * 2);
      final ratio = (listened / estimatedDuration).clamp(0.0, 1.5).toDouble();

      e['playedSecs'] = listened;
      e['endedAtMs'] = nowMs;
      e['completionRatio'] = ratio;
      if (completed != null) {
        final wasCompleted = e['completed'] == true;
        e['completed'] = wasCompleted || completed;
      }
      _scheduleSave();
      break;
    }
  }

  Duration _wrappedWindowDuration() {
    switch (_wrappedPeriod) {
      case 0:
        return const Duration(days: 7);
      case 1:
        return const Duration(days: 30);
      default:
        return const Duration(days: 365);
    }
  }

  List<Map<String, dynamic>> _wrappedLogs() {
    final cutoff = DateTime.now().subtract(_wrappedWindowDuration());
    return _listeningLogs.where((e) {
      final ts = (e['startedAtMs'] as num?)?.toInt() ?? 0;
      if (ts <= 0) return false;
      return DateTime.fromMillisecondsSinceEpoch(ts).isAfter(cutoff);
    }).toList();
  }

  List<String> _wrappedPersonality(List<Map<String, dynamic>> logs) {
    if (logs.isEmpty) return ['New Listener'];
    final total = logs.length;
    final artistCounts = <String, int>{};
    final hourCounts = List<int>.filled(24, 0);
    for (final e in logs) {
      final artist = (e['artist'] as String? ?? 'Unknown').trim();
      artistCounts[artist] = (artistCounts[artist] ?? 0) + 1;
      final ts = (e['startedAtMs'] as num?)?.toInt() ?? 0;
      if (ts > 0) {
        hourCounts[DateTime.fromMillisecondsSinceEpoch(ts).hour] += 1;
      }
    }

    final sortedArtists = artistCounts.values.toList()..sort((a, b) => b - a);
    final topShare = sortedArtists.isEmpty ? 0.0 : sortedArtists.first / total;
    final uniqueArtists = artistCounts.length;
    final nightPlays = hourCounts
        .asMap()
        .entries
        .where((e) => e.key >= 22 || e.key <= 4)
        .fold<int>(0, (s, e) => s + e.value);
    final morningPlays = hourCounts
        .asMap()
        .entries
        .where((e) => e.key >= 5 && e.key <= 10)
        .fold<int>(0, (s, e) => s + e.value);
    final totalSecs = logs.fold<int>(
      0,
      (s, e) => s + ((e['durationSecs'] as num?)?.toInt() ?? 0),
    );
    final minutes = (totalSecs / 60).round();

    final out = <String>[];
    if (uniqueArtists >= 20) out.add('Explorer');
    if (topShare >= 0.35) out.add('Loyal Fan');
    if (nightPlays / total >= 0.35) out.add('Night Owl');
    if (morningPlays / total >= 0.35) out.add('Early Bird');
    if (minutes >= 600) out.add('Power Listener');
    if (out.isEmpty) out.add('Steady Listener');
    return out.take(3).toList();
  }

  Map<String, dynamic> _buildWrappedStats() {
    final logs = _wrappedLogs();
    final artistMap = <String, Map<String, dynamic>>{};
    final songMap = <String, Map<String, dynamic>>{};
    int totalSecs = 0;
    for (final e in logs) {
      final artist = (e['artist'] as String? ?? 'Unknown').trim();
      final title = (e['title'] as String? ?? 'Unknown').trim();
      final videoId = (e['videoId'] as String? ?? '').trim();
      final secs = (e['durationSecs'] as num?)?.toInt() ?? 0;
      totalSecs += secs;

      final a = artistMap.putIfAbsent(
          artist, () => {'name': artist, 'plays': 0, 'secs': 0});
      a['plays'] = (a['plays'] as int) + 1;
      a['secs'] = (a['secs'] as int) + secs;

      final songKey = videoId.isNotEmpty ? videoId : '$title|$artist';
      final s = songMap.putIfAbsent(
          songKey,
          () => {
                'id': songKey,
                'title': title,
                'artist': artist,
                'plays': 0,
                'secs': 0,
              });
      s['plays'] = (s['plays'] as int) + 1;
      s['secs'] = (s['secs'] as int) + secs;
    }

    final topArtists = artistMap.values.toList()
      ..sort((a, b) {
        final byPlays = (b['plays'] as int).compareTo(a['plays'] as int);
        if (byPlays != 0) return byPlays;
        return (b['secs'] as int).compareTo(a['secs'] as int);
      });
    final topSongs = songMap.values.toList()
      ..sort((a, b) {
        final byPlays = (b['plays'] as int).compareTo(a['plays'] as int);
        if (byPlays != 0) return byPlays;
        return (b['secs'] as int).compareTo(a['secs'] as int);
      });

    final uniqueSongs = songMap.length;
    final uniqueArtists = artistMap.length;
    final minutes = (totalSecs / 60).round();
    return {
      'logs': logs,
      'minutes': minutes,
      'plays': logs.length,
      'uniqueSongs': uniqueSongs,
      'uniqueArtists': uniqueArtists,
      'topArtists': topArtists.take(5).toList(),
      'topSongs': topSongs.take(5).toList(),
      'personality': _wrappedPersonality(logs),
    };
  }

  bool _isValidYoutubeVideoId(String id) =>
      RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id);

  Map<String, dynamic>? _wrappedStoryTopSong(Map<String, dynamic> stats) {
    final topSongs = (stats['topSongs'] as List?)?.cast<Map<String, dynamic>>();
    if (topSongs == null || topSongs.isEmpty) return null;
    return topSongs.first;
  }

  Video? _resolveWrappedSongVideo(Map<String, dynamic>? song) {
    if (song == null) return null;
    final rawId = (song['id'] as String? ?? '').trim();
    final title = (song['title'] as String? ?? 'Top Song').trim();
    final artist = (song['artist'] as String? ?? 'Unknown').trim();

    if (_isValidYoutubeVideoId(rawId)) {
      for (final v in [
        ..._history,
        ..._playQueue,
        ..._likedPlaylist.videos,
        ..._ytLikedVideos,
      ]) {
        if (v.id.value == rawId) return v;
      }
      final di = _findDownloadIndexByVideoId(rawId);
      if (di >= 0) return _videoFromDownloadEntry(_downloads[di]);
      return _videoFromMap({
        'id': rawId,
        'title': title.isEmpty ? 'Top Song' : title,
        'author': artist.isEmpty ? 'Unknown' : artist,
      });
    }

    String key(String t, String a) =>
        '${_cleanTitle(t).toLowerCase()}|${_cleanAuthor(a).toLowerCase()}';
    final target = key(title, artist);
    for (final v in [
      ..._history,
      ..._playQueue,
      ..._likedPlaylist.videos,
      ..._ytLikedVideos,
    ]) {
      if (key(v.title, v.author) == target) return v;
    }
    for (final d in _downloads) {
      if (key(d['title'] ?? '', d['author'] ?? '') == target) {
        return _videoFromDownloadEntry(d);
      }
    }
    return null;
  }

  String? _wrappedTopSongArtUrl(
      Map<String, dynamic>? song, Video? resolvedVideo) {
    if (resolvedVideo != null) return resolvedVideo.thumbnails.highResUrl;
    if (song == null) return null;
    final id = (song['id'] as String? ?? '').trim();
    if (!_isValidYoutubeVideoId(id)) return null;
    return 'https://i.ytimg.com/vi/$id/hqdefault.jpg';
  }

  Future<void> _openWrappedStory({Map<String, dynamic>? stats}) async {
    final wrapped = stats ?? _buildWrappedStats();
    final plays = (wrapped['plays'] as int?) ?? 0;
    if (plays <= 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Play a few songs first to generate your Wrap'),
        duration: Duration(seconds: 2),
      ));
      return;
    }

    final topSong = _wrappedStoryTopSong(wrapped);
    final topVideo = _resolveWrappedSongVideo(topSong);
    final topSongId = (topSong?['id'] as String? ?? '').trim();

    if (_isValidYoutubeVideoId(topSongId)) {
      final downloadIndex = _findDownloadIndexByVideoId(topSongId);
      if (downloadIndex >= 0 &&
          (_nowPlaying == null || _nowPlaying!.id.value != topSongId)) {
        unawaited(_playDownloadedAt(downloadIndex));
      } else if (topVideo != null &&
          (_nowPlaying == null || _nowPlaying!.id.value != topVideo.id.value)) {
        int playIndex =
            _playQueue.indexWhere((v) => v.id.value == topVideo.id.value);
        if (playIndex < 0) {
          setState(() {
            _playQueue = [topVideo];
            _radioMode = false;
          });
          playIndex = 0;
        }
        _playFromUserAction(
          topVideo,
          playIndex,
          tasteWeight: 1.05,
          source: 'wrapped_story',
        );
      }
    }

    if (!mounted) return;
    await Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => _WrappedStoryViewer(
          periodLabel: _wrappedPeriodLabels[_wrappedPeriod],
          periodWindowLabel: _wrappedPeriodWindows[_wrappedPeriod],
          periodEmoji: _wrappedPeriodEmoji[_wrappedPeriod],
          stats: wrapped,
          heroArtUrl: _wrappedTopSongArtUrl(topSong, topVideo),
        ),
        transitionsBuilder: (ctx, anim, secondary, child) {
          final curved =
              CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.03),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }

  String? _savedLyricsForVideoId(String videoId) {
    final i = _findDownloadIndexByVideoId(videoId);
    if (i < 0) return null;
    final lyrics = (_downloads[i]['lyrics'] ?? '').trim();
    return lyrics.isEmpty ? null : lyrics;
  }

  Future<void> _storeLyricsForDownloadedVideo(Video video) async {
    final i = _findDownloadIndexByVideoId(video.id.value);
    if (i < 0) return;

    final existing = (_downloads[i]['lyrics'] ?? '').trim();
    if (existing.isNotEmpty) return;

    final lyrics = await _fetchLyrics(video);
    if (lyrics == null || lyrics.trim().isEmpty) return;
    final cleanLyrics = lyrics.trim();

    if (mounted) {
      setState(() => _downloads[i]['lyrics'] = cleanLyrics);
    } else {
      _downloads[i]['lyrics'] = cleanLyrics;
    }
    _scheduleSave();
  }

  Video _videoFromDownloadEntry(Map<String, String> download) {
    final videoId = _resolveDownloadVideoId(download);
    final title = (download['title'] ?? '').trim();
    final author = (download['author'] ?? '').trim();
    final secs = int.tryParse((download['durationSecs'] ?? '').trim());
    return Video(
      VideoId(videoId),
      title.isEmpty ? 'Unknown' : title,
      author.isEmpty ? 'Unknown' : author,
      ChannelId('UC0000000000000000000000'),
      null,
      null,
      null,
      '',
      (secs != null && secs > 0) ? Duration(seconds: secs) : null,
      ThumbnailSet(videoId),
      const <String>[],
      const Engagement(0, null, null),
      false,
    );
  }

  Future<void> _deleteDownloadedAt(int index, {bool askConfirm = true}) async {
    if (index < 0 || index >= _downloads.length) return;
    final entry = _downloads[index];
    final title = _cleanTitle(entry['title'] ?? 'song');

    if (askConfirm && mounted) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          title: const Text('Delete download',
              style:
                  TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          content: Text(
            'Remove "$title" from this device?',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child:
                  Text('Cancel', style: TextStyle(color: Colors.grey.shade400)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    final filePath = (entry['filePath'] ?? '').trim();
    final wasCurrent = _isDownloadPlayback && _currentDownloadIndex == index;

    if (mounted) {
      setState(() {
        _downloads.removeAt(index);
        if (_downloads.isEmpty) {
          _downloadQueue.clear();
          _unshuffledDownloadQueue.clear();
          _currentDownloadQueuePos = -1;
          _currentDownloadIndex = -1;
          if (wasCurrent) _currentVideoId = null;
        } else if (_currentDownloadIndex > index) {
          _currentDownloadIndex -= 1;
          _ensureDownloadQueueForPlayback(_currentDownloadIndex, reset: true);
        } else if (!wasCurrent &&
            _currentDownloadIndex >= 0 &&
            _currentDownloadIndex < _downloads.length) {
          _ensureDownloadQueueForPlayback(_currentDownloadIndex, reset: true);
        }
      });
    } else {
      _downloads.removeAt(index);
      if (_downloads.isEmpty) {
        _downloadQueue.clear();
        _unshuffledDownloadQueue.clear();
        _currentDownloadQueuePos = -1;
        _currentDownloadIndex = -1;
        if (wasCurrent) _currentVideoId = null;
      } else if (_currentDownloadIndex > index) {
        _currentDownloadIndex -= 1;
        _ensureDownloadQueueForPlayback(_currentDownloadIndex, reset: true);
      } else if (!wasCurrent &&
          _currentDownloadIndex >= 0 &&
          _currentDownloadIndex < _downloads.length) {
        _ensureDownloadQueueForPlayback(_currentDownloadIndex, reset: true);
      }
    }

    if (filePath.isNotEmpty) {
      try {
        final f = File(filePath);
        if (await f.exists()) await f.delete();
      } catch (e) {
        debugPrint('[Delete download] $e');
      }
    }

    if (wasCurrent) {
      await _player.stop();
      if (mounted) {
        setState(() {
          _nowPlaying = null;
          _showNowPlaying = false;
          _currentVideoId = null;
          _currentDownloadIndex = -1;
          _currentDownloadQueuePos = -1;
        });
      } else {
        _nowPlaying = null;
        _showNowPlaying = false;
        _currentVideoId = null;
        _currentDownloadIndex = -1;
        _currentDownloadQueuePos = -1;
      }
    }

    _scheduleSave();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Deleted: $title',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _playDownloadedAt(int index, {bool resetQueue = false}) async {
    if (index < 0 || index >= _downloads.length) return;
    _ensureDownloadQueueForPlayback(
      index,
      reset: resetQueue || !_isDownloadPlayback,
    );

    final d = _downloads[index];
    final filePath = d['filePath'];
    if (filePath == null || filePath.isEmpty) return;
    final downloadVideo = _videoFromDownloadEntry(d);

    if (!await File(filePath).exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('File not found on device'),
            duration: Duration(seconds: 2)));
        setState(() {
          _downloads.removeAt(index);
          if (_downloads.isNotEmpty) {
            final nextIndex = index < _downloads.length ? index : 0;
            _ensureDownloadQueueForPlayback(nextIndex, reset: true);
          } else {
            _downloadQueue.clear();
            _unshuffledDownloadQueue.clear();
            _currentDownloadQueuePos = -1;
            _currentDownloadIndex = -1;
            _currentVideoId = null;
          }
        });
      } else {
        _downloads.removeAt(index);
        if (_downloads.isNotEmpty) {
          final nextIndex = index < _downloads.length ? index : 0;
          _ensureDownloadQueueForPlayback(nextIndex, reset: true);
        } else {
          _downloadQueue.clear();
          _unshuffledDownloadQueue.clear();
          _currentDownloadQueuePos = -1;
          _currentDownloadIndex = -1;
          _currentVideoId = null;
        }
      }
      _scheduleSave();
      return;
    }

    _currentVideoId = 'download:$filePath';
    _currentDownloadIndex = index;
    final secs = int.tryParse((d['durationSecs'] ?? '').trim());
    _recordListeningEvent(
      downloadVideo,
      durationSecs: secs,
      isDownload: true,
    );
    _scheduleSave();
    if (mounted) {
      setState(() {
        _nowPlaying = downloadVideo;
        _currentIndex = _currentDownloadQueuePos;
        _isBuffering = false;
      });
    }
    _activeDl?.cancel();
    _activeDl = null;
    _playYt?.close();
    _playYt = null;
    await _cancelActiveSecondaryPlayback();
    await _player.stop();
    await _setPlayerSource(
      AudioSource.uri(
        Uri.file(filePath),
        tag: _mediaItemForDownloadedTrack(d, filePath, index),
      ),
    );
    await _player.setSpeed(_playbackSpeed);
    await _applyNormalizationForPlayer(_player, downloadVideo);
    try {
      await _player.play();
      await Future<void>.delayed(const Duration(milliseconds: 900));
      final duration = _player.duration ?? Duration.zero;
      final position = _player.position;
      final stuckAtZero = duration <= Duration.zero && position <= Duration.zero;
      if (stuckAtZero) {
        throw Exception('Downloaded file is unreadable');
      }
    } catch (e) {
      debugPrint('[Download Playback] file failed, falling back to stream: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'This downloaded file looks broken. Playing online and re-download it.',
            ),
            duration: Duration(seconds: 3),
          ),
        );
      }
      unawaited(_play(downloadVideo, _currentIndex >= 0 ? _currentIndex : 0));
    }
  }

  void _playNext({bool userInitiated = false}) {
    if (_isDownloadPlayback) {
      final nextDownload = _downloadNextIndex;
      if (nextDownload != null) unawaited(_playDownloadedAt(nextDownload));
      return;
    }
    if (userInitiated) {
      _registerManualSkipFeedbackForCurrent();
    }
    final seed = _nowPlaying;
    if (seed != null) {
      _ensureQueueBackfilledWithYtMusicAi(
        seed,
        localMinUpcoming: 5,
        networkMinUpcoming: 9,
      );
    }
    if (_currentIndex < _playQueue.length - 1) {
      int nextIndex = _currentIndex + 1;
      Video next = _playQueue[nextIndex];
      final smartNext = (seed == null || _strictYtMusicFeedMode)
          ? null
          : _bestUpcomingQueueCandidate(
              seed,
              lookahead: userInitiated ? 10 : 8,
            );
      if (smartNext != null && smartNext.index != nextIndex) {
        if (mounted) {
          setState(() {
            _playQueue.removeAt(smartNext.index);
            _playQueue.insert(nextIndex, smartNext.video);
          });
          _notifyQueueChanged();
        } else {
          _playQueue.removeAt(smartNext.index);
          _playQueue.insert(nextIndex, smartNext.video);
          _notifyQueueChanged();
        }
        next = _playQueue[nextIndex];
      }
      if (_isCrossfadeEligible(next, userInitiated: userInitiated)) {
        final fadeSecs = _effectiveCrossfadeSeconds(next);
        unawaited(_doCrossfade(next, nextIndex, fadeSecs: fadeSecs));
      } else if (_shouldDoGaplessHandoff(next, userInitiated: userInitiated)) {
        unawaited(_playGaplessFromCache(next, nextIndex));
      } else {
        unawaited(_play(next, nextIndex));
      }
    }
  }

  void _playPrevious() {
    if (_isDownloadPlayback) {
      final prevDownload = _downloadPreviousIndex;
      if (prevDownload != null) {
        unawaited(_playDownloadedAt(prevDownload));
      } else {
        unawaited(_player.seek(Duration.zero));
      }
      return;
    }
    if (_currentIndex > 0) {
      unawaited(_play(_playQueue[_currentIndex - 1], _currentIndex - 1));
    }
  }

  void _handleNotificationEvent(dynamic event) {
    if (event is! Map) return;
    var name = event['event'];
    if (name is! String) {
      name = event['action'] ?? event['name'] ?? event['type'];
    }
    if (name is! String) return;

    switch (name) {
      case _notificationEventSkipNext:
        if (_isDownloadPlayback || _currentIndex < _playQueue.length - 1) {
          _playNext(userInitiated: true);
        } else {
          _registerManualSkipFeedbackForCurrent();
          unawaited(_playRadioNext());
        }
        break;
      case _notificationEventSkipPrevious:
        if (_isDownloadPlayback || _currentIndex > 0) {
          _playPrevious();
        } else {
          unawaited(_player.seek(Duration.zero));
        }
        break;
      case _notificationEventToggleLike:
        final current = _nowPlaying;
        if (current != null) _toggleLike(current);
        break;
      // Accept alternative like event names for better compatibility.
      case 'toggle_like':
      case 'like':
      case 'favorite':
      case 'heart':
        final current2 = _nowPlaying;
        if (current2 != null) _toggleLike(current2);
        break;
      // Alternative names seen on some ROMs/players
      case 'android.media.action.LIKE':
      case 'ACTION_FAVORITE':
      case 'ACTION_TOGGLE_FAVORITE':
      case 'media_like':
      case 'media_favorite':
        final current3 = _nowPlaying;
        if (current3 != null) _toggleLike(current3);
        break;
    }
  }

  void _playFromUserAction(
    Video video,
    int index, {
    double tasteWeight = 1.0,
    String source = 'manual_play',
  }) {
    if (source.startsWith('quick_')) {
      _rewardQuickPickSelection(video, strength: 3.5);
    }
    _currentFromQuick = source.startsWith('quick_');
    _registerFeedback(video, weight: tasteWeight, source: source);
    unawaited(_play(video, index));
    // Keep search taps as normal playback. Only prime search queue for
    // an explicit radio-style search action.
    if (source == 'search_result_radio_tap') {
      _primeSearchTapQueue(video);
    }
  }

  void _seedUpcomingFromLocalTaste(
    Video seed, {
    int minUpcoming = 6,
  }) {
    if (_isDownloadPlayback) return;
    if (_playQueue.isEmpty) return;

    final upcoming = max(0, _playQueue.length - _currentIndex - 1);
    if (upcoming >= minUpcoming) return;

    final existingIds = _playQueue.map((v) => v.id.value).toSet();
    final profile = _buildTasteProfile();
    final seedArtist = _primaryArtistKey(seed.author);
    final seedText = '${_cleanTitle(seed.title)} ${_cleanAuthor(seed.author)}';
    final seedTags = _extractMusicTags(seedText.toLowerCase());
    final seedMood = _primaryMoodTag(seedTags);
    final seedTokens = _tokenizeSearchText(
      seedText,
      dropCommonWords: true,
    );
    final queueArtistCount = <String, int>{};
    for (final qv in _playQueue) {
      final artist = _primaryArtistKey(qv.author);
      queueArtistCount[artist] = (queueArtistCount[artist] ?? 0) + 1;
    }
    final recentTailArtists = _playQueue
        .skip(max(0, _playQueue.length - 4))
        .map((v) => _primaryArtistKey(v.author))
        .toSet();

    final poolById = <String, ({Video v, double sourceBoost})>{};
    void addSource(Iterable<Video> source, double startBoost, double step) {
      var index = 0;
      for (final v in source) {
        if (v.id.value == seed.id.value) continue;
        if (!_isMusicCandidate(v, strictSingles: true)) continue;
        if (_isRecommendationBlocked(v)) continue;
        if (existingIds.contains(v.id.value)) continue;
        final boost = max(0.0, startBoost - (index * step));
        final prev = poolById[v.id.value];
        if (prev == null || boost > prev.sourceBoost) {
          poolById[v.id.value] = (v: v, sourceBoost: boost);
        }
        index++;
      }
    }

    addSource(_playQueue.skip(_currentIndex + 1).take(18), 2.2, 0.08);
    addSource(_becauseYouLiked.take(70), 2.0, 0.03);
    addSource(_quickRow1.take(70), 1.85, 0.03);
    addSource(_newReleases.take(70), 1.4, 0.02);
    addSource(_moodChill.take(60), 1.1, 0.02);
    addSource(_history.take(70), 1.55, 0.03);
    addSource(_likedPlaylist.videos.take(110), 1.25, 0.018);
    addSource(_ytLikedVideos.take(140), 1.1, 0.015);
    addSource(_trendingVideos.take(60), 0.9, 0.02);

    final ranked = poolById.values
        .map((item) {
          final v = item.v;
          final artistKey = _primaryArtistKey(v.author);
          final contextScore =
              _contextualSeedAffinity(seed, v, profile, strict: true);
          final transitionScore =
              _transitionAffinityScore(seed, v, profile, strict: true);
          final candTokens = _tokenizeSearchText(
            '${_cleanTitle(v.title)} ${_cleanAuthor(v.author)}',
            dropCommonWords: true,
          );
          final sameArtist = artistKey == seedArtist;
          final candTags = _extractMusicTags('${v.title} ${v.author}'.toLowerCase());
          final sameMood = _primaryMoodTag(candTags);
          final artistSeenInQueue = queueArtistCount[artistKey] ?? 0;
          final artistOverusePenalty = max(0, artistSeenInQueue - 1) * 1.35;
          final sameArtistBias =
              sameArtist ? (artistSeenInQueue <= 1 ? 0.35 : -0.95) : 0.0;
          final tailPenalty = recentTailArtists.contains(artistKey) ? 0.95 : 0.0;
          final clashPenalty = _vibeClashPenalty(seedTags, candTags, strict: false);
          if (contextScore < 0.85 && !sameArtist) return null;
          final score = _personalTasteScore(
                    v,
                    profile,
                    queryHint:
                        '${_cleanTitle(seed.title)} ${_cleanAuthor(seed.author)} queue',
                    penalizeRepeats: true,
                  ) *
                  0.55 +
              (contextScore * 2.9) +
              (transitionScore * 1.35) +
              (_fuzzyTokenOverlapScore(seedTokens, candTokens) * 0.65) +
              sameArtistBias +
              (seedMood != null && sameMood == seedMood
                  ? 0.65
                  : 0.0) +
              item.sourceBoost -
              artistOverusePenalty -
              tailPenalty -
              (clashPenalty * 0.55);
          return (v: v, score: score, artist: artistKey, context: contextScore);
        })
        .whereType<({Video v, double score, String artist, double context})>()
        .toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    final need = max(0, minUpcoming - upcoming);
    if (need <= 0) return;

    final localAdds = <Video>[];
    final addedByArtist = <String, int>{};
    final queueTailArtist = _playQueue.isNotEmpty
        ? _primaryArtistKey(_playQueue.last.author)
        : '';
    String lastChosenArtist = queueTailArtist;
    const seedArtistCap = 1;
    const otherArtistCap = 2;
    for (final item in ranked) {
      if (localAdds.length >= need) break;
      if (item.context < 1.0 && localAdds.length >= max(1, need - 2)) break;
      if (item.artist.isNotEmpty &&
          item.artist == lastChosenArtist &&
          ranked.any((r) => r.artist != item.artist)) {
        continue;
      }
      final cap = item.artist == seedArtist ? seedArtistCap : otherArtistCap;
      final used = addedByArtist[item.artist] ?? 0;
      if (used >= cap) continue;
      addedByArtist[item.artist] = used + 1;
      localAdds.add(item.v);
      lastChosenArtist = item.artist;
    }
    if (localAdds.isEmpty) return;

    if (mounted) {
      setState(() {
        for (final v in localAdds) {
          if (existingIds.add(v.id.value)) _playQueue.add(v);
        }
      });
    } else {
      for (final v in localAdds) {
        if (existingIds.add(v.id.value)) _playQueue.add(v);
      }
    }
  }

  void _backfillQueueWithNetwork(
    Video seed, {
    int minUpcoming = 10,
  }) {
    unawaited(() async {
      if (_isDownloadPlayback) return;
      if (_currentVideoId != seed.id.value) return;
      final upcoming = max(0, _playQueue.length - _currentIndex - 1);
      if (upcoming >= minUpcoming) return;
      await _appendRadioCandidates(seed, minAdds: minUpcoming - upcoming);
    }());
  }

  void _ensureQueueBackfilledWithYtMusicAi(
    Video seed, {
    int localMinUpcoming = 6,
    int networkMinUpcoming = 10,
  }) {
    if (_isDownloadPlayback) return;
    if (!_strictYtMusicFeedMode) {
      _seedUpcomingFromLocalTaste(seed, minUpcoming: localMinUpcoming);
    }
    _backfillQueueWithNetwork(
      seed,
      minUpcoming: _strictYtMusicFeedMode
          ? max(localMinUpcoming, networkMinUpcoming)
          : networkMinUpcoming,
    );
  }

  ({Video video, int index})? _bestUpcomingQueueCandidate(
    Video seed, {
    int lookahead = 8,
  }) {
    if (_isDownloadPlayback) return null;
    if (_currentIndex < 0 || _playQueue.isEmpty) return null;
    if (_currentIndex >= _playQueue.length - 1) return null;

    final start = _currentIndex + 1;
    final end = min(_playQueue.length, start + max(1, lookahead));
    if (end <= start) return null;

    final profile = _buildTasteProfile();
    final scored = <({Video video, int index, double score})>[];

    for (int idx = start; idx < end; idx++) {
      final candidate = _playQueue[idx];
      if (_isRecommendationBlocked(candidate)) continue;
      final offset = idx - start;
      final score = _radioRelevanceScore(seed, candidate, profile) +
          (_personalTasteScore(
                candidate,
                profile,
                queryHint:
                    '${_cleanTitle(seed.title)} ${_cleanAuthor(seed.author)} next queue',
                penalizeRepeats: true,
              ) *
              0.42) +
          (_contextualSeedAffinity(seed, candidate, profile, strict: true) *
              1.35) +
          (_seedAffinityScore(candidate, [seed]) * 0.9) +
          max(0.0, 1.25 - (offset * 0.18));
      scored.add((video: candidate, index: idx, score: score));
    }

    if (scored.isEmpty) return null;
    scored.sort((a, b) => b.score.compareTo(a.score));
    final best = scored.first;
    return (video: best.video, index: best.index);
  }

  void _primeSearchTapQueue(Video seed) {
    if (_isDownloadPlayback) return;
    if (_currentVideoId == seed.id.value) {
      _ensureQueueBackfilledWithYtMusicAi(
        seed,
        localMinUpcoming: 5,
        networkMinUpcoming: 10,
      );
      if (mounted && !_radioMode) {
        setState(() => _radioMode = true);
      } else {
        _radioMode = true;
      }
    }

    // Re-check once playback has settled to guarantee queue priming.
    Future<void>.delayed(const Duration(milliseconds: 180), () {
      if (!mounted) return;
      if (_isDownloadPlayback) return;
      if (_currentVideoId != seed.id.value) return;

      _ensureQueueBackfilledWithYtMusicAi(
        seed,
        localMinUpcoming: 5,
        networkMinUpcoming: 10,
      );
      if (!_radioMode) setState(() => _radioMode = true);
    });
  }

  Future<void> _startRadioFromSong(Video video) async {
    _currentFromQuick = _quickRow1.any((v) => v.id.value == video.id.value);
    _rewardQuickPickSelection(video, strength: 3.8);
    _registerFeedback(video, weight: 1.35, source: 'start_radio');
    if (mounted) {
      setState(() {
        _playQueue = [video];
        _radioMode = true;
      });
    }
    _radioSeenIds
      ..clear()
      ..add(video.id.value);
    await _play(video, 0);
    unawaited(_appendRadioCandidates(video, minAdds: 10));
  }

  void _insertPlayNext(Video video) {
    _registerFeedback(video, weight: 0.95, source: 'queue_next');
    final insertAt = _currentIndex + 1;
    setState(() {
      _playQueue.removeWhere((v) =>
          v.id.value == video.id.value &&
          _playQueue.indexOf(v) > _currentIndex);
      _playQueue.insert(insertAt, video);
    });
    _notifyQueueChanged();
    unawaited(_prefetchSingle(video));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Playing next'), duration: Duration(seconds: 1)));
  }

  void _addToQueue(Video video) {
    _registerFeedback(video, weight: 0.75, source: 'queue_add');
    setState(() => _playQueue.add(video));
    _notifyQueueChanged();
    unawaited(_prefetchSingle(video));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Added to queue'), duration: Duration(seconds: 1)));
  }

  Future<void> _prefetchSingle(Video video) async {
    final videoId = video.id.value;
    if (_tmpFiles.containsKey(videoId)) return;
    if (_prefetching.contains(videoId)) return;
    _prefetching.add(videoId);
    try {
      final result = await _fetchManifest(videoId, silent: true);
      if (result == null) {
        _prefetching.remove(videoId);
        return;
      }
      final audioStream = _selectStream(result.manifest.audioOnly.toList());
      final tmpDir = await getTemporaryDirectory();
      final tmpPath = '${tmpDir.path}/$videoId.${audioStream.container.name}';
      if (await File(tmpPath).exists()) {
        _tmpFiles[videoId] = tmpPath;
        _prefetching.remove(videoId);
        return;
      }
      final sink = File(tmpPath).openWrite();
      try {
        await for (final chunk
            in result.yt.videos.streamsClient.get(audioStream)) {
          sink.add(chunk);
        }
        await sink.flush();
        await sink.close();
        _tmpFiles[videoId] = tmpPath;
      } finally {
        try {
          result.yt.close();
        } catch (_) {}
        _prefetching.remove(videoId);
      }
    } catch (e) {
      debugPrint('[PrefetchSingle] error: $e');
      _prefetching.remove(videoId);
    }
  }

  // Three-dot song menu
  void _showSongMenu(Video video) {
    final isLiked = _isLiked(video);
    final isPinned = _isSpeedDialPinned(video);
    final isTrackBlocked =
        _blockedVideoIds.contains(video.id.value.toLowerCase());
    final isArtistBlocked = _isBlockedArtist(video.author);
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141414),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.82),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                    color: Colors.grey[700],
                    borderRadius: BorderRadius.circular(2)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Row(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CachedNetworkImage(
                      imageUrl: video.thumbnails.mediumResUrl,
                      width: 46,
                      height: 46,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Container(
                          color: Colors.grey[800], width: 46, height: 46),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(_cleanTitle(video.title),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 13)),
                        GestureDetector(
                          onTap: () {
                            Navigator.pop(ctx);
                            _openArtistPage(video.author);
                          },
                          child: Text(_cleanAuthor(video.author),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color:
                                      Colors.greenAccent.withValues(alpha: 0.8),
                                  fontSize: 11)),
                        ),
                      ])),
                ]),
              ),
              const Divider(color: Color(0xFF252525), height: 1),
              _menuItem(
                  ctx, Icons.person_rounded, 'Go to Artist', Colors.greenAccent,
                  () {
                Navigator.pop(ctx);
                _openArtistPage(video.author);
              }),
              _menuItem(
                  ctx, Icons.play_arrow_rounded, 'Play Next', Colors.white, () {
                Navigator.pop(ctx);
                _insertPlayNext(video);
              }),
              _menuItem(
                  ctx, Icons.queue_music_rounded, 'Add to Queue', Colors.white,
                  () {
                Navigator.pop(ctx);
                _addToQueue(video);
              }),
              _menuItem(
                  ctx,
                  isTrackBlocked
                      ? Icons.visibility_rounded
                      : Icons.thumb_down_alt_rounded,
                  isTrackBlocked ? 'Allow this Song Again' : 'Not Interested',
                  isTrackBlocked ? Colors.greenAccent : Colors.orangeAccent,
                  () {
                Navigator.pop(ctx);
                _toggleNotInterested(video);
              }),
              _menuItem(
                  ctx,
                  isArtistBlocked
                      ? Icons.person_add_alt_1_rounded
                      : Icons.block_rounded,
                  isArtistBlocked
                      ? 'Allow this Artist Again'
                      : 'Don\'t Recommend this Artist',
                  isArtistBlocked ? Colors.greenAccent : Colors.redAccent, () {
                Navigator.pop(ctx);
                _toggleBlockedArtist(video.author, sampleVideo: video);
              }),
              _menuItem(
                  ctx,
                  isLiked
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  isLiked ? 'Remove from Liked' : 'Like',
                  isLiked ? Colors.pinkAccent : Colors.white, () {
                _toggleLike(video);
                Navigator.pop(ctx);
              }),
              _menuItem(
                  ctx,
                  isPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                  isPinned ? 'Unpin from Speed Dial' : 'Pin to Speed Dial',
                  Colors.white, () {
                Navigator.pop(ctx);
                _toggleSpeedDialPin(video);
              }),
              _menuItem(ctx, Icons.playlist_add_rounded, 'Add to Playlist',
                  Colors.white, () {
                Navigator.pop(ctx);
                _showAddToPlaylist(video);
              }),
              _menuItem(ctx, Icons.download_rounded, 'Download', Colors.white,
                  () {
                Navigator.pop(ctx);
                _downloadAudio(video);
              }),
              _menuItem(ctx, Icons.share_rounded, 'Share', Colors.white, () {
                Navigator.pop(ctx);
                _shareSong(video);
              }),
              const SizedBox(height: 8),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _sheetHandle() => Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
            color: Colors.grey[700], borderRadius: BorderRadius.circular(2)),
      );

  Widget _sheetHeader({
    required IconData icon,
    required Color color,
    required String title,
    String? subtitle,
    Widget? trailing,
    EdgeInsetsGeometry padding = const EdgeInsets.fromLTRB(20, 0, 20, 12),
  }) {
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.grey[600], fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            trailing,
          ],
        ],
      ),
    );
  }

  Widget _menuItem(BuildContext ctx, IconData icon, String label,
      Color iconColor, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: iconColor, size: 22),
      title: Text(label,
          style: const TextStyle(color: Colors.white, fontSize: 14)),
      dense: true,
      onTap: onTap,
    );
  }

  void _showDownloadsQueueSheet() {
    if (_downloads.isEmpty) return;
    if (!_isValidDownloadQueue(_downloadQueue)) {
      _downloadQueue
        ..clear()
        ..addAll(_allDownloadIndices());
      _currentDownloadQueuePos = _downloadQueue.indexOf(_currentDownloadIndex);
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF111111),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.65,
        minChildSize: 0.35,
        maxChildSize: 0.95,
        expand: false,
        builder: (ctx, sheetCtrl) => Column(children: [
          _sheetHandle(),
          _sheetHeader(
            icon: Icons.download_done_rounded,
            color: Colors.greenAccent,
            title: 'Downloads Queue',
            subtitle: '${_downloadQueue.length} songs',
          ),
          Expanded(
            child: ListView.builder(
              controller: sheetCtrl,
              padding: const EdgeInsets.only(bottom: 24),
              itemCount: _downloadQueue.length,
              itemBuilder: (ctx, pos) {
                final di = _downloadQueue[pos];
                final d = _downloads[di];
                final isCurrent = pos == _currentDownloadQueuePos;
                return ListTile(
                  dense: true,
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: CachedNetworkImage(
                      imageUrl: d['thumbnailUrl'] ?? '',
                      width: 42,
                      height: 42,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Container(
                        width: 42,
                        height: 42,
                        color: Colors.grey[850],
                        child: const Icon(Icons.music_note, color: Colors.grey),
                      ),
                    ),
                  ),
                  title: Text(
                    _cleanTitle(d['title'] ?? 'Unknown'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isCurrent ? Colors.greenAccent : Colors.white,
                      fontSize: 13,
                      fontWeight:
                          isCurrent ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                  subtitle: Text(
                    _cleanAuthor(d['author'] ?? 'Unknown'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.grey[600], fontSize: 11),
                  ),
                  trailing: SizedBox(
                    width: 74,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (isCurrent)
                          const Icon(Icons.volume_up_rounded,
                              color: Colors.greenAccent, size: 18),
                        IconButton(
                          tooltip: 'Delete',
                          icon: const Icon(Icons.delete_outline_rounded,
                              color: Colors.redAccent, size: 18),
                          onPressed: () async {
                            Navigator.pop(ctx);
                            await _deleteDownloadedAt(di);
                          },
                        ),
                      ],
                    ),
                  ),
                  onTap: isCurrent
                      ? null
                      : () {
                          unawaited(_playDownloadedAt(di));
                          Navigator.pop(ctx);
                        },
                );
              },
            ),
          ),
        ]),
      ),
    );
  }

  // Queue bottom sheet
  void _ensureNowPlayingInStreamQueue() {
    if (_isDownloadPlayback) return;
    final now = _nowPlaying;
    if (now == null) return;

    final currentId = now.id.value;
    final existingIndex = _playQueue.indexWhere((v) => v.id.value == currentId);
    if (existingIndex >= 0) {
      _currentIndex = existingIndex;
      return;
    }

    final deduped = _playQueue.where((v) => v.id.value != currentId).toList();
    _playQueue = [now, ...deduped];
    _currentIndex = 0;
    _notifyQueueChanged();
  }

  void _showQueueSheet() {
    if (_isDownloadPlayback) {
      _showDownloadsQueueSheet();
      return;
    }
    _ensureNowPlayingInStreamQueue();
    final now = _nowPlaying;
    if (now != null) {
      final upcoming = max(0, _playQueue.length - _currentIndex - 1);
      if (upcoming < 4) {
        _ensureQueueBackfilledWithYtMusicAi(
          now,
          localMinUpcoming: 5,
          networkMinUpcoming: 9,
        );
      }
    }
    showModalBottomSheet(
        context: context,
        backgroundColor: const Color(0xFF111111),
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        builder: (ctx) => ValueListenableBuilder<int>(
              valueListenable: _queueChangeNotifier,
              builder: (ctx, _, __) => StatefulBuilder(
                builder: (ctx, setSheet) {
                  return DraggableScrollableSheet(
                    initialChildSize: 0.7,
                    minChildSize: 0.4,
                    maxChildSize: 0.95,
                    expand: false,
                    builder: (ctx, sheetCtrl) {
                      // scroll to current song on first frame
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (sheetCtrl.hasClients && _currentIndex > 2) {
                          sheetCtrl.animateTo(
                            (_currentIndex - 1) * 72.0,
                            duration: const Duration(milliseconds: 350),
                            curve: Curves.easeOut,
                          );
                        }
                      });

                      final upcoming = _currentIndex + 1 < _playQueue.length
                          ? _playQueue.length - _currentIndex - 1
                          : 0;

                      return Column(children: [
                        _sheetHandle(),
                        _sheetHeader(
                          icon: Icons.queue_music_rounded,
                          color: Colors.greenAccent,
                          title: 'Queue',
                          subtitle: '${_playQueue.length} songs',
                          trailing: upcoming > 0
                              ? TextButton(
                                  onPressed: () {
                                    final removed = _currentIndex + 1 <
                                            _playQueue.length
                                        ? _playQueue.sublist(_currentIndex + 1)
                                        : <Video>[];
                                    for (final v in removed.take(24)) {
                                      _registerFeedback(
                                        v,
                                        weight: -0.22,
                                        source: 'clear_next',
                                      );
                                    }
                                    setState(() => _playQueue = _playQueue
                                        .sublist(0, _currentIndex + 1));
                                    _notifyQueueChanged();
                                    setSheet(() {});
                                  },
                                  child: const Text('Clear next',
                                      style: TextStyle(
                                          color: Colors.redAccent,
                                          fontSize: 12)),
                                )
                              : null,
                        ),
                        Expanded(
                          child: _playQueue.isEmpty
                              ? Center(
                                  child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                      Icon(Icons.queue_music_rounded,
                                          color: Colors.grey[700], size: 52),
                                      const SizedBox(height: 12),
                                      Text('Queue is empty',
                                          style: TextStyle(
                                              color: Colors.grey[600],
                                              fontSize: 15)),
                                      const SizedBox(height: 4),
                                      Text(
                                          'Use "Play next" on any song to add it',
                                          style: TextStyle(
                                              color: Colors.grey[700],
                                              fontSize: 12)),
                                    ]))
                              : ListView.builder(
                                  controller: sheetCtrl,
                                  padding: const EdgeInsets.only(bottom: 32),
                                  itemCount: _playQueue.length,
                                  itemBuilder: (ctx, qi) {
                                    final video = _playQueue[qi];
                                    final isCurrent = qi == _currentIndex;
                                    final isPlayed = qi < _currentIndex;
                                    final isUpcoming = qi > _currentIndex;
                                    final cached =
                                        _tmpFiles.containsKey(video.id.value);
                                    final fetching =
                                        _prefetching.contains(video.id.value);

                                    return AnimatedContainer(
                                      key: ValueKey('q_${video.id.value}_$qi'),
                                      duration:
                                          const Duration(milliseconds: 200),
                                      margin: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: isCurrent
                                            ? Colors.green.shade900
                                                .withValues(alpha: 0.5)
                                            : isPlayed
                                                ? Colors.transparent
                                                : const Color(0xFF1A1A1A),
                                        borderRadius: BorderRadius.circular(12),
                                        border: isCurrent
                                            ? Border.all(
                                                color: Colors.greenAccent
                                                    .withValues(alpha: 0.5))
                                            : null,
                                      ),
                                      child: Material(
                                        color: Colors.transparent,
                                        child: InkWell(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          onTap: isCurrent
                                              ? null
                                              : () {
                                                  setState(
                                                      () => _radioMode = false);
                                                  _playFromUserAction(
                                                    video,
                                                    qi,
                                                    tasteWeight: 0.55,
                                                    source: 'queue_jump',
                                                  );
                                                  Navigator.pop(ctx);
                                                },
                                          splashColor: Colors.greenAccent
                                              .withValues(alpha: 0.1),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 12, vertical: 8),
                                            child: Row(children: [
                                              // Thumbnail with overlay
                                              SizedBox(
                                                width: 48,
                                                height: 48,
                                                child: Stack(
                                                    clipBehavior: Clip.none,
                                                    children: [
                                                      ClipRRect(
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(8),
                                                        child: ColorFiltered(
                                                          colorFilter: isPlayed
                                                              ? const ColorFilter
                                                                  .matrix([
                                                                  0.25,
                                                                  0,
                                                                  0,
                                                                  0,
                                                                  0,
                                                                  0,
                                                                  0.25,
                                                                  0,
                                                                  0,
                                                                  0,
                                                                  0,
                                                                  0,
                                                                  0.25,
                                                                  0,
                                                                  0,
                                                                  0,
                                                                  0,
                                                                  0,
                                                                  1,
                                                                  0,
                                                                ])
                                                              : const ColorFilter
                                                                  .mode(
                                                                  Colors
                                                                      .transparent,
                                                                  BlendMode
                                                                      .multiply),
                                                          child:
                                                              CachedNetworkImage(
                                                            imageUrl: video
                                                                .thumbnails
                                                                .mediumResUrl,
                                                            width: 48,
                                                            height: 48,
                                                            fit: BoxFit.cover,
                                                            placeholder: (_,
                                                                    __) =>
                                                                Container(
                                                                    color: Colors
                                                                            .grey[
                                                                        850],
                                                                    width: 48,
                                                                    height: 48),
                                                            errorWidget: (_, __,
                                                                    ___) =>
                                                                Container(
                                                                    color: Colors
                                                                            .grey[
                                                                        850],
                                                                    width: 48,
                                                                    height: 48,
                                                                    child: const Icon(
                                                                        Icons
                                                                            .music_note,
                                                                        color: Colors
                                                                            .grey,
                                                                        size:
                                                                            20)),
                                                          ),
                                                        ),
                                                      ),
                                                      if (isCurrent)
                                                        Positioned.fill(
                                                          child: Container(
                                                            decoration: BoxDecoration(
                                                                borderRadius:
                                                                    BorderRadius
                                                                        .circular(
                                                                            8),
                                                                color: Colors
                                                                    .black
                                                                    .withValues(
                                                                        alpha:
                                                                            0.45)),
                                                            child: Center(
                                                              child: _isBuffering
                                                                  ? const SizedBox(
                                                                      width: 18,
                                                                      height:
                                                                          18,
                                                                      child: CircularProgressIndicator(
                                                                          color: Colors
                                                                              .greenAccent,
                                                                          strokeWidth:
                                                                              2))
                                                                  : _buildEqualizerBars(
                                                                      size: 18,
                                                                      color: Colors
                                                                          .greenAccent),
                                                            ),
                                                          ),
                                                        ),
                                                      if (isUpcoming)
                                                        Positioned(
                                                          right: -4,
                                                          bottom: -4,
                                                          child: Container(
                                                            width: 16,
                                                            height: 16,
                                                            decoration: BoxDecoration(
                                                                shape: BoxShape.circle,
                                                                color: cached
                                                                    ? Colors.greenAccent
                                                                    : fetching
                                                                        ? Colors.orange
                                                                        : Colors.grey[800]),
                                                            child: Icon(
                                                              cached
                                                                  ? Icons
                                                                      .check_rounded
                                                                  : fetching
                                                                      ? Icons
                                                                          .hourglass_top_rounded
                                                                      : Icons
                                                                          .cloud_rounded,
                                                              size: 10,
                                                              color: cached
                                                                  ? Colors.black
                                                                  : Colors
                                                                      .white,
                                                            ),
                                                          ),
                                                        ),
                                                    ]),
                                              ),
                                              const SizedBox(width: 12),
                                              // Title + author
                                              Expanded(
                                                  child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: [
                                                    Text(
                                                        _cleanTitle(
                                                            video.title),
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                          color: isCurrent
                                                              ? Colors
                                                                  .greenAccent
                                                              : isPlayed
                                                                  ? Colors
                                                                      .grey[600]
                                                                  : Colors
                                                                      .white,
                                                          fontSize: 13,
                                                          fontWeight: isCurrent
                                                              ? FontWeight.w600
                                                              : FontWeight
                                                                  .normal,
                                                        )),
                                                    const SizedBox(height: 2),
                                                    Text(
                                                        _cleanAuthor(
                                                            video.author),
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                            color: isPlayed
                                                                ? Colors
                                                                    .grey[800]
                                                                : Colors
                                                                    .grey[600],
                                                            fontSize: 11)),
                                                  ])),
                                              // Trailing
                                              if (isCurrent)
                                                const Padding(
                                                  padding:
                                                      EdgeInsets.only(left: 8),
                                                  child: Icon(
                                                      Icons.volume_up_rounded,
                                                      color: Colors.greenAccent,
                                                      size: 18),
                                                )
                                              else if (isUpcoming)
                                                Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      Text(
                                                          '+${qi - _currentIndex}',
                                                          style: TextStyle(
                                                              color: Colors
                                                                  .grey[700],
                                                              fontSize: 10)),
                                                      const SizedBox(width: 4),
                                                      GestureDetector(
                                                        onTap: () {
                                                          final removed =
                                                              _playQueue[qi];
                                                          _registerFeedback(
                                                            removed,
                                                            weight: -0.8,
                                                            source:
                                                                'queue_remove',
                                                          );
                                                          setState(() =>
                                                              _playQueue
                                                                  .removeAt(
                                                                      qi));
                                                          setSheet(() {});
                                                        },
                                                        child: Padding(
                                                          padding:
                                                              const EdgeInsets
                                                                  .symmetric(
                                                                  horizontal: 4,
                                                                  vertical: 4),
                                                          child: Icon(
                                                              Icons
                                                                  .remove_circle_outline_rounded,
                                                              color: Colors
                                                                  .grey[700],
                                                              size: 18),
                                                        ),
                                                      ),
                                                    ]),
                                            ]),
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ]);
                    },
                  );
                },
              ),
            ));
  }

  // Shuffle
  void _toggleShuffle() {
    if (_isDownloadPlayback) {
      setState(() {
        if (_downloadShuffleOn) {
          if (_isValidDownloadQueue(_unshuffledDownloadQueue)) {
            _downloadQueue
              ..clear()
              ..addAll(_unshuffledDownloadQueue);
          } else {
            _downloadQueue
              ..clear()
              ..addAll(_allDownloadIndices());
          }
          _downloadShuffleOn = false;
          _unshuffledDownloadQueue.clear();
        } else {
          final all = _allDownloadIndices();
          _unshuffledDownloadQueue
            ..clear()
            ..addAll(all);
          final current = _currentDownloadIndex >= 0 &&
                  _currentDownloadIndex < _downloads.length
              ? _currentDownloadIndex
              : (all.isNotEmpty ? all.first : -1);
          final rest = all.where((i) => i != current).toList()..shuffle();
          _downloadQueue
            ..clear()
            ..addAll(current >= 0 ? <int>[current, ...rest] : rest);
          _downloadShuffleOn = true;
        }
        _currentDownloadQueuePos =
            _downloadQueue.indexOf(_currentDownloadIndex);
        _currentIndex = _currentDownloadQueuePos;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_downloadShuffleOn
            ? 'Downloads shuffle on'
            : 'Downloads shuffle off'),
        duration: const Duration(seconds: 1),
      ));
      return;
    }

    setState(() {
      if (_shuffleOn) {
        _playQueue = List<Video>.from(_unshuffledQueue);
        _currentIndex =
            _playQueue.indexWhere((v) => v.id.value == _nowPlaying?.id.value);
        _unshuffledQueue = [];
        _shuffleOn = false;
      } else {
        _unshuffledQueue = List<Video>.from(_playQueue);
        final played = _playQueue.sublist(0, _currentIndex + 1);
        final rest = _playQueue.sublist(_currentIndex + 1)..shuffle();
        _playQueue = [...played, ...rest];
        _shuffleOn = true;
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(_shuffleOn ? 'Shuffle on' : 'Shuffle off'),
      duration: const Duration(seconds: 1),
    ));
  }

  void _cycleRepeat() {
    setState(() => _repeatMode = (_repeatMode + 1) % 3);
    final labels = ['Repeat off', 'Repeat all', 'Repeat one'];
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(labels[_repeatMode]),
      duration: const Duration(seconds: 1),
    ));
  }

  // Sleep timer
  void _showSleepTimerSheet() {
    final options = [5, 10, 15, 20, 30, 45, 60, 90];
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) =>
            Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
                color: Colors.grey[700],
                borderRadius: BorderRadius.circular(2)),
          ),
          _sheetHeader(
            icon: Icons.bedtime_rounded,
            color: Colors.greenAccent,
            title: 'Sleep Timer',
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            trailing: _sleepTimer != null
                ? TextButton(
                    onPressed: () {
                      _cancelSleepTimer();
                      Navigator.pop(ctx);
                    },
                    child: const Text('Cancel timer',
                        style:
                            TextStyle(color: Colors.redAccent, fontSize: 12)),
                  )
                : null,
          ),
          if (_sleepTimer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: StreamBuilder<void>(
                stream: Stream.periodic(const Duration(seconds: 1)),
                builder: (_, __) {
                  final rem =
                      _sleepAt?.difference(DateTime.now()) ?? Duration.zero;
                  final mins = rem.inMinutes;
                  final secs = rem.inSeconds % 60;
                  return Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.greenAccent.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: Colors.greenAccent.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.timer_rounded,
                              color: Colors.greenAccent, size: 16),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                                'Stops in ${mins}m ${secs.toString().padLeft(2, '0')}s',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.greenAccent, fontSize: 14)),
                          ),
                        ]),
                  );
                },
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: options
                .map((mins) => GestureDetector(
                      onTap: () {
                        _setSleepTimer(mins);
                        Navigator.pop(ctx);
                      },
                      child: Container(
                        width: 72,
                        height: 48,
                        decoration: BoxDecoration(
                          color: const Color(0xFF252525),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.grey.shade800),
                        ),
                        child: Center(
                            child: Text('${mins}m',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600))),
                      ),
                    ))
                .toList(),
          ),
          const SizedBox(height: 20),
        ]),
      ),
    );
  }

  void _setSleepTimer(int minutes) {
    _cancelSleepTimer();
    final dur = Duration(minutes: minutes);
    _sleepAt = DateTime.now().add(dur);
    _sleepTimer = Timer(dur, () {
      _player.pause();
      _cancelSleepTimer();
      if (mounted) setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Sleep timer: music paused'),
          duration: Duration(seconds: 3)));
    });
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Stops in $minutes minutes'),
        duration: const Duration(seconds: 2)));
  }

  void _cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepCountdown?.cancel();
    _sleepTimer = null;
    _sleepAt = null;
    if (mounted) setState(() {});
  }

  // Crossfade
  Future<void> _doCrossfade(
    Video nextVideo,
    int nextIndex, {
    double? fadeSecs,
  }) async {
    if (_crossfading) return;
    _crossfading = true;

    final nextId = nextVideo.id.value;
    final cachedPath = _tmpFiles[nextId];
    if (cachedPath == null || !await File(cachedPath).exists()) {
      _crossfading = false;
      await _play(nextVideo, nextIndex);
      return;
    }

    try {
      final fromVolume = _targetVolumeForVideo(_nowPlaying);
      final toVolume = _targetVolumeForVideo(nextVideo);
      final transitionSecs = (fadeSecs ?? _crossfadeSecs).clamp(0.8, 8.0);
      await _playerB.setFilePath(cachedPath);
      await _playerB.setSpeed(_playbackSpeed);
      await _player.setVolume(fromVolume);
      await _playerB.setVolume(0);
      await _playerB.play();

      final steps = max(1, (transitionSecs * 10).round());
      const stepDur = Duration(milliseconds: 100);

      for (int i = 1; i <= steps; i++) {
        await Future<void>.delayed(stepDur);
        if (!_crossfading) break;
        final t = i / steps;
        await _player.setVolume(fromVolume * (1.0 - t));
        await _playerB.setVolume(toVolume * t);
      }

      if (!_crossfading) {
        await _playerB.stop();
        await _playerB.setVolume(1.0);
        return;
      }

      await _player.stop();
      await _setPlayerSource(
        AudioSource.uri(
          Uri.file(cachedPath),
          tag: _mediaItemForVideo(nextVideo, cachedPath),
        ),
      );
      await _player.setSpeed(_playbackSpeed);
      await _player.seek(_playerB.position);
      await _player.setVolume(toVolume);
      await _player.play();
      await _playerB.stop();
      await _playerB.setVolume(1.0);

      setState(() {
        _nowPlaying = nextVideo;
        _currentIndex = nextIndex;
      });

      _history.removeWhere((v) => v.id == nextVideo.id);
      _history.insert(0, nextVideo);
      _radioSeenIds.add(nextId);
      unawaited(_prefetchNext(nextIndex, nextId));
    } catch (e) {
      debugPrint('[Crossfade] error: $e');
      _crossfading = false;
      await _play(nextVideo, nextIndex);
      return;
    }
    _crossfading = false;
  }

  // Playback speed sheet
  void _showSpeedSheet() {
    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) =>
            Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
                color: Colors.grey[700],
                borderRadius: BorderRadius.circular(2)),
          ),
          _sheetHeader(
            icon: Icons.speed_rounded,
            color: Colors.greenAccent,
            title: 'Playback Speed',
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(children: [
              Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  _playbackSpeed == 1.0
                      ? 'Normal speed'
                      : '${_playbackSpeed}x speed',
                  style: TextStyle(
                    color: _playbackSpeed == 1.0
                        ? Colors.grey[400]
                        : Colors.greenAccent,
                    fontSize: 14,
                  ),
                ),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: speeds.map((s) {
                  final active = (_playbackSpeed - s).abs() < 0.01;
                  return GestureDetector(
                    onTap: () async {
                      setState(() => _playbackSpeed = s);
                      await _player.setSpeed(s);
                      setSheet(() {});
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: active
                            ? Colors.greenAccent
                            : const Color(0xFF252525),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: active
                                ? Colors.greenAccent
                                : Colors.grey.shade800),
                      ),
                      child: Center(
                        child: Text(
                          s == 1.0 ? '1x' : '${s}x',
                          style: TextStyle(
                              color: active ? Colors.black : Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),
            ]),
          ),
        ]),
      ),
    );
  }

  // Crossfade sheet
  void _showLoudnessNormalizationSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) =>
            Column(mainAxisSize: MainAxisSize.min, children: [
          _sheetHandle(),
          _sheetHeader(
            icon: Icons.graphic_eq_rounded,
            color: Colors.lightBlueAccent,
            title: 'Loudness Normalization',
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            trailing: Switch(
              value: _loudnessNormalizationOn,
              activeThumbColor: Colors.greenAccent,
              onChanged: (v) {
                setState(() => _loudnessNormalizationOn = v);
                setSheet(() {});
                _scheduleSave();
                unawaited(_syncCurrentTrackVolume());
              },
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            child: _loudnessNormalizationOn
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          alignment: WrapAlignment.spaceBetween,
                          children: [
                            Text(
                                'Strength: ${(_loudnessNormalizationStrength * 100).round()}%',
                                style: TextStyle(
                                    color: Colors.grey[400], fontSize: 13)),
                            Text('Gentle to aggressive',
                                style: TextStyle(
                                    color: Colors.grey[700], fontSize: 11)),
                          ],
                        ),
                        SliderTheme(
                          data: SliderTheme.of(ctx).copyWith(
                            activeTrackColor: Colors.greenAccent,
                            inactiveTrackColor: Colors.grey[800],
                            thumbColor: Colors.greenAccent,
                          ),
                          child: Slider(
                            value: _loudnessNormalizationStrength,
                            min: 0.2,
                            max: 1.0,
                            divisions: 16,
                            onChanged: (v) {
                              setState(
                                  () => _loudnessNormalizationStrength = v);
                              setSheet(() {});
                              _scheduleSave();
                              unawaited(_syncCurrentTrackVolume());
                            },
                          ),
                        ),
                        Text(
                          'Balances track-to-track volume swings without changing your music taste mix.',
                          style:
                              TextStyle(color: Colors.grey[600], fontSize: 11),
                        ),
                      ],
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    child: Text(
                      'Off: songs play at their original level.',
                      style: TextStyle(color: Colors.grey[600], fontSize: 11),
                    ),
                  ),
          ),
        ]),
      ),
    );
  }

  void _showCrossfadeSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) =>
            Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
                color: Colors.grey[700],
                borderRadius: BorderRadius.circular(2)),
          ),
          _sheetHeader(
            icon: Icons.blur_on_rounded,
            color: Colors.greenAccent,
            title: 'Crossfade',
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            trailing: Switch(
              value: _crossfadeOn,
              activeThumbColor: Colors.greenAccent,
              onChanged: (v) {
                setState(() => _crossfadeOn = v);
                _scheduleSave();
                setSheet(() {});
              },
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            child: _crossfadeOn
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          alignment: WrapAlignment.spaceBetween,
                          children: [
                            Text(
                                'Duration: ${_crossfadeSecs.toStringAsFixed(1)}s',
                                style: TextStyle(
                                    color: Colors.grey[400], fontSize: 13)),
                            Text('1s - 8s',
                                style: TextStyle(
                                    color: Colors.grey[700], fontSize: 11)),
                          ],
                        ),
                        SliderTheme(
                          data: SliderTheme.of(ctx).copyWith(
                            activeTrackColor: Colors.greenAccent,
                            inactiveTrackColor: Colors.grey[800],
                            thumbColor: Colors.greenAccent,
                            overlayColor:
                                Colors.greenAccent.withValues(alpha: 0.2),
                          ),
                          child: Slider(
                            value: _crossfadeSecs,
                            min: 1,
                            max: 8,
                            divisions: 14,
                            onChanged: (v) {
                              setState(() => _crossfadeSecs = v);
                              _scheduleSave();
                              setSheet(() {});
                            },
                          ),
                        ),
                        Text(
                          'Songs will blend smoothly into each other.\n'
                          'Only works when the next song is pre-cached.',
                          style:
                              TextStyle(color: Colors.grey[600], fontSize: 11),
                        ),
                      ],
                    ),
                  )
                : const SizedBox(height: 16),
          ),
        ]),
      ),
    );
  }

  // Like toggle
  void _enqueueLikedSongForAutoDownload(Video video) {
    if (_hasDownloadForVideoId(video.id.value)) return;
    if (_taskForVideoId(video.id.value) != null) return;
    if (_likedAutoDownloadQueue.any((v) => v.id.value == video.id.value)) {
      return;
    }
    _likedAutoDownloadQueue.add(video);
    unawaited(_drainLikedAutoDownloadQueue());
  }

  Future<void> _drainLikedAutoDownloadQueue() async {
    if (_autoDownloadingLiked) return;
    _autoDownloadingLiked = true;
    try {
      while (_likedAutoDownloadQueue.isNotEmpty) {
        final video = _likedAutoDownloadQueue.removeAt(0);
        if (_hasDownloadForVideoId(video.id.value)) continue;
        await _downloadAudio(video, silent: true);
      }
    } finally {
      _autoDownloadingLiked = false;
    }
  }

  void _toggleLike(Video video) {
    final id = video.id.value;
    final wasLiked = _likedVideoIds.contains(id);
    if (wasLiked) {
      _likedAutoDownloadQueue.removeWhere((v) => v.id.value == id);
    }
    setState(() {
      if (wasLiked) {
        _likedVideoIds.remove(id);
        _likedPlaylist.videos.removeWhere((v) => v.id.value == id);
      } else {
        _likedVideoIds.add(id);
        if (!_likedPlaylist.videos.any((v) => v.id.value == id)) {
          _likedPlaylist.videos.insert(0, video);
        }
      }
    });
    _registerFeedback(
      video,
      weight: wasLiked ? -2.1 : 2.6,
      source: wasLiked ? 'unlike' : 'like',
    );
    // Refresh "Because you liked" when liked songs change
    if (_likedPlaylist.videos.isNotEmpty) {
      unawaited(_loadBecauseYouLiked());
    }
    if (!wasLiked) {
      _enqueueLikedSongForAutoDownload(video);
    }
    if (_nowPlaying != null && _nowPlaying!.id.value == id) {
      final liked = _likedVideoIds.contains(id);
      try {
        AudioService.customAction('set_like_state', {'liked': liked});
      } catch (_) {}
    }
    _scheduleSave();
  }

  bool _isLiked(Video? video) =>
      video != null && _likedVideoIds.contains(video.id.value);

  // Add-to-playlist sheet
  void _showAddToPlaylist(Video video) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final allPlaylists = <BeastPlaylist>[_likedPlaylist, ..._playlists];
          return Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                  color: Colors.grey[700],
                  borderRadius: BorderRadius.circular(2)),
            ),
            _sheetHeader(
              icon: Icons.playlist_add_rounded,
              color: Colors.greenAccent,
              title: 'Add to Playlist',
              padding: const EdgeInsets.fromLTRB(20, 0, 16, 12),
              trailing: TextButton.icon(
                icon:
                    const Icon(Icons.add, color: Colors.greenAccent, size: 18),
                label: const Text('New',
                    style: TextStyle(color: Colors.greenAccent)),
                onPressed: () {
                  Navigator.pop(ctx);
                  _showCreatePlaylistDialog(prefillVideo: video);
                },
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView(
                shrinkWrap: true,
                children: allPlaylists.map((pl) {
                  final has =
                      pl.videos.any((v) => v.id.value == video.id.value);
                  return ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: pl.id == '__liked__'
                          ? Container(
                              width: 44,
                              height: 44,
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(colors: [
                                  Color(0xFF1a1a2e),
                                  Color(0xFF6d28d9)
                                ]),
                              ),
                              child: const Icon(Icons.favorite_rounded,
                                  color: Colors.pinkAccent, size: 22),
                            )
                          : pl.coverUrl != null
                              ? CachedNetworkImage(
                                  imageUrl: pl.coverUrl!,
                                  width: 44,
                                  height: 44,
                                  fit: BoxFit.cover,
                                  errorWidget: (_, __, ___) =>
                                      _playlistFallbackIcon())
                              : _playlistFallbackIcon(),
                    ),
                    title: Text(pl.name,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 13)),
                    subtitle: Text('${pl.videos.length} songs',
                        style:
                            TextStyle(color: Colors.grey[600], fontSize: 11)),
                    trailing: has
                        ? const Icon(Icons.check_circle_rounded,
                            color: Colors.greenAccent, size: 22)
                        : const Icon(Icons.add_circle_outline_rounded,
                            color: Colors.grey, size: 22),
                    onTap: () {
                      if (pl.id == '__liked__') {
                        if (!has) _toggleLike(video);
                      } else {
                        setState(() {
                          if (has) {
                            pl.videos.removeWhere(
                                (v) => v.id.value == video.id.value);
                          } else {
                            pl.videos.insert(0, video);
                          }
                        });
                        _scheduleSave();
                      }
                      setSheetState(() {});
                    },
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 16),
          ]);
        },
      ),
    );
  }

  Widget _appLogoImage({
    double size = 22,
    BorderRadius? borderRadius,
  }) =>
      ClipRRect(
        borderRadius: borderRadius ?? BorderRadius.circular(6),
        child: Image.asset(
          'assets/app_logo.png',
          width: size,
          height: size,
          fit: BoxFit.cover,
        ),
      );

  Widget _playlistFallbackIcon() => Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
            color: const Color(0xFF252525),
            borderRadius: BorderRadius.circular(6)),
        child: Center(child: _appLogoImage(size: 24)),
      );

  // Create playlist dialog
  void _showCreatePlaylistDialog({Video? prefillVideo}) {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('New Playlist',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Playlist name',
            hintStyle: TextStyle(color: Colors.grey[600]),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: Colors.grey[800]!)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Colors.greenAccent)),
            filled: true,
            fillColor: const Color(0xFF252525),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: TextStyle(color: Colors.grey[500]))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.greenAccent,
                foregroundColor: Colors.black),
            onPressed: () {
              final name = ctrl.text.trim();
              if (name.isEmpty) return;
              final pl = BeastPlaylist(
                id: 'pl_${DateTime.now().millisecondsSinceEpoch}',
                name: name,
              );
              if (prefillVideo != null) pl.videos.add(prefillVideo);
              setState(() => _playlists.insert(0, pl));
              Navigator.pop(ctx);
              _scheduleSave();
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('"$name" created',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  duration: const Duration(seconds: 2)));
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  // Rename playlist dialog
  void _showRenamePlaylistDialog(BeastPlaylist pl) {
    final ctrl = TextEditingController(text: pl.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Rename Playlist',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'New name',
            hintStyle: TextStyle(color: Colors.grey[600]),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: Colors.grey[800]!)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Colors.greenAccent)),
            filled: true,
            fillColor: const Color(0xFF252525),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: TextStyle(color: Colors.grey[500]))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.greenAccent,
                foregroundColor: Colors.black),
            onPressed: () {
              final name = ctrl.text.trim();
              if (name.isEmpty) return;
              setState(() => pl.name = name);
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('Renamed to "$name"',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  duration: const Duration(seconds: 2)));
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  // Download
  Future<void> _downloadPlaylist(
    BeastPlaylist playlist, {
    bool onlyMissing = true,
  }) async {
    final songs = playlist.videos
        .where((v) => _isMusicCandidate(v, strictSingles: true))
        .toList();
    if (songs.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('No downloadable songs in this playlist')),
        );
      }
      return;
    }

    var queued = 0;
    for (final video in songs) {
      final alreadyDownloaded = _hasDownloadForVideoId(video.id.value);
      final alreadyQueued = _taskForVideoId(video.id.value) != null;
      if (onlyMissing && (alreadyDownloaded || alreadyQueued)) continue;
      await _downloadAudio(video, silent: true);
      if (!alreadyDownloaded && !alreadyQueued) queued += 1;
    }

    if (!mounted) return;
    final name = playlist.name.trim().isEmpty ? 'Playlist' : playlist.name;
    final msg = queued > 0
        ? 'Queued $queued of ${songs.length} songs from "$name"'
        : 'All ${songs.length} songs from "$name" are already downloaded or queued';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(msg, maxLines: 2, overflow: TextOverflow.ellipsis),
          duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _downloadAudio(Video video, {bool silent = false}) async {
    if (_hasDownloadForVideoId(video.id.value)) {
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Song already downloaded')),
        );
      }
      return;
    }

    final existing = _taskForVideoId(video.id.value);
    if (existing != null) {
      if (existing.state == _DownloadTaskState.downloading &&
          !_isTaskActive(existing) &&
          existing.progress >= 0.99) {
        if (mounted) {
          setState(
              () => _downloadTasks.removeWhere((t) => t.id == existing.id));
        } else {
          _downloadTasks.removeWhere((t) => t.id == existing.id);
        }
      } else if (existing.state == _DownloadTaskState.failed ||
          existing.state == _DownloadTaskState.paused) {
        _resumeDownloadTask(existing);
        if (!silent && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Download resumed')),
          );
        }
      } else if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Already in download queue')),
        );
      }
      return;
    }

    final task = _DownloadTask(video: video, silent: silent);
    if (mounted) {
      setState(() => _downloadTasks.add(task));
    } else {
      _downloadTasks.add(task);
    }
    if (!silent && mounted) {
      final count = _downloadTasks.length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Added to download queue ($count)',
                maxLines: 1, overflow: TextOverflow.ellipsis)),
      );
    }
    _scheduleDownloadKeepAliveSync(immediate: true);
    unawaited(_processDownloadQueue());
  }

  void _requestPauseDownloadTask(_DownloadTask task) {
    if (!_isTaskActive(task)) return;
    _downloadPauseRequestedTaskIds.add(task.id);
    final c = _downloadAbortByTaskId[task.id];
    if (c != null && !c.isCompleted) c.complete();
    final sub = _downloadStreamSubByTaskId.remove(task.id);
    if (sub != null) {
      unawaited(sub.cancel());
    }
  }

  void _requestCancelDownloadTask(_DownloadTask task) {
    if (!_isTaskActive(task)) return;
    _downloadCancelRequestedTaskIds.add(task.id);
    final c = _downloadAbortByTaskId[task.id];
    if (c != null && !c.isCompleted) c.complete();
    final sub = _downloadStreamSubByTaskId.remove(task.id);
    if (sub != null) {
      unawaited(sub.cancel());
    }
  }

  void _resumeDownloadTask(_DownloadTask task) {
    if (task.state == _DownloadTaskState.downloading ||
        task.state == _DownloadTaskState.queued) {
      return;
    }
    if (mounted) {
      setState(() {
        task.state = _DownloadTaskState.queued;
        task.error = null;
        task.progress = 0;
      });
    } else {
      task.state = _DownloadTaskState.queued;
      task.error = null;
      task.progress = 0;
    }
    _scheduleDownloadKeepAliveSync(immediate: true);
    unawaited(_processDownloadQueue());
  }

  void _retryDownloadTask(_DownloadTask task) {
    _resumeDownloadTask(task);
  }

  void _cancelDownloadTask(_DownloadTask task) {
    if (_isTaskActive(task)) {
      _requestCancelDownloadTask(task);
      _scheduleDownloadKeepAliveSync(immediate: true);
      return;
    }
    if (mounted) {
      setState(() => _downloadTasks.removeWhere((t) => t.id == task.id));
    } else {
      _downloadTasks.removeWhere((t) => t.id == task.id);
    }
    _scheduleDownloadKeepAliveSync(immediate: true);
  }

  Future<void> _processDownloadQueue() async {
    if (_downloadQueuePumpScheduled) return;
    _downloadQueuePumpScheduled = true;
    try {
      while (_runningDownloadTaskIds.length < _maxConcurrentDownloads) {
        _DownloadTask? task;
        for (final t in _downloadTasks) {
          final isAlreadyRunning = _runningDownloadTaskIds.contains(t.id);
          if (!isAlreadyRunning && t.state == _DownloadTaskState.queued) {
            task = t;
            break;
          }
        }
        if (task == null) break;
        final currentTask = task;
        _runningDownloadTaskIds.add(currentTask.id);
        unawaited(_runDownloadTask(currentTask).whenComplete(() {
          _runningDownloadTaskIds.remove(currentTask.id);
          _scheduleDownloadKeepAliveSync(immediate: true);
          unawaited(_processDownloadQueue());
        }));
      }
      if (mounted) {
        setState(() => _isDownloading = _runningDownloadTaskIds.isNotEmpty);
      } else {
        _isDownloading = _runningDownloadTaskIds.isNotEmpty;
      }
      if (_runningDownloadTaskIds.isEmpty) {
        if (mounted) {
          setState(() => _downloadProgress = 0);
        } else {
          _downloadProgress = 0;
        }
      }
    } finally {
      _downloadQueuePumpScheduled = false;
    }
  }

  Future<String> _resolveDownloadSavePath() async {
    for (final candidate in const [
      '/storage/emulated/0/Music/BeastMusic',
      '/storage/emulated/0/Download/BeastMusic',
    ]) {
      try {
        final dir = Directory(candidate);
        if (!await dir.exists()) await dir.create(recursive: true);
        final testFile = File('$candidate/.test');
        await testFile.writeAsString('test');
        await testFile.delete();
        return candidate;
      } catch (_) {}
    }

    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        final dir = Directory('${ext.path}/BeastMusic');
        if (!await dir.exists()) await dir.create(recursive: true);
        return dir.path;
      }
    } catch (_) {}

    return (await getApplicationDocumentsDirectory()).path;
  }

  Future<void> _runDownloadTask(_DownloadTask task) async {
    final video = task.video;
    final taskId = task.id;
    _downloadPauseRequestedTaskIds.remove(taskId);
    _downloadCancelRequestedTaskIds.remove(taskId);
    final abort = Completer<void>();
    _downloadAbortByTaskId[taskId] = abort;
    _downloadKeepAliveTaskId = task.id;
    _downloadKeepAliveProgressBucket = -1;

    if (mounted) {
      setState(() {
        task.state = _DownloadTaskState.downloading;
        task.error = null;
        _isDownloading = true;
        _downloadProgress = task.progress;
      });
    } else {
      task.state = _DownloadTaskState.downloading;
      task.error = null;
      _isDownloading = true;
      _downloadProgress = task.progress;
    }
    _scheduleDownloadKeepAliveSync(immediate: true);

    String? filePath;
    try {
      final result = await _fetchManifest(
        video.id.value,
        silent: task.silent,
      );
      if (result == null) throw Exception('Could not fetch audio stream');

      final yt = result.yt;
      final manifest = result.manifest;
      try {
        final savePath = await _resolveDownloadSavePath();
        final safeName = video.title
            .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        final streamCandidates =
            _downloadStreamCandidates(manifest.audioOnly.toList());
        if (streamCandidates.isEmpty) {
          throw Exception('No downloadable audio streams found');
        }
        Object? lastStreamError;
        for (int streamIdx = 0;
            streamIdx < streamCandidates.length;
            streamIdx++) {
          final audioStream = streamCandidates[streamIdx];
          final ext = audioStream.container.name;
          filePath = '$savePath/$safeName.$ext';
          final total = audioStream.size.totalBytes;
          int received = 0;
          final sink = File(filePath).openWrite();
          try {
            final downloadStream = yt.videos.streamsClient
                .get(audioStream)
                .timeout(const Duration(seconds: 120), onTimeout: (sink) {
              sink.addError(
                TimeoutException('Download stalled. Please retry.'),
              );
            });
            final streamDone = Completer<void>();
            Object? streamError;
            StackTrace? streamStack;
            int lastUiBucket = -1;
            StreamSubscription<List<int>>? sub;
            sub = downloadStream.listen(
              (chunk) {
                final pauseRequested =
                    _downloadPauseRequestedTaskIds.contains(taskId);
                final cancelRequested =
                    _downloadCancelRequestedTaskIds.contains(taskId);
                final interrupted =
                    (_downloadAbortByTaskId[taskId]?.isCompleted == true) ||
                        pauseRequested ||
                        cancelRequested;
                if (interrupted) {
                  streamError = _DownloadInterrupted(paused: pauseRequested);
                  final localSub = sub;
                  sub = null;
                  if (localSub != null) {
                    unawaited(localSub.cancel());
                  }
                  if (!streamDone.isCompleted) streamDone.complete();
                  return;
                }
                sink.add(chunk);
                received += chunk.length;
                if (total > 0 && received >= total) {
                  final localSub = sub;
                  sub = null;
                  if (localSub != null) {
                    unawaited(localSub.cancel());
                  }
                  if (!streamDone.isCompleted) streamDone.complete();
                }
                if (total > 0) {
                  final rawProgress = (received / total).clamp(0.0, 1.0);
                  task.progress =
                      rawProgress >= 1.0 ? 0.985 : rawProgress.toDouble();
                } else {
                  final rawProgress =
                      (received / (8 * 1024 * 1024)).clamp(0.0, 0.94);
                  task.progress = rawProgress.toDouble();
                }
                final bucket = (task.progress * 100 ~/ 10);
                if (_downloadKeepAliveTaskId != task.id) {
                  _downloadKeepAliveTaskId = task.id;
                  _downloadKeepAliveProgressBucket = -1;
                }
                if (bucket != _downloadKeepAliveProgressBucket) {
                  _downloadKeepAliveProgressBucket = bucket;
                  _scheduleDownloadKeepAliveSync();
                }
                if (mounted) {
                  final uiBucket = (task.progress * 100).floor();
                  if (uiBucket != lastUiBucket) {
                    lastUiBucket = uiBucket;
                    setState(() => _downloadProgress = task.progress);
                  }
                } else {
                  _downloadProgress = task.progress;
                }
              },
              onError: (Object e, StackTrace st) {
                streamError = e;
                streamStack = st;
                if (!streamDone.isCompleted) streamDone.complete();
              },
              onDone: () {
                if (!streamDone.isCompleted) streamDone.complete();
              },
              cancelOnError: false,
            );
            _downloadStreamSubByTaskId[taskId] = sub!;
            final totalBytes = total > 0 ? total : (6 * 1024 * 1024);
            final dynamicTimeoutSecs =
                ((totalBytes / 32000).ceil()).clamp(180, 1800);
            await streamDone.future.timeout(
              Duration(seconds: dynamicTimeoutSecs),
              onTimeout: () {
                streamError = TimeoutException('Download stalled. Please retry.');
              },
            );
            final localSub = sub;
            sub = null;
            if (localSub != null) {
              await localSub.cancel();
            }
            _downloadStreamSubByTaskId.remove(taskId);
            final pauseRequested =
                _downloadPauseRequestedTaskIds.contains(taskId);
            final cancelRequested =
                _downloadCancelRequestedTaskIds.contains(taskId);
            if (cancelRequested ||
                _downloadAbortByTaskId[taskId]?.isCompleted == true) {
              throw _DownloadInterrupted(paused: pauseRequested);
            }
            if (received <= 0) {
              throw TimeoutException('Download ended early. Please retry.');
            }
            if (total > 0 && received < total) {
              throw TimeoutException('Download ended early. Please retry.');
            }
            if (streamError != null) {
              if (streamError is _DownloadInterrupted) {
                throw streamError as _DownloadInterrupted;
              }
              if (streamStack != null) {
                Error.throwWithStackTrace(streamError!, streamStack!);
              }
              throw streamError!;
            }
            await sink.flush()
                .timeout(const Duration(seconds: 8), onTimeout: () {});
            lastStreamError = null;
            break;
          } on _DownloadInterrupted {
            rethrow;
          } catch (e) {
            lastStreamError = e;
            try {
              final f = File(filePath);
              if (await f.exists()) await f.delete();
            } catch (_) {}
            if (streamIdx >= streamCandidates.length - 1) {
              rethrow;
            }
          } finally {
            try {
              await sink.close()
                  .timeout(const Duration(seconds: 8), onTimeout: () {});
            } catch (_) {}
          }
        }
        if (lastStreamError != null) {
          throw lastStreamError;
        }

        final pauseRequested = _downloadPauseRequestedTaskIds.contains(taskId);
        final cancelRequested = _downloadCancelRequestedTaskIds.contains(taskId);
        if (cancelRequested || _downloadAbortByTaskId[taskId]?.isCompleted == true) {
          throw _DownloadInterrupted(paused: pauseRequested);
        }
        if (task.progress < 0.985) {
          task.progress = 0.985;
        }
        if (mounted) {
          setState(() => _downloadProgress = task.progress);
        } else {
          _downloadProgress = task.progress;
        }
        task.progress = 1.0;
        final cachedLyrics =
            _cachedLyricsVideoId == video.id.value ? (_cachedLyrics ?? '') : '';
        final completedFilePath = (filePath ?? '').toString();
        if (completedFilePath.isEmpty) {
          throw Exception('Download finalize failed: missing file path');
        }
        final exists = await File(completedFilePath).exists();
        if (!exists) {
          throw Exception('Download finalize failed: file not found');
        }
        final completedSize = await File(completedFilePath).length();
        if (completedSize < 48 * 1024) {
          throw Exception('Download finalize failed: file too small/corrupt');
        }
        if (mounted) {
          setState(() {
            _downloads.removeWhere((d) => d['filePath'] == completedFilePath);
            _downloads.insert(0, {
              'sourceVideoId': video.id.value,
              'title': video.title,
              'author': video.author,
              'durationSecs': '${video.duration?.inSeconds ?? 0}',
              'filePath': completedFilePath,
              'thumbnailUrl': video.thumbnails.mediumResUrl,
              'lyrics': cachedLyrics,
            });
            _downloadTasks.removeWhere((t) => t.videoId == task.videoId);
          });
        } else {
          _downloads.removeWhere((d) => d['filePath'] == completedFilePath);
          _downloads.insert(0, {
            'sourceVideoId': video.id.value,
            'title': video.title,
            'author': video.author,
            'durationSecs': '${video.duration?.inSeconds ?? 0}',
            'filePath': completedFilePath,
            'thumbnailUrl': video.thumbnails.mediumResUrl,
            'lyrics': cachedLyrics,
          });
          _downloadTasks.removeWhere((t) => t.videoId == task.videoId);
        }
        if (_isDownloadPlayback && _currentDownloadIndex >= 0) {
          _ensureDownloadQueueForPlayback(_currentDownloadIndex, reset: false);
        }
        _scheduleSave();
        _scheduleDownloadKeepAliveSync(immediate: true);
        unawaited(_storeLyricsForDownloadedVideo(video));

        if (!task.silent && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
              'Downloaded: ${_cleanTitle(video.title)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            duration: const Duration(seconds: 3),
            backgroundColor: const Color(0xFF1A2A1A),
          ));
        }
      } finally {
        try {
          yt.close();
        } catch (_) {}
      }
    } on _DownloadInterrupted catch (e) {
      if (filePath != null) {
        try {
          final f = File(filePath);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }

      if (e.paused) {
        if (mounted) {
          setState(() {
            task.state = _DownloadTaskState.paused;
            task.progress = 0;
          });
        } else {
          task.state = _DownloadTaskState.paused;
          task.progress = 0;
        }
        _scheduleDownloadKeepAliveSync(immediate: true);
      } else {
        if (mounted) {
          setState(() => _downloadTasks.removeWhere((t) => t.id == task.id));
        } else {
          _downloadTasks.removeWhere((t) => t.id == task.id);
        }
        _scheduleDownloadKeepAliveSync(immediate: true);
      }
    } catch (e) {
      if (filePath != null) {
        try {
          final f = File(filePath);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }

      if (mounted) {
        setState(() {
          task.state = _DownloadTaskState.failed;
          task.error = '$e';
        });
      } else {
        task.state = _DownloadTaskState.failed;
        task.error = '$e';
      }
      _scheduleDownloadKeepAliveSync(immediate: true);
      if (!task.silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            'Download failed: ${_cleanTitle(video.title)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          backgroundColor: const Color(0xFF2A1A1A),
          duration: const Duration(seconds: 3),
        ));
      }
    } finally {
      _downloadAbortByTaskId.remove(taskId);
      final sub = _downloadStreamSubByTaskId.remove(taskId);
      if (sub != null) {
        try {
          await sub.cancel();
        } catch (_) {}
      }
      _downloadPauseRequestedTaskIds.remove(taskId);
      _downloadCancelRequestedTaskIds.remove(taskId);
      if (_downloadKeepAliveTaskId == taskId) {
        _downloadKeepAliveTaskId = null;
        _downloadKeepAliveProgressBucket = -1;
      }
      if (mounted) {
        setState(() {
          _isDownloading = _runningDownloadTaskIds.isNotEmpty;
          if (!_isDownloading) _downloadProgress = 0;
        });
      } else {
        _isDownloading = _runningDownloadTaskIds.isNotEmpty;
        if (!_isDownloading) _downloadProgress = 0;
      }
      _scheduleDownloadKeepAliveSync(immediate: true);
    }
  }
  // DATA PERSISTENCE
  // pubspec.yaml: no new packages needed uses dart:convert + path_provider
  //
  // Data is saved to TWO locations:
  //   1. App documents dir  (always accessible, cleared on uninstall)
  //   2. Download path      (if set to external storage it survives reinstall)
  // On load, app docs are tried first, then the download-path backup.
  // ---

  Map<String, dynamic> _videoToMap(Video v) => {
        'id': v.id.value,
        'title': v.title,
        'author': v.author,
        'durationSecs': v.duration?.inSeconds,
      };

  Video _videoFromMap(Map<String, dynamic> m) {
    final id = (m['id'] as String?) ?? '';
    final secs = m['durationSecs'] as int?;
    return Video(
      VideoId(id),
      (m['title'] as String?) ?? 'Unknown',
      (m['author'] as String?) ?? 'Unknown',
      ChannelId('UC0000000000000000000000'),
      null, // uploadDate
      null, // publishDate
      null, // uploadDateText (3rd nullable date-ish field)
      '', // description
      secs != null ? Duration(seconds: secs) : null,
      ThumbnailSet(id),
      const <String>[],
      const Engagement(0, null, null),
      false,
    );
  }

  /// Debounced save coalesces rapid mutations into one write.
  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 2), _saveData);
  }

  Future<void> _saveData({bool skipCloudBackup = false}) async {
    if (!_dataLoaded) return; // never overwrite good data with empty defaults
    try {
      _capturePlaybackSnapshot();
      final cfOut = <String, Map<String, double>>{};
      final cfKeys = _cfCounts.keys.toList();
      for (final k in cfKeys.take(900)) {
        final m = _cfCounts[k] ?? {};
        final sorted = m.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        cfOut[k] = Map.fromEntries(sorted.take(80));
      }
      final eqBandGains = <String, double>{};
      final params = _eqParams;
      if (params != null) {
        for (final band in params.bands) {
          eqBandGains['${band.centerFrequency.toInt()}'] = band.gain;
        }
      }
      final data = <String, dynamic>{
        'version': 4,
        'savedAtMs': DateTime.now().millisecondsSinceEpoch,
        'likedIds': _likedVideoIds.toList(),
        'liked': _likedPlaylist.videos.map(_videoToMap).toList(),
        'playlists': _playlists
            .map((p) => {
                  'id': p.id,
                  'name': p.name,
                  'videos': p.videos.map(_videoToMap).toList(),
                  'createdAt': p.createdAt.millisecondsSinceEpoch,
                })
            .toList(),
        'history': _history.take(50).map(_videoToMap).toList(),
        'speedDialPins': _speedDialPins.map(_videoToMap).toList(),
        'downloads': _downloads,
        'listeningLogs': _listeningLogs.take(6000).toList(),
        'searchHistory': _searchHistory.take(50).toList(),
        'settings': {
          'isDark': _isDarkNotifier.value,
          'audioQuality': _audioQuality,
          'crossfadeOn': _crossfadeOn,
          'crossfadeSecs': _crossfadeSecs,
          'smartTransitionsOn': _smartTransitionsOn,
          'loudnessNormalizationOn': _loudnessNormalizationOn,
          'debugModeEnabled': _debugModeEnabled,
          'loudnessNormalizationStrength': _loudnessNormalizationStrength,
          'playbackSpeed': _playbackSpeed,
          'bassBoostEnabled': _bassBoostEnabled,
          'bassBoostGain': _bassBoostGain,
          'eqEnabled': _eqEnabled,
          'eqBandGains': eqBandGains,
          'downloadPath': _downloadPath,
          'ytMusicPhoneOnlyMode': _ytMusicPhoneOnlyMode,
          'ytMusicBackendUrlOverride': _ytMusicBackendUrlOverride,
          'ytMusicBackendApiKeyOverride': _ytMusicBackendApiKeyOverride,
        },
        'playerState': {
          'nowPlaying': _nowPlaying != null ? _videoToMap(_nowPlaying!) : null,
          'queue': _playQueue.take(200).map(_videoToMap).toList(),
          'currentIndex': _currentIndex,
          'positionMs': _lastKnownPlayerPosition.inMilliseconds,
          'wasPlaying': _lastKnownPlayerPlaying,
        },
        'ytAccount': {
          'email': _ytAccountEmail,
          'name': _ytAccountName,
          'photo': _ytAccountPhoto,
          'token': _ytAccessToken,
          'musicCookie': _ytMusicCookie,
          'musicAuthUser': _ytMusicAuthUser,
          'musicVisitorData': _ytMusicVisitorData,
          'liked': _ytLikedVideos.map(_videoToMap).toList(),
        },
        'tasteSignals': {
          'artist': _artistActionBoost,
          'genre': _genreActionBoost,
          'language': _langActionBoost,
          'query': _queryActionBoost,
          'video': _videoActionBoost,
          'quickExposure': _quickPickExposurePenalty,
          'blockedVideos': _blockedVideoIds.toList(),
          'blockedArtists': _blockedArtistKeys.toList(),
        },
        'experiments': {
          'enabled': _experimentsEnabled,
          'qpVariant': _qpVariant,
          'deviceId': _deviceId,
        },
        'banditQP': _banditQuickArms,
        'quickMetrics': _quickMetrics,
        'cfCounts': cfOut,
        'homeCache': {
          'label': _homeCacheQuickLabel,
          'ts': _homeCacheAt?.millisecondsSinceEpoch,
          'quick': _homeCacheQuick.take(20).map(_videoToMap).toList(),
        },
      };
      final json = jsonEncode(data);
      _lastPersistedDataSavedAtMs =
          (data['savedAtMs'] as int?) ?? _lastPersistedDataSavedAtMs;

      // Primary: app documents
      try {
        final dir = await getApplicationDocumentsDirectory();
        await File('${dir.path}/beast_data.json').writeAsString(json);
      } catch (e) {
        debugPrint('[Save] primary: $e');
      }

      // Backup: download path (may be external storage survives reinstall)
      if (_downloadPath.isNotEmpty) {
        try {
          await File('$_downloadPath/beast_data.json').writeAsString(json);
        } catch (e) {
          debugPrint('[Save] backup: $e');
        }
      }

      if (!skipCloudBackup) {
        _scheduleCloudBackup(json);
      }
    } catch (e) {
      debugPrint('[Save] encode: $e');
    }
  }

  Future<void> _loadData() async {
    String? json;

    // Try primary location first
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/beast_data.json');
      if (await f.exists()) json = await f.readAsString();
    } catch (e) {
      debugPrint('[Load] primary: $e');
    }

    // Try backup (external / download path) if primary failed
    if (json == null && _downloadPath.isNotEmpty) {
      try {
        final f = File('$_downloadPath/beast_data.json');
        if (await f.exists()) json = await f.readAsString();
      } catch (e) {
        debugPrint('[Load] backup: $e');
      }
    }

    if (json == null || json.isEmpty) {
      _dataLoaded = true;
      return;
    }

    try {
      final data = jsonDecode(json) as Map<String, dynamic>;
      _lastPersistedDataSavedAtMs =
          (data['savedAtMs'] as num?)?.toInt() ?? _lastPersistedDataSavedAtMs;

      final likedIds = (data['likedIds'] as List?)?.cast<String>() ?? [];
      final likedVids = ((data['liked'] as List?) ?? [])
          .map((m) => _videoFromMap(m as Map<String, dynamic>))
          .toList();

      final loadedPlaylists = <BeastPlaylist>[];
      for (final p in (data['playlists'] as List?) ?? []) {
        final pm = p as Map<String, dynamic>;
        loadedPlaylists.add(BeastPlaylist(
          id: pm['id'] as String? ?? 'pl_0',
          name: pm['name'] as String? ?? 'Playlist',
          videos: ((pm['videos'] as List?) ?? [])
              .map((v) => _videoFromMap(v as Map<String, dynamic>))
              .toList(),
          createdAt:
              DateTime.fromMillisecondsSinceEpoch(pm['createdAt'] as int? ?? 0),
        ));
      }

      final histVids = ((data['history'] as List?) ?? [])
          .map((m) => _videoFromMap(m as Map<String, dynamic>))
          .toList();
      final speedDialPins = ((data['speedDialPins'] as List?) ?? [])
          .map((m) => _videoFromMap(m as Map<String, dynamic>))
          .toList();

      final savedDownloads = ((data['downloads'] as List?) ?? [])
          .map((d) => (d as Map).cast<String, String>())
          .toList();
      final savedListeningLogs = ((data['listeningLogs'] as List?) ?? [])
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      final savedSearchHistory =
          ((data['searchHistory'] as List?) ?? []).whereType<String>().toList();
      for (final d in savedDownloads) {
        final sourceId = (d['sourceVideoId'] ?? '').trim();
        if (sourceId.isEmpty) {
          final derived = _resolveDownloadVideoId(d);
          if (derived != '00000000000') {
            d['sourceVideoId'] = derived;
          }
        }
      }

      final s = (data['settings'] as Map<String, dynamic>?) ?? {};
      final ytAcc = (data['ytAccount'] as Map<String, dynamic>?) ?? {};
      final tasteSignals =
          (data['tasteSignals'] as Map<String, dynamic>?) ?? {};
      _lastPersistedDataSavedAtMs =
          (data['savedAtMs'] as num?)?.toInt() ?? _lastPersistedDataSavedAtMs;
      final ex = (data['experiments'] as Map<String, dynamic>?) ?? {};
      final bandit = (data['banditQP'] as Map<String, dynamic>?) ?? {};
      final qm = (data['quickMetrics'] as Map<String, dynamic>?) ?? {};
      final cf = (data['cfCounts'] as Map<String, dynamic>?) ?? {};
      final homeCache = (data['homeCache'] as Map<String, dynamic>?) ?? {};
      final playerState = _jsonMap(data['playerState']);

      if (mounted) {
        setState(() {
          _likedVideoIds.addAll(likedIds);
          _likedPlaylist.videos.addAll(
            _filterMusicResults(likedVids, limit: 5000),
          );
          _likedVideoIds.addAll(_likedPlaylist.videos.map((v) => v.id.value));
          _playlists.addAll(loadedPlaylists);
          _history.addAll(_filterMusicResults(histVids, limit: 50));
          final restoredSpeedDial = <Video>[];
          final speedDialSeen = <String>{};
          for (final v in _filterMusicResults(
            speedDialPins,
            limit: _maxSpeedDialPins * 2,
            strictSingles: true,
          )) {
            if (!speedDialSeen.add(v.id.value)) continue;
            restoredSpeedDial.add(v);
            if (restoredSpeedDial.length >= _maxSpeedDialPins) break;
          }
          _speedDialPins
            ..clear()
            ..addAll(restoredSpeedDial);
          _downloads.addAll(savedDownloads);
          _listeningLogs.addAll(savedListeningLogs.take(6000));
          _searchHistory
            ..clear()
            ..addAll(savedSearchHistory.take(50));

          _isDarkNotifier.value = s['isDark'] as bool? ?? true;
          _audioQuality = s['audioQuality'] as int? ?? 2;
          _crossfadeOn = s['crossfadeOn'] as bool? ?? false;
          _crossfadeSecs = (s['crossfadeSecs'] as num?)?.toDouble() ?? 3.0;
          _smartTransitionsOn = s['smartTransitionsOn'] as bool? ?? true;
          _loudnessNormalizationOn =
              s['loudnessNormalizationOn'] as bool? ?? true;
          _loudnessNormalizationStrength =
              ((s['loudnessNormalizationStrength'] as num?)?.toDouble() ?? 0.7)
                  .clamp(0.2, 1.0);
          _playbackSpeed = (s['playbackSpeed'] as num?)?.toDouble() ?? 1.0;
          _bassBoostEnabled = s['bassBoostEnabled'] as bool? ?? false;
          _bassBoostGain = _clampedBassBoostGain(
              (s['bassBoostGain'] as num?)?.toDouble() ?? 0.39);
          _eqEnabled = s['eqEnabled'] as bool? ?? false;
          _savedEqBandGains
            ..clear()
            ..addAll(_toDoubleMap(s['eqBandGains'], maxEntries: 24).map(
              (k, v) => MapEntry(int.tryParse(k) ?? -1, v),
            ))
            ..remove(-1);
          final savedPath = s['downloadPath'] as String?;
          if (savedPath != null && savedPath.isNotEmpty) {
            _downloadPath = savedPath;
          }
          _ytMusicPhoneOnlyMode = s['ytMusicPhoneOnlyMode'] as bool? ?? true;
          _ytMusicBackendUrlOverride =
              (s['ytMusicBackendUrlOverride'] as String? ?? '').trim();
          _ytMusicBackendApiKeyOverride =
              (s['ytMusicBackendApiKeyOverride'] as String? ?? '').trim();

          // Restore YT account
          _ytAccountEmail = ytAcc['email'] as String?;
          _ytAccountName = ytAcc['name'] as String?;
          _ytAccountPhoto = ytAcc['photo'] as String?;
          _ytAccessToken = ytAcc['token'] as String?;
          _ytMusicCookie = ytAcc['musicCookie'] as String?;
          _ytMusicAuthUser = _normalizeYtMusicAuthUser(
              ytAcc['musicAuthUser'] as String? ?? '0');
          _ytMusicVisitorData =
              (ytAcc['musicVisitorData'] as String?)?.trim().isNotEmpty == true
                  ? (ytAcc['musicVisitorData'] as String).trim()
                  : _ytMusicDefaultVisitorData;
          final restoredLiked = ((ytAcc['liked'] as List?) ?? [])
              .map((m) => _videoFromMap(m as Map<String, dynamic>))
              .toList();
          _ytLikedVideos = _filterMusicResults(
            restoredLiked,
            limit: 1000,
            strictSingles: true,
          );

          _artistActionBoost
            ..clear()
            ..addAll(
              _toDoubleMap(tasteSignals['artist'], maxEntries: 260),
            );
          _genreActionBoost
            ..clear()
            ..addAll(
              _toDoubleMap(tasteSignals['genre'], maxEntries: 260),
            );
          _langActionBoost
            ..clear()
            ..addAll(
              _toDoubleMap(tasteSignals['language'], maxEntries: 32),
            );
          _queryActionBoost
            ..clear()
            ..addAll(
              _toDoubleMap(tasteSignals['query'], maxEntries: 320),
            );
          _videoActionBoost
            ..clear()
            ..addAll(
              _toDoubleMap(tasteSignals['video'], maxEntries: 500),
            );
          _quickPickExposurePenalty
            ..clear()
            ..addAll(
              _toDoubleMap(tasteSignals['quickExposure'], maxEntries: 900),
            );
          _blockedVideoIds
            ..clear()
            ..addAll(_stringSetFromDynamic(tasteSignals['blockedVideos']));
          _blockedArtistKeys
            ..clear()
            ..addAll(_stringSetFromDynamic(tasteSignals['blockedArtists']));
          _experimentsEnabled = ex['enabled'] as bool? ?? true;
          _qpVariant = ex['qpVariant'] as String? ?? _qpVariant;
          final did = ex['deviceId'] as String?;
          if (did != null && did.trim().isNotEmpty) _deviceId = did.trim();
          _banditQuickArms
            ..clear()
            ..addAll(bandit.map((k, v) => MapEntry(
                k,
                (v as Map)
                    .map((kk, vv) => MapEntry(kk.toString(), vv as Object)))));
          for (final e in qm.entries) {
            final key = e.key.toString();
            final val = (e.value as num?) ?? 0;
            _quickMetrics[key] = val;
          }
          _cfCounts
            ..clear()
            ..addAll(cf.map((k, v) => MapEntry(
                k.toString(),
                (v as Map).map((kk, vv) =>
                    MapEntry(kk.toString(), (vv as num).toDouble())))));
          final hcLabel = (homeCache['label'] as String?) ?? '';
          final hcTs = (homeCache['ts'] as num?)?.toInt();
          final hcQuick = ((homeCache['quick'] as List?) ?? [])
              .map((m) => _videoFromMap(m as Map<String, dynamic>))
              .toList();
          _homeCacheQuickLabel = hcLabel;
          _homeCacheQuick
            ..clear()
            ..addAll(
                _filterMusicResults(hcQuick, limit: 20, strictSingles: true));
          _homeCacheAt = hcTs != null && hcTs > 0
              ? DateTime.fromMillisecondsSinceEpoch(hcTs)
              : null;

          if (playerState != null) {
            _pendingPlaybackRestore = playerState;
          }
        });
        unawaited(_syncCurrentTrackVolume());
      }
    } catch (e) {
      debugPrint('[Load] parse error: $e');
    } finally {
      _dataLoaded = true;
    }
  }

  void _scheduleCloudBackup(String json) {
    if (_cloudWritesPausedForRestore) return;
    final token = _ytAccessToken;
    if (token == null || token.isEmpty) return;
    _pendingCloudBackupJson = json;
    _cloudSaveDebounce?.cancel();
    _cloudSaveDebounce = Timer(const Duration(seconds: 7), () {
      final payload = _pendingCloudBackupJson;
      _pendingCloudBackupJson = null;
      if (payload == null || payload.isEmpty) return;
      unawaited(_syncCloudBackupNow(payload));
    });
  }

  bool get _hasRestorableLocalData =>
      _likedPlaylist.videos.isNotEmpty ||
      _playlists.isNotEmpty ||
      _history.isNotEmpty ||
      _downloads.isNotEmpty ||
      _listeningLogs.isNotEmpty;

  String _driveErrorMessage(String body, int statusCode,
      {String fallback = 'Drive request failed'}) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final err = decoded['error'];
        if (err is Map) {
          final message = err['message'] as String?;
          if (message != null && message.trim().isNotEmpty) {
            return message.trim();
          }
        }
      }
    } catch (_) {}
    return '$fallback ($statusCode)';
  }

  bool _isDriveScopeError(String message) {
    final m = message.toLowerCase();
    return m.contains('insufficient') &&
        (m.contains('scope') || m.contains('permission'));
  }

  Future<String?> _findCloudBackupFileId(
      HttpClient client, String token) async {
    final uri = Uri.https(
      'www.googleapis.com',
      '/drive/v3/files',
      {
        'spaces': 'appDataFolder',
        'q': "name='$_cloudBackupFileName' and trashed=false",
        'fields': 'files(id,modifiedTime)',
        'orderBy': 'modifiedTime desc',
        'pageSize': '1',
      },
    );
    final req = await client.getUrl(uri);
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final resp = await req.close().timeout(const Duration(seconds: 12));
    final body = await resp.transform(const Utf8Decoder()).join();
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final files = (decoded['files'] as List?) ?? const [];
      if (files.isEmpty) return null;
      return (files.first as Map)['id'] as String?;
    }
    throw Exception(
      _driveErrorMessage(body, resp.statusCode, fallback: 'Drive list failed'),
    );
  }

  Future<String?> _createCloudBackupFileId(
      HttpClient client, String token) async {
    final req = await client.postUrl(
      Uri.https('www.googleapis.com', '/drive/v3/files', {'fields': 'id'}),
    );
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    req.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    req.write(jsonEncode({
      'name': _cloudBackupFileName,
      'parents': ['appDataFolder'],
    }));
    final resp = await req.close().timeout(const Duration(seconds: 12));
    final body = await resp.transform(const Utf8Decoder()).join();
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      return decoded['id'] as String?;
    }
    throw Exception(
      _driveErrorMessage(body, resp.statusCode,
          fallback: 'Drive create failed'),
    );
  }

  Future<void> _uploadCloudBackupFileContent(
      HttpClient client, String token, String fileId, String json) async {
    final req = await client.patchUrl(
      Uri.https(
        'www.googleapis.com',
        '/upload/drive/v3/files/$fileId',
        {'uploadType': 'media'},
      ),
    );
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    req.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    req.write(json);
    final resp = await req.close().timeout(const Duration(seconds: 18));
    final body = await resp.transform(const Utf8Decoder()).join();
    if (resp.statusCode >= 200 && resp.statusCode < 300) return;
    throw Exception(
      _driveErrorMessage(body, resp.statusCode,
          fallback: 'Drive upload failed'),
    );
  }

  Future<void> _syncCloudBackupNow(String json, {bool silent = true}) async {
    var token = (_ytAccessToken ?? '').trim();
    if (token.isEmpty) return;
    try {
      final fresh = await _getFreshGoogleAccessToken(interactive: false);
      if (fresh != null && fresh.isNotEmpty) {
        token = fresh;
        _ytAccessToken = fresh;
      }
    } catch (e) {
      debugPrint('[Cloud Sync token refresh] $e');
    }
    if (token.isEmpty) return;
    if (_cloudSyncing) {
      _pendingCloudBackupJson = json;
      return;
    }

    if (mounted) {
      setState(() => _cloudSyncing = true);
    } else {
      _cloudSyncing = true;
    }

    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
      var fileId = _cloudBackupFileId;
      fileId ??= await _findCloudBackupFileId(client, token);
      fileId ??= await _createCloudBackupFileId(client, token);
      if (fileId == null || fileId.isEmpty) {
        throw Exception('Unable to create cloud backup file');
      }
      _cloudBackupFileId = fileId;
      await _uploadCloudBackupFileContent(client, token, fileId, json);
      _cloudLastSyncAt = DateTime.now();
      _cloudSyncError = null;
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cloud backup synced')),
        );
      }
    } catch (e) {
      _cloudSyncError = e.toString();
      debugPrint('[Cloud Sync] $e');
      if (!silent && mounted) {
        final msg = _isDriveScopeError(_cloudSyncError!)
            ? 'Cloud sync needs Drive scope. Reconnect and include drive.appdata.'
            : _cloudSyncError!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              msg.length > 95 ? '${msg.substring(0, 95)}...' : msg,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            backgroundColor: Colors.redAccent.shade700,
          ),
        );
      }
    } finally {
      client?.close(force: true);
      if (mounted) {
        setState(() => _cloudSyncing = false);
      } else {
        _cloudSyncing = false;
      }
      final queued = _pendingCloudBackupJson;
      if (queued != null && queued != json) {
        _pendingCloudBackupJson = null;
        unawaited(_syncCloudBackupNow(queued));
      }
    }
  }

  Future<String?> _downloadCloudBackupJson(String token) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      var fileId = _cloudBackupFileId;
      fileId ??= await _findCloudBackupFileId(client, token);
      if (fileId == null || fileId.isEmpty) return null;
      _cloudBackupFileId = fileId;

      Future<(int, String)> fetchBody(String id) async {
        final req = await client.getUrl(
          Uri.https(
              'www.googleapis.com', '/drive/v3/files/$id', {'alt': 'media'}),
        );
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        final resp = await req.close().timeout(const Duration(seconds: 15));
        final body = await resp.transform(const Utf8Decoder()).join();
        return (resp.statusCode, body);
      }

      var result = await fetchBody(fileId);
      if (result.$1 == 404) {
        _cloudBackupFileId = null;
        final refreshedId = await _findCloudBackupFileId(client, token);
        if (refreshedId == null || refreshedId.isEmpty) return null;
        _cloudBackupFileId = refreshedId;
        result = await fetchBody(refreshedId);
      }
      if (result.$1 >= 200 && result.$1 < 300) return result.$2;

      throw Exception(
        _driveErrorMessage(result.$2, result.$1,
            fallback: 'Cloud restore failed'),
      );
    } finally {
      client.close(force: true);
    }
  }

  bool _applyPersistedDataMap(
    Map<String, dynamic> data, {
    bool replaceExisting = false,
    bool preserveCurrentYtAccount = false,
    bool preserveCurrentYtLikes = false,
  }) {
    try {
      final likedIds = (data['likedIds'] as List?)?.cast<String>() ?? [];
      final likedVids = ((data['liked'] as List?) ?? [])
          .map((m) => _videoFromMap(m as Map<String, dynamic>))
          .toList();

      final loadedPlaylists = <BeastPlaylist>[];
      for (final p in (data['playlists'] as List?) ?? []) {
        final pm = p as Map<String, dynamic>;
        loadedPlaylists.add(BeastPlaylist(
          id: pm['id'] as String? ?? 'pl_0',
          name: pm['name'] as String? ?? 'Playlist',
          videos: ((pm['videos'] as List?) ?? [])
              .map((v) => _videoFromMap(v as Map<String, dynamic>))
              .toList(),
          createdAt:
              DateTime.fromMillisecondsSinceEpoch(pm['createdAt'] as int? ?? 0),
        ));
      }

      final histVids = ((data['history'] as List?) ?? [])
          .map((m) => _videoFromMap(m as Map<String, dynamic>))
          .toList();

      final savedDownloads = ((data['downloads'] as List?) ?? [])
          .map((d) => (d as Map).cast<String, String>())
          .toList();
      final savedListeningLogs = ((data['listeningLogs'] as List?) ?? [])
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      final savedSearchHistory =
          ((data['searchHistory'] as List?) ?? []).whereType<String>().toList();
      for (final d in savedDownloads) {
        final sourceId = (d['sourceVideoId'] ?? '').trim();
        if (sourceId.isEmpty) {
          final derived = _resolveDownloadVideoId(d);
          if (derived != '00000000000') {
            d['sourceVideoId'] = derived;
          }
        }
      }

      final s = (data['settings'] as Map<String, dynamic>?) ?? {};
      final ytAcc = (data['ytAccount'] as Map<String, dynamic>?) ?? {};
      final tasteSignals =
          (data['tasteSignals'] as Map<String, dynamic>?) ?? {};

      final keepYtEmail = _ytAccountEmail;
      final keepYtName = _ytAccountName;
      final keepYtPhoto = _ytAccountPhoto;
      final keepYtToken = _ytAccessToken;
      final keepYtMusicCookie = _ytMusicCookie;
      final keepYtMusicAuthUser = _ytMusicAuthUser;
      final keepYtMusicVisitorData = _ytMusicVisitorData;
      final keepYtLiked = List<Video>.from(_ytLikedVideos);

      if (!mounted) return false;
      setState(() {
        if (replaceExisting) {
          _likedVideoIds.clear();
          _likedPlaylist.videos.clear();
          _playlists.clear();
          _history.clear();
          _downloads.clear();
          _downloadQueue.clear();
          _unshuffledDownloadQueue.clear();
          _currentDownloadQueuePos = -1;
          _currentDownloadIndex = -1;
          _downloadShuffleOn = false;
          _listeningLogs.clear();
          _likedAutoDownloadQueue.clear();
          _blockedVideoIds.clear();
          _blockedArtistKeys.clear();
          _quickPickExposurePenalty.clear();
        }

        _likedVideoIds.addAll(likedIds);
        _likedPlaylist.videos.addAll(
          _filterMusicResults(likedVids, limit: 5000),
        );
        _likedVideoIds.addAll(_likedPlaylist.videos.map((v) => v.id.value));
        _playlists.addAll(loadedPlaylists);
        _history.addAll(_filterMusicResults(histVids, limit: 50));
        _downloads.addAll(savedDownloads);
        _listeningLogs.addAll(savedListeningLogs.take(6000));
        _searchHistory
          ..clear()
          ..addAll(savedSearchHistory.take(50));

        _isDarkNotifier.value = s['isDark'] as bool? ?? true;
        _audioQuality = s['audioQuality'] as int? ?? 2;
        _crossfadeOn = s['crossfadeOn'] as bool? ?? false;
        _crossfadeSecs = (s['crossfadeSecs'] as num?)?.toDouble() ?? 3.0;
        _smartTransitionsOn = s['smartTransitionsOn'] as bool? ?? true;
        _loudnessNormalizationOn =
            s['loudnessNormalizationOn'] as bool? ?? true;
        _loudnessNormalizationStrength =
            ((s['loudnessNormalizationStrength'] as num?)?.toDouble() ?? 0.7)
                .clamp(0.2, 1.0);
        _playbackSpeed = (s['playbackSpeed'] as num?)?.toDouble() ?? 1.0;
        _bassBoostEnabled = s['bassBoostEnabled'] as bool? ?? false;
        _bassBoostGain = _clampedBassBoostGain(
            (s['bassBoostGain'] as num?)?.toDouble() ?? 0.39);
        _eqEnabled = s['eqEnabled'] as bool? ?? false;
        final savedPath = s['downloadPath'] as String?;
        if (savedPath != null && savedPath.isNotEmpty) {
          _downloadPath = savedPath;
        }

        _ytAccountEmail = ytAcc['email'] as String?;
        _ytAccountName = ytAcc['name'] as String?;
        _ytAccountPhoto = ytAcc['photo'] as String?;
        _ytAccessToken = ytAcc['token'] as String?;
        _ytMusicCookie = ytAcc['musicCookie'] as String?;
        _ytMusicAuthUser =
            _normalizeYtMusicAuthUser(ytAcc['musicAuthUser'] as String? ?? '0');
        _ytMusicVisitorData =
            (ytAcc['musicVisitorData'] as String?)?.trim().isNotEmpty == true
                ? (ytAcc['musicVisitorData'] as String).trim()
                : _ytMusicDefaultVisitorData;
        final restoredLiked = ((ytAcc['liked'] as List?) ?? [])
            .map((m) => _videoFromMap(m as Map<String, dynamic>))
            .toList();
        _ytLikedVideos = _filterMusicResults(
          restoredLiked,
          limit: 1000,
          strictSingles: true,
        );

        if (preserveCurrentYtAccount) {
          if (keepYtEmail != null && keepYtEmail.isNotEmpty) {
            _ytAccountEmail = keepYtEmail;
          }
          if (keepYtName != null && keepYtName.isNotEmpty) {
            _ytAccountName = keepYtName;
          }
          if (keepYtPhoto != null && keepYtPhoto.isNotEmpty) {
            _ytAccountPhoto = keepYtPhoto;
          }
          if (keepYtToken != null && keepYtToken.isNotEmpty) {
            _ytAccessToken = keepYtToken;
          }
          if (keepYtMusicCookie != null && keepYtMusicCookie.isNotEmpty) {
            _ytMusicCookie = keepYtMusicCookie;
          }
          _ytMusicAuthUser = _normalizeYtMusicAuthUser(keepYtMusicAuthUser);
          if (keepYtMusicVisitorData.trim().isNotEmpty) {
            _ytMusicVisitorData = keepYtMusicVisitorData;
          }
        }
        if (preserveCurrentYtLikes && keepYtLiked.isNotEmpty) {
          _ytLikedVideos = _filterMusicResults(
            keepYtLiked,
            limit: 1000,
            strictSingles: true,
          );
        }

        _artistActionBoost
          ..clear()
          ..addAll(
            _toDoubleMap(tasteSignals['artist'], maxEntries: 260),
          );
        _genreActionBoost
          ..clear()
          ..addAll(
            _toDoubleMap(tasteSignals['genre'], maxEntries: 260),
          );
        _langActionBoost
          ..clear()
          ..addAll(
            _toDoubleMap(tasteSignals['language'], maxEntries: 32),
          );
        _queryActionBoost
          ..clear()
          ..addAll(
            _toDoubleMap(tasteSignals['query'], maxEntries: 320),
          );
        _videoActionBoost
          ..clear()
          ..addAll(
            _toDoubleMap(tasteSignals['video'], maxEntries: 500),
          );
        _quickPickExposurePenalty
          ..clear()
          ..addAll(
            _toDoubleMap(tasteSignals['quickExposure'], maxEntries: 900),
          );
        _blockedVideoIds
          ..clear()
          ..addAll(_stringSetFromDynamic(tasteSignals['blockedVideos']));
        _blockedArtistKeys
          ..clear()
          ..addAll(_stringSetFromDynamic(tasteSignals['blockedArtists']));
      });
      unawaited(_syncCurrentTrackVolume());
      return true;
    } catch (e) {
      debugPrint('[Apply data] $e');
      return false;
    }
  }

  Future<bool> _restoreFromCloudBackup({
    required String token,
    bool replaceExisting = true,
    bool preserveCurrentYtAccount = false,
    bool preserveCurrentYtLikes = false,
    int? onlyIfCloudNewerThanMs,
  }) async {
    try {
      final backupJson = await _downloadCloudBackupJson(token);
      if (backupJson == null || backupJson.isEmpty) return false;
      final decoded = jsonDecode(backupJson);
      if (decoded is! Map) return false;
      final map = Map<String, dynamic>.from(decoded);
      if (onlyIfCloudNewerThanMs != null && onlyIfCloudNewerThanMs > 0) {
        final cloudSavedAtMs = (map['savedAtMs'] as num?)?.toInt() ?? 0;
        if (cloudSavedAtMs <= onlyIfCloudNewerThanMs) {
          _cloudSyncError = null;
          _cloudLastSyncAt = DateTime.now();
          return false;
        }
      }
      final applied = _applyPersistedDataMap(
        map,
        replaceExisting: replaceExisting,
        preserveCurrentYtAccount: preserveCurrentYtAccount,
        preserveCurrentYtLikes: preserveCurrentYtLikes,
      );
      if (applied) {
        _cloudSyncError = null;
        _cloudLastSyncAt = DateTime.now();
      }
      return applied;
    } catch (e) {
      _cloudSyncError = e.toString();
      debugPrint('[Cloud Restore] $e');
      return false;
    }
  }

  String _cloudSyncStatusText() {
    if (_ytAccessToken == null || _ytAccessToken!.isEmpty) {
      return 'Connect account to enable cloud backup';
    }
    if (_cloudSyncing) return 'Cloud backup syncing...';
    if (_cloudLastSyncAt != null) {
      final mins = DateTime.now().difference(_cloudLastSyncAt!).inMinutes;
      if (mins < 1) return 'Cloud backup synced just now';
      if (mins < 60) return 'Cloud backup synced ${mins}m ago';
      final hours = mins ~/ 60;
      if (hours < 24) return 'Cloud backup synced ${hours}h ago';
      final days = hours ~/ 24;
      return 'Cloud backup synced ${days}d ago';
    }
    if (_cloudSyncError != null && _cloudSyncError!.isNotEmpty) {
      return _isDriveScopeError(_cloudSyncError!)
          ? 'Reconnect with drive.appdata scope for cloud backup'
          : 'Cloud backup pending';
    }
    return 'Cloud backup ready';
  }

  // Title cleaner
  /// Strips YouTube noise so only the clean song name shows.
  /// e.g. "KR$NA - I Guess | Official Music Video" "I Guess"
  static String _cleanTitle(String raw, {String? author}) {
    var t = raw;

    // 1) Strip "Artist - Title" prefix (keep only the part after " - ")
    // but only when the part before " - " looks like an artist ( 40 chars, no comma)
    final dashIdx = t.indexOf(' - ');
    if (dashIdx > 0 && dashIdx <= 40) {
      final before = t.substring(0, dashIdx);
      if (!before.contains(',')) t = t.substring(dashIdx + 3);
    }

    // 2) Strip everything from a pipe onwards (| Official Video, | Prod. by )
    final pipeIdx = t.indexOf(' | ');
    if (pipeIdx > 0) t = t.substring(0, pipeIdx);

    // 3) Strip common parenthetical / bracketed suffixes (case-insensitive)
    t = t.replaceAll(
        RegExp(
            r'\s*[\(\[]\s*(?:official|lyric[s]?|audio|video|hd|4k|mv|music\s*video'
            r'|full\s*song|full\s*video|visualizer|remake|cover|karaoke'
            r'|prod\.?[^)\]]*|ft\.?[^)\]]*|feat\.?[^)\]]*'
            r'|explicit|clean|radio\s*edit|extended|remix)[^\)\]]*[\)\]]\s*',
            caseSensitive: false),
        '');

    // 4) Strip trailing "ft." / "feat." references
    t = t.replaceAll(
        RegExp(r'\s+(?:ft|feat)\.?\s+.*$', caseSensitive: false), '');

    t = t.replaceAll(
        RegExp(
            r'\s*[-|:]\s*(?:official\s*(?:music\s*)?(?:audio|video)|audio|video'
            r'|full\s*(?:audio|track|song|video)|lyric(?:s)?(?:\s*video)?'
            r'|visualizer|hq|hd|4k)\s*$',
            caseSensitive: false),
        '');

    t = t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    t = t.replaceAll(RegExp(r'[\s\-|]+$'), '').trim();

    if (author != null && author.trim().isNotEmpty && t.isNotEmpty) {
      String norm(String s) =>
          s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
      final normalizedTitle = norm(t);
      final cleanArtist = _cleanAuthor(author);
      final normalizedArtist = norm(cleanArtist);
      if (normalizedArtist.isNotEmpty && normalizedTitle == normalizedArtist) {
        final escapedArtist = RegExp.escape(cleanArtist);
        var fallback = raw
            .replaceAll(RegExp(escapedArtist, caseSensitive: false), '')
            .replaceAll(RegExp(r'[-|:]+'), ' ')
            .replaceAll(RegExp(r'\s{2,}'), ' ')
            .trim();
        fallback = fallback.replaceAll(RegExp(r'[\s\-|]+$'), '').trim();
        if (fallback.isNotEmpty && norm(fallback) != normalizedArtist) {
          t = fallback;
        } else {
          t = 'Unknown Track';
        }
      }
    }

    return t.isEmpty ? raw : t;
  }

  /// Strips " - Topic" suffix from auto-generated YouTube channel names.
  static String _cleanAuthor(String raw) => raw
      .replaceAll(RegExp(r'\s*-\s*Topic\s*$', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s*VEVO\s*$', caseSensitive: false), '')
      .trim();

  String _displayArtistNames(Video v) {
    final base = _cleanAuthor(v.author);
    final names = <String>[];
    final seen = <String>{};
    String norm(String s) =>
        _cleanAuthor(s).replaceAll(RegExp(r'\s+'), ' ').trim();
    void addName(String s) {
      final n = norm(s);
      if (n.isEmpty) return;
      final k = _primaryArtistKey(n);
      if (k.isEmpty) return;
      if (seen.add(k)) names.add(n);
    }

    addName(base);
    final t = _cleanTitle(v.title, author: v.author);
    if (RegExp(r'\s+[xX]\s+').hasMatch(t)) {
      final parts = t.split(RegExp(r'\s+[xX]\s+'));
      if (parts.length >= 2) {
        addName(parts.first);
        addName(parts.last);
      }
    }
    final m =
        RegExp(r'\b(feat\.?|featuring|ft\.)\s+(.+)$', caseSensitive: false)
            .firstMatch(t);
    if (m != null) {
      final tail = m.group(2) ?? '';
      for (final p in tail.split(RegExp(r'\s*(,|&|x|X|\/)\s*'))) {
        addName(p);
      }
    }
    if (names.isEmpty) return base;
    if (names.length == 1) return names.first;
    return '${names[0]} & ${names[1]}';
  }

  bool _isOAuthClientConfigured() => _oauthClientId.trim().isNotEmpty;

  void _attachOAuthClient(oauth2.Client client) {
    _ytClient?.close();
    _ytClient = client;
    _ytAccessToken = client.credentials.accessToken.trim();
    _ytRefreshToken = client.credentials.refreshToken;
  }

  Future<void> _persistOAuthCredentials(oauth2.Credentials credentials) async {
    final token = credentials.accessToken.trim();
    _ytAccessToken = token.isEmpty ? null : token;
    _ytRefreshToken = credentials.refreshToken;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ytOauthCredentialsPrefKey, credentials.toJson());
  }

  Future<void> _clearOAuthCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_ytOauthCredentialsPrefKey);
  }

  oauth2.AuthorizationCodeGrant _buildOAuthGrant() {
    return oauth2.AuthorizationCodeGrant(
      _oauthClientId.trim(),
      Uri.parse(_oauthAuthorizationEndpoint),
      Uri.parse(_oauthTokenEndpoint),
      secret: null,
      onCredentialsRefreshed: (credentials) {
        _ytRefreshToken = credentials.refreshToken;
        _ytAccessToken = credentials.accessToken.trim();
        unawaited(_persistOAuthCredentials(credentials));
      },
    );
  }

  Future<oauth2.Client?> _restoreOAuthClientFromPrefs() async {
    if (_ytClient != null) return _ytClient;
    final prefs = await SharedPreferences.getInstance();
    final raw = (prefs.getString(_ytOauthCredentialsPrefKey) ?? '').trim();
    if (raw.isEmpty) return null;
    try {
      final credentials = oauth2.Credentials.fromJson(raw);
      final client = oauth2.Client(
        credentials,
        identifier:
            _oauthClientId.trim().isEmpty ? null : _oauthClientId.trim(),
        secret: null,
        onCredentialsRefreshed: (fresh) {
          _ytRefreshToken = fresh.refreshToken;
          _ytAccessToken = fresh.accessToken.trim();
          unawaited(_persistOAuthCredentials(fresh));
        },
      );
      _attachOAuthClient(client);
      return client;
    } catch (e) {
      debugPrint('[YT OAuth restore] $e');
      await _clearOAuthCredentials();
      return null;
    }
  }

  bool get _useGoogleSignInAndroid => Platform.isAndroid;

  Future<String?> _getAndroidGoogleSignInToken({
    required bool interactive,
  }) async {
    GoogleSignInAccount? account;
    try {
      account = await _googleSignIn.signInSilently(
        suppressErrors: true,
        reAuthenticate: false,
      );
    } catch (e) {
      debugPrint('[GSI silent] $e');
    }

    if (account == null && interactive) {
      try {
        account = await _googleSignIn.signIn();
      } catch (e) {
        debugPrint('[GSI interactive] $e');
      }
    }

    if (account == null) return null;

    if (_ytGoogleSignInScopes.isNotEmpty && interactive) {
      try {
        final granted =
            await _googleSignIn.requestScopes(_ytGoogleSignInScopes);
        if (!granted) return null;
      } on UnimplementedError {
        // Some Android plugin builds don't expose runtime scope APIs.
        // Continue with scopes requested during sign-in initialization.
        debugPrint('[GSI scopes] requestScopes not implemented');
      } catch (e) {
        debugPrint('[GSI scopes] $e');
      }
    }

    final auth = await account.authentication;
    final token = (auth.accessToken ?? '').trim();
    if (token.isEmpty) return null;

    _ytAccessToken = token;
    _ytAccountEmail =
        account.email.trim().isEmpty ? _ytAccountEmail : account.email;
    _ytAccountName = (account.displayName ?? '').trim().isEmpty
        ? (_ytAccountName ?? account.email)
        : account.displayName;
    _ytAccountPhoto = (account.photoUrl ?? '').trim().isEmpty
        ? _ytAccountPhoto
        : account.photoUrl;
    return token;
  }

  void _setupDeepLink() {
    _oauthLinkSub?.cancel();
    _oauthLinkSub = _appLinks.uriLinkStream.listen(
      (uri) => unawaited(_handleOAuthRedirect(uri)),
      onError: (Object e, StackTrace st) {
        debugPrint('[YT OAuth deep link] $e');
      },
    );
    unawaited(() async {
      try {
        final initial = await _appLinks.getInitialLink();
        if (initial != null) {
          await _handleOAuthRedirect(initial);
        }
      } catch (e) {
        debugPrint('[YT OAuth initial link] $e');
      }
    }());
  }

  bool _isExpectedOAuthRedirect(Uri uri) {
    final expected = Uri.parse(_oauthRedirectUri);
    if (uri.scheme != expected.scheme) return false;

    final expectedHost = expected.host.trim();
    if (expectedHost.isNotEmpty && uri.host != expectedHost) return false;

    final expectedPath = expected.path.trim();
    if (expectedPath.isNotEmpty && uri.path != expectedPath) return false;

    return true;
  }

  Future<void> _handleOAuthRedirect(Uri uri) async {
    if (!_isExpectedOAuthRedirect(uri)) return;
    final params = Map<String, String>.from(uri.queryParameters);
    final oauthError = (params['error'] ?? '').trim();
    if (oauthError.isNotEmpty) {
      _ytAuthGrant = null;
      if (mounted) {
        setState(() => _ytSigningIn = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Login cancelled: $oauthError')),
        );
      } else {
        _ytSigningIn = false;
      }
      return;
    }

    final grant = _ytAuthGrant;
    if (grant == null) {
      debugPrint('[YT OAuth] callback received without active grant');
      if (mounted) {
        setState(() => _ytSigningIn = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Sign-in session expired. Tap Connect again.')),
        );
      } else {
        _ytSigningIn = false;
      }
      return;
    }

    try {
      final client = await grant.handleAuthorizationResponse(params);
      _ytAuthGrant = null;
      _attachOAuthClient(client);
      await _persistOAuthCredentials(client.credentials);
      final token = (_ytAccessToken ?? '').trim();
      if (token.isEmpty) {
        throw StateError('OAuth token was empty after authorization.');
      }
      await _ytFetchWithToken(token);
    } catch (e) {
      debugPrint('[YT OAuth callback] $e');
      _ytAuthGrant = null;
      if (mounted) {
        setState(() => _ytSigningIn = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Login failed: $e')),
        );
      } else {
        _ytSigningIn = false;
      }
    }
  }

  Future<void> _loginWithYouTubeMusic() async {
    if (_ytSigningIn || _ytDataLoading) return;
    if (_useGoogleSignInAndroid) {
      if (mounted) {
        setState(() => _ytSigningIn = true);
      } else {
        _ytSigningIn = true;
      }
      try {
        final token = await _getAndroidGoogleSignInToken(interactive: true);
        if (token == null || token.isEmpty) {
          throw StateError(
            'Google Sign-In failed. Make sure this Gmail is added as a test user.',
          );
        }
        await _ytFetchWithToken(token);
        return;
      } catch (e) {
        debugPrint('[YT Android sign-in] $e');
        if (mounted) {
          setState(() => _ytSigningIn = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Sign-in failed: $e')),
          );
        } else {
          _ytSigningIn = false;
        }
        return;
      }
    }

    if (!_isOAuthClientConfigured()) {
      await _showGoogleSignInSetupDialog(
        errorMessage:
            'Missing OAuth client. Run with --dart-define=YT_OAUTH_CLIENT_ID=...',
      );
      return;
    }

    if (mounted) {
      setState(() => _ytSigningIn = true);
    } else {
      _ytSigningIn = true;
    }

    try {
      final existingToken =
          await _getFreshGoogleAccessToken(interactive: false);
      if (existingToken != null && existingToken.isNotEmpty) {
        await _ytFetchWithToken(existingToken);
        return;
      }

      final grant = _buildOAuthGrant();
      _ytAuthGrant = grant;
      final baseAuthUri = grant.getAuthorizationUrl(
        Uri.parse(_oauthRedirectUri),
        scopes: _ytOauthScopes,
      );
      final authUri = baseAuthUri.replace(queryParameters: {
        ...baseAuthUri.queryParameters,
        'access_type': 'offline',
        'prompt': 'consent',
        'include_granted_scopes': 'true',
      });
      final launched =
          await launchUrl(authUri, mode: LaunchMode.externalApplication);
      if (!launched) {
        throw StateError('Could not open Google sign-in page.');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Complete sign-in in browser...')),
        );
      }
    } catch (e) {
      debugPrint('[YT OAuth launch] $e');
      _ytAuthGrant = null;
      if (mounted) {
        setState(() => _ytSigningIn = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sign-in failed: $e')),
        );
      } else {
        _ytSigningIn = false;
      }
    }
  }

  Future<String?> _getFreshGoogleAccessToken({
    required bool interactive,
  }) async {
    if (_useGoogleSignInAndroid) {
      return _getAndroidGoogleSignInToken(interactive: interactive);
    }

    oauth2.Client? client = _ytClient ?? await _restoreOAuthClientFromPrefs();
    if (client == null) {
      if (interactive) {
        await _loginWithYouTubeMusic();
      }
      return null;
    }

    try {
      if (client.credentials.isExpired && client.credentials.canRefresh) {
        await client.refreshCredentials();
      } else if (client.credentials.isExpired &&
          !client.credentials.canRefresh) {
        throw StateError('OAuth session expired and cannot refresh.');
      }
      _attachOAuthClient(client);
      await _persistOAuthCredentials(client.credentials);
      final token = (_ytAccessToken ?? '').trim();
      return token.isEmpty ? null : token;
    } catch (e) {
      debugPrint('[YT OAuth token refresh] $e');
      _ytClient?.close();
      _ytClient = null;
      _ytAccessToken = null;
      _ytRefreshToken = null;
      await _clearOAuthCredentials();
      if (interactive) {
        await _loginWithYouTubeMusic();
      }
      return null;
    }
  }

  Future<void> _restoreGoogleSignInSession() async {
    try {
      final token = await _getFreshGoogleAccessToken(interactive: false);
      if (token == null || token.isEmpty) return;
      final hadLocalData = _hasRestorableLocalData;
      final localSavedAtMs = _lastPersistedDataSavedAtMs;

      final needsFetch = (_ytAccountEmail ?? '').trim().isEmpty ||
          _ytLikedVideos.isEmpty ||
          (_ytAccessToken ?? '').trim().isEmpty;

      if (needsFetch) {
        await _ytFetchWithToken(token);
        return;
      }

      if (mounted) {
        setState(() => _ytAccessToken = token);
      } else {
        _ytAccessToken = token;
      }
      final restoredFromCloud = await _restoreFromCloudBackup(
        token: token,
        replaceExisting: true,
        preserveCurrentYtAccount: true,
        preserveCurrentYtLikes: true,
        onlyIfCloudNewerThanMs: hadLocalData ? localSavedAtMs : null,
      );
      if (restoredFromCloud) {
        await _saveData();
      }
      _scheduleSave();
    } catch (e) {
      debugPrint('[YT restore] $e');
    }
  }

  Future<void> _openExternalUrl(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) return;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (ok || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not open $rawUrl')),
    );
  }

  Future<void> _showGoogleSignInSetupDialog({String? errorMessage}) async {
    if (!mounted) return;
    const oauthDefineHint = '--dart-define=YT_OAUTH_CLIENT_ID=YOUR_CLIENT_ID';
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text(
          'Google OAuth Setup Required',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Automatic login uses OAuth deep links. Configure Android OAuth client and run the app.',
                style:
                    TextStyle(color: Colors.white70, fontSize: 12, height: 1.4),
              ),
              const SizedBox(height: 10),
              const Text(
                'Package name: $_androidApplicationId',
                style: TextStyle(
                    color: Colors.greenAccent,
                    fontFamily: 'monospace',
                    fontSize: 11),
              ),
              const SizedBox(height: 4),
              const Text(
                'Redirect URI: $_oauthRedirectUri',
                style: TextStyle(
                    color: Colors.white70,
                    fontFamily: 'monospace',
                    fontSize: 11),
              ),
              const SizedBox(height: 8),
              const Text(
                'Run command with:',
                style: TextStyle(
                    color: Colors.white70, fontSize: 11, height: 1.35),
              ),
              const SizedBox(height: 4),
              const Text(
                'flutter run',
                style: TextStyle(
                    color: Colors.greenAccent,
                    fontFamily: 'monospace',
                    fontSize: 10),
              ),
              const SizedBox(height: 8),
              const Text(
                'Google Cloud: OAuth consent in Testing + your Gmail in Test users.',
                style: TextStyle(
                    color: Colors.white70, fontSize: 11, height: 1.35),
              ),
              if ((errorMessage ?? '').trim().isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  'Error: $errorMessage',
                  style: TextStyle(color: Colors.grey[500], fontSize: 10),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(
                const ClipboardData(text: _androidApplicationId),
              );
              if (!ctx.mounted) return;
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(content: Text('Package name copied')),
              );
            },
            child: const Text('Copy Package',
                style: TextStyle(color: Colors.white)),
          ),
          TextButton(
            onPressed: () async {
              await Clipboard.setData(
                const ClipboardData(
                    text: '$_oauthRedirectUri\n$oauthDefineHint'),
              );
              if (!ctx.mounted) return;
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(content: Text('OAuth setup hint copied')),
              );
            },
            child:
                const Text('Copy Setup', style: TextStyle(color: Colors.white)),
          ),
          TextButton(
            onPressed: () =>
                unawaited(_openExternalUrl(_googleCloudYouTubeApiUrl)),
            child: const Text('Enable API',
                style: TextStyle(color: Colors.greenAccent)),
          ),
          TextButton(
            onPressed: () =>
                unawaited(_openExternalUrl(_googleCloudConsoleUrl)),
            child: const Text('Console',
                style: TextStyle(color: Colors.greenAccent)),
          ),
          TextButton(
            onPressed: () =>
                unawaited(_openExternalUrl(_googleCloudCredentialsUrl)),
            child: const Text('Credentials',
                style: TextStyle(color: Colors.greenAccent)),
          ),
          TextButton(
            onPressed: () =>
                unawaited(_openExternalUrl(_googleCloudConsentUrl)),
            child: const Text('Consent',
                style: TextStyle(color: Colors.greenAccent)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Close', style: TextStyle(color: Colors.grey[500])),
          ),
        ],
      ),
    );
  }

  Future<void> _ytSignIn() async {
    await _loginWithYouTubeMusic();
  }

  Future<void> _syncYouTubeAccount() async {
    if (_ytDataLoading || _ytSigningIn) return;
    var token = (_ytAccessToken ?? '').trim();
    try {
      final fresh = await _getFreshGoogleAccessToken(interactive: false);
      if (fresh != null && fresh.isNotEmpty) {
        token = fresh;
      }
    } catch (e) {
      debugPrint('[YT Sync token] $e');
    }
    if (token.isEmpty) {
      await _loginWithYouTubeMusic();
      return;
    }
    await _ytFetchWithToken(token);
    await _saveData();
  }

  Future<void> _showYtMusicCookieDialog() async {
    final dialogResult = await showDialog<_YtMusicCookieDialogResult>(
      context: context,
      builder: (_) => _YtMusicCookieDialog(
        initialCookie: _effectiveYtMusicCookie(),
        initialAuthUser: _ytMusicAuthUser,
        initialVisitorData: _normalizeYtMusicVisitorData(_ytMusicVisitorData),
        showClear: (_ytMusicCookie ?? '').trim().isNotEmpty,
        normalizeCookieInput: _normalizeYtMusicCookieInput,
        extractAuthUser: _extractYtMusicAuthUser,
        extractVisitorData: _extractYtMusicVisitorData,
      ),
    );

    if (!mounted || dialogResult == null) return;

    if (dialogResult.clear) {
      setState(() {
        _ytMusicCookie = null;
        _ytMusicAuthUser = '0';
        _ytMusicVisitorData = _ytMusicDefaultVisitorData;
        _ytMusicResolvedWebRemixClientVersion = null;
        _ytMusicBackendRetryAfter = null;
        _ytMusicSessionChecking = false;
        _ytMusicSessionValid = false;
        _ytMusicSessionName = null;
        _ytMusicSessionEmail = null;
        _ytMusicSessionHandle = null;
        _ytMusicSessionError = null;
        _usingYtMusicHomeFeed = false;
        _ytHomeMixes = [];
        _ytMusicHomeShelves = [];
      });
      _scheduleSave();
      _maybeReloadHomeAuto();
      return;
    }

    final normalizedCookie = (dialogResult.cookie ?? '').trim();
    final normalizedAuthUser =
        _normalizeYtMusicAuthUser(dialogResult.authUser ?? '0');
    final normalizedVisitorData =
        _normalizeYtMusicVisitorData(dialogResult.visitorData ?? '');
    setState(() {
      _ytMusicCookie = normalizedCookie.isEmpty ? null : normalizedCookie;
      _ytMusicAuthUser = normalizedAuthUser;
      _ytMusicVisitorData = normalizedVisitorData.isNotEmpty
          ? normalizedVisitorData
          : _ytMusicDefaultVisitorData;
      _ytMusicResolvedWebRemixClientVersion = null;
      _ytMusicBackendRetryAfter = null;
      _ytMusicSessionChecking = normalizedCookie.isNotEmpty;
      _ytMusicSessionValid = false;
      _ytMusicSessionName = null;
      _ytMusicSessionEmail = null;
      _ytMusicSessionHandle = null;
      _ytMusicSessionError = null;
      _usingYtMusicHomeFeed = false;
    });
    _scheduleSave();
    unawaited(
      _refreshYtMusicSession(
        reloadHome: true,
        showToast: normalizedCookie.isNotEmpty,
      ),
    );
  }

  Future<void> _showYtMusicBackendDialog() async {
    final urlCtrl = TextEditingController(text: _ytMusicBackendUrlOverride);
    final apiKeyCtrl = TextEditingController(text: _ytMusicBackendApiKeyOverride);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF151515),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'YT Music Backend',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Paste the hosted backend URL so your phone can stream without your PC running. Leave these empty to use the app defaults.',
                style: TextStyle(
                  color: Colors.grey[400],
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: urlCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Backend URL',
                  hintText: 'https://your-backend.onrender.com',
                  labelStyle: TextStyle(color: Colors.grey[300]),
                  hintStyle: TextStyle(color: Colors.grey[600]),
                  filled: true,
                  fillColor: const Color(0xFF1D1D1D),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: apiKeyCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'API Key',
                  hintText: 'Optional',
                  labelStyle: TextStyle(color: Colors.grey[300]),
                  hintStyle: TextStyle(color: Colors.grey[600]),
                  filled: true,
                  fillColor: const Color(0xFF1D1D1D),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (_ytMusicBackendUrlOverride.trim().isNotEmpty ||
              _ytMusicBackendApiKeyOverride.trim().isNotEmpty)
            TextButton(
              onPressed: () {
                urlCtrl.clear();
                apiKeyCtrl.clear();
              },
              child: const Text(
                'Clear',
                style: TextStyle(color: Colors.orangeAccent),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.grey),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.greenAccent,
              foregroundColor: Colors.black,
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (!mounted || saved != true) return;

    final rawUrl = urlCtrl.text.trim();
    final normalizedUrl = rawUrl.endsWith('/')
        ? rawUrl.substring(0, rawUrl.length - 1)
        : rawUrl;
    if (normalizedUrl.isNotEmpty) {
      final parsed = Uri.tryParse(normalizedUrl);
      if (parsed == null || !parsed.hasScheme || parsed.host.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a valid backend URL.')),
        );
        return;
      }
    }

    setState(() {
      _ytMusicBackendUrlOverride = normalizedUrl;
      _ytMusicBackendApiKeyOverride = apiKeyCtrl.text.trim();
      _ytMusicBackendRetryAfter = null;
    });
    _scheduleSave();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          normalizedUrl.isEmpty
              ? 'Backend override cleared'
              : 'Backend updated',
        ),
      ),
    );
  }

  String _googleApiErrorText(dynamic rawError) {
    final map = _jsonMap(rawError);
    if (map == null) return '';
    final direct = (map['message'] ?? '').toString().trim();
    if (direct.isNotEmpty) return direct;
    for (final item in _jsonList(map['errors'])) {
      final message = (_jsonMap(item)?['message'] ?? '').toString().trim();
      if (message.isNotEmpty) return message;
    }
    return (map['status'] ?? '').toString().trim();
  }

  Future<void> _ytFetchWithToken(String token) async {
    final hadLocalDataBeforeLogin = _hasRestorableLocalData;
    final localSavedAtBeforeLoginMs = _lastPersistedDataSavedAtMs;
    if (mounted) {
      setState(() {
        _ytSigningIn = true;
        _ytDataLoading = true;
      });
    }

    http.Client? fallbackClient;
    try {
      var effectiveToken =
          (await _getFreshGoogleAccessToken(interactive: false) ?? token)
              .trim();
      if (effectiveToken.isEmpty) {
        throw StateError('OAuth token unavailable. Please reconnect.');
      }

      final oauthClient = _ytClient ?? await _restoreOAuthClientFromPrefs();
      if (oauthClient == null) {
        fallbackClient = http.Client();
      } else {
        _attachOAuthClient(oauthClient);
        final refreshed = oauthClient.credentials.accessToken.trim();
        if (refreshed.isNotEmpty) {
          effectiveToken = refreshed;
        }
      }

      Future<Map<String, dynamic>> getJson(
        Uri uri, {
        Duration timeout = const Duration(seconds: 15),
      }) async {
        final headers = <String, String>{
          HttpHeaders.acceptHeader: 'application/json',
        };
        late final http.Response response;

        if (oauthClient != null) {
          response =
              await oauthClient.get(uri, headers: headers).timeout(timeout);
          final refreshed = oauthClient.credentials.accessToken.trim();
          if (refreshed.isNotEmpty) {
            effectiveToken = refreshed;
          }
        } else {
          headers[HttpHeaders.authorizationHeader] = 'Bearer $effectiveToken';
          response =
              await fallbackClient!.get(uri, headers: headers).timeout(timeout);
        }

        final body = response.body;
        final decoded = body.trim().isEmpty
            ? <String, dynamic>{}
            : _jsonMap(jsonDecode(body));
        if (decoded == null) {
          throw FormatException('Invalid JSON object from ${uri.path}');
        }

        final apiError = _googleApiErrorText(decoded['error']);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final suffix = apiError.isEmpty ? '' : ': $apiError';
          throw Exception(
            'Google API ${uri.path} failed (${response.statusCode})$suffix',
          );
        }
        if (apiError.isNotEmpty) {
          throw Exception('Google API ${uri.path} error: $apiError');
        }
        return decoded;
      }

      final info = await getJson(
        Uri.https('www.googleapis.com', '/oauth2/v3/userinfo'),
        timeout: const Duration(seconds: 10),
      );
      final email = (info['email'] as String?)?.trim();
      final name = (info['name'] as String?)?.trim();
      final photo = (info['picture'] as String?)?.trim();
      final resolvedEmail =
          (email == null || email.isEmpty) ? 'YouTube Account' : email;
      final resolvedName =
          (name == null || name.isEmpty) ? resolvedEmail : name;

      final likedVideos = <Video>[];
      String? nextPageToken;
      int pagesFetched = 0;
      const maxPages = 20;

      do {
        final likedQuery = <String, String>{
          'part': 'snippet,contentDetails',
          'playlistId': 'LM',
          'maxResults': '50',
          if (nextPageToken != null && nextPageToken.isNotEmpty)
            'pageToken': nextPageToken,
        };
        final likedUri = Uri.https(
          'www.googleapis.com',
          '/youtube/v3/playlistItems',
          likedQuery,
        );

        Map<String, dynamic> likedJson;
        try {
          likedJson =
              await getJson(likedUri, timeout: const Duration(seconds: 20));
        } catch (e) {
          debugPrint('[YT LM playlist] $e - falling back to myRating');
          await _fetchLikedByRating(getJson: getJson, out: likedVideos);
          break;
        }

        for (final item in _jsonList(likedJson['items'])) {
          final snippet = _jsonMap(_jsonAt(item, const ['snippet'])) ??
              const <String, dynamic>{};
          final id = (_stringAt(item, const ['contentDetails', 'videoId']) ??
                  _stringAt(item, const ['snippet', 'resourceId', 'videoId']) ??
                  '')
              .trim();
          final title = (snippet['title'] ?? '').toString().trim();
          if (id.isEmpty ||
              title.toLowerCase() == 'deleted video' ||
              title.toLowerCase() == 'private video') {
            continue;
          }

          final channel = (_stringAt(
                    item,
                    const ['snippet', 'videoOwnerChannelTitle'],
                  ) ??
                  _stringAt(item, const ['snippet', 'channelTitle']) ??
                  '')
              .trim();
          final dur = _parseIsoDuration(
            _stringAt(item, const ['contentDetails', 'duration']) ?? '',
          );

          final video = _videoFromMap({
            'id': id,
            'title': title.isEmpty ? 'Unknown' : title,
            'author': channel,
            'durationSecs': dur?.inSeconds,
          });
          if (_isMusicCandidate(video, strictSingles: true)) {
            likedVideos.add(video);
          }
        }

        nextPageToken = (likedJson['nextPageToken'] ?? '').toString().trim();
        if (nextPageToken.isEmpty) nextPageToken = null;
        pagesFetched++;

        if (mounted) {
          setState(() {
            _ytLikedVideos = _filterMusicResults(
              likedVideos,
              limit: 1000,
              strictSingles: true,
            );
            _bufferLabel = 'Loading liked songs... ${likedVideos.length}';
          });
        }

        if (nextPageToken != null) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      } while (nextPageToken != null && pagesFetched < maxPages);

      final subJson = await getJson(
        Uri.https(
          'www.googleapis.com',
          '/youtube/v3/subscriptions',
          const {
            'part': 'snippet',
            'mine': 'true',
            'maxResults': '20',
            'order': 'relevance',
          },
        ),
        timeout: const Duration(seconds: 15),
      );
      final subscribedChannels = <String>[];
      for (final item in _jsonList(subJson['items'])) {
        final title = _stringAt(item, const ['snippet', 'title']);
        if (title != null && title.isNotEmpty) subscribedChannels.add(title);
      }
      if (subscribedChannels.isNotEmpty) {
        debugPrint(
          '[YT Account] loaded ${subscribedChannels.length} subscriptions',
        );
      }

      final oauthRefresh = (_ytClient?.credentials.refreshToken ??
              oauthClient?.credentials.refreshToken ??
              '')
          .trim();
      if (oauthRefresh.isNotEmpty) {
        _ytRefreshToken = oauthRefresh;
      }

      if (mounted) {
        setState(() {
          _ytAccessToken = effectiveToken;
          _ytRefreshToken =
              oauthRefresh.isNotEmpty ? oauthRefresh : _ytRefreshToken;
          _ytAccountEmail = resolvedEmail;
          _ytAccountName = resolvedName;
          _ytAccountPhoto = (photo == null || photo.isEmpty) ? null : photo;
          _ytLikedVideos = _filterMusicResults(
            likedVideos,
            limit: 1000,
            strictSingles: true,
          );
          _cloudSyncError = null;
          _ytSigningIn = false;
          _ytDataLoading = false;
        });
      } else {
        _ytAccessToken = effectiveToken;
        _ytRefreshToken =
            oauthRefresh.isNotEmpty ? oauthRefresh : _ytRefreshToken;
        _ytAccountEmail = resolvedEmail;
        _ytAccountName = resolvedName;
        _ytAccountPhoto = (photo == null || photo.isEmpty) ? null : photo;
        _ytLikedVideos = _filterMusicResults(
          likedVideos,
          limit: 1000,
          strictSingles: true,
        );
        _cloudSyncError = null;
        _ytSigningIn = false;
        _ytDataLoading = false;
      }

      var restoredFromCloud = false;
      if (!hadLocalDataBeforeLogin) {
        _cloudWritesPausedForRestore = true;
      }
      try {
        restoredFromCloud = await _restoreFromCloudBackup(
          token: effectiveToken,
          replaceExisting: true,
          preserveCurrentYtAccount: true,
          preserveCurrentYtLikes: true,
          onlyIfCloudNewerThanMs:
              hadLocalDataBeforeLogin ? localSavedAtBeforeLoginMs : null,
        );
      } finally {
        _cloudWritesPausedForRestore = false;
      }

      for (final v in likedVideos) {
        if (!_likedVideoIds.contains(v.id.value)) {
          _likedVideoIds.add(v.id.value);
          _likedPlaylist.videos.insert(0, v);
        }
      }

      if (_ytClient != null) {
        await _persistOAuthCredentials(_ytClient!.credentials);
      }
      await _saveData();
      if ((_ytMusicCookie ?? '').trim().isNotEmpty) {
        unawaited(_refreshYtMusicSession(reloadHome: true));
      } else {
        _maybeReloadHomeAuto();
      }
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(
                Icons.check_circle_rounded,
                color: Colors.greenAccent,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  restoredFromCloud
                      ? 'Connected as $resolvedName | ${likedVideos.length} liked songs imported | cloud data restored'
                      : 'Connected as $resolvedName | ${likedVideos.length} liked songs from YouTube Music imported',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          duration: const Duration(seconds: 4),
          backgroundColor: const Color(0xFF1A1A1A),
        ),
      );
    } catch (e) {
      debugPrint('[YT Account] $e');
      if (mounted) {
        setState(() {
          _ytSigningIn = false;
          _ytDataLoading = false;
        });
        final message = e.toString().trim();
        final clipped =
            message.length > 80 ? '${message.substring(0, 80)}...' : message;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Connection failed: $clipped',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            backgroundColor: Colors.redAccent.shade700,
          ),
        );
      } else {
        _ytSigningIn = false;
        _ytDataLoading = false;
      }
    } finally {
      fallbackClient?.close();
    }
  }

  /// Fallback: fetch liked videos via myRating=like but filter to music only.
  /// Used when the LM playlist is unavailable or returns an error.
  Future<void> _fetchLikedByRating({
    required Future<Map<String, dynamic>> Function(
      Uri uri, {
      Duration timeout,
    }) getJson,
    required List<Video> out,
  }) async {
    String? nextPage;
    int pages = 0;
    do {
      final query = <String, String>{
        'part': 'snippet,contentDetails',
        'myRating': 'like',
        'videoCategoryId': '10',
        'maxResults': '50',
        if (nextPage != null && nextPage.isNotEmpty) 'pageToken': nextPage,
      };
      final uri = Uri.https('www.googleapis.com', '/youtube/v3/videos', query);

      Map<String, dynamic> json2;
      try {
        json2 = await getJson(uri, timeout: const Duration(seconds: 20));
      } catch (e) {
        debugPrint('[YT likes fallback] $e');
        break;
      }

      for (final item in _jsonList(json2['items'])) {
        final id = (_stringAt(item, const ['id']) ?? '').trim();
        if (id.isEmpty) continue;

        final title =
            (_stringAt(item, const ['snippet', 'title']) ?? 'Unknown').trim();
        final channel =
            (_stringAt(item, const ['snippet', 'channelTitle']) ?? '').trim();
        final dur = _parseIsoDuration(
          _stringAt(item, const ['contentDetails', 'duration']) ?? '',
        );
        final v = _videoFromMap({
          'id': id,
          'title': title.isEmpty ? 'Unknown' : title,
          'author': channel,
          'durationSecs': dur?.inSeconds,
        });
        if (_isMusicCandidate(v, strictSingles: true)) {
          out.add(v);
        }
      }

      nextPage = (json2['nextPageToken'] ?? '').toString().trim();
      if (nextPage.isEmpty) nextPage = null;
      pages++;
      if (nextPage != null) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    } while (nextPage != null && pages < 20);
  }

  bool _looksLikeShortForm(String text) {
    const shortKeywords = [
      '#shorts',
      ' shorts',
      'short video',
      'youtube shorts',
      'yt shorts',
      '#reel',
      ' reels',
      'whatsapp status',
      'status video',
      'tiktok',
      'capcut',
    ];
    for (final kw in shortKeywords) {
      if (text.contains(kw)) return true;
    }
    return false;
  }

  bool _looksLikeDerivativeVersion(String text) {
    final t = text.toLowerCase();
    const derivatives = [
      'unofficial',
      'fan made',
      'fanmade',
      'cover',
      'karaoke',
      'instrumental',
      'slowed',
      'reverb',
      'sped up',
      'nightcore',
      '8d',
      'edit',
      'mashup',
      'bootleg',
    ];
    for (final kw in derivatives) {
      if (t.contains(kw)) return true;
    }
    return false;
  }

  bool _isQuickPickAllowed(Video video) {
    final title = _cleanTitle(video.title, author: video.author).toLowerCase();
    final author = _cleanAuthor(video.author).toLowerCase();
    final text = '$title $author';
    if (_looksLikeDerivativeVersion(text)) return false;
    const blocked = <String>[
      'lofi',
      'lo-fi',
      'remix',
      'fanmade',
      'fan made',
      'unofficial',
      'slowed',
      'reverb',
      'nightcore',
      'mashup',
      'bootleg',
      'cover',
      'dj mix',
      'edit',
    ];
    for (final kw in blocked) {
      if (text.contains(kw)) return false;
    }
    return true;
  }

  bool _isStrictRomanceCandidate(Video video) {
    final title = _cleanTitle(video.title, author: video.author).toLowerCase();
    final author = _cleanAuthor(video.author).toLowerCase();
    final text = '$title $author';
    const strongPositive = <String>[
      'love',
      'romance',
      'romantic',
      'ishq',
      'pyaar',
      'pyar',
      'mohabbat',
      'dil',
      'valentine',
      'heart',
      'sanam',
      'sajna',
    ];
    const blocked = <String>[
      'rap',
      'hip hop',
      'hip-hop',
      'drill',
      'diss',
      'beef',
      'freestyle',
      'cypher',
      'workout',
      'gym',
      'trap',
      'phonk',
      'lofi',
      'remix',
      'mashup',
      'edit',
      'slowed',
      'nightcore',
    ];
    for (final kw in blocked) {
      if (text.contains(kw)) return false;
    }
    return strongPositive.any(text.contains);
  }

  bool _looksLikeCompilation(String title) {
    final t = title.toLowerCase();
    const hardKeywords = [
      'playlist',
      'non stop',
      'nonstop',
      'jukebox',
      'full album',
      'hour mix',
      'hours mix',
      'dj mix',
      'mega mix',
      'all songs',
      'best songs',
      'hits of',
      'top songs',
      'chartbuster',
    ];
    for (final kw in hardKeywords) {
      if (t.contains(kw)) return true;
    }
    if (RegExp(r'\btop\s*(10|20|25|30|50|100)\b', caseSensitive: false)
        .hasMatch(t)) {
      return true;
    }
    return false;
  }

  bool _isDurationMusicFriendly(
    Duration? d, {
    bool strictSingles = false,
  }) {
    if (d == null) return true;
    final secs = d.inSeconds;
    if (secs < 50) return false;
    if (strictSingles && secs < 80) return false;
    if (secs > (strictSingles ? 11 * 60 : 20 * 60)) return false;
    return true;
  }

  bool _hasMusicIntentSignal(String text) {
    final t = text.toLowerCase();
    const cues = <String>[
      'song',
      'songs',
      'music',
      'audio',
      'official audio',
      'lyric',
      'lyrics',
      'topic',
      'album',
      'ep',
      'ost',
      'soundtrack',
      'mix',
      'remix',
      'cover',
      'instrumental',
      'beats',
      'lofi',
      'dj',
      'vevo',
      'feat',
      ' ft.',
    ];
    for (final cue in cues) {
      if (t.contains(cue)) return true;
    }
    return false;
  }

  bool _looksLikeNewsOrTalkHeadline(String title, String channel) {
    final t = title.toLowerCase();
    final c = channel.toLowerCase();
    final text = '$t $c';

    const phraseHits = <String>[
      'breaking news',
      'live update',
      'must watch',
      'what happened',
      'just walked into',
      'open letter',
      'full debate',
      'policy breakdown',
      'geopolitical',
    ];
    for (final p in phraseHits) {
      if (text.contains(p)) return true;
    }

    const geoTerms = <String>[
      'usa',
      'u.s.',
      'america',
      'russia',
      'ukraine',
      'israel',
      'iran',
      'china',
      'taiwan',
      'pakistan',
      'president',
      'prime minister',
      'election',
      'parliament',
      'senate',
      'government',
      'war',
      'missile',
      'nuclear',
      'sanction',
      'inflation',
      'economy',
    ];
    const commentaryTerms = <String>[
      'explained',
      'analysis',
      'debate',
      'speech',
      'conflict',
      'politics',
      'news',
      'report',
      'interview',
      'talk show',
      'podcast',
    ];

    int geoHits = 0;
    for (final term in geoTerms) {
      if (text.contains(term)) geoHits++;
    }
    int commentaryHits = 0;
    for (final term in commentaryTerms) {
      if (text.contains(term)) commentaryHits++;
    }

    return (geoHits >= 2) || (geoHits >= 1 && commentaryHits >= 1);
  }

  bool _looksLikeCommentaryOrDrama(String title, String channel) {
    final text = '${title.toLowerCase()} ${channel.toLowerCase()}';
    const hardTerms = <String>[
      'my opinion',
      'opinion on',
      'what if',
      'first listen',
      'listening to',
      'reacts to',
      'reaction to',
      'my reaction',
      'breaks down',
      'explained',
      'exposed',
      'reply to',
      'replied to',
      'response to',
      'beef',
      'controversy',
      'breakdown',
      'debate',
      'analysis',
      'review',
      'rant',
      'vs ',
      ' versus ',
    ];
    int hits = 0;
    for (final t in hardTerms) {
      if (text.contains(t)) hits++;
    }
    return hits >= 1;
  }

  /// Returns true if title/channel looks like music, not shorts or non-music.
  bool _looksLikeMusic(
    String title,
    String channel, {
    bool strictSingles = false,
  }) {
    final t = title.toLowerCase();
    final c = channel.toLowerCase();
    final text = '$t $c';
    final hasMusicIntent = _hasMusicIntentSignal(text);

    if (_looksLikeShortForm('$t $c')) return false;
    if (_looksLikeDerivativeVersion(t)) return false;
    if (_looksLikeCompilation(t)) return false;

    // Avoid cases where the "title" is just the artist/channel name.
    final ct = _normalizeSignalKey(_cleanTitle(title));
    final ca = _primaryArtistKey(_cleanAuthor(channel));
    if (ct.isNotEmpty && ca.isNotEmpty && ct == ca) {
      return false;
    }

    // Strong negative: "what if" style hypothetical content is rarely a song.
    if (t.contains('what if')) {
      final official = _looksOfficialMusicChannel(channel);
      final strongMusicCue = t.contains('official audio') ||
          t.contains('topic') ||
          t.contains('lyrics') ||
          t.contains('lyric') ||
          t.contains('vevo') ||
          t.contains('records') ||
          t.contains('official');
      if (!official && !strongMusicCue) return false;
    }

    const nonMusicKeywords = [
      'minecraft',
      'gameplay',
      'playthrough',
      'walkthrough',
      'tutorial',
      'how to',
      'review',
      'unboxing',
      'vlog',
      'podcast',
      'funny video',
      'prank',
      'challenge',
      'reaction',
      'roast',
      'highlights',
      'trailer',
      'teaser',
      'episode',
      'season',
      'speedrun',
      'stream',
      'gaming',
      'roblox',
      'fortnite',
      'gta ',
      'pubg',
      'free fire',
      'interview',
      'talk show',
      'herobrine',
      'daku edit',
      'meme compilation',
      'motivation speech',
      'news',
      'politics',
      'comedy show',
      'open letter',
    ];
    for (final kw in nonMusicKeywords) {
      if (t.contains(kw) || c.contains(kw)) return false;
    }

    final looksOfficial = _looksOfficialMusicChannel(channel);
    if (!hasMusicIntent &&
        !looksOfficial &&
        _looksLikeNewsOrTalkHeadline(title, channel)) {
      return false;
    }
    if (!hasMusicIntent && _looksLikeCommentaryOrDrama(title, channel)) {
      return false;
    }
    if (!hasMusicIntent) {
      final text2 = '$t $c';
      final commentaryTerms = <String>[
        'livestream',
        'live stream',
        'live update',
        'analysis',
        'debate',
        'explained',
        'exposed',
        'copied',
        'breakdown',
        'drama',
        'gossip',
        'commentary',
        'shorts',
        'short ',
        ' clip',
        ' clips',
        'react',
        'reaction',
        'podcast',
        'news',
        ' tv',
        ' zone',
      ];
      for (final term in commentaryTerms) {
        if (text2.contains(term)) return false;
      }
      if (t.contains('?') || t.contains('||') || t.contains(' vs ')) {
        return false;
      }
    }

    if (strictSingles && !hasMusicIntent && !looksOfficial) {
      final words =
          t.split(RegExp(r'\s+')).where((w) => w.trim().isNotEmpty).toList();
      if (words.length >= 5) return false;
    }

    return true;
  }

  bool _isMusicCandidate(Video v, {bool strictSingles = false}) {
    if (!_looksLikeMusic(v.title, v.author, strictSingles: strictSingles)) {
      return false;
    }
    if (!_isDurationMusicFriendly(v.duration, strictSingles: strictSingles)) {
      return false;
    }
    return true;
  }

  List<Video> _filterMusicResults(
    Iterable<Video> source, {
    int limit = 20,
    bool strictSingles = false,
  }) {
    final out = <Video>[];
    final seenIds = <String>{};
    final seenTracks = <String>{};
    for (final v in source) {
      if (!_isMusicCandidate(v, strictSingles: strictSingles)) continue;
      if (!seenIds.add(v.id.value)) continue;
      final key =
          '${_cleanTitle(v.title).toLowerCase()}::${_cleanAuthor(v.author).toLowerCase()}';
      if (!seenTracks.add(key)) continue;
      out.add(v);
      if (out.length >= limit) break;
    }
    return out;
  }

  String _trackFeaturesCacheKey({
    required String title,
    required String author,
    String videoId = '',
  }) {
    final idKey = videoId.trim().toLowerCase();
    if (idKey.isNotEmpty) return 'id:$idKey';

    final normalizedTitle = _normalizeSignalKey(_cleanTitle(title));
    final authorKey = _primaryArtistKey(author);
    final trackKey = [normalizedTitle, authorKey]
        .where((part) => part.isNotEmpty)
        .join('::');
    if (trackKey.isNotEmpty) return 'track:$trackKey';
    return 'text:${_normalizeSignalKey('$title $author')}';
  }

  _TrackFeatures _trackFeaturesForParts({
    required String title,
    required String author,
    String videoId = '',
  }) {
    final cacheKey = _trackFeaturesCacheKey(
      title: title,
      author: author,
      videoId: videoId,
    );
    final cached = _trackFeaturesCache[cacheKey];
    if (cached != null) return cached;

    final cleanTitle = _cleanTitle(title).trim();
    final cleanAuthor = _cleanAuthor(author).trim();
    final text = '$cleanTitle $cleanAuthor'.toLowerCase().trim();
    final normalizedTitle = _normalizeSignalKey(cleanTitle);
    final authorKey = _primaryArtistKey(cleanAuthor);
    final tags = _extractMusicTags(text);
    final features = _TrackFeatures(
      idKey: videoId.trim().toLowerCase(),
      title: cleanTitle,
      author: cleanAuthor,
      text: text,
      normalizedTitle: normalizedTitle,
      authorKey: authorKey,
      language: _detectLanguageTag(text),
      tags: tags,
      tokens: _tokenizeSearchText(
        '$cleanTitle $cleanAuthor',
        dropCommonWords: true,
      ),
      mood: _primaryMoodTag(tags),
      trackKey: [normalizedTitle, authorKey]
          .where((part) => part.isNotEmpty)
          .join('::'),
    );
    _trackFeaturesCache[cacheKey] = features;
    return features;
  }

  _TrackFeatures _trackFeaturesForVideo(Video video) {
    return _trackFeaturesForParts(
      title: video.title,
      author: video.author,
      videoId: video.id.value,
    );
  }

  _TrackFeatures? _trackFeaturesFromLogEntry(
    Map<String, dynamic> entry, {
    bool strictSingles = true,
  }) {
    final title = (entry['title'] as String? ?? '').trim();
    final artist = (entry['artist'] as String? ?? '').trim();
    if (title.isEmpty && artist.isEmpty) return null;
    if (!_looksLikeMusic(title, artist, strictSingles: strictSingles)) {
      return null;
    }
    return _trackFeaturesForParts(
      title: title,
      author: artist,
      videoId: (entry['videoId'] as String? ?? '').trim(),
    );
  }

  bool _isBlockedTrackFeatures(_TrackFeatures features) {
    if (features.idKey.isNotEmpty &&
        _blockedVideoIds.contains(features.idKey)) {
      return true;
    }
    return features.authorKey.isNotEmpty &&
        _blockedArtistKeys.contains(features.authorKey);
  }

  bool _isBlockedArtist(String artistName) {
    final key = _primaryArtistKey(artistName);
    return key.isNotEmpty && _blockedArtistKeys.contains(key);
  }

  bool _isRecommendationBlocked(Video? video) {
    if (video == null) return false;
    return _isBlockedTrackFeatures(_trackFeaturesForVideo(video));
  }

  List<Video> _filterBlockedRecommendations(
    Iterable<Video> source, {
    int? limit,
  }) {
    final out = <Video>[];
    for (final video in source) {
      if (_isRecommendationBlocked(video)) continue;
      out.add(video);
      if (limit != null && out.length >= limit) break;
    }
    return out;
  }

  void _pruneBlockedRecommendationsFromState() {
    final currentId = _nowPlaying?.id.value;

    setState(() {
      _quickRow1 = _filterBlockedRecommendations(_quickRow1);
      _newReleases = _filterBlockedRecommendations(_newReleases);
      _hindiHits = _filterBlockedRecommendations(_hindiHits);
      _moodChill = _filterBlockedRecommendations(_moodChill);
      _exploreResults = _filterBlockedRecommendations(_exploreResults);
      _trendingVideos = _filterBlockedRecommendations(_trendingVideos);
      _becauseYouLiked = _filterBlockedRecommendations(_becauseYouLiked);
      _relatedArtists =
          _relatedArtists.where((artist) => !_isBlockedArtist(artist)).toList();
      _playQueue = _playQueue
          .where((video) =>
              video.id.value == currentId || !_isRecommendationBlocked(video))
          .toList();
      for (final mix in _dailyMixes) {
        final filtered =
            _filterBlockedRecommendations(List<Video>.from(mix.videos));
        mix.videos
          ..clear()
          ..addAll(filtered);
      }
    });
  }

  void _refreshRecommendationsAfterBlockChange() {
    _pruneBlockedRecommendationsFromState();
    _scheduleSave();
    if (_nowPlaying != null) {
      _updateRelatedArtists();
      if (_radioMode) {
        _seedUpcomingFromLocalTaste(_nowPlaying!, minUpcoming: 6);
      }
    }
    if (_likedPlaylist.videos.isNotEmpty || _ytLikedVideos.isNotEmpty) {
      unawaited(_loadBecauseYouLiked());
    }
    if (!_homeLoading) _maybeReloadHomeAuto();
  }

  void _toggleNotInterested(Video video) {
    final idKey = video.id.value.toLowerCase();
    final wasBlocked = _blockedVideoIds.contains(idKey);

    setState(() {
      if (wasBlocked) {
        _blockedVideoIds.remove(idKey);
      } else {
        _blockedVideoIds.add(idKey);
        _speedDialPins.removeWhere((v) => v.id.value == video.id.value);
      }
    });

    _bumpSignal(
      _videoActionBoost,
      idKey,
      wasBlocked ? 5.2 : -8.5,
      min: -18.0,
      max: 22.0,
    );
    _registerFeedback(
      video,
      weight: wasBlocked ? 1.2 : -3.2,
      source: wasBlocked ? 'allow_track' : 'not_interested',
    );
    _refreshRecommendationsAfterBlockChange();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          wasBlocked
              ? 'Song allowed again in recommendations'
              : 'Song hidden from recommendations',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _toggleBlockedArtist(String artistName, {Video? sampleVideo}) {
    final artistKey = _primaryArtistKey(artistName);
    if (artistKey.isEmpty) return;
    final wasBlocked = _blockedArtistKeys.contains(artistKey);

    setState(() {
      if (wasBlocked) {
        _blockedArtistKeys.remove(artistKey);
      } else {
        _blockedArtistKeys.add(artistKey);
        _speedDialPins.removeWhere(
          (v) => _primaryArtistKey(v.author) == artistKey,
        );
      }
    });

    _bumpSignal(
      _artistActionBoost,
      artistKey,
      wasBlocked ? 6.5 : -12.0,
      min: -22.0,
      max: 26.0,
    );
    if (sampleVideo != null) {
      _registerFeedback(
        sampleVideo,
        weight: wasBlocked ? 1.4 : -3.8,
        source: wasBlocked ? 'allow_artist' : 'block_artist',
      );
    }
    _refreshRecommendationsAfterBlockChange();

    if (!mounted) return;
    final cleanArtist = _cleanAuthor(artistName);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          wasBlocked
              ? '$cleanArtist allowed again in recommendations'
              : '$cleanArtist hidden from recommendations',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _detectLanguageTag(String text) {
    final t = text.toLowerCase();
    if (t.contains('punjabi') || t.contains('diljit') || t.contains('sidhu')) {
      return 'punjabi';
    }
    if (t.contains('hindi') ||
        t.contains('bollywood') ||
        t.contains('arijit') ||
        t.contains('yaar') ||
        t.contains('dil')) {
      return 'hindi';
    }
    if (t.contains('tamil') ||
        t.contains('kollywood') ||
        t.contains('anirudh')) {
      return 'tamil';
    }
    if (t.contains('telugu') ||
        t.contains('tollywood') ||
        t.contains('sid sriram')) {
      return 'telugu';
    }
    if (t.contains('kpop') ||
        t.contains('k-pop') ||
        t.contains('bts') ||
        t.contains('blackpink')) {
      return 'kpop';
    }
    return 'english';
  }

  Set<String> _extractMusicTags(String text) {
    final t = text.toLowerCase();
    final tags = <String>{};
    const checks = <String, List<String>>{
      'lofi': ['lofi', 'lo-fi', 'study'],
      'chill': ['chill', 'relax', 'calm', 'mellow', 'soft'],
      'sad': ['sad', 'breakup', 'heartbreak', 'cry', 'dard'],
      'happy': ['happy', 'party', 'upbeat', 'dance'],
      'romantic': [
        'love',
        'romantic',
        'dil',
        'ishq',
        'pyaar',
        'mohabbat',
        'husn',
        'baarishein',
        'sajni',
        'riha',
        'jain',
        'prateek kuhad',
        'aditya rikhari'
      ],
      'workout': ['workout', 'gym', 'run', 'energy'],
      'hip-hop': [
        'hip hop',
        'hip-hop',
        'rap',
        'trap',
        'kr\$na',
        'krsna',
        'emiway',
        'bantai',
        'raftaar',
        'divine',
        'karma',
        'seedhe maut',
        'mc stan',
        'ikka',
        'bella'
      ],
      'edm': ['edm', 'electronic', 'house', 'techno'],
      'pop': ['pop'],
      'indie': [
        'indie',
        'bedroom pop',
        'anuv jain',
        'prateek kuhad',
        'aditya rikhari',
        'jasleen royal'
      ],
      'acoustic': [
        'acoustic',
        'unplugged',
        'ukulele',
        'guitar',
        'piano version',
        'anuv jain',
        'prateek kuhad',
        'aditya rikhari'
      ],
      'rock': ['rock', 'metal', 'guitar'],
      'r&b': ['r&b', 'rnb', 'soul'],
      'classical': ['classical', 'orchestra'],
      'folk': ['folk', 'sufi', 'acoustic'],
      'kpop': ['kpop', 'k-pop'],
      'hindi': ['hindi', 'bollywood'],
      'punjabi': ['punjabi', 'bhangra'],
      'tamil': ['tamil', 'kollywood'],
      'telugu': ['telugu', 'tollywood'],
    };
    for (final entry in checks.entries) {
      for (final kw in entry.value) {
        if (t.contains(kw)) {
          tags.add(entry.key);
          break;
        }
      }
    }
    return tags;
  }

  String? _primaryMoodTag(Set<String> tags) {
    const priority = <String>[
      'romantic',
      'acoustic',
      'indie',
      'sad',
      'chill',
      'lofi',
      'happy',
      'workout',
      'hip-hop',
      'edm',
      'folk',
      'pop',
      'rock',
      'classical',
    ];
    for (final tag in priority) {
      if (tags.contains(tag)) return tag;
    }
    if (tags.isEmpty) return null;
    return tags.first;
  }

  double _vibeClashPenalty(
    Set<String> seedTags,
    Set<String> candTags, {
    bool strict = false,
  }) {
    const softVibes = <String>{
      'romantic',
      'sad',
      'chill',
      'lofi',
      'indie',
      'acoustic',
      'folk',
    };
    const hardVibes = <String>{
      'hip-hop',
      'workout',
      'edm',
      'happy',
    };

    final seedSoft = seedTags.any(softVibes.contains);
    final seedHard = seedTags.any(hardVibes.contains);
    final candSoft = candTags.any(softVibes.contains);
    final candHard = candTags.any(hardVibes.contains);

    double penalty = 0.0;
    if (seedSoft && candHard) penalty += strict ? 4.6 : 2.8;
    if (seedHard && candSoft) penalty += strict ? 3.3 : 1.9;
    if (seedTags.contains('acoustic') && candTags.contains('hip-hop')) {
      penalty += strict ? 2.6 : 1.4;
    }
    if (seedTags.contains('romantic') && candTags.contains('workout')) {
      penalty += strict ? 2.4 : 1.2;
    }
    return penalty;
  }

  bool _looksOfficialMusicChannel(String author) {
    final a = author.toLowerCase();
    return a.contains('topic') ||
        a.contains('records') ||
        a.contains('vevo') ||
        a.contains('official');
  }

  String _primaryArtistKey(String author) {
    final a = _cleanAuthor(author).toLowerCase();
    final seps = [' & ', ' and ', ' x ', ',', '/', '|', ' ft.', ' feat.'];
    for (final s in seps) {
      final i = a.indexOf(s);
      if (i > 0) {
        return a.substring(0, i).trim();
      }
    }
    return a.trim();
  }

  String _normalizeSignalKey(String input) {
    return input
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s_&-]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _squashRepeatedChars(String token) {
    return token.replaceAllMapped(
      RegExp(r'([a-z])\1{1,}'),
      (m) => m.group(1) ?? '',
    );
  }

  String _softNormalizeSearchText(String input) {
    final normalized = _normalizeSignalKey(input);
    if (normalized.isEmpty) return '';
    return normalized
        .split(' ')
        .where((w) => w.isNotEmpty)
        .map(_squashRepeatedChars)
        .where((w) => w.isNotEmpty)
        .join(' ')
        .trim();
  }

  List<String> _tokenizeSearchText(
    String input, {
    bool dropCommonWords = false,
  }) {
    final normalized = _normalizeSignalKey(input);
    if (normalized.isEmpty) return const <String>[];
    return normalized
        .split(' ')
        .where(
          (w) => w.length >= 2 && (!dropCommonWords || !_isCommonQueryWord(w)),
        )
        .toList();
  }

  int _boundedLevenshtein(
    String a,
    String b, {
    int maxDistance = 2,
  }) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    if ((a.length - b.length).abs() > maxDistance) return maxDistance + 1;

    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (int i = 0; i < a.length; i++) {
      final curr = List<int>.filled(b.length + 1, 0);
      curr[0] = i + 1;
      int rowMin = curr[0];
      for (int j = 0; j < b.length; j++) {
        final cost = a.codeUnitAt(i) == b.codeUnitAt(j) ? 0 : 1;
        curr[j + 1] = min(
          min(curr[j] + 1, prev[j + 1] + 1),
          prev[j] + cost,
        );
        if (curr[j + 1] < rowMin) rowMin = curr[j + 1];
      }
      if (rowMin > maxDistance) return maxDistance + 1;
      prev = curr;
    }
    return prev.last;
  }

  double _fuzzyTokenOverlapScore(
    List<String> queryTokens,
    List<String> candidateTokens,
  ) {
    if (queryTokens.isEmpty || candidateTokens.isEmpty) return 0.0;

    double score = 0.0;
    for (final qt in queryTokens.take(6)) {
      if (candidateTokens.contains(qt)) {
        score += 1.8;
        continue;
      }

      final hasPrefix =
          candidateTokens.any((ct) => ct.startsWith(qt) || qt.startsWith(ct));
      if (hasPrefix) {
        score += 1.05;
        continue;
      }

      final maxDist = qt.length >= 7 ? 2 : 1;
      int bestDist = 9;
      for (final ct in candidateTokens) {
        if ((ct.length - qt.length).abs() > maxDist) continue;
        final d = _boundedLevenshtein(qt, ct, maxDistance: maxDist);
        if (d < bestDist) bestDist = d;
        if (bestDist == 0) break;
      }
      if (bestDist <= maxDist) {
        score += bestDist == 1 ? 0.75 : 0.42;
      }
    }
    return score;
  }

  Map<String, double> _buildSearchLexicon({int maxWords = 1400}) {
    final weights = <String, double>{};

    void addText(String text, double weight) {
      if (weight <= 0) return;
      for (final token
          in _tokenizeSearchText(text, dropCommonWords: true).take(8)) {
        weights[token] = (weights[token] ?? 0.0) + weight;
      }
    }

    final queryEntries = _queryActionBoost.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final entry in queryEntries.take(140)) {
      addText(entry.key, 1.8 + entry.value.abs() * 0.6);
    }

    for (int i = 0; i < _history.length && i < 220; i++) {
      final v = _history[i];
      final recencyBoost = max(0.4, 1.6 - (i * 0.004));
      addText(_cleanTitle(v.title), recencyBoost);
      addText(_cleanAuthor(v.author), recencyBoost * 0.75);
    }

    for (int i = 0; i < _likedPlaylist.videos.length && i < 180; i++) {
      final v = _likedPlaylist.videos[i];
      addText(_cleanTitle(v.title), 1.15);
      addText(_cleanAuthor(v.author), 0.95);
    }

    for (int i = 0; i < _ytLikedVideos.length && i < 180; i++) {
      final v = _ytLikedVideos[i];
      addText(_cleanTitle(v.title), 1.25);
      addText(_cleanAuthor(v.author), 1.0);
    }

    if (weights.length <= maxWords) return weights;
    final sorted = weights.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Map<String, double>.fromEntries(sorted.take(maxWords));
  }

  String? _correctSearchQuery(String query) {
    final normalized = _normalizeSignalKey(query);
    if (normalized.isEmpty) return null;

    final tokens = normalized.split(' ').where((w) => w.isNotEmpty).toList();
    if (tokens.isEmpty || tokens.length > 8) return null;

    final lexicon = _buildSearchLexicon();
    if (lexicon.isEmpty) return null;

    final corrected = <String>[];
    bool changed = false;

    for (final token in tokens) {
      if (token.length < 4 ||
          _isCommonQueryWord(token) ||
          lexicon.containsKey(token)) {
        corrected.add(token);
        continue;
      }

      final maxDist = token.length >= 7 ? 2 : 1;
      final tokenSoft = _squashRepeatedChars(token);
      String best = token;
      double bestScore = -1e9;

      for (final entry in lexicon.entries) {
        final candidate = entry.key;
        final candidateSoft = _squashRepeatedChars(candidate);
        final lenDiff = (candidate.length - token.length).abs();
        if (lenDiff > maxDist) continue;
        if (candidate.isEmpty) continue;
        if (candidate.codeUnitAt(0) != token.codeUnitAt(0) &&
            token.length <= 5) {
          continue;
        }

        final strictDist =
            _boundedLevenshtein(token, candidate, maxDistance: maxDist);
        final softDist = _boundedLevenshtein(
          tokenSoft,
          candidateSoft,
          maxDistance: maxDist + 1,
        );
        final dist = min(strictDist, softDist);
        if (dist > maxDist) continue;

        final score = entry.value - (dist * 2.1) - (lenDiff * 0.5);
        if (score > bestScore) {
          bestScore = score;
          best = candidate;
        }
      }

      if (best != token) changed = true;
      corrected.add(best);
    }

    final out = corrected.join(' ').trim();
    if (!changed || out.isEmpty || out == normalized) return null;
    return out;
  }

  List<String> _buildSearchSuggestions(String rawInput, {int limit = 8}) {
    final query = rawInput.trim();
    final qNorm = _normalizeSignalKey(query);
    final qTokens = _tokenizeSearchText(query, dropCommonWords: true);

    final scoreByKey = <String, double>{};
    final labelByKey = <String, String>{};

    void addCandidate(String label, double baseScore) {
      final clean = label.trim();
      if (clean.isEmpty) return;
      final key = _normalizeSignalKey(clean);
      if (key.isEmpty) return;

      double score = baseScore;
      if (qNorm.isNotEmpty) {
        if (key == qNorm) {
          score += 14.0;
        } else if (key.startsWith(qNorm)) {
          score += 8.0;
        } else if (key.contains(qNorm)) {
          score += 5.0;
        } else {
          final candidateTokens =
              _tokenizeSearchText(clean, dropCommonWords: true);
          final fuzzy = _fuzzyTokenOverlapScore(qTokens, candidateTokens);
          if (fuzzy <= 0) return;
          score += fuzzy;
        }
      }

      final prev = scoreByKey[key];
      if (prev == null || score > prev) {
        scoreByKey[key] = score;
        labelByKey[key] = clean;
      }
    }

    final boostedQueries = _queryActionBoost.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final entry in boostedQueries.take(70)) {
      if (entry.value <= -0.2) continue;
      addCandidate(entry.key, 6.4 + (entry.value * 0.55));
    }

    final boostedArtists = _artistActionBoost.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final entry in boostedArtists.take(42)) {
      if (entry.value <= 0.2) continue;
      addCandidate(_cleanAuthor(entry.key), 4.3 + (entry.value * 0.42));
    }

    for (int i = 0; i < _history.length && i < 140; i++) {
      final v = _history[i];
      final recencyBoost = max(0.2, 5.0 - (i * 0.03));
      addCandidate(
          '${_cleanTitle(v.title)} ${_cleanAuthor(v.author)}', recencyBoost);
      addCandidate(_cleanTitle(v.title), recencyBoost - 0.4);
      addCandidate(_cleanAuthor(v.author), recencyBoost - 1.0);
    }

    for (int i = 0; i < _likedPlaylist.videos.length && i < 90; i++) {
      final v = _likedPlaylist.videos[i];
      addCandidate('${_cleanTitle(v.title)} ${_cleanAuthor(v.author)}', 3.6);
      addCandidate(_cleanAuthor(v.author), 2.8);
    }

    for (int i = 0; i < _ytLikedVideos.length && i < 90; i++) {
      final v = _ytLikedVideos[i];
      addCandidate('${_cleanTitle(v.title)} ${_cleanAuthor(v.author)}', 3.8);
      addCandidate(_cleanAuthor(v.author), 2.9);
    }

    for (final chip in _moodChips) {
      addCandidate(chip['label']!, 2.2);
      addCandidate(chip['query']!, 2.0);
    }
    if (qNorm.isEmpty) {
      for (final h in _searchHistory) {
        addCandidate(h, 9.8);
      }
    } else {
      for (final h in _searchHistory) {
        addCandidate(h, 4.6);
      }
    }

    final corrected = _correctSearchQuery(query);
    if (corrected != null && corrected != qNorm) {
      addCandidate(corrected, 11.0);
    }

    if (qNorm.isNotEmpty && !_hasMusicIntentSignal(qNorm)) {
      addCandidate('$query song', 3.1);
      addCandidate('$query official audio', 2.8);
    }

    final sorted = scoreByKey.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final out = <String>[];
    for (final entry in sorted) {
      if (qNorm.isNotEmpty && entry.key == qNorm) continue;
      final label = labelByKey[entry.key] ?? entry.key;
      if (label.length < 2) continue;
      out.add(label);
      if (out.length >= limit) break;
    }
    return out;
  }

  bool _isCommonQueryWord(String word) {
    const common = <String>{
      'a',
      'an',
      'the',
      'song',
      'songs',
      'music',
      'official',
      'audio',
      'video',
      'lyrics',
      'lyric',
      'radio',
      'mix',
      'playlist',
      'best',
      'top',
      'latest',
      'new',
      'full',
      'album',
      'and',
      'or',
      'of',
      'for',
      'to',
      'in',
      'on',
    };
    return common.contains(word);
  }

  void _bumpSignal(
    Map<String, double> map,
    String key,
    double delta, {
    double min = -14.0,
    double max = 26.0,
  }) {
    if (delta == 0) return;
    final k = _normalizeSignalKey(key);
    if (k.isEmpty) return;
    final next = ((map[k] ?? 0.0) + delta).clamp(min, max).toDouble();
    if (next.abs() < 0.03) {
      map.remove(k);
    } else {
      map[k] = next;
    }
  }

  void _trimSignalMap(Map<String, double> map, {int maxEntries = 260}) {
    if (map.length <= maxEntries) return;
    final sorted = map.entries.toList()
      ..sort((a, b) => b.value.abs().compareTo(a.value.abs()));
    map
      ..clear()
      ..addEntries(sorted.take(maxEntries));
  }

  void _bumpNestedSignal(
    Map<String, Map<String, double>> map,
    String sourceKey,
    String targetKey,
    double delta, {
    double min = 0.0,
    double max = 18.0,
  }) {
    if (delta == 0) return;
    final source = _normalizeSignalKey(sourceKey);
    final target = _normalizeSignalKey(targetKey);
    if (source.isEmpty || target.isEmpty) return;

    final bucket = map.putIfAbsent(source, () => <String, double>{});
    final next = ((bucket[target] ?? 0.0) + delta).clamp(min, max).toDouble();
    if (next < 0.03) {
      bucket.remove(target);
    } else {
      bucket[target] = next;
    }
    if (bucket.isEmpty) map.remove(source);
  }

  void _trimNestedSignalMap(
    Map<String, Map<String, double>> map, {
    int maxParents = 160,
    int maxChildren = 8,
  }) {
    if (map.isEmpty) return;

    final parentEntries = map.entries.toList()
      ..sort((a, b) {
        final aWeight =
            a.value.values.fold<double>(0.0, (sum, v) => sum + v.abs());
        final bWeight =
            b.value.values.fold<double>(0.0, (sum, v) => sum + v.abs());
        return bWeight.compareTo(aWeight);
      });

    map.clear();
    for (final entry in parentEntries.take(maxParents)) {
      final trimmedChildren = entry.value.entries.toList()
        ..sort((a, b) => b.value.abs().compareTo(a.value.abs()));
      map[entry.key] = {
        for (final child in trimmedChildren.take(maxChildren))
          child.key: child.value,
      };
    }
  }

  Map<String, Map<String, double>> _nestedSignalMap(dynamic raw) {
    if (raw is! Map) return const <String, Map<String, double>>{};
    final out = <String, Map<String, double>>{};
    for (final entry in raw.entries) {
      final source = _normalizeSignalKey((entry.key ?? '').toString());
      if (source.isEmpty || entry.value is! Map) continue;
      final bucket = <String, double>{};
      for (final child in (entry.value as Map).entries) {
        final target = _normalizeSignalKey((child.key ?? '').toString());
        if (target.isEmpty) continue;
        final value = child.value;
        final parsed = value is num
            ? value.toDouble()
            : double.tryParse(value?.toString() ?? '');
        if (parsed == null || parsed.isNaN || parsed.isInfinite) continue;
        bucket[target] = parsed;
      }
      if (bucket.isNotEmpty) out[source] = bucket;
    }
    return out;
  }

  void _registerSearchFeedback(String query, {double weight = 0.6}) {
    final q = _normalizeSignalKey(query);
    if (q.isEmpty) return;

    _bumpSignal(_queryActionBoost, q, weight, min: -8.0, max: 20.0);

    final tags = _extractMusicTags(q);
    if (tags.isNotEmpty) {
      final perTag = (weight * 0.9) / tags.length;
      for (final t in tags) {
        _bumpSignal(_genreActionBoost, t, perTag);
      }
    }

    final lang = _detectLanguageTag(q);
    _bumpSignal(_langActionBoost, lang, weight * 0.65);

    _trimSignalMap(_queryActionBoost, maxEntries: 320);
    _trimSignalMap(_artistActionBoost);
    _trimSignalMap(_genreActionBoost);
    _trimSignalMap(_langActionBoost, maxEntries: 32);
    _scheduleSave();
  }

  void _registerFeedback(
    Video video, {
    required double weight,
    String source = 'generic',
  }) {
    if (weight == 0) return;
    _sessionStartAt ??= DateTime.now();
    if (weight > 0) _sessionPositiveEvents++;
    final sourceKey = source.toLowerCase();
    final isManualSkip =
        sourceKey == 'manual_skip_early' || sourceKey == 'manual_skip_mid';
    final isTrackOnlyNegative = weight < 0 &&
        (isManualSkip ||
            sourceKey == 'queue_remove' ||
            sourceKey == 'clear_next');
    final applyLongTermTaste = !isTrackOnlyNegative;
    final text = '${video.title} ${video.author}'.toLowerCase();
    final artistKey = _primaryArtistKey(video.author);
    if (applyLongTermTaste && artistKey.isNotEmpty) {
      _bumpSignal(_artistActionBoost, artistKey, weight * 1.15);
    }

    final tags = _extractMusicTags(text);
    if (applyLongTermTaste && tags.isNotEmpty) {
      final perTag = (weight * 0.85) / tags.length;
      for (final t in tags) {
        _bumpSignal(_genreActionBoost, t, perTag);
      }
    }

    final lang = _detectLanguageTag(text);
    if (applyLongTermTaste) {
      _bumpSignal(_langActionBoost, lang, weight * 0.75);
    }

    _bumpSignal(
      _videoActionBoost,
      video.id.value.toLowerCase(),
      weight * (isTrackOnlyNegative ? 1.05 : 1.35),
      min: -12.0,
      max: 22.0,
    );

    if (applyLongTermTaste && weight > 0) {
      final q = _normalizeSignalKey(
        '${_cleanTitle(video.title)} ${_cleanAuthor(video.author)}',
      );
      if (q.isNotEmpty) {
        _bumpSignal(_queryActionBoost, q, weight * 0.18, min: -8.0, max: 20.0);
      }
    }

    if (sourceKey == 'queue_remove' || sourceKey == 'clear_next') {
      _bumpSignal(
          _videoActionBoost, video.id.value.toLowerCase(), weight * 0.4);
    }

    _trimSignalMap(_artistActionBoost);
    _trimSignalMap(_genreActionBoost);
    _trimSignalMap(_langActionBoost, maxEntries: 32);
    _trimSignalMap(_queryActionBoost, maxEntries: 320);
    _trimSignalMap(_videoActionBoost, maxEntries: 500);
    _scheduleSave();
  }

  void _maybeConsolidateSessionTaste() {
    final start = _sessionStartAt ?? DateTime.now();
    final elapsed = DateTime.now().difference(start).inMinutes;
    if (_sessionPositiveEvents < 5 && elapsed < 20) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final windowMs = const Duration(minutes: 75).inMilliseconds;
    final artistScore = <String, double>{};
    final tagScore = <String, double>{};
    final langScore = <String, double>{};
    for (final e in _listeningLogs) {
      final endAt = (e['endedAtMs'] as num?)?.toInt() ?? 0;
      if (endAt <= 0 || nowMs - endAt > windowMs) continue;
      final completion = ((e['completionRatio'] as num?)?.toDouble() ?? 0.0);
      if (completion < 0.5) continue;
      final artistKey =
          _primaryArtistKey((e['artist'] as String? ?? '').trim());
      final title = (e['title'] as String? ?? '').trim();
      final text = '$title ${e['artist'] ?? ''}'.toLowerCase();
      final tags = _extractMusicTags(text);
      final lang = _detectLanguageTag(text);
      if (artistKey.isNotEmpty) {
        artistScore[artistKey] =
            (artistScore[artistKey] ?? 0.0) + (0.6 + completion);
      }
      for (final t in tags) {
        tagScore[t] = (tagScore[t] ?? 0.0) + (0.45 + completion * 0.5);
      }
      langScore[lang] = (langScore[lang] ?? 0.0) + (0.35 + completion * 0.4);
    }
    final topArtists = artistScore.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topTags = tagScore.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topLangs = langScore.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in topArtists.take(3)) {
      _bumpSignal(_artistActionBoost, e.key, 0.35);
    }
    for (final e in topTags.take(4)) {
      _bumpSignal(_genreActionBoost, e.key, 0.22);
    }
    for (final e in topLangs.take(1)) {
      _bumpSignal(_langActionBoost, e.key, 0.18);
    }
    _trimSignalMap(_artistActionBoost);
    _trimSignalMap(_genreActionBoost);
    _trimSignalMap(_langActionBoost, maxEntries: 32);
    _sessionPositiveEvents = 0;
    _sessionStartAt = DateTime.now();
    _scheduleSave();
  }

  double _queryAffinityForText(String text) {
    if (_queryActionBoost.isEmpty) return 0.0;
    final normalized = _normalizeSignalKey(text);
    if (normalized.isEmpty) return 0.0;

    double score = 0.0;
    final entries = _queryActionBoost.entries.toList()
      ..sort((a, b) => b.value.abs().compareTo(a.value.abs()));
    for (final entry in entries.take(20)) {
      final terms = entry.key
          .split(' ')
          .where((w) => w.length >= 3 && !_isCommonQueryWord(w))
          .take(5)
          .toList();
      if (terms.isEmpty) continue;
      int hits = 0;
      for (final term in terms) {
        if (normalized.contains(term)) hits++;
      }
      if (hits == 0) continue;
      score += entry.value * (hits / terms.length);
    }
    return score.clamp(-5.0, 8.0).toDouble();
  }

  double _behaviorTasteConfidence() {
    double positive = 0.0;
    for (final v in _artistActionBoost.values) {
      if (v > 0) positive += v;
    }
    for (final v in _genreActionBoost.values) {
      if (v > 0) positive += v;
    }
    for (final v in _langActionBoost.values) {
      if (v > 0) positive += v;
    }
    return (positive / 70.0).clamp(0.0, 1.0).toDouble();
  }

  Map<String, double> _toDoubleMap(
    dynamic raw, {
    int maxEntries = 400,
  }) {
    final out = <String, double>{};
    if (raw is! Map) return out;
    for (final entry in raw.entries) {
      final key = (entry.key ?? '').toString().trim();
      if (key.isEmpty) continue;
      final value = entry.value;
      double? parsed;
      if (value is num) {
        parsed = value.toDouble();
      } else {
        parsed = double.tryParse(value?.toString() ?? '');
      }
      if (parsed == null || parsed.isNaN || parsed.isInfinite) continue;
      out[_normalizeSignalKey(key)] = parsed;
    }
    _trimSignalMap(out, maxEntries: maxEntries);
    return out;
  }

  String _sceneDiscoveryQuery(String language, Set<String> tags) {
    if (tags.contains('hip-hop')) {
      switch (language) {
        case 'hindi':
          return 'hindi hip hop rap songs official audio';
        case 'punjabi':
          return 'punjabi hip hop rap songs official audio';
        default:
          return 'desi hip hop rap songs official audio';
      }
    }
    if (tags.contains('romantic')) {
      return '$language romantic songs official audio';
    }
    if (tags.contains('sad')) {
      return '$language emotional songs official audio';
    }
    if (tags.contains('acoustic') || tags.contains('indie')) {
      return '$language indie acoustic songs official audio';
    }
    if (tags.contains('edm')) {
      return '$language electronic dance songs official audio';
    }
    if (tags.contains('lofi') || tags.contains('chill')) {
      return '$language chill lofi songs official audio';
    }
    return '$language trending songs official audio';
  }

  double _radioRelevanceScore(
    Video seed,
    Video candidate,
    Map<String, dynamic> profile,
  ) {
    if (_isRecommendationBlocked(candidate)) return -999.0;
    final seedArtist = _primaryArtistKey(seed.author);
    final candArtist = _primaryArtistKey(candidate.author);
    final candIdKey = candidate.id.value.toLowerCase();
    final seedText = '${seed.title} ${seed.author}'.toLowerCase();
    final candText = '${candidate.title} ${candidate.author}'.toLowerCase();
    final seedTags = _extractMusicTags(seedText);
    final candTags = _extractMusicTags(candText);
    final topArtists = (profile['topArtists'] as List<String>? ?? [])
        .map(_primaryArtistKey)
        .toSet();
    final topGenres = (profile['topGenres'] as List<String>? ?? []).toSet();
    final artistAffinity = (profile['artistAffinity'] as Map<String, int>?) ??
        const <String, int>{};
    final genreAffinity = (profile['genreAffinity'] as Map<String, int>?) ??
        const <String, int>{};
    final langAffinity =
        (profile['langAffinity'] as Map<String, int>?) ?? const <String, int>{};
    final logArtistBoost =
        (profile['logArtistBoost'] as Map<String, double>?) ??
            const <String, double>{};
    final recentArtistBoost =
        (profile['recentArtistBoost'] as Map<String, double>?) ??
            const <String, double>{};
    final logVideoBoost = (profile['logVideoBoost'] as Map<String, double>?) ??
        const <String, double>{};
    final logGenreBoost = (profile['logGenreBoost'] as Map<String, double>?) ??
        const <String, double>{};
    final hourGenreBoost =
        (profile['hourGenreBoost'] as Map<String, double>?) ??
            const <String, double>{};
    final logLangBoost = (profile['logLangBoost'] as Map<String, double>?) ??
        const <String, double>{};
    final skipVideoPenalty =
        (profile['skipVideoPenalty'] as Map<String, double>?) ??
            const <String, double>{};
    final skipArtistPenalty =
        (profile['skipArtistPenalty'] as Map<String, double>?) ??
            const <String, double>{};
    final recentPlayCount = (profile['recentPlayCount'] as Map<String, int>?) ??
        const <String, int>{};
    final ytLikedIds =
        (profile['ytLikedIds'] as Set<String>?) ?? const <String>{};
    final seedLanguage = _detectLanguageTag(seedText);
    final candLanguage = _detectLanguageTag(candText);
    final overlapWithSeed = candTags.where(seedTags.contains).length;
    final overlapWithTaste = candTags.where(topGenres.contains).length;
    final topLanguage = profile['topLanguage'] as String? ?? seedLanguage;
    final topLanguageCount = langAffinity[topLanguage] ?? 0;
    final candLanguageCount = langAffinity[candLanguage] ?? 0;
    final artistCount = artistAffinity[candArtist] ?? 0;
    final totalSongs = (profile['totalSongs'] as int?) ?? 1;
    final artistAction = _artistActionBoost[candArtist] ?? 0.0;
    final langAction = _langActionBoost[candLanguage] ?? 0.0;
    final videoAction = _videoActionBoost[candIdKey] ?? 0.0;
    final queryAction = _queryAffinityForText(candText);
    final repeatCount = recentPlayCount[candIdKey] ?? 0;
    final contextAffinity =
        _contextualSeedAffinity(seed, candidate, profile, strict: true);
    final transitionAffinity =
        _transitionAffinityScore(seed, candidate, profile, strict: true);
    final qualityText =
        '${_cleanTitle(candidate.title)} ${_cleanAuthor(candidate.author)}';
    final candDuration = candidate.duration;
    final durationFriendly =
        _isDurationMusicFriendly(candDuration, strictSingles: true);
    final exposurePenalty = _quickPickExposurePenalty[candIdKey] ?? 0.0;
    final seedTokens = _tokenizeSearchText(
      '${_cleanTitle(seed.title)} ${_cleanAuthor(seed.author)}',
      dropCommonWords: true,
    );
    final candTokens = _tokenizeSearchText(
      '${_cleanTitle(candidate.title)} ${_cleanAuthor(candidate.author)}',
      dropCommonWords: true,
    );
    final tokenSimilarity = _fuzzyTokenOverlapScore(seedTokens, candTokens);

    double score = 0.0;
    score += contextAffinity * 2.1;
    score += transitionAffinity * 1.55;
    score += tokenSimilarity * 0.95;
    if (candArtist == seedArtist) score += 1.1;
    if (topArtists.contains(candArtist)) score += 3.2;
    score += (artistCount / totalSongs) * 22.0;

    if (candLanguage == seedLanguage) score += 2.4;
    if (candLanguage == topLanguage) score += 2.2;
    if (candLanguage != seedLanguage && candLanguage != topLanguage) {
      score -= 3.4;
      if (candLanguageCount == 0 && topLanguageCount > 0) score -= 1.3;
    }

    score += overlapWithSeed * 2.1;
    score += overlapWithTaste * 1.4;
    for (final t in candTags) {
      score += (genreAffinity[t] ?? 0) * 0.04;
      score += (_genreActionBoost[t] ?? 0.0) * 0.24;
    }
    score += artistAction * 1.9;
    score += langAction * 1.2;
    score += videoAction * 1.6;
    score += (logArtistBoost[candArtist] ?? 0.0) * 1.35;
    score += (recentArtistBoost[candArtist] ?? 0.0) * 1.55;
    score += (logVideoBoost[candIdKey] ?? 0.0) * 1.1;
    score += (logLangBoost[candLanguage] ?? 0.0) * 0.9;
    for (final t in candTags) {
      score += (logGenreBoost[t] ?? 0.0) * 0.7;
      score += (hourGenreBoost[t] ?? 0.0) * 0.8;
    }
    score += _sessionMomentumScore(
      videoId: candIdKey,
      artistKey: candArtist,
      tags: candTags,
      language: candLanguage,
      profile: profile,
      penalizeSeen: true,
    );
    score += queryAction * 0.9;
    score -= (skipVideoPenalty[candIdKey] ?? 0.0) * 1.5;
    score -= (skipArtistPenalty[candArtist] ?? 0.0) * 0.95;
    score -= exposurePenalty * 0.48;

    if (_looksOfficialMusicChannel(candidate.author)) score += 0.9;
    if (_likedVideoIds.contains(candidate.id.value)) score += 0.18;
    if (ytLikedIds.contains(candidate.id.value)) score += 0.26;
    if (_looksLikeDerivativeVersion(candText)) score -= 4.0;
    if (_looksLikeCompilation(_cleanTitle(candidate.title))) score -= 2.25;
    if (_looksLikeShortForm(qualityText.toLowerCase())) score -= 1.95;
    if (!durationFriendly) {
      score -= 2.1;
    } else if (candDuration != null) {
      final secs = candDuration.inSeconds;
      if (secs >= 130 && secs <= 370) score += 0.65;
      if (secs > 520) score -= 0.6;
    }
    if (candArtist == seedArtist && overlapWithSeed == 0) score -= 1.6;
    if (repeatCount >= 2) score -= (repeatCount - 1) * 1.15;
    if (contextAffinity < -1.2) score -= 1.6;
    if (transitionAffinity <= 0 && contextAffinity < 0.2) score -= 0.7;

    if (seedTags.isNotEmpty && overlapWithSeed == 0) score -= 2.4;
    if (overlapWithSeed == 0 &&
        overlapWithTaste == 0 &&
        artistAction < 0.4 &&
        queryAction < 0.6) {
      score -= 2.0;
    }
    if (!_looksOfficialMusicChannel(candidate.author) &&
        candArtist.split(' ').length >= 3) {
      score -= 0.5;
    }
    return score;
  }

  List<Video> _rankSearchResults(
    List<Video> input,
    String query, {
    bool personalize = true,
    bool preferSongFirst = false,
  }) {
    if (input.isEmpty) return const <Video>[];

    final queryNorm = _normalizeSignalKey(query);
    final querySoftNorm = _softNormalizeSearchText(query);
    final queryTokens = _tokenizeSearchText(query, dropCommonWords: true);
    final hasMusicIntent = _hasMusicIntentSignal(queryNorm);

    final base = (personalize && input.length > 1)
        ? _rankPersonalizedRecommendations(input, query)
        : List<Video>.from(input);
    final baseIndex = <String, int>{
      for (int i = 0; i < base.length; i++) base[i].id.value: i,
    };

    final scored = <({Video v, double score})>[];
    for (final video in input) {
      final cleanTitle = _cleanTitle(video.title);
      final cleanAuthor = _cleanAuthor(video.author);
      final titleNorm = _normalizeSignalKey(cleanTitle);
      final authorNorm = _normalizeSignalKey(cleanAuthor);
      final textNorm = '$titleNorm $authorNorm'.trim();
      final titleSoftNorm = _softNormalizeSearchText(cleanTitle);
      final authorSoftNorm = _softNormalizeSearchText(cleanAuthor);
      final textSoftNorm = '$titleSoftNorm $authorSoftNorm'.trim();
      final titleTokens =
          _tokenizeSearchText(cleanTitle, dropCommonWords: true);
      final authorTokens =
          _tokenizeSearchText(cleanAuthor, dropCommonWords: true);
      final allTokens = <String>[...titleTokens, ...authorTokens];

      double score =
          ((base.length - (baseIndex[video.id.value] ?? base.length)) * 0.12)
              .toDouble();

      if (queryNorm.isNotEmpty) {
        if (titleNorm == queryNorm) {
          score += 9.2;
        } else if (titleNorm.startsWith(queryNorm)) {
          score += 6.8;
        } else if (textNorm.startsWith(queryNorm)) {
          score += 5.4;
        } else if (titleNorm.contains(queryNorm)) {
          score += 4.2;
        } else if (textNorm.contains(queryNorm)) {
          score += 3.1;
        }
        if (querySoftNorm.isNotEmpty) {
          if (titleSoftNorm == querySoftNorm) {
            score += 9.8;
          } else if (titleSoftNorm.startsWith(querySoftNorm)) {
            score += 7.1;
          } else if (titleSoftNorm.contains(querySoftNorm)) {
            score += 4.8;
          } else if (textSoftNorm.contains(querySoftNorm)) {
            score += 3.4;
          }
        }
      }

      final titleTokenScore = _fuzzyTokenOverlapScore(queryTokens, titleTokens);
      final allTokenScore = _fuzzyTokenOverlapScore(queryTokens, allTokens);
      score += titleTokenScore * 1.45;
      score += allTokenScore * 0.92;
      if (queryTokens.isNotEmpty) {
        final titleMatches = queryTokens
            .where(
              (qt) => titleTokens.any((tt) => tt == qt || tt.startsWith(qt)),
            )
            .length;
        final authorMatches = queryTokens
            .where(
              (qt) => authorTokens.any((at) => at == qt || at.startsWith(qt)),
            )
            .length;
        final titleRatio = titleMatches / queryTokens.length;
        final authorRatio = authorMatches / queryTokens.length;
        score += titleRatio * 5.6;
        score += authorRatio * 2.8;
        if (titleRatio >= 0.9 && queryTokens.length >= 2) score += 3.0;
        if (titleRatio >= 0.75 && authorMatches > 0) score += 2.5;
      }

      score += _queryAffinityForText('$cleanTitle $cleanAuthor') * 0.35;

      if (_looksOfficialMusicChannel(video.author)) score += 0.9;
      if (_looksLikeCompilation(cleanTitle)) score -= 3.2;
      if (_looksLikeDerivativeVersion('$cleanTitle $cleanAuthor')) score -= 2.9;
      if (_looksLikeShortForm('$cleanTitle $cleanAuthor')) score -= 2.2;

      final duration = video.duration;
      if (!_isDurationMusicFriendly(duration, strictSingles: true)) {
        score -= 2.2;
      } else if (duration != null) {
        final secs = duration.inSeconds;
        if (secs >= 120 && secs <= 390) score += 0.9;
        if (secs > 520) score -= 0.8;
      }

      if (preferSongFirst) {
        if (titleNorm.contains('official audio') ||
            titleNorm.contains('lyric')) {
          score += 0.65;
        }
        if (titleNorm.contains('full video')) score -= 0.35;
        if (textNorm.contains('cover') ||
            textNorm.contains('karaoke') ||
            textNorm.contains('tribute') ||
            textNorm.contains('reaction') ||
            textNorm.contains('8d') ||
            textNorm.contains('slowed') ||
            textNorm.contains('reverb') ||
            textNorm.contains('remix') ||
            textNorm.contains('live')) {
          score -= 2.5;
        }
      }

      if (!hasMusicIntent && _hasMusicIntentSignal(textNorm)) score += 0.6;

      scored.add((v: video, score: score));
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.map((x) => x.v).toList();
  }

  List<Video> _rankPersonalizedRecommendations(
    List<Video> input,
    String query,
  ) {
    final profile = _buildTasteProfile();
    final quickSeeds = _collectQuickPickSeeds(maxSeeds: 8);
    final leadSeed =
        _nowPlaying ?? (quickSeeds.isNotEmpty ? quickSeeds.first : null);
    final topArtists = (profile['topArtists'] as List<String>? ?? [])
        .take(12)
        .map(_primaryArtistKey)
        .toSet();
    final topGenres = (profile['topGenres'] as List<String>? ?? []).toSet();
    final topLanguage = profile['topLanguage'] as String? ?? 'english';
    final artistAffinity = (profile['artistAffinity'] as Map<String, int>?) ??
        const <String, int>{};
    final genreAffinity = (profile['genreAffinity'] as Map<String, int>?) ??
        const <String, int>{};
    final langAffinity =
        (profile['langAffinity'] as Map<String, int>?) ?? const <String, int>{};
    final logArtistBoost =
        (profile['logArtistBoost'] as Map<String, double>?) ??
            const <String, double>{};
    final recentArtistBoost =
        (profile['recentArtistBoost'] as Map<String, double>?) ??
            const <String, double>{};
    final logVideoBoost = (profile['logVideoBoost'] as Map<String, double>?) ??
        const <String, double>{};
    final logGenreBoost = (profile['logGenreBoost'] as Map<String, double>?) ??
        const <String, double>{};
    final hourGenreBoost =
        (profile['hourGenreBoost'] as Map<String, double>?) ??
            const <String, double>{};
    final logLangBoost = (profile['logLangBoost'] as Map<String, double>?) ??
        const <String, double>{};
    final skipVideoPenalty =
        (profile['skipVideoPenalty'] as Map<String, double>?) ??
            const <String, double>{};
    final skipArtistPenalty =
        (profile['skipArtistPenalty'] as Map<String, double>?) ??
            const <String, double>{};
    final recentPlayCount = (profile['recentPlayCount'] as Map<String, int>?) ??
        const <String, int>{};
    final ytLikedIds =
        (profile['ytLikedIds'] as Set<String>?) ?? const <String>{};
    final totalSongs = (profile['totalSongs'] as int?) ?? 1;
    final recentArtists =
        _history.take(12).map((v) => _primaryArtistKey(v.author)).toSet();
    final q = query.toLowerCase();
    final hasLanguageHint = q.contains('hindi') ||
        q.contains('punjabi') ||
        q.contains('tamil') ||
        q.contains('telugu') ||
        q.contains('kpop') ||
        q.contains('english') ||
        q.contains('bollywood') ||
        q.contains('kollywood') ||
        q.contains('tollywood');
    final queryLanguage = _detectLanguageTag(q);
    final queryTags = _extractMusicTags(q);
    final queryTokens = _tokenizeSearchText(query, dropCommonWords: true);
    final queryKey = _normalizeSignalKey(query);
    final directQuerySignal = _queryActionBoost[queryKey] ?? 0.0;

    final scored = <({Video v, double score})>[];
    for (int i = 0; i < input.length; i++) {
      final v = input[i];
      if (_isRecommendationBlocked(v)) continue;
      final idKey = v.id.value.toLowerCase();
      final authorKey = _primaryArtistKey(v.author);
      final text = '${v.title} ${v.author}'.toLowerCase();
      final tags = _extractMusicTags(text);
      final overlap = tags.where(topGenres.contains).length;
      final lang = _detectLanguageTag(text);
      final titleTokens =
          _tokenizeSearchText(_cleanTitle(v.title), dropCommonWords: true);
      final authorTokens =
          _tokenizeSearchText(_cleanAuthor(v.author), dropCommonWords: true);
      final artistAction = _artistActionBoost[authorKey] ?? 0.0;
      final langAction = _langActionBoost[lang] ?? 0.0;
      final videoAction = _videoActionBoost[idKey] ?? 0.0;
      final queryAction = _queryAffinityForText(text);
      final repeatCount = recentPlayCount[idKey] ?? 0;
      double score = (input.length - i) * 0.06;

      if (topArtists.contains(authorKey)) score += 3.0;
      if (recentArtists.contains(authorKey)) score += 1.0;
      score += overlap * 1.5;
      score += ((artistAffinity[authorKey] ?? 0) / totalSongs) * 18.0;
      if (lang == topLanguage) {
        score += 2.1;
      } else {
        score -= 1.8;
      }
      if ((langAffinity[lang] ?? 0) == 0) score -= 1.0;
      for (final t in tags) {
        score += (genreAffinity[t] ?? 0) * 0.03;
        score += (_genreActionBoost[t] ?? 0.0) * 0.24;
      }
      score += artistAction * 1.8;
      score += langAction * 1.1;
      score += videoAction * 1.7;
      score += (logArtistBoost[authorKey] ?? 0.0) * 1.45;
      score += (recentArtistBoost[authorKey] ?? 0.0) * 1.65;
      score += (logVideoBoost[idKey] ?? 0.0) * 1.1;
      score += (logLangBoost[lang] ?? 0.0) * 0.75;
      for (final t in tags) {
        score += (logGenreBoost[t] ?? 0.0) * 0.65;
        score += (hourGenreBoost[t] ?? 0.0) * 0.72;
      }
      score += _sessionMomentumScore(
        videoId: idKey,
        artistKey: authorKey,
        tags: tags,
        language: lang,
        profile: profile,
        penalizeSeen: true,
      );
      if (leadSeed != null) {
        score +=
            _contextualSeedAffinity(leadSeed, v, profile, strict: false) * 0.24;
        score += _transitionAffinityScore(leadSeed, v, profile) * 0.16;
      }
      if (quickSeeds.isNotEmpty) {
        score += _seedAffinityScore(v, quickSeeds) * 0.28;
        score += _multiSeedTransitionScore(v, quickSeeds, profile) * 0.22;
      }
      score += queryAction * 1.2;
      score += directQuerySignal * 0.25;
      if (queryTokens.isNotEmpty) {
        final tokenScore = _fuzzyTokenOverlapScore(
          queryTokens,
          <String>[...titleTokens, ...authorTokens],
        );
        score += tokenScore * 0.95;
      }
      if (queryTags.isNotEmpty) {
        final queryTagOverlap = tags.where(queryTags.contains).length;
        score += queryTagOverlap * 1.35;
        if (queryTagOverlap == 0 && tags.isNotEmpty) score -= 0.9;
      }
      if (hasLanguageHint) {
        if (lang == queryLanguage) {
          score += 1.05;
        } else {
          score -= 1.2;
        }
      }
      score -= (skipVideoPenalty[idKey] ?? 0.0) * 1.45;
      score -= (skipArtistPenalty[authorKey] ?? 0.0) * 0.9;
      score -= (_quickPickExposurePenalty[idKey] ?? 0.0) * 0.55;
      if (_looksOfficialMusicChannel(v.author)) score += 0.8;
      if (_looksLikeCompilation(_cleanTitle(v.title))) score -= 2.1;
      if (_looksLikeDerivativeVersion(text)) score -= 2.6;
      if (_looksLikeShortForm(text)) score -= 1.6;
      if (!_isDurationMusicFriendly(v.duration, strictSingles: true)) {
        score -= 1.3;
      }
      if (_likedVideoIds.contains(v.id.value)) score -= 2.5;
      if (ytLikedIds.contains(v.id.value)) score -= 1.2;
      if (q.contains(authorKey)) score += 0.9;
      if (artistAction < -0.6 && !q.contains(authorKey)) score -= 0.8;
      if (repeatCount >= 2) score -= (repeatCount - 1) * 1.05;
      if (!_likedVideoIds.contains(v.id.value) &&
          !ytLikedIds.contains(v.id.value) &&
          repeatCount == 0 &&
          !recentArtists.contains(authorKey)) {
        score += 0.8;
      }

      scored.add((v: v, score: score));
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.map((x) => x.v).toList();
  }

  Duration? _parseIsoDuration(String iso) {
    if (iso.isEmpty) return null;
    final m = RegExp(r'PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?').firstMatch(iso);
    if (m == null) return null;
    final h = int.tryParse(m.group(1) ?? '0') ?? 0;
    final min = int.tryParse(m.group(2) ?? '0') ?? 0;
    final s = int.tryParse(m.group(3) ?? '0') ?? 0;
    return Duration(hours: h, minutes: min, seconds: s);
  }

  Future<void> _ytSignOut() async {
    _cloudSaveDebounce?.cancel();
    _pendingCloudBackupJson = null;
    _ytAuthGrant = null;
    _ytClient?.close();
    _ytClient = null;
    if (_useGoogleSignInAndroid) {
      try {
        await _googleSignIn.disconnect();
      } catch (_) {
        try {
          await _googleSignIn.signOut();
        } catch (_) {}
      }
    }
    await _clearOAuthCredentials();
    if (mounted) {
      setState(() {
        _ytAccessToken = null;
        _ytRefreshToken = null;
        _ytAccountEmail = null;
        _ytAccountName = null;
        _ytAccountPhoto = null;
        _ytLikedVideos = [];
        _cloudBackupFileId = null;
        _cloudLastSyncAt = null;
        _cloudSyncError = null;
        _cloudSyncing = false;
        _cloudWritesPausedForRestore = false;
      });
    } else {
      _ytAccessToken = null;
      _ytRefreshToken = null;
      _ytAccountEmail = null;
      _ytAccountName = null;
      _ytAccountPhoto = null;
      _ytLikedVideos = [];
      _cloudBackupFileId = null;
      _cloudLastSyncAt = null;
      _cloudSyncError = null;
      _cloudSyncing = false;
      _cloudWritesPausedForRestore = false;
    }
    _scheduleSave();
    _maybeReloadHomeAuto();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Logged out from YouTube Music')),
      );
    }
  }

  String _fmt(Duration? d) {
    if (d == null) return '0:00';
    return '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  // Share a song
  void _shareSong(Video video) {
    final url = 'https://youtu.be/${video.id.value}';
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(children: [
          const Icon(Icons.share_rounded, color: Colors.greenAccent, size: 16),
          const SizedBox(width: 8),
          Expanded(
              child: Text('Link copied: $url',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12))),
        ]),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(label: 'OK', onPressed: () {}),
      ),
    );
  }

  List<String> _lyricsArtistCandidates(Video video) {
    final out = <String>[];
    final seen = <String>{};
    void add(String value) {
      final cleaned = _cleanAuthor(value)
          .replaceAll(
              RegExp(r'\s+(?:feat|ft)\.?\s+.*$', caseSensitive: false), '')
          .replaceAll(RegExp(r'\s{2,}'), ' ')
          .trim();
      if (cleaned.isEmpty) return;
      final key = cleaned.toLowerCase();
      if (seen.add(key)) out.add(cleaned);
    }

    add(video.author);
    add(_displayArtistNames(video));
    for (final part in _displayArtistNames(video)
        .split(RegExp(r',|&|\bx\b|/|;|\|', caseSensitive: false))) {
      add(part);
    }
    return out.take(5).toList();
  }

  List<String> _lyricsTitleCandidates(Video video) {
    final out = <String>[];
    final seen = <String>{};
    void add(String value) {
      final cleaned = value
          .replaceAll(
              RegExp(
                  r'\((?:official|lyrics?|video|audio|hd|4k|visualizer|full song|full video|prod\.?[^)]*)\)',
                  caseSensitive: false),
              '')
          .replaceAll(
              RegExp(
                  r'\[(?:official|lyrics?|video|audio|hd|4k|visualizer|full song|full video)[^\]]*\]',
                  caseSensitive: false),
              '')
          .replaceAll(
              RegExp(r'\s+(?:feat|ft)\.?\s+.*$', caseSensitive: false), '')
          .replaceAll(RegExp(r'\s{2,}'), ' ')
          .trim();
      if (cleaned.isEmpty) return;
      final key = cleaned.toLowerCase();
      if (seen.add(key)) out.add(cleaned);
    }

    add(video.title);
    add(_cleanTitle(video.title));
    final clean = _cleanTitle(video.title);
    if (clean.contains(' - ')) {
      add(clean.split(' - ').last.trim());
    }
    return out.take(5).toList();
  }

  String _normalizeLyricsText(String raw) {
    final withoutTiming =
        raw.replaceAll(RegExp(r'^\[[0-9:.]+\]\s*', multiLine: true), '');
    final normalized = withoutTiming
        .replaceAll('\r\n', '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    return normalized;
  }

  Future<String?> _fetchLyricsFromLyricsOvh(String artist, String title) async {
    try {
      final encodedArtist = Uri.encodeComponent(artist);
      final encodedTitle = Uri.encodeComponent(title);
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8);
      final req = await client.getUrl(
          Uri.parse('https://api.lyrics.ovh/v1/$encodedArtist/$encodedTitle'));
      req.headers.set('User-Agent', 'BeastMusic/1.0');
      final resp = await req.close().timeout(const Duration(seconds: 10));
      final body = await resp.transform(const Utf8Decoder()).join();
      client.close();
      if (resp.statusCode != 200 || body.trim().isEmpty) return null;
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final lyrics = (decoded['lyrics'] as String? ?? '').trim();
      if (lyrics.isEmpty) return null;
      final normalized = _normalizeLyricsText(lyrics);
      if (normalized.isEmpty) return null;
      return normalized;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _fetchLyricsFromLrcLib(
    String artist,
    String title, {
    int? durationSecs,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    Future<String?> parseResponse(HttpClientResponse resp) async {
      final body = await resp.transform(const Utf8Decoder()).join();
      if (resp.statusCode < 200 ||
          resp.statusCode >= 300 ||
          body.trim().isEmpty) {
        return null;
      }
      final decoded = jsonDecode(body);
      String pickLyrics(Map<dynamic, dynamic> m) {
        final plain = (m['plainLyrics'] as String? ?? '').trim();
        if (plain.isNotEmpty) return plain;
        final synced = (m['syncedLyrics'] as String? ?? '').trim();
        return synced;
      }

      if (decoded is Map) {
        final picked = pickLyrics(decoded);
        if (picked.isNotEmpty) return _normalizeLyricsText(picked);
        return null;
      }
      if (decoded is List) {
        for (final item in decoded) {
          if (item is! Map) continue;
          final picked = pickLyrics(item);
          if (picked.trim().isNotEmpty) return _normalizeLyricsText(picked);
        }
      }
      return null;
    }

    try {
      final getUri = Uri.https('lrclib.net', '/api/get', {
        'artist_name': artist,
        'track_name': title,
        if (durationSecs != null && durationSecs > 0)
          'duration': durationSecs.toString(),
      });
      final getReq = await client.getUrl(getUri);
      getReq.headers.set('User-Agent', 'BeastMusic/1.0');
      final getResp = await getReq.close().timeout(const Duration(seconds: 10));
      final fromGet = await parseResponse(getResp);
      if (fromGet != null && fromGet.trim().isNotEmpty) {
        client.close();
        return fromGet;
      }
    } catch (_) {}

    try {
      final searchUri = Uri.https('lrclib.net', '/api/search', {
        'artist_name': artist,
        'track_name': title,
      });
      final searchReq = await client.getUrl(searchUri);
      searchReq.headers.set('User-Agent', 'BeastMusic/1.0');
      final searchResp =
          await searchReq.close().timeout(const Duration(seconds: 10));
      final fromSearch = await parseResponse(searchResp);
      client.close();
      if (fromSearch != null && fromSearch.trim().isNotEmpty) {
        return fromSearch;
      }
    } catch (_) {
      client.close();
    }
    return null;
  }

  // Lyrics fetching
  Future<String?> _fetchLyrics(Video video) async {
    final saved = _savedLyricsForVideoId(video.id.value);
    if (saved != null) {
      _cachedLyricsVideoId = video.id.value;
      _cachedLyrics = saved;
      return saved;
    }

    if (_cachedLyricsVideoId == video.id.value && _cachedLyrics != null) {
      return _cachedLyrics;
    }
    final artists = _lyricsArtistCandidates(video);
    final titles = _lyricsTitleCandidates(video);
    final durationSecs = video.duration?.inSeconds;

    for (final artist in artists) {
      for (final title in titles) {
        final lrclib = await _fetchLyricsFromLrcLib(
          artist,
          title,
          durationSecs: durationSecs,
        );
        if (lrclib != null && lrclib.trim().isNotEmpty) {
          _cachedLyricsVideoId = video.id.value;
          _cachedLyrics = lrclib.trim();
          final di = _findDownloadIndexByVideoId(video.id.value);
          if (di >= 0 && (_downloads[di]['lyrics'] ?? '').trim().isEmpty) {
            if (mounted) {
              setState(() => _downloads[di]['lyrics'] = _cachedLyrics!);
            } else {
              _downloads[di]['lyrics'] = _cachedLyrics!;
            }
            _scheduleSave();
          }
          return _cachedLyrics;
        }
      }
    }

    for (final artist in artists) {
      for (final title in titles) {
        final ovh = await _fetchLyricsFromLyricsOvh(artist, title);
        if (ovh != null && ovh.trim().isNotEmpty) {
          _cachedLyricsVideoId = video.id.value;
          _cachedLyrics = ovh.trim();
          final di = _findDownloadIndexByVideoId(video.id.value);
          if (di >= 0 && (_downloads[di]['lyrics'] ?? '').trim().isEmpty) {
            if (mounted) {
              setState(() => _downloads[di]['lyrics'] = _cachedLyrics!);
            } else {
              _downloads[di]['lyrics'] = _cachedLyrics!;
            }
            _scheduleSave();
          }
          return _cachedLyrics;
        }
      }
    }
    return null;
  }

  // Lyrics sheet
  void _showLyricsSheet(Video video) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111111),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (ctx, scrollCtrl) => Column(children: [
          _sheetHandle(),
          _sheetHeader(
            icon: Icons.lyrics_rounded,
            color: Colors.greenAccent,
            title: 'Lyrics',
            subtitle: _cleanTitle(video.title),
          ),
          Expanded(
            child: FutureBuilder<String?>(
              future: _fetchLyrics(video),
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(
                      child: CircularProgressIndicator(
                          color: Colors.greenAccent, strokeWidth: 2));
                }
                if (snap.data == null) {
                  return Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.music_off_rounded,
                          color: Colors.grey[700], size: 52),
                      const SizedBox(height: 12),
                      Text('Lyrics not found',
                          style:
                              TextStyle(color: Colors.grey[500], fontSize: 15)),
                      const SizedBox(height: 6),
                      Text('Powered by LRCLIB + lyrics.ovh',
                          style:
                              TextStyle(color: Colors.grey[700], fontSize: 11)),
                    ]),
                  );
                }
                return SingleChildScrollView(
                  controller: scrollCtrl,
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
                  child: Text(
                    snap.data!,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        height: 1.85,
                        fontWeight: FontWeight.w300),
                  ),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }

  // Artist bio sheet
  Future<Map<String, dynamic>?> _fetchArtistBio(String artistName) async {
    if (_artistBioCache.containsKey(artistName)) {
      return _artistBioCache[artistName];
    }
    final cleanName = artistName
        .replaceAll(RegExp(r'\s*-\s*Topic', caseSensitive: false), '')
        .trim();
    final encoded = Uri.encodeComponent(cleanName);
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 8);
      final req = await client.getUrl(Uri.parse(
          'https://en.wikipedia.org/api/rest_v1/page/summary/$encoded'));
      req.headers.set('User-Agent', 'BeastMusic/1.0');
      final resp = await req.close().timeout(const Duration(seconds: 10));
      final body = await resp.transform(const Utf8Decoder()).join();
      client.close();
      if (resp.statusCode == 200) {
        final json = jsonDecode(body) as Map<String, dynamic>;
        if (json['type'] != 'disambiguation') {
          final bio = <String, dynamic>{
            'title': json['title'] ?? cleanName,
            'extract': json['extract'] ?? '',
            'description': json['description'] ?? '',
            'thumbnail': (json['thumbnail'] as Map?)?['source'],
            'url': (json['content_urls'] as Map?)?['desktop']?['page'],
          };
          _artistBioCache[artistName] = bio;
          return bio;
        }
      }
    } catch (e) {
      debugPrint('[ArtistBio] $e');
    }
    return null;
  }

  void _showArtistBioSheet(String artistName) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111111),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (ctx, scrollCtrl) => FutureBuilder<Map<String, dynamic>?>(
          future: _fetchArtistBio(artistName),
          builder: (ctx, snap) {
            final bio = snap.data;
            final displayName = artistName
                .replaceAll(RegExp(r'\s*-\s*Topic', caseSensitive: false), '')
                .trim();
            return ListView(
              controller: scrollCtrl,
              padding: const EdgeInsets.only(bottom: 40),
              children: [
                _sheetHandle(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                  child: Row(children: [
                    const Icon(Icons.person_rounded,
                        color: Colors.greenAccent, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(displayName,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.bold)),
                    ),
                  ]),
                ),
                if (snap.connectionState == ConnectionState.waiting)
                  const Padding(
                    padding: EdgeInsets.all(40),
                    child: Center(
                        child: CircularProgressIndicator(
                            color: Colors.greenAccent, strokeWidth: 2)),
                  )
                else if (bio == null)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.person_search_rounded,
                          color: Colors.grey[700], size: 52),
                      const SizedBox(height: 12),
                      Text('No biography found',
                          style:
                              TextStyle(color: Colors.grey[500], fontSize: 15)),
                      const SizedBox(height: 6),
                      Text('Powered by Wikipedia',
                          style:
                              TextStyle(color: Colors.grey[700], fontSize: 11)),
                    ]),
                  )
                else ...[
                  if (bio['thumbnail'] != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: CachedNetworkImage(
                          imageUrl: bio['thumbnail'],
                          height: 180,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  if ((bio['description'] as String?)?.isNotEmpty == true)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                      child: Text(
                        bio['description'],
                        style: TextStyle(
                            color: Colors.greenAccent.withValues(alpha: 0.8),
                            fontSize: 12,
                            fontStyle: FontStyle.italic),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                    child: Text(
                      bio['extract'] as String,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          height: 1.65,
                          fontWeight: FontWeight.w300),
                    ),
                  ),
                  if (bio['url'] != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                      child: Row(children: [
                        Icon(Icons.open_in_new_rounded,
                            color: Colors.grey[600], size: 13),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            bio['url'],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: Colors.grey[600],
                                fontSize: 11,
                                decoration: TextDecoration.underline,
                                decorationColor: Colors.grey[600]),
                          ),
                        ),
                      ]),
                    ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  // Song credits / metadata sheet
  void _showSongCreditsSheet(Video video) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111111),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        expand: false,
        builder: (ctx, scrollCtrl) => ListView(
          controller: scrollCtrl,
          padding: const EdgeInsets.only(bottom: 40),
          children: [
            _sheetHandle(),
            _sheetHeader(
              icon: Icons.info_outline_rounded,
              color: Colors.greenAccent,
              title: 'Song Details',
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Row(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: CachedNetworkImage(
                    imageUrl: video.thumbnails.highResUrl,
                    width: 80,
                    height: 80,
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) => Container(
                        width: 80,
                        height: 80,
                        color: Colors.grey[850],
                        child:
                            const Icon(Icons.music_note, color: Colors.grey)),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_cleanTitle(video.title),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        GestureDetector(
                          onTap: () {
                            Navigator.pop(ctx);
                            _openArtistPage(video.author);
                          },
                          child: Text(_cleanAuthor(video.author),
                              style: TextStyle(
                                  color:
                                      Colors.greenAccent.withValues(alpha: 0.8),
                                  fontSize: 12,
                                  decoration: TextDecoration.underline,
                                  decorationColor: Colors.greenAccent
                                      .withValues(alpha: 0.4))),
                        ),
                      ]),
                ),
              ]),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Divider(color: Color(0xFF252525)),
            ),
            _creditRow(Icons.link_rounded, 'YouTube ID', video.id.value),
            _creditRow(
                Icons.schedule_rounded, 'Duration', _fmt(video.duration)),
            if (video.uploadDate != null)
              _creditRow(Icons.calendar_today_rounded, 'Upload Date',
                  '${video.uploadDate!.day}/${video.uploadDate!.month}/${video.uploadDate!.year}'),
            if (video.engagement.viewCount > 0)
              _creditRow(Icons.visibility_rounded, 'Views',
                  _formatCount(video.engagement.viewCount)),
            if (video.engagement.likeCount != null &&
                video.engagement.likeCount! > 0)
              _creditRow(Icons.thumb_up_rounded, 'Likes',
                  _formatCount(video.engagement.likeCount!)),
            if (video.description.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 6),
                child: Text('Description',
                    style: TextStyle(
                        color: Colors.greenAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                child: Text(
                  video.description.length > 600
                      ? '${video.description.substring(0, 600)}...'
                      : video.description,
                  style: TextStyle(
                      color: Colors.grey[400], fontSize: 12, height: 1.6),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _creditRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(children: [
        Icon(icon, color: Colors.grey[600], size: 16),
        const SizedBox(width: 12),
        Text('$label:',
            style: TextStyle(color: Colors.grey[500], fontSize: 12)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500)),
        ),
      ]),
    );
  }

  String _formatCount(int count) {
    if (count >= 1000000000) {
      return '${(count / 1000000000).toStringAsFixed(1)}B';
    }
    if (count >= 1000000) return '${(count / 1000000).toStringAsFixed(1)}M';
    if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}K';
    return count.toString();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _activeDl?.cancel();
    _notificationEventSub?.cancel();
    _oauthLinkSub?.cancel();
    _playerPositionSub?.cancel();
    _ytClient?.close();
    _playYt?.close();
    _prefetchForVideoId = null;
    _prefetching.clear();
    _saveDebounce?.cancel();
    _cloudSaveDebounce?.cancel();
    if (_dataLoaded) {
      _capturePlaybackSnapshot();
      _saveData();
    }
    _quickPicksCtrl.dispose();
    _speedDialCtrl.dispose();
    for (final p in _tmpFiles.values) {
      try {
        File(p).deleteSync();
      } catch (_) {}
    }
    _tmpFiles.clear();
    _sleepTimer?.cancel();
    _sleepCountdown?.cancel();
    _searchSuggestDebounce?.cancel();
    for (final taskId in _runningDownloadTaskIds.toList()) {
      _downloadCancelRequestedTaskIds.add(taskId);
      _downloadAbortByTaskId[taskId]?.complete();
      final sub = _downloadStreamSubByTaskId.remove(taskId);
      if (sub != null) {
        unawaited(sub.cancel());
      }
    }
    _downloadTasks.clear();
    if (_beastClientReady) {
      unawaited(_beastClient?.dispose());
    }
    _player.dispose();
    _playerB.dispose();
    _searchController.dispose();
    _playlistSearchCtrl.dispose();
    super.dispose();
  }

  // ---
  // UI BUILD
  // ---
  Widget _buildReactiveMiniPlayer(bool isDark) {
    return StreamBuilder<Duration>(
      stream: _player.positionStream,
      builder: (context, posSnap) {
        final position = posSnap.data ?? _player.position;
        return StreamBuilder<Duration?>(
          stream: _player.durationStream,
          builder: (context, durSnap) {
            final duration = durSnap.data ?? _player.duration ?? Duration.zero;
            final progress = duration.inMilliseconds > 0
                ? (position.inMilliseconds / duration.inMilliseconds)
                    .clamp(0.0, 1.0)
                : 0.0;
            return _buildMiniPlayer(_player.playing, progress, isDark);
          },
        );
      },
    );
  }

  Widget _buildReactiveNowPlaying(bool isDark, Color textColor) {
    return StreamBuilder<Duration>(
      stream: _player.positionStream,
      builder: (context, posSnap) {
        final position = posSnap.data ?? _player.position;
        return StreamBuilder<Duration?>(
          stream: _player.durationStream,
          builder: (context, durSnap) {
            final duration = durSnap.data ?? _player.duration ?? Duration.zero;
            final progress = duration.inMilliseconds > 0
                ? (position.inMilliseconds / duration.inMilliseconds)
                    .clamp(0.0, 1.0)
                : 0.0;
            return _buildNowPlayingScreen(
              _player.playing,
              progress,
              position,
              duration,
              isDark,
              textColor,
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = _isDarkNotifier.value;
    final isPlaying = _player.playing;

    final bg = isDark ? Colors.black : const Color(0xFFF5F5F5);
    final cardBg = isDark ? const Color(0xFF141414) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black87;

    return Scaffold(
      backgroundColor: bg,
      body: Stack(
        children: [
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragEnd: _switchTabBySwipe,
                    child: RepaintBoundary(
                      child: _buildAnimatedTabBody(
                        isPlaying,
                        isDark,
                        textColor,
                        cardBg,
                      ),
                    ),
                  ),
                ),
                if (_nowPlaying != null) const SizedBox(height: 72),
                _buildNavBar(isDark, textColor),
              ],
            ),
          ),
          if (_nowPlaying != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: _navBarHeight(context),
              child: RepaintBoundary(
                child: _buildReactiveMiniPlayer(isDark),
              ),
            ),
          if (_showNowPlaying && _nowPlaying != null)
            AnimatedOpacity(
              opacity: _showNowPlaying ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 280),
              child: AnimatedSlide(
                offset: _showNowPlaying ? Offset.zero : const Offset(0, 0.08),
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                child: RepaintBoundary(
                  child: _buildReactiveNowPlaying(isDark, textColor),
                ),
              ),
            ),
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
            ),
        ],
      ),
    );
  }

  double _navBarHeight(BuildContext ctx) =>
      56 + MediaQuery.of(ctx).padding.bottom;

  void _switchTabBySwipe(DragEndDetails details) {
    if (_showNowPlaying || _isSearchMode) return;
    if (_artistPageName != null || _openPlaylist != null) return;
    final v = details.primaryVelocity;
    if (v == null || v.abs() < 700) return;

    if (v < 0 && _selectedTab < 5) {
      setState(() => _selectedTab += 1);
      HapticFeedback.lightImpact();
    } else if (v > 0 && _selectedTab > 0) {
      setState(() => _selectedTab -= 1);
      HapticFeedback.lightImpact();
    }

    if (_selectedTab == 2) {
      _openPlaylist = null;
      _artistPageName = null;
    } else {
      _artistPageName = null;
    }
  }

  // Nav bar
  Widget _buildNavBar(bool isDark, Color textColor) {
    const items = [
      (Icons.home_rounded, Icons.home_outlined, 'Home'),
      (Icons.explore_rounded, Icons.explore_outlined, 'Explore'),
      (Icons.library_music_rounded, Icons.library_music_outlined, 'Library'),
      (Icons.history_rounded, Icons.history_outlined, 'History'),
      (Icons.download_done_rounded, Icons.download_outlined, 'Downloads'),
      (Icons.settings_rounded, Icons.settings_outlined, 'Settings'),
    ];
    final navBg = isDark ? const Color(0xFF0D0D0D) : Colors.white;
    final divColor = isDark ? const Color(0xFF1A1A1A) : Colors.grey.shade200;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: navBg,
          border: Border(top: BorderSide(color: divColor, width: 0.5)),
        ),
        child: Row(
          children: [
            ...List.generate(items.length, (i) {
              final selected = _selectedTab == i;
              const activeColor = Colors.greenAccent;
              final inactiveColor =
                  isDark ? Colors.grey[600] : Colors.grey[500];
              return Expanded(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () {
                      if (_selectedTab != i) {
                        HapticFeedback.selectionClick();
                      }
                      setState(() {
                        _selectedTab = i;
                        if (i == 2) {
                          _openPlaylist = null;
                          _artistPageName = null;
                        }
                        if (i != 2) _artistPageName = null;
                      });
                    },
                    splashColor: Colors.greenAccent.withValues(alpha: 0.12),
                    highlightColor: Colors.greenAccent.withValues(alpha: 0.04),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      padding: EdgeInsets.symmetric(
                        vertical: selected ? 7.5 : 9,
                      ),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        AnimatedScale(
                          scale: selected ? 1.08 : 1.0,
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOutCubic,
                          child: Icon(
                            selected ? items[i].$1 : items[i].$2,
                            color: selected ? activeColor : inactiveColor,
                            size: 22,
                          ),
                        ),
                        const SizedBox(height: 2),
                        AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOutCubic,
                          style: TextStyle(
                            fontSize: 9,
                            color: selected ? activeColor : inactiveColor,
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.normal,
                          ),
                          child: Text(items[i].$3),
                        ),
                      ]),
                    ),
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  // Tab body router
  Widget _buildTabBody(
      bool isPlaying, bool isDark, Color textColor, Color cardBg) {
    if (_artistPageName != null) return _buildArtistPage(isPlaying, isDark);

    switch (_selectedTab) {
      case 0:
        return _buildHomeTab(isPlaying);
      case 1:
        return _buildExploreTab(isPlaying);
      case 2:
        return _buildLibraryTab(isPlaying);
      case 3:
        return _buildHistoryTab(isPlaying);
      case 4:
        return _buildDownloadsTab();
      case 5:
        return _buildSettingsTab(isDark);
      default:
        return _buildHomeTab(isPlaying);
    }
  }

  String _currentBodyKey() {
    if (_artistPageName != null) {
      return 'artist:${_artistPageName!}';
    }
    if (_openPlaylist != null) {
      return 'playlist:${_openPlaylist!.id}';
    }
    if (_isSearchMode && _selectedTab == 0) {
      return 'tab:0:search';
    }
    return 'tab:$_selectedTab';
  }

  Widget _buildAnimatedTabBody(
    bool isPlaying,
    bool isDark,
    Color textColor,
    Color cardBg,
  ) {
    final body = _buildTabBody(isPlaying, isDark, textColor, cardBg);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final slide = Tween<Offset>(
          begin: const Offset(0.02, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        ));
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(position: slide, child: child),
        );
      },
      child: KeyedSubtree(
        key: ValueKey(_currentBodyKey()),
        child: body,
      ),
    );
  }

  // ARTIST PAGE
  Widget _buildArtistPage(bool isPlaying, bool isDark) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 16, 0),
        child: Row(children: [
          IconButton(
            icon: Icon(Icons.arrow_back_rounded,
                color: isDark ? Colors.white : Colors.black87),
            onPressed: () => setState(() {
              _artistPageName = null;
              _artistVideos = [];
            }),
          ),
          Expanded(
            child: Text(
              _artistPageName!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: isDark ? Colors.white : Colors.black87,
                  fontSize: 18,
                  fontWeight: FontWeight.bold),
            ),
          ),
          if (_artistVideos.isNotEmpty)
            IconButton(
              tooltip: 'Play all',
              icon: const Icon(Icons.play_circle_fill,
                  color: Colors.greenAccent, size: 30),
              onPressed: () {
                setState(() {
                  _playQueue = List<Video>.from(_artistVideos);
                  _radioMode = false;
                });
                _playFromUserAction(
                  _artistVideos.first,
                  0,
                  tasteWeight: 0.8,
                  source: 'artist_play_all',
                );
              },
            ),
        ]),
      ),
      Container(
        margin: const EdgeInsets.fromLTRB(20, 10, 20, 16),
        height: 130,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: const LinearGradient(
            colors: [Color(0xFF0a2a1a), Color(0xFF003020)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Stack(children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: CustomPaint(painter: _DotPatternPainter()),
            ),
          ),
          Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.greenAccent.withValues(alpha: 0.15),
                border: Border.all(
                    color: Colors.greenAccent.withValues(alpha: 0.4), width: 2),
              ),
              child: const Icon(Icons.person_rounded,
                  color: Colors.greenAccent, size: 32),
            ),
            const SizedBox(height: 10),
            Text(_artistPageName!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
            if (!_artistLoading)
              Text('${_artistVideos.length} songs',
                  style: TextStyle(color: Colors.grey[500], fontSize: 12)),
          ])),
        ]),
      ),
      if (_artistLoading)
        const Expanded(
            child: Center(
                child: CircularProgressIndicator(color: Colors.greenAccent)))
      else if (_artistVideos.isEmpty)
        Expanded(
            child: Center(
                child: Text('No songs found',
                    style: TextStyle(color: Colors.grey[600], fontSize: 15))))
      else
        Expanded(child: _buildSongList(_artistVideos, isPlaying)),
    ]);
  }

  // Shared search bar
  Widget _buildSearchBar({bool showRefresh = false}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Row(children: [
        if (_isSearchMode)
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
            onPressed: _resetSearchState,
          ),
        Expanded(
          child: Container(
            height: 54,
            decoration: BoxDecoration(
              color: const Color(0xFF171717),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                  color: _isSearchMode
                      ? Colors.greenAccent.withValues(alpha: 0.45)
                      : Colors.grey.shade900,
                  width: 0.8),
              boxShadow: _isSearchMode
                  ? [
                      BoxShadow(
                        color: Colors.greenAccent.withValues(alpha: 0.08),
                        blurRadius: 14,
                        spreadRadius: 0.2,
                      ),
                    ]
                  : null,
            ),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w600),
              onTap: () {
                if (!_isSearchMode) {
                  setState(() {
                    _isSearchMode = true;
                    _searchSuggestions =
                        _buildSearchSuggestions(_searchController.text);
                  });
                } else if (_searchSuggestions.isEmpty) {
                  setState(() {
                    _searchSuggestions =
                        _buildSearchSuggestions(_searchController.text);
                  });
                }
              },
              decoration: InputDecoration(
                hintText: 'Search songs, artists...',
                hintStyle: TextStyle(
                    color: Colors.grey[500],
                    fontSize: 16,
                    fontWeight: FontWeight.w500),
                prefixIcon: Icon(Icons.search_rounded,
                    color:
                        _isSearchMode ? Colors.greenAccent : Colors.grey[600],
                    size: 23),
                border: InputBorder.none,
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 15, horizontal: 2),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close_rounded,
                            color: Colors.grey, size: 20),
                        onPressed: _resetSearchState)
                    : null,
              ),
              onChanged: _onSearchInputChanged,
              onSubmitted: (q) {
                _selectedTab = 0;
                _search(q);
              },
              textInputAction: TextInputAction.search,
            ),
          ),
        ),
        if (showRefresh)
          IconButton(
            icon: Icon(Icons.refresh_rounded,
                color: _homeLoading ? Colors.greenAccent : Colors.grey[700]),
            onPressed: _homeLoading ? null : _loadHome,
          ),
      ]),
    );
  }

  String _homeGreeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  // HOME TAB
  Widget _buildHomeTab(bool isPlaying) {
    return Column(children: [
      _buildSearchBar(showRefresh: !_isSearchMode),
      const SizedBox(height: 8),
      Expanded(
          child: _isSearchMode
              ? _buildSearchResults(isPlaying)
              : RefreshIndicator(
                  color: Colors.greenAccent,
                  backgroundColor: const Color(0xFF141414),
                  onRefresh: () async => _loadHome(),
                  child: _buildHomeScreen(isPlaying),
                )),
    ]);
  }

  // Mood chips data
  static const List<Map<String, String>> _moodChips = [
    {'label': 'Romance', 'query': 'romantic love songs soft melody'},
    {'label': 'Feel good', 'query': 'feel good uplifting happy songs'},
    {'label': 'Relax', 'query': 'relaxing chill lofi calm songs'},
    {'label': 'Workout', 'query': 'workout gym high energy motivational songs'},
    {'label': 'Sad', 'query': 'emotional sad songs'},
    {'label': 'Party', 'query': 'party dance songs'},
    {'label': 'Focus', 'query': 'focus study lofi music'},
    {'label': 'Sleep', 'query': 'sleep calm ambient music'},
  ];

  Future<void> _openMoodFeed(String label, String baseQuery) async {
    setState(() {
      _isSearchMode = true;
      _isLoading = true;
      _searchResults = [];
      _searchDidYouMean = null;
    });
    try {
      final profile = _buildTasteProfile();
      final topGenres = (profile['topGenres'] as List<String>? ?? []).toSet();
      final topLanguage = profile['topLanguage'] as String? ?? 'english';
      final seeds = _collectQuickPickSeeds(maxSeeds: 10);
      final seedIds = seeds.map((v) => v.id.value).toSet();
      final seedArtists = seeds.map((v) => _primaryArtistKey(v.author)).toSet();
      final tags = <String>{...topGenres};
      if (label.toLowerCase().contains('relax')) tags.add('chill');
      if (label.toLowerCase().contains('feel')) tags.add('happy');
      if (label.toLowerCase().contains('romance')) tags.add('romantic');
      if (label.toLowerCase().contains('workout')) tags.add('workout');
      if (label.toLowerCase().contains('sad')) tags.add('sad');
      if (label.toLowerCase().contains('party')) tags.add('party');
      if (label.toLowerCase().contains('focus')) tags.add('lofi');
      if (label.toLowerCase().contains('sleep')) tags.add('sleep');

      final moodQuery = _sceneDiscoveryQuery(topLanguage, tags);
      final q1 = baseQuery;
      final q2 = '$topLanguage $baseQuery';
      final q3 = moodQuery;

      final batches = await Future.wait<List<Video>>([
        _searchMusic(q1,
            limit: 32,
            strictSingles: true,
            personalize: true,
            smartQuery: true,
            excludeBlocked: true,
            sourceQuery: label),
        _searchMusic(q2,
            limit: 32,
            strictSingles: true,
            personalize: true,
            smartQuery: true,
            excludeBlocked: true,
            sourceQuery: label),
        _searchMusic(q3,
            limit: 32,
            strictSingles: true,
            personalize: true,
            smartQuery: true,
            excludeBlocked: true,
            sourceQuery: label),
      ]);

      final merged = <String, Video>{};
      for (final b in batches) {
        for (final v in b) {
          merged.putIfAbsent(v.id.value, () => v);
        }
      }
      final profileMap = _buildTasteProfile();

      // Mood suitability scoring to enforce the requested mood.
      double moodScore(Video v) {
        final text =
            '${_cleanTitle(v.title)} ${_cleanAuthor(v.author)}'.toLowerCase();
        final allTags = _extractMusicTags(text);
        final toks = _tokenizeSearchText(text, dropCommonWords: true).toSet();
        final requires = <String>{};
        final positive = <String>{};
        final negative = <String>{};
        final L = label.toLowerCase();
        if (L.contains('romance')) {
          requires.addAll({'romantic', 'love', 'romance'});
          final romTokens = {
            'ishq',
            'pyaar',
            'pyar',
            'mohabbat',
            'dil',
            'valentine'
          };
          if (!allTags.any(requires.contains) && toks.any(romTokens.contains)) {
            positive.addAll({'romantic', 'love'});
          }
          negative.addAll({
            'diss',
            'beef',
            'freestyle',
            'cypher',
            'drill',
            'trap',
            'rap',
            'hiphop',
            'hip-hop'
          });
        } else if (L.contains('feel')) {
          requires.addAll({'happy', 'uplifting', 'positive', 'feel-good'});
          positive.addAll({'happy', 'feel-good', 'uplifting', 'positive'});
          negative.addAll({'diss', 'beef', 'sad'});
        } else if (L.contains('relax')) {
          requires.addAll({'chill', 'lofi', 'calm'});
          negative.addAll({'workout', 'hard', 'diss', 'freestyle'});
        } else if (L.contains('workout')) {
          requires.addAll({'workout', 'gym', 'energetic', 'high-energy'});
          positive.addAll({
            'workout',
            'energetic',
            'edm',
            'trap',
            'bass',
            'hiphop',
            'hip-hop',
            'rap'
          });
          negative.addAll({'sleep', 'calm', 'romantic'});
        } else if (L.contains('sad')) {
          positive.add('sad');
          negative.addAll({'party', 'workout'});
        } else if (L.contains('party')) {
          positive.addAll({'party', 'dance', 'edm'});
          negative.addAll({'sleep', 'sad'});
        } else if (L.contains('focus')) {
          requires.addAll({'lofi'});
          negative.addAll({'party', 'workout'});
        } else if (L.contains('sleep')) {
          requires.addAll({'sleep', 'calm'});
          negative.addAll({'workout', 'party'});
        }
        if (requires.isNotEmpty &&
            !allTags.any(requires.contains) &&
            !toks.any(requires.contains)) {
          return -999.0;
        }
        double s = 0.0;
        for (final t in allTags) {
          if (positive.contains(t)) s += 2.0;
          if (negative.contains(t)) s -= 2.2;
        }
        for (final t in toks) {
          if (positive.contains(t)) s += 1.4;
          if (negative.contains(t)) s -= 1.6;
        }
        return s;
      }

      final rankedPairs = merged.values
          .map((v) =>
              (v: v, score: _personalTasteScore(v, profileMap) + moodScore(v)))
          .where((p) => p.score > -900) // drop hard mismatches
          .toList()
        ..sort((a, b) => b.score.compareTo(a.score));

      final diversified = _pickDiverseQuickPicks(
        rankedPairs,
        target: 30,
        seedIds: seedIds,
        seedArtists: seedArtists,
        profile: profileMap,
      );
      List<Video> finalList = diversified.take(30).toList();
      if (finalList.length < 12) {
        try {
          final hardQuery = () {
            final L = label.toLowerCase();
            if (L.contains('romance')) {
              return '$topLanguage romantic love songs';
            } else if (L.contains('relax')) {
              return '$topLanguage chill relax lofi calm songs';
            } else if (L.contains('feel')) {
              return '$topLanguage happy feel good uplifting songs';
            } else if (L.contains('workout')) {
              return '$topLanguage workout energetic gym songs';
            } else {
              return '$topLanguage $baseQuery';
            }
          }();
          final extra = await _searchMusic(hardQuery,
              limit: 40,
              strictSingles: true,
              personalize: true,
              smartQuery: true,
              excludeBlocked: true,
              sourceQuery: 'mood:$label');
          final extraMap = <String, Video>{
            for (final v in finalList) v.id.value: v
          };
          for (final v in extra) {
            if (!extraMap.containsKey(v.id.value)) {
              extraMap[v.id.value] = v;
            }
          }
          final extraRanked = extraMap.values
              .map((v) => (
                    v: v,
                    score: _personalTasteScore(v, profileMap) + moodScore(v)
                  ))
              .where((p) => p.score > -900)
              .toList()
            ..sort((a, b) => b.score.compareTo(a.score));
          finalList = _pickDiverseQuickPicks(extraRanked,
                  target: 30,
                  seedIds: seedIds,
                  seedArtists: seedArtists,
                  profile: profileMap)
              .take(30)
              .toList();
        } catch (_) {}
      }
      if (label.toLowerCase().contains('romance')) {
        var strict = finalList.where(_isStrictRomanceCandidate).toList();
        if (strict.length < 10) {
          try {
            final extraRomance = await _searchMusic(
              '$topLanguage romantic love songs',
              limit: 50,
              strictSingles: true,
              personalize: false,
              smartQuery: true,
              excludeBlocked: true,
              sourceQuery: 'mood:romance_strict',
            );
            final mergedStrict = <String, Video>{
              for (final v in strict) v.id.value: v,
            };
            for (final v in extraRomance.where(_isStrictRomanceCandidate)) {
              mergedStrict.putIfAbsent(v.id.value, () => v);
            }
            strict = mergedStrict.values.toList();
          } catch (_) {}
        }
        finalList = strict.take(30).toList();
      }
      if (!mounted) return;
      setState(() {
        _searchResults = finalList;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('[MoodFeed] $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _buildHomeScreen(bool isPlaying) {
    if (_homeLoading && _quickRow1.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 140),
        children: [
          Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(
                    color: Colors.greenAccent, strokeWidth: 2.5),
              ),
              const SizedBox(height: 16),
              Text('Loading your music...',
                  style: TextStyle(color: Colors.grey[600], fontSize: 14)),
            ]),
          ),
        ],
      );
    }

    final allQuick = _quickRow1;
    final preferOfficialYtHome = _usingYtMusicHomeFeed &&
        (allQuick.isNotEmpty ||
            _ytHomeMixes.isNotEmpty ||
            _ytMusicHomeShelves.isNotEmpty);
    final quickDebugSignature =
        allQuick.take(5).map((v) => v.id.value).join('|');
    if (allQuick.isNotEmpty &&
        quickDebugSignature != _lastQuickUiDebugSignature) {
      _lastQuickUiDebugSignature = quickDebugSignature;
      debugPrint('[UI] Rendering Quick Picks: ${allQuick.length} songs');
      for (final v in allQuick.take(5)) {
        debugPrint('  - ${_cleanTitle(v.title)} by ${_cleanAuthor(v.author)}');
      }
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.only(top: 4, bottom: _nowPlaying != null ? 16 : 8),
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _homeGreeting(),
                style: TextStyle(
                  color: Colors.grey[500],
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.25,
                ),
              ),
              const SizedBox(height: 5),
              RichText(
                  text: const TextSpan(
                style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1.2,
                    height: 1),
                children: [
                  TextSpan(
                      text: 'Beast ', style: TextStyle(color: Colors.white)),
                  TextSpan(
                      text: 'Music',
                      style: TextStyle(color: Colors.greenAccent)),
                ],
              )),
            ],
          ),
        ),

        // Mood Chips like YT Music's Podcasts/Romance/Feel good row
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _moodChips.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (ctx, i) {
              final chip = _moodChips[i];
              return GestureDetector(
                onTap: () {
                  unawaited(_openMoodFeed(chip['label']!, chip['query']!));
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                  decoration: BoxDecoration(
                    color: const Color(0xFF191919),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: Colors.grey.shade800, width: 0.8),
                  ),
                  child: Text(chip['label']!,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600)),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 20),

        // Quick Picks
        if (allQuick.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 16, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Expanded(
                  child: Text('Quick picks',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 23,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.65)),
                ),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: () {
                    final quickQueue = _buildQuickPlayAllQueue(allQuick);
                    if (quickQueue.isEmpty) return;
                    setState(() {
                      _playQueue = quickQueue;
                      _radioMode = false;
                    });
                    _playFromUserAction(
                      quickQueue.first,
                      0,
                      tasteWeight: 0.65,
                      source: 'quick_play_all',
                    );
                  },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.greenAccent,
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.play_arrow_rounded,
                          color: Colors.black, size: 17),
                      SizedBox(width: 3),
                      Text('Play all',
                          style: TextStyle(
                              color: Colors.black,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700)),
                    ]),
                  ),
                ),
              ],
            ),
          ),
          if (_quickRow1Label.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
              child: Text(_quickRow1Label,
                  style: TextStyle(
                      color: Colors.grey[500],
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.1)),
            )
          else
            const SizedBox(height: 10),
          _buildQuickPicksGrid(allQuick, isPlaying),
          const SizedBox(height: 28),
        ],

        if (_ytHomeMixes.isNotEmpty)
          _buildPlaylistSection(
            title: 'Mixed for you',
            subtitle:
                (_ytMusicSessionValid || (_ytAccessToken ?? '').isNotEmpty)
                    ? 'Pulled from your verified YouTube Music home feed'
                    : 'Pulled from the YouTube Music guest home feed',
            playlists: _ytHomeMixes,
          ),

        if (_ytMusicHomeShelves.isNotEmpty)
          for (final shelf in _ytMusicHomeShelves)
            _buildSection(
              title: shelf.title,
              subtitle: shelf.subtitle.isEmpty
                  ? ((_ytMusicSessionValid || (_ytAccessToken ?? '').isNotEmpty)
                      ? 'From your verified YouTube Music feed'
                      : 'From the YouTube Music guest feed')
                  : shelf.subtitle,
              videos: shelf.videos,
            )
        else ...[
          if (_newReleases.isNotEmpty)
            _buildSection(
                title: 'New Releases',
                subtitle: 'Fresh off the press',
                videos: _newReleases),
          if (_hindiHits.isNotEmpty)
            _buildSection(
                title: 'Hindi Picks',
                subtitle: 'Personal Hindi recommendations',
                videos: _hindiHits),
          if (_moodChill.isNotEmpty)
            _buildSection(
                title: 'Chill Vibes',
                subtitle: 'Relax & unwind',
                videos: _moodChill),
        ],

        if (_becauseYouLikedLoading || _becauseYouLiked.isNotEmpty)
          _buildBecauseYouLikedSection(),

        if (!preferOfficialYtHome) ...[
          _buildSpeedDialSection(isPlaying),
          _buildTrendingByCountrySection(isPlaying),
        ],

        if (_homeLoading)
          const Padding(
              padding: EdgeInsets.all(20),
              child: Center(
                  child: CircularProgressIndicator(
                      color: Colors.greenAccent, strokeWidth: 2))),

        const SizedBox(height: 8),
      ],
    );
  }

  // Quick Picks: YT Music style rows with dividers
  Widget _buildQuickPicksGrid(List<Video> videos, bool isPlaying) {
    const double rowH = 72.0;
    final int pageCount = min(
      (videos.length / _quickPicksItemsPerPage).ceil(),
      _quickPicksMaxPages,
    );
    if (pageCount == 0) return const SizedBox.shrink();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: _quickPicksItemsPerPage * rowH,
          child: PageView.builder(
            controller: _quickPicksCtrl,
            itemCount: pageCount,
            onPageChanged: (p) {
              setState(() => _quickPicksPage = p);
            },
            itemBuilder: (ctx, page) {
              final start = page * _quickPicksItemsPerPage;
              final end =
                  (start + _quickPicksItemsPerPage).clamp(0, videos.length);
              final pageVideos = videos.sublist(start, end);

              return Column(
                children: pageVideos.asMap().entries.map((entry) {
                  final idx = entry.key;
                  final video = entry.value;
                  final isActive = _nowPlaying?.id == video.id;
                  final cleanName =
                      _cleanTitle(video.title, author: video.author);
                  final author = _displayArtistNames(video);
                  final isLast = idx == pageVideos.length - 1;

                  return Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () {
                              unawaited(_startRadioFromSong(video));
                            },
                            onDoubleTap: () {
                              _toggleLike(video);
                              HapticFeedback.lightImpact();
                            },
                            onLongPress: () => _showSongMenu(video),
                            behavior: HitTestBehavior.opaque,
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16),
                              child: Row(children: [
                                // Thumbnail
                                RepaintBoundary(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: Stack(children: [
                                      CachedNetworkImage(
                                        imageUrl: video.thumbnails.mediumResUrl,
                                        width: 52,
                                        height: 52,
                                        memCacheWidth: 104,
                                        memCacheHeight: 104,
                                        fit: BoxFit.cover,
                                        placeholder: (_, __) => Container(
                                            color: Colors.grey[850],
                                            width: 52,
                                            height: 52),
                                        errorWidget: (_, __, ___) => Container(
                                            color: Colors.grey[850],
                                            width: 52,
                                            height: 52,
                                            child: const Icon(Icons.music_note,
                                                color: Colors.grey, size: 20)),
                                      ),
                                      if (isActive)
                                        Positioned.fill(
                                          child: Container(
                                            color: Colors.black
                                                .withValues(alpha: 0.5),
                                            child: Center(
                                              child: _isBuffering &&
                                                      _nowPlaying?.id ==
                                                          video.id
                                                  ? const SizedBox(
                                                      width: 16,
                                                      height: 16,
                                                      child:
                                                          CircularProgressIndicator(
                                                              color: Colors
                                                                  .greenAccent,
                                                              strokeWidth: 2))
                                                  : _buildEqualizerBars(
                                                      size: 14,
                                                      color:
                                                          Colors.greenAccent),
                                            ),
                                          ),
                                        ),
                                    ]),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                // Title + artist
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(cleanName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              color: isActive
                                                  ? Colors.greenAccent
                                                  : Colors.white,
                                              fontSize: 13.5,
                                              fontWeight: FontWeight.w500,
                                              letterSpacing: -0.1)),
                                      const SizedBox(height: 2),
                                      Text(author,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              color: Colors.grey[600],
                                              fontSize: 12)),
                                    ],
                                  ),
                                ),
                                // Three-dot
                                GestureDetector(
                                  onTap: () => _showSongMenu(video),
                                  behavior: HitTestBehavior.opaque,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8),
                                    child: Icon(Icons.more_vert_rounded,
                                        color: Colors.grey[700], size: 20),
                                  ),
                                ),
                              ]),
                            ),
                          ),
                        ),
                        // Divider between items, not after last
                        if (!isLast)
                          Divider(
                              height: 1,
                              thickness: 0.5,
                              indent: 80,
                              endIndent: 0,
                              color: Colors.grey.shade900),
                      ],
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ),

        // Page indicator dots
        if (pageCount > 1)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(pageCount, (i) {
                final active = i == _quickPicksPage;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: active ? 18 : 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: active ? Colors.greenAccent : Colors.grey[800],
                    borderRadius: BorderRadius.circular(3),
                  ),
                );
              }),
            ),
          ),
      ],
    );
  }

  // NEW: Trending by country section
  Widget _buildSpeedDialSection(bool isPlaying) {
    final pool = _buildSpeedDialPool(limit: 48);
    if (pool.isEmpty) return const SizedBox.shrink();

    const songsPerPage = 8;
    final pageCount = (pool.length / songsPerPage).ceil().clamp(1, 99);
    const horizontalPadding = 16.0;
    const crossSpacing = 6.0;
    const mainSpacing = 6.0;
    const childAspectRatio = 0.84;
    const rows = 3;
    const cols = 3;
    final gridWidth =
        MediaQuery.sizeOf(context).width - (horizontalPadding * 2);
    final tileWidth = (gridWidth - (crossSpacing * (cols - 1))) / cols;
    final tileHeight = tileWidth / childAspectRatio;
    final gridHeight = (tileHeight * rows) + (mainSpacing * (rows - 1));
    final label = (_ytAccountName ?? '').trim().isNotEmpty
        ? (_ytAccountName ?? '').trim().toUpperCase()
        : 'FOR YOU';
    final avatarSeed = (_ytAccountName ?? '').trim().isNotEmpty
        ? (_ytAccountName ?? '').trim()
        : 'B';
    final avatarLetter = avatarSeed[0].toUpperCase();
    final activePage = _speedDialPage.clamp(0, pageCount - 1);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 2, 20, 2),
        child: Row(children: [
          Container(
            width: 34,
            height: 34,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [Color(0xFF2A2A2A), Color(0xFF131313)],
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              avatarLetter,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
              child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.grey[500],
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                ),
              ),
              const Text(
                'Speed dial',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
            ],
          )),
        ]),
      ),
      const SizedBox(height: 10),
      SizedBox(
        height: gridHeight,
        child: PageView.builder(
          controller: _speedDialCtrl,
          itemCount: pageCount,
          onPageChanged: (p) => setState(() => _speedDialPage = p),
          itemBuilder: (ctx, page) {
            final start = page * songsPerPage;
            final end = min(start + songsPerPage, pool.length);
            final pageSongs = pool.sublist(start, end);

            return GridView.count(
              crossAxisCount: cols,
              physics: const NeverScrollableScrollPhysics(),
              shrinkWrap: true,
              padding:
                  const EdgeInsets.symmetric(horizontal: horizontalPadding),
              crossAxisSpacing: crossSpacing,
              mainAxisSpacing: mainSpacing,
              childAspectRatio: childAspectRatio,
              children: [
                for (int i = 0; i < pageSongs.length; i++)
                  _buildSpeedDialCard(
                    pageSongs[i],
                    source: pool,
                    sourceIndex: start + i,
                    isPlaying: isPlaying,
                  ),
                _buildSpeedDialRandomCard(pool),
              ],
            );
          },
        ),
      ),
      if (pageCount > 1)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(pageCount, (i) {
              final active = i == activePage;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: active ? 14 : 5,
                height: 5,
                decoration: BoxDecoration(
                  color: active ? Colors.white : Colors.grey[700],
                  borderRadius: BorderRadius.circular(3),
                ),
              );
            }),
          ),
        ),
      const SizedBox(height: 20),
    ]);
  }

  Widget _buildSpeedDialCard(
    Video video, {
    required List<Video> source,
    required int sourceIndex,
    required bool isPlaying,
  }) {
    final pinned = _isSpeedDialPinned(video);
    final isActive = _nowPlaying?.id == video.id;
    final showEq = isActive && isPlaying;

    return GestureDetector(
      onTap: () => _playSpeedDialSong(source, sourceIndex),
      onDoubleTap: () {
        _toggleLike(video);
        HapticFeedback.lightImpact();
      },
      onLongPress: () => _showSongMenu(video),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            CachedNetworkImage(
              imageUrl: video.thumbnails.mediumResUrl,
              fit: BoxFit.cover,
              placeholder: (_, __) => Container(color: Colors.grey[850]),
              errorWidget: (_, __, ___) => Container(
                color: Colors.grey[850],
                child: const Icon(Icons.music_note_rounded,
                    color: Colors.grey, size: 22),
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: isActive ? 0.20 : 0.08),
                      Colors.black.withValues(alpha: 0.22),
                      Colors.black.withValues(alpha: 0.85),
                    ],
                  ),
                ),
              ),
            ),
            if (showEq)
              Positioned(
                left: 8,
                top: 8,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child:
                      _buildEqualizerBars(size: 11, color: Colors.greenAccent),
                ),
              ),
            Positioned(
              top: 6,
              right: 6,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _toggleSpeedDialPin(video, showToast: false),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                    color: pinned ? Colors.white : Colors.white70,
                    size: 14,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: Text(
                _cleanTitle(video.title),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isActive ? Colors.greenAccent : Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.1,
                  shadows: const [
                    Shadow(color: Colors.black, blurRadius: 8),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSpeedDialRandomCard(List<Video> source) {
    return GestureDetector(
      onTap: () => _playSpeedDialRandom(source),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    const Color(0xFF0F0F10),
                    const Color(0xFF151527),
                    const Color(0xFF2A1031).withValues(alpha: 0.9),
                  ],
                ),
              ),
            ),
            CustomPaint(painter: _DotPatternPainter()),
            Center(
              child: Wrap(
                spacing: 18,
                runSpacing: 16,
                alignment: WrapAlignment.center,
                children: List.generate(6, (i) {
                  return Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.65),
                      shape: BoxShape.circle,
                    ),
                  );
                }),
              ),
            ),
            Positioned(
              left: 10,
              right: 10,
              bottom: 10,
              child: Row(children: [
                const Expanded(
                  child: Text(
                    'Random',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.1,
                    ),
                  ),
                ),
                Icon(Icons.arrow_forward_ios_rounded,
                    color: Colors.white.withValues(alpha: 0.9), size: 12),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTrendingByCountrySection(bool isPlaying) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 12, 10),
        child: Row(children: [
          const Text('Trending Charts',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3)),
          const Spacer(),
          if (_trendingVideos.isNotEmpty)
            TextButton(
              onPressed: () => setState(() {
                _searchResults = List<Video>.from(_trendingVideos);
                _isSearchMode = true;
                _radioMode = false;
              }),
              style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
              child: Text('See all',
                  style: TextStyle(
                      color: Colors.greenAccent.withValues(alpha: 0.9),
                      fontSize: 13,
                      fontWeight: FontWeight.w500)),
            ),
        ]),
      ),
      // Country chips
      SizedBox(
        height: 36,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: _trendingCountries.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (ctx, i) {
            final selected = _selectedCountryIdx == i;
            return GestureDetector(
              onTap: () {
                setState(() => _selectedCountryIdx = i);
                unawaited(_loadTrendingByCountry(i));
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color:
                      selected ? Colors.greenAccent : const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color:
                          selected ? Colors.greenAccent : Colors.grey.shade800,
                      width: 0.8),
                ),
                child: Text(_trendingCountries[i],
                    style: TextStyle(
                        color: selected ? Colors.black : Colors.white,
                        fontSize: 13,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500)),
              ),
            );
          },
        ),
      ),
      const SizedBox(height: 10),
      if (_trendingLoading)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Center(
              child: CircularProgressIndicator(
                  color: Colors.greenAccent, strokeWidth: 2)),
        )
      else if (_trendingVideos.isNotEmpty) ...[
        SizedBox(
          height: 204,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _trendingVideos.take(15).length,
            itemBuilder: (ctx, i) => _buildCard(_trendingVideos, i, 140, 140),
          ),
        ),
      ],
      const SizedBox(height: 20),
    ]);
  }

  // NEW: Because you liked section
  Widget _buildBecauseYouLikedSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 12, 10),
        child: Row(children: [
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                const Text('Because you liked',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.55)),
                if (_becauseYouLikedLabel.isNotEmpty)
                  Text('"$_becauseYouLikedLabel"',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: Colors.grey[500],
                          fontStyle: FontStyle.italic,
                          fontSize: 13)),
              ])),
          if (_becauseYouLiked.isNotEmpty)
            TextButton(
              onPressed: () => setState(() {
                _searchResults = List<Video>.from(_becauseYouLiked);
                _isSearchMode = true;
                _radioMode = false;
              }),
              style: TextButton.styleFrom(
                  backgroundColor: const Color(0xFF1B1B1B),
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  )),
              child: Text('See all',
                  style: TextStyle(
                      color: Colors.greenAccent.withValues(alpha: 0.95),
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700)),
            ),
        ]),
      ),
      if (_becauseYouLikedLoading)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Center(
              child: CircularProgressIndicator(
                  color: Colors.greenAccent, strokeWidth: 2)),
        )
      else if (_becauseYouLiked.isNotEmpty)
        SizedBox(
          height: 204,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _becauseYouLiked.length,
            itemBuilder: (ctx, i) => _buildCard(_becauseYouLiked, i, 140, 140),
          ),
        ),
      const SizedBox(height: 20),
    ]);
  }

  Widget _buildPlaylistSection({
    required String title,
    required String subtitle,
    required List<BeastPlaylist> playlists,
  }) {
    if (playlists.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 12, 12),
        child: Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.55)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: TextStyle(
                        color: Colors.grey[500],
                        fontSize: 13,
                        fontWeight: FontWeight.w500)),
              ],
            ),
          ),
          TextButton(
            onPressed: () => setState(() => _selectedTab = 2),
            style: TextButton.styleFrom(
                backgroundColor: const Color(0xFF1B1B1B),
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                )),
            child: Text('See all',
                style: TextStyle(
                    color: Colors.greenAccent.withValues(alpha: 0.95),
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700)),
          ),
        ]),
      ),
      SizedBox(
        height: 214,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: playlists.length,
          itemBuilder: (ctx, i) => SizedBox(
            width: 152,
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: _buildPlaylistCard(playlists[i]),
            ),
          ),
        ),
      ),
      const SizedBox(height: 20),
    ]);
  }

  Widget _buildSection({
    required String title,
    required String subtitle,
    required List<Video> videos,
  }) {
    const double cardW = 136;
    const double cardH = 136;
    const double textH = 58;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 12, 12),
        child: Row(children: [
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.55)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: TextStyle(
                        color: Colors.grey[500],
                        fontSize: 13,
                        fontWeight: FontWeight.w500)),
              ])),
          TextButton(
            onPressed: () => setState(() {
              _searchResults = List<Video>.from(videos);
              _isSearchMode = true;
              _radioMode = false;
            }),
            style: TextButton.styleFrom(
                backgroundColor: const Color(0xFF1B1B1B),
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                )),
            child: Text('See all',
                style: TextStyle(
                    color: Colors.greenAccent.withValues(alpha: 0.95),
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700)),
          ),
        ]),
      ),
      SizedBox(
        height: cardH + textH,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: videos.length,
          itemBuilder: (ctx, i) => _buildCard(videos, i, cardW, cardH),
        ),
      ),
      const SizedBox(height: 20),
    ]);
  }

  Widget _buildCard(List<Video> section, int i, double cardW, double cardH) {
    final video = section[i];
    final isActive = _nowPlaying?.id == video.id;
    final cleanName = _cleanTitle(video.title, author: video.author);
    final author = _cleanAuthor(video.author);
    return GestureDetector(
      onTap: () {
        setState(() {
          _playQueue = List<Video>.from(section);
          _radioMode = false;
        });
        _notifyQueueChanged();
        _playFromUserAction(video, i, source: 'card_tap');
      },
      onDoubleTap: () {
        _toggleLike(video);
        HapticFeedback.lightImpact();
      },
      onLongPress: () => _showSongMenu(video),
      child: SizedBox(
        width: cardW,
        child: Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: CachedNetworkImage(
                    imageUrl: video.thumbnails.mediumResUrl,
                    width: cardW - 12,
                    height: cardH,
                    fit: BoxFit.cover,
                    placeholder: (_, __) =>
                        _shimmerBox(cardW - 12, cardH, radius: 12),
                    errorWidget: (_, __, ___) => Container(
                        color: Colors.grey[850],
                        width: cardW - 12,
                        height: cardH,
                        child:
                            const Icon(Icons.music_note, color: Colors.grey)),
                  ),
                ),
                if (isActive)
                  Positioned.fill(
                      child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      color: Colors.greenAccent.withValues(alpha: 0.25),
                      child: const Center(
                          child: _EqualizerBars(
                              size: 28, color: Colors.greenAccent)),
                    ),
                  )),
                if (!isActive)
                  Positioned(
                      right: 8,
                      bottom: 8,
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.black.withValues(alpha: 0.65)),
                        child: const Icon(Icons.play_arrow_rounded,
                            color: Colors.white, size: 18),
                      )),
                if (_isLiked(video))
                  Positioned(
                      left: 6,
                      top: 6,
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.black.withValues(alpha: 0.7)),
                        child: const Icon(Icons.favorite_rounded,
                            color: Colors.pinkAccent, size: 13),
                      )),
                Positioned(
                    right: 8,
                    top: 6,
                    child: GestureDetector(
                      onTap: () => _showSongMenu(video),
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.black.withValues(alpha: 0.7)),
                        child: const Icon(Icons.more_vert_rounded,
                            color: Colors.white, size: 15),
                      ),
                    )),
              ]),
              const SizedBox(height: 7),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 48),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(cleanName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: isActive ? Colors.greenAccent : Colors.white,
                            fontSize: 12,
                            fontWeight:
                                isActive ? FontWeight.bold : FontWeight.w500,
                            height: 1.3)),
                    const SizedBox(height: 2),
                    Text(author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            TextStyle(color: Colors.grey[600], fontSize: 10)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // EXPLORE TAB
  Widget _buildExploreTab(bool isPlaying) {
    return Column(children: [
      _buildSearchBar(),
      const SizedBox(height: 12),
      SizedBox(
        height: 38,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: _genres.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (ctx, i) {
            final genre = _genres[i];
            final selected = _selectedGenre == genre;
            return GestureDetector(
              onTap: () => _loadGenre(genre),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color:
                      selected ? Colors.greenAccent : const Color(0xFF1A1A1A),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color:
                          selected ? Colors.greenAccent : Colors.grey.shade800),
                ),
                child: Text(genre,
                    style: TextStyle(
                        color: selected ? Colors.black : Colors.grey[300],
                        fontSize: 13,
                        fontWeight:
                            selected ? FontWeight.bold : FontWeight.normal)),
              ),
            );
          },
        ),
      ),
      const SizedBox(height: 12),
      Expanded(
          child: _exploreLoading
              ? const Center(
                  child: CircularProgressIndicator(color: Colors.greenAccent))
              : _exploreResults.isEmpty && _selectedGenre == null
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.explore_outlined,
                          color: Colors.grey[700], size: 64),
                      const SizedBox(height: 12),
                      Text('Pick a genre to explore',
                          style:
                              TextStyle(color: Colors.grey[600], fontSize: 16)),
                    ]))
                  : _exploreResults.isEmpty
                      ? Center(
                          child: Text('No results for $_selectedGenre',
                              style: TextStyle(color: Colors.grey[600])))
                      : _buildSongList(_exploreResults, isPlaying)),
    ]);
  }

  // LIBRARY TAB
  Widget _buildLibraryTab(bool isPlaying) {
    if (_openPlaylist != null) {
      return _buildPlaylistDetail(_openPlaylist!, isPlaying);
    }

    final sorted = _sortedPlaylists;
    // FIX: always include liked playlist was hidden when allPlaylists.length <= 1
    final allPlaylists = <BeastPlaylist>[_likedPlaylist, ...sorted];

    // Include system mixes after liked, before user playlists.
    final displayPlaylists = <BeastPlaylist>[
      _likedPlaylist,
      ..._ytHomeMixes,
      ..._dailyMixes,
      ...sorted,
    ];

    return Column(children: [
      // Header row
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 16, 8),
        child: Row(children: [
          const Text('Your Library',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold)),
          const Spacer(),
          if (_librarySortMode == 0 && _playlists.isNotEmpty)
            IconButton(
              tooltip: _libraryReorderMode ? 'Done' : 'Reorder',
              icon: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                    color: _libraryReorderMode
                        ? Colors.greenAccent.withValues(alpha: 0.2)
                        : Colors.transparent,
                    shape: BoxShape.circle),
                child: Icon(
                    _libraryReorderMode
                        ? Icons.check_rounded
                        : Icons.swap_vert_rounded,
                    color: _libraryReorderMode
                        ? Colors.greenAccent
                        : Colors.grey[500],
                    size: 20),
              ),
              onPressed: () =>
                  setState(() => _libraryReorderMode = !_libraryReorderMode),
            ),
          IconButton(
            onPressed: _showCreatePlaylistDialog,
            tooltip: 'New Playlist',
            icon: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                  color: Colors.greenAccent.withValues(alpha: 0.15),
                  shape: BoxShape.circle),
              child: const Icon(Icons.add_rounded,
                  color: Colors.greenAccent, size: 20),
            ),
          ),
        ]),
      ),

      // Sort chips
      if (_playlists.isNotEmpty ||
          _dailyMixes.isNotEmpty ||
          _ytHomeMixes.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            _sortChip(label: 'Custom', index: 0),
            _sortChip(label: 'A-Z', index: 1),
            _sortChip(label: 'Songs', index: 2),
            _sortChip(label: 'Date', index: 3),
          ]),
        ),

      // Daily Mix promo banner (shown if generated)
      if (_dailyMixes.isNotEmpty && _openPlaylist == null)
        _buildDailyMixBanner(),

      // Playlist grid / reorder list
      // FIX: was `allPlaylists.length <= 1` that hid liked playlist when
      // no user playlists existed. Now shows grid whenever list is non-empty.
      Expanded(
        child: displayPlaylists.isEmpty
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.library_music_outlined,
                    color: Colors.grey[700], size: 64),
                const SizedBox(height: 12),
                Text('No playlists yet',
                    style: TextStyle(color: Colors.grey[600], fontSize: 16)),
              ]))
            : _libraryReorderMode && _librarySortMode == 0
                ? ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: allPlaylists.length,
                    proxyDecorator: (child, _, __) => Material(
                      elevation: 8,
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(14),
                      child: child,
                    ),
                    onReorder: (oldIdx, newIdx) {
                      if (oldIdx == 0 || newIdx == 0) return;
                      setState(() {
                        final pOld = oldIdx - 1;
                        var pNew = newIdx - 1;
                        if (pNew > pOld) pNew -= 1;
                        if (pNew < 0) pNew = 0;
                        if (pNew > _playlists.length - 1) {
                          pNew = _playlists.length - 1;
                        }
                        final item = _playlists.removeAt(pOld);
                        _playlists.insert(pNew, item);
                      });
                    },
                    itemBuilder: (ctx, i) {
                      final pl = allPlaylists[i];
                      return _buildPlaylistListTile(pl, key: ValueKey(pl.id));
                    },
                  )
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 14,
                      crossAxisSpacing: 14,
                      childAspectRatio: 0.80,
                    ),
                    itemCount: displayPlaylists.length,
                    itemBuilder: (ctx, i) =>
                        _buildPlaylistCard(displayPlaylists[i]),
                  ),
      ),
    ]);
  }

  // NEW: Daily mix promo banner
  Widget _buildDailyMixBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: const LinearGradient(
          colors: [Color(0xFF0d3320), Color(0xFF1a5c3a)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.3)),
      ),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
              color: Colors.greenAccent.withValues(alpha: 0.2),
              shape: BoxShape.circle),
          child: const Icon(Icons.auto_awesome_rounded,
              color: Colors.greenAccent, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Daily Mixes Ready!',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold)),
          Text('${_dailyMixes.length} personalized mixes from your history',
              style: TextStyle(color: Colors.grey[400], fontSize: 11)),
        ])),
      ]),
    );
  }

  Widget _sortChip({required String label, required int index}) {
    final active = _librarySortMode == index;
    return GestureDetector(
      onTap: () => setState(() {
        _librarySortMode = index;
        _libraryReorderMode = false;
      }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: active
              ? Colors.greenAccent.withValues(alpha: 0.2)
              : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: active
                  ? Colors.greenAccent.withValues(alpha: 0.7)
                  : Colors.grey.shade800),
        ),
        child: Text(label,
            style: TextStyle(
                color: active ? Colors.greenAccent : Colors.grey[500],
                fontSize: 12,
                fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
      ),
    );
  }

  Widget _buildPlaylistListTile(BeastPlaylist pl, {required Key key}) {
    final isLikedPl = pl.id == '__liked__';
    final isDailyMix = pl.id.startsWith('__dailymix_');
    return Container(
      key: key,
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
          color: const Color(0xFF141414),
          borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: isLikedPl
              ? Container(
                  width: 52,
                  height: 52,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                        colors: [Color(0xFF1a1a2e), Color(0xFF6d28d9)]),
                  ),
                  child: const Icon(Icons.favorite_rounded,
                      color: Colors.pinkAccent, size: 28),
                )
              : isDailyMix
                  ? Container(
                      width: 52,
                      height: 52,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                            colors: [Color(0xFF0d3320), Color(0xFF1a5c3a)]),
                      ),
                      child: const Icon(Icons.auto_awesome_rounded,
                          color: Colors.greenAccent, size: 26),
                    )
                  : pl.coverUrl != null
                      ? CachedNetworkImage(
                          imageUrl: pl.coverUrl!,
                          width: 52,
                          height: 52,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => _playlistCoverFallback())
                      : SizedBox(
                          width: 52,
                          height: 52,
                          child: _playlistCoverFallback()),
        ),
        title: Text(pl.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w600)),
        subtitle: Text(_playlistDownloadLabel(pl),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Colors.grey[600], fontSize: 12)),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (!isLikedPl && !isDailyMix)
            Icon(Icons.drag_handle_rounded, color: Colors.grey[600], size: 22),
        ]),
        onTap: () => setState(() {
          _openPlaylist = pl;
          _playlistSearchQuery = '';
          _playlistSearchCtrl.clear();
          _libraryReorderMode = false;
        }),
        onLongPress: (isLikedPl || isDailyMix)
            ? null
            : () => _showPlaylistOptionsMenu(pl),
      ),
    );
  }

  void _showPlaylistOptionsMenu(BeastPlaylist pl) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        final stats = _playlistDownloadStats(pl);
        final total = stats['total'] ?? 0;
        final downloaded = stats['downloaded'] ?? 0;
        final queued = stats['queued'] ?? 0;
        final downloading = stats['downloading'] ?? 0;
        final paused = stats['paused'] ?? 0;
        final failed = stats['failed'] ?? 0;
        final hasActive = queued + downloading > 0;
        final hasPaused = paused + failed > 0;
        final hasTasks = hasActive || hasPaused;

        return Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
                color: Colors.grey[700],
                borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(children: [
              const Icon(Icons.queue_music_rounded,
                  color: Colors.greenAccent, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(pl.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 15)),
                    if (total > 0) ...[
                      const SizedBox(height: 2),
                      Text(
                        '$downloaded of $total downloaded',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.grey[500], fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
            ]),
          ),
          const Divider(color: Color(0xFF252525), height: 1),
          _menuItem(ctx, Icons.edit_rounded, 'Rename', Colors.white, () {
            Navigator.pop(ctx);
            _showRenamePlaylistDialog(pl);
          }),
          _menuItem(ctx, Icons.download_for_offline_rounded,
              'Download Playlist', Colors.white, () {
            Navigator.pop(ctx);
            unawaited(_downloadPlaylist(pl));
          }),
          if (hasActive)
            _menuItem(ctx, Icons.pause_circle_rounded, 'Pause Downloads',
                Colors.amberAccent, () {
              Navigator.pop(ctx);
              _pausePlaylistDownloads(pl);
            }),
          if (hasPaused)
            _menuItem(ctx, Icons.play_arrow_rounded, 'Resume Downloads',
                Colors.lightBlueAccent, () {
              Navigator.pop(ctx);
              _resumePlaylistDownloads(pl);
            }),
          if (hasTasks)
            _menuItem(
                ctx, Icons.close_rounded, 'Cancel Downloads', Colors.redAccent,
                () {
              Navigator.pop(ctx);
              _cancelPlaylistDownloads(pl);
            }),
          _menuItem(
              ctx, Icons.delete_rounded, 'Delete Playlist', Colors.redAccent,
              () {
            Navigator.pop(ctx);
            setState(() => _playlists.remove(pl));
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text('"${pl.name}" deleted',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                duration: const Duration(seconds: 2)));
          }),
          const SizedBox(height: 8),
        ]);
      },
    );
  }

  Widget _buildPlaylistCard(BeastPlaylist pl) {
    final isLikedPl = pl.id == '__liked__';
    final isDailyMix = pl.id.startsWith('__dailymix_');
    return GestureDetector(
      onTap: () => setState(() {
        _openPlaylist = pl;
        _playlistSearchQuery = '';
        _playlistSearchCtrl.clear();
        _libraryReorderMode = false;
      }),
      onLongPress: (pl.isSystem) ? null : () => _showPlaylistOptionsMenu(pl),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF141414),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(14)),
              child: isLikedPl
                  ? Container(
                      width: double.infinity,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Color(0xFF1a1a2e), Color(0xFF6d28d9)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                      ),
                      child: const Center(
                          child: Icon(Icons.favorite_rounded,
                              color: Colors.pinkAccent, size: 52)),
                    )
                  : isDailyMix
                      ? Container(
                          width: double.infinity,
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              colors: [Color(0xFF0d3320), Color(0xFF1a5c3a)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                          ),
                          child: const Center(
                              child: Icon(Icons.auto_awesome_rounded,
                                  color: Colors.greenAccent, size: 48)),
                        )
                      : pl.coverUrl != null
                          ? CachedNetworkImage(
                              imageUrl: pl.coverUrl!,
                              width: double.infinity,
                              fit: BoxFit.cover,
                              errorWidget: (_, __, ___) =>
                                  _playlistCoverFallback(),
                            )
                          : _playlistCoverFallback(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(pl.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(_playlistDownloadLabel(pl),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.grey[600], fontSize: 11)),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _playlistCoverFallback() => Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF1a1a1a), Color(0xFF2a2a2a)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: const Center(
            child: Icon(Icons.queue_music_rounded,
                color: Colors.greenAccent, size: 48)),
      );

  // Playlist detail
  Widget _buildPlaylistDownloadBar(BeastPlaylist pl) {
    final stats = _playlistDownloadStats(pl);
    final total = stats['total'] ?? 0;
    if (total <= 0) return const SizedBox.shrink();
    final downloaded = stats['downloaded'] ?? 0;
    final queued = stats['queued'] ?? 0;
    final downloading = stats['downloading'] ?? 0;
    final paused = stats['paused'] ?? 0;
    final failed = stats['failed'] ?? 0;
    final hasActive = queued + downloading > 0;
    final hasPaused = paused + failed > 0;
    final hasTasks = hasActive || hasPaused;
    final progress = total <= 0 ? 0.0 : downloaded / total;

    final detailParts = <String>['$downloaded of $total downloaded'];
    if (downloading > 0) detailParts.add('$downloading downloading');
    if (queued > 0) detailParts.add('$queued queued');
    if (paused > 0) detailParts.add('$paused paused');
    if (failed > 0) detailParts.add('$failed failed');

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: const Color(0xFF121212),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF252525)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Playlist downloads',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              detailParts.join(' | '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.grey[500], fontSize: 11),
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: progress.clamp(0.0, 1.0).toDouble(),
                minHeight: 5,
                backgroundColor: const Color(0xFF222222),
                valueColor: AlwaysStoppedAnimation<Color>(
                  downloaded >= total && total > 0
                      ? Colors.greenAccent
                      : Colors.lightBlueAccent,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (downloaded < total || hasTasks)
                  _playlistDownloadChip(
                    label: downloaded < total ? 'Download Missing' : 'Download',
                    icon: Icons.download_for_offline_rounded,
                    color: Colors.greenAccent,
                    onTap: () => unawaited(_downloadPlaylist(pl)),
                  ),
                if (hasActive)
                  _playlistDownloadChip(
                    label: 'Pause',
                    icon: Icons.pause_rounded,
                    color: Colors.amberAccent,
                    onTap: () => _pausePlaylistDownloads(pl),
                  ),
                if (hasPaused)
                  _playlistDownloadChip(
                    label: 'Resume',
                    icon: Icons.play_arrow_rounded,
                    color: Colors.lightBlueAccent,
                    onTap: () => _resumePlaylistDownloads(pl),
                  ),
                if (hasTasks)
                  _playlistDownloadChip(
                    label: 'Cancel',
                    icon: Icons.close_rounded,
                    color: Colors.redAccent,
                    onTap: () => _cancelPlaylistDownloads(pl),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _playlistDownloadChip({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    color: color, fontSize: 12, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _downloadSummaryChip({
    required String label,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  color: color, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _buildPlaylistDetail(BeastPlaylist pl, bool isPlaying) {
    final List<Video> displayVideos = _playlistSearchQuery.isEmpty
        ? pl.videos
        : pl.videos.where((v) {
            final q = _playlistSearchQuery.toLowerCase();
            return v.title.toLowerCase().contains(q) ||
                v.author.toLowerCase().contains(q);
          }).toList();

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 16, 0),
        child: Row(children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
            onPressed: () => setState(() {
              _openPlaylist = null;
              _playlistSearchQuery = '';
              _playlistSearchCtrl.clear();
            }),
          ),
          Expanded(
            child: Text(pl.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
          ),
          if (pl.videos.isNotEmpty)
            IconButton(
              icon: Icon(Icons.download_for_offline_rounded,
                  color: Colors.grey[500], size: 22),
              tooltip: 'Download playlist',
              onPressed: () => unawaited(_downloadPlaylist(pl)),
            ),
          if (!pl.isSystem)
            IconButton(
              icon: Icon(Icons.edit_rounded, color: Colors.grey[600], size: 20),
              tooltip: 'Rename',
              onPressed: () => _showRenamePlaylistDialog(pl),
            ),
          if (!pl.isSystem)
            IconButton(
              icon: Icon(Icons.delete_outline_rounded,
                  color: Colors.grey[600], size: 22),
              onPressed: () => setState(() {
                _playlists.remove(pl);
                _openPlaylist = null;
              }),
            ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Container(
          height: 40,
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: _playlistSearchQuery.isNotEmpty
                    ? Colors.greenAccent.withValues(alpha: 0.4)
                    : Colors.transparent),
          ),
          child: TextField(
            controller: _playlistSearchCtrl,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            onChanged: (v) => setState(() => _playlistSearchQuery = v),
            decoration: InputDecoration(
              hintText: 'Search in ${pl.name}...',
              hintStyle: TextStyle(color: Colors.grey[600], fontSize: 13),
              prefixIcon: Icon(Icons.search_rounded,
                  color: _playlistSearchQuery.isNotEmpty
                      ? Colors.greenAccent
                      : Colors.grey[600],
                  size: 18),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              suffixIcon: _playlistSearchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close_rounded,
                          color: Colors.grey, size: 16),
                      onPressed: () => setState(() {
                        _playlistSearchQuery = '';
                        _playlistSearchCtrl.clear();
                      }),
                    )
                  : null,
            ),
          ),
        ),
      ),
      Container(
        margin: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        height: 140,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: pl.id == '__liked__'
              ? const LinearGradient(
                  colors: [Color(0xFF1a1a2e), Color(0xFF6d28d9)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : pl.id.startsWith('__dailymix_')
                  ? const LinearGradient(
                      colors: [Color(0xFF0d3320), Color(0xFF1a5c3a)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    )
                  : LinearGradient(
                      colors: [Colors.grey[900]!, Colors.grey[850]!]),
        ),
        child: Stack(children: [
          if (pl.coverUrl != null && !pl.id.startsWith('__'))
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: CachedNetworkImage(
                    imageUrl: pl.coverUrl!,
                    fit: BoxFit.cover,
                    color: Colors.black38,
                    colorBlendMode: BlendMode.darken,
                    errorWidget: (_, __, ___) => const SizedBox()),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (pl.id == '__liked__')
                  const Icon(Icons.favorite_rounded,
                      color: Colors.pinkAccent, size: 36)
                else if (pl.id.startsWith('__dailymix_'))
                  const Icon(Icons.auto_awesome_rounded,
                      color: Colors.greenAccent, size: 36),
                const SizedBox(height: 6),
                Text(pl.name,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold)),
                Text(
                    _playlistSearchQuery.isNotEmpty
                        ? '${displayVideos.length} of ${pl.videos.length} songs'
                        : '${pl.videos.length} songs',
                    style: TextStyle(color: Colors.grey[400], fontSize: 12)),
              ],
            ),
          ),
          if (pl.videos.isNotEmpty)
            Positioned(
                right: 16,
                bottom: 16,
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      _playQueue = List<Video>.from(pl.videos);
                      _radioMode = false;
                    });
                    _playFromUserAction(
                      pl.videos.first,
                      0,
                      tasteWeight: 0.75,
                      source: 'playlist_play_all',
                    );
                  },
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.greenAccent,
                      boxShadow: [
                        BoxShadow(
                            color: Colors.greenAccent.withValues(alpha: 0.4),
                            blurRadius: 12)
                      ],
                    ),
                    child: const Icon(Icons.play_arrow_rounded,
                        color: Colors.black, size: 30),
                  ),
                )),
        ]),
      ),
      _buildPlaylistDownloadBar(pl),
      pl.videos.isEmpty
          ? Expanded(
              child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.music_off_rounded, color: Colors.grey[700], size: 52),
              const SizedBox(height: 12),
              Text('No songs yet',
                  style: TextStyle(color: Colors.grey[600], fontSize: 15)),
              const SizedBox(height: 6),
              Text('Long-press any song to add it here',
                  style: TextStyle(color: Colors.grey[700], fontSize: 12)),
            ])))
          : displayVideos.isEmpty
              ? Expanded(
                  child: Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.search_off_rounded,
                      color: Colors.grey[700], size: 52),
                  const SizedBox(height: 12),
                  Text('No matches for "$_playlistSearchQuery"',
                      style: TextStyle(color: Colors.grey[600], fontSize: 14)),
                ])))
              : Expanded(
                  child: ListView.builder(
                    padding:
                        EdgeInsets.only(bottom: _nowPlaying != null ? 16 : 8),
                    itemCount: displayVideos.length,
                    itemBuilder: (ctx, index) {
                      final video = displayVideos[index];
                      final isActive = _nowPlaying?.id == video.id;
                      final isPlayingNow = isActive && isPlaying;
                      final isDownloaded = _isVideoDownloaded(video);
                      return Container(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 3),
                        decoration: BoxDecoration(
                          color: isActive
                              ? Colors.green.shade900.withValues(alpha: 0.6)
                              : const Color(0xFF141414),
                          borderRadius: BorderRadius.circular(12),
                          border: isActive
                              ? Border.all(
                                  color:
                                      Colors.greenAccent.withValues(alpha: 0.4))
                              : null,
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 4),
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: CachedNetworkImage(
                              imageUrl: video.thumbnails.mediumResUrl,
                              width: 56,
                              height: 56,
                              fit: BoxFit.cover,
                              placeholder: (_, __) => Container(
                                  color: Colors.grey[850],
                                  width: 56,
                                  height: 56),
                              errorWidget: (_, __, ___) => Container(
                                  color: Colors.grey[850],
                                  width: 56,
                                  height: 56,
                                  child: const Icon(Icons.music_note,
                                      color: Colors.grey)),
                            ),
                          ),
                          title: Text(_cleanTitle(video.title),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: isActive
                                      ? Colors.greenAccent
                                      : Colors.white,
                                  fontWeight: isActive
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                  fontSize: 13)),
                          subtitle: GestureDetector(
                            onTap: () => _openArtistPage(video.author),
                            child:
                                Row(mainAxisSize: MainAxisSize.min, children: [
                              Flexible(
                                child: Text(_cleanAuthor(video.author),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: Colors.greenAccent
                                            .withValues(alpha: 0.7),
                                        fontSize: 11)),
                              ),
                              if (isDownloaded) ...[
                                const SizedBox(width: 6),
                                const Icon(Icons.download_done_rounded,
                                    size: 12, color: Colors.greenAccent),
                              ],
                            ]),
                          ),
                          trailing:
                              Row(mainAxisSize: MainAxisSize.min, children: [
                            if (isActive && _isBuffering)
                              const SizedBox(
                                  width: 28,
                                  height: 28,
                                  child: CircularProgressIndicator(
                                      color: Colors.greenAccent,
                                      strokeWidth: 2.5))
                            else
                              Icon(
                                  isPlayingNow
                                      ? Icons.pause_circle_filled
                                      : Icons.play_circle_fill,
                                  color: Colors.greenAccent,
                                  size: 34),
                            const SizedBox(width: 4),
                            GestureDetector(
                              onTap: () => setState(() {
                                if (pl.id == '__liked__') {
                                  _toggleLike(video);
                                } else {
                                  pl.videos.removeWhere(
                                      (v) => v.id.value == video.id.value);
                                }
                              }),
                              child: Icon(Icons.remove_circle_outline_rounded,
                                  color: Colors.grey[700], size: 20),
                            ),
                          ]),
                          onTap: () {
                            setState(() {
                              _playQueue = List<Video>.from(pl.videos);
                              _radioMode = false;
                            });
                            if (isActive && isPlayingNow) {
                              _player.pause();
                            } else if (isActive && !_isBuffering) {
                              _player.play();
                            } else {
                              _playFromUserAction(
                                video,
                                pl.videos.indexOf(video),
                                source: 'playlist_tap',
                              );
                            }
                          },
                        ),
                      );
                    },
                  ),
                ),
    ]);
  }

  // HISTORY TAB
  Widget _buildHistoryTab(bool isPlaying) {
    if (_history.isEmpty && _listeningLogs.isEmpty) {
      return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.history_rounded, color: Colors.grey[700], size: 64),
        const SizedBox(height: 12),
        Text('No history yet',
            style: TextStyle(color: Colors.grey[600], fontSize: 16)),
        const SizedBox(height: 6),
        Text('Songs you play will appear here',
            style: TextStyle(color: Colors.grey[700], fontSize: 13)),
      ]));
    }
    return Column(children: [
      _buildWrappedAnalyticsCard(),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Row(children: [
          const Text('Recently Played',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold)),
          const Spacer(),
          TextButton(
            onPressed: () => setState(() => _history.clear()),
            child: const Text('Clear',
                style: TextStyle(color: Colors.redAccent, fontSize: 13)),
          ),
        ]),
      ),
      Expanded(
        child: _history.isEmpty
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.music_note_rounded,
                    color: Colors.grey[700], size: 52),
                const SizedBox(height: 12),
                Text('No recent songs',
                    style: TextStyle(color: Colors.grey[600], fontSize: 15)),
                const SizedBox(height: 4),
                Text('Your wrapped stats are still available above',
                    style: TextStyle(color: Colors.grey[700], fontSize: 12)),
              ]))
            : _buildSongList(_history, isPlaying),
      ),
    ]);
  }

  Widget _buildWrappedAnalyticsCard() {
    final stats = _buildWrappedStats();
    final plays = (stats['plays'] as int?) ?? 0;
    final minutes = (stats['minutes'] as int?) ?? 0;
    final topSongs = (stats['topSongs'] as List).cast<Map<String, dynamic>>();
    final topSong = topSongs.isNotEmpty ? topSongs.first : null;
    final hasData = plays > 0;
    final topSongLabel = topSong == null
        ? 'No top song yet'
        : '${topSong['title']} | ${topSong['artist']}';
    final periodLabel = _wrappedPeriodLabels[_wrappedPeriod];
    final palette = switch (_wrappedPeriod) {
      0 => [
          const Color(0xFF213A8F),
          const Color(0xFF0D7B8F),
          const Color(0xFF0A2D44)
        ],
      1 => [
          const Color(0xFF5E2A79),
          const Color(0xFFAA3A66),
          const Color(0xFF2E1238)
        ],
      _ => [
          const Color(0xFF7E3E12),
          const Color(0xFFCF7D1D),
          const Color(0xFF2E1A08)
        ],
    };

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          colors: palette,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: palette[1].withValues(alpha: 0.25),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: hasData ? () => _openWrappedStory(stats: stats) : null,
          child: Stack(children: [
            Positioned(
              top: -22,
              right: -14,
              child: Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            Positioned(
              bottom: -30,
              left: -24,
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
              child: Row(children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(12),
                    border:
                        Border.all(color: Colors.white.withValues(alpha: 0.18)),
                  ),
                  child: const Icon(Icons.auto_awesome_rounded,
                      color: Colors.white, size: 22),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'View your $periodLabel Wrap',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        hasData
                            ? '$minutes min | $plays plays | $topSongLabel'
                            : 'Start listening to unlock your story slides',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.82),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  height: 34,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.26),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.16),
                    ),
                  ),
                  child: PopupMenuButton<int>(
                    initialValue: _wrappedPeriod,
                    padding: EdgeInsets.zero,
                    onSelected: (i) => setState(() => _wrappedPeriod = i),
                    icon: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(
                        periodLabel,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.keyboard_arrow_down_rounded,
                          color: Colors.white, size: 16),
                    ]),
                    itemBuilder: (ctx) => List.generate(
                      _wrappedPeriodLabels.length,
                      (i) => PopupMenuItem<int>(
                        value: i,
                        child: Text(_wrappedPeriodLabels[i]),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _compactActionIcon({
    required String tooltip,
    required IconData icon,
    required Color color,
    required VoidCallback onPressed,
    double size = 32,
    double iconSize = 20,
  }) {
    return IconButton(
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: BoxConstraints.tightFor(width: size, height: size),
      splashRadius: size * 0.52,
      icon: Icon(icon, color: color, size: iconSize),
      onPressed: onPressed,
    );
  }

  Widget _buildDownloadsTab() {
    final hasTasks = _downloadTasks.isNotEmpty;
    final pendingCount = _pendingDownloadTaskCount;
    final pausedOrFailedCount = _pausedOrFailedDownloadTaskCount;
    if (_downloads.isEmpty && !hasTasks) {
      return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.download_done_rounded, color: Colors.grey[700], size: 64),
        const SizedBox(height: 12),
        Text('No downloads yet',
            style: TextStyle(color: Colors.grey[600], fontSize: 16)),
        const SizedBox(height: 6),
        Text('Tap download on any song to save it',
            style: TextStyle(color: Colors.grey[700], fontSize: 13)),
      ]));
    }

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Row(children: [
          Expanded(
            child: Text('${_downloads.length} Downloaded',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold)),
          ),
          if (_isDownloading)
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                value: _downloadProgress > 0 ? _downloadProgress : null,
                color: Colors.greenAccent,
                strokeWidth: 2,
              ),
            ),
        ]),
      ),
      if (hasTasks)
        Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF141414),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF252525)),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.download_for_offline_rounded,
                            color: Colors.lightBlueAccent, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Download Queue (${_downloadTasks.length})',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _downloadSummaryChip(
                          label: '${_downloads.length} done',
                          icon: Icons.download_done_rounded,
                          color: Colors.greenAccent,
                        ),
                        _downloadSummaryChip(
                          label: '$pendingCount active/queued',
                          icon: Icons.downloading_rounded,
                          color: Colors.lightBlueAccent,
                        ),
                        if (pausedOrFailedCount > 0)
                          _downloadSummaryChip(
                            label: '$pausedOrFailedCount paused/failed',
                            icon: Icons.pause_circle_rounded,
                            color: Colors.amberAccent,
                          ),
                        if (pendingCount > 0)
                          _playlistDownloadChip(
                            label: 'Pause all',
                            icon: Icons.pause_rounded,
                            color: Colors.amberAccent,
                            onTap: _pauseAllDownloads,
                          ),
                        if (pausedOrFailedCount > 0)
                          _playlistDownloadChip(
                            label: 'Resume all',
                            icon: Icons.play_arrow_rounded,
                            color: Colors.lightBlueAccent,
                            onTap: _resumeAllDownloads,
                          ),
                        _playlistDownloadChip(
                          label: 'Cancel all',
                          icon: Icons.close_rounded,
                          color: Colors.redAccent,
                          onTap: _cancelAllDownloads,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _downloadTasks.length,
                  physics: _downloadTasks.length > 3
                      ? const BouncingScrollPhysics()
                      : const NeverScrollableScrollPhysics(),
                  itemBuilder: (ctx, i) {
                    final task = _downloadTasks[i];
                    final active = _isTaskActive(task);
                    final canResume = task.state == _DownloadTaskState.paused;
                    final canRetry = task.state == _DownloadTaskState.failed;
                    final canPause =
                        task.state == _DownloadTaskState.downloading && active;

                    final icon = switch (task.state) {
                      _DownloadTaskState.queued => Icons.schedule_rounded,
                      _DownloadTaskState.downloading =>
                        Icons.downloading_rounded,
                      _DownloadTaskState.paused => Icons.pause_circle_rounded,
                      _DownloadTaskState.failed => Icons.error_rounded,
                    };
                    final iconColor = switch (task.state) {
                      _DownloadTaskState.queued => Colors.grey,
                      _DownloadTaskState.downloading => Colors.greenAccent,
                      _DownloadTaskState.paused => Colors.amberAccent,
                      _DownloadTaskState.failed => Colors.redAccent,
                    };

                    return ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 0),
                      leading: Icon(icon, color: iconColor, size: 18),
                      title: Text(
                        _cleanTitle(task.video.title),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _downloadTaskLabel(task),
                            style: TextStyle(
                                color: Colors.grey[500], fontSize: 11),
                          ),
                          if (task.state == _DownloadTaskState.downloading)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: LinearProgressIndicator(
                                value: task.progress > 0 ? task.progress : null,
                                minHeight: 2,
                                backgroundColor: const Color(0xFF222222),
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                  Colors.greenAccent,
                                ),
                              ),
                            ),
                        ],
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (canPause)
                            _compactActionIcon(
                              tooltip: 'Pause',
                              icon: Icons.pause_rounded,
                              color: Colors.amberAccent,
                              onPressed: () => _requestPauseDownloadTask(task),
                            )
                          else if (canResume)
                            _compactActionIcon(
                              tooltip: 'Resume',
                              icon: Icons.play_arrow_rounded,
                              color: Colors.greenAccent,
                              onPressed: () => _resumeDownloadTask(task),
                            )
                          else if (canRetry)
                            _compactActionIcon(
                              tooltip: 'Retry',
                              icon: Icons.refresh_rounded,
                              color: Colors.lightBlueAccent,
                              onPressed: () => _retryDownloadTask(task),
                            )
                          else
                            const SizedBox(width: 32),
                          const SizedBox(width: 2),
                          _compactActionIcon(
                            tooltip: 'Remove',
                            icon: Icons.close_rounded,
                            color: Colors.grey,
                            onPressed: () => _cancelDownloadTask(task),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      Expanded(
        child: _downloads.isEmpty
            ? Center(
                child: Text(
                  'Downloads queue is active. Completed songs will appear here.',
                  style: TextStyle(color: Colors.grey[600], fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              )
            : ListView.builder(
                padding: EdgeInsets.only(bottom: _nowPlaying != null ? 16 : 8),
                itemCount: _downloads.length,
                itemBuilder: (ctx, i) {
                  final d = _downloads[i];
                  return Container(
                    margin:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                    decoration: BoxDecoration(
                        color: const Color(0xFF141414),
                        borderRadius: BorderRadius.circular(12)),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: CachedNetworkImage(
                          imageUrl: d['thumbnailUrl'] ?? '',
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => Container(
                              color: Colors.grey[850],
                              width: 56,
                              height: 56,
                              child: const Icon(Icons.music_note,
                                  color: Colors.grey)),
                        ),
                      ),
                      title: Text(d['title'] ?? 'Unknown',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13)),
                      subtitle: Row(children: [
                        const Icon(Icons.offline_pin_rounded,
                            color: Colors.greenAccent, size: 12),
                        const SizedBox(width: 4),
                        Expanded(
                            child: Text(d['author'] ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: Colors.grey[600], fontSize: 11))),
                      ]),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _compactActionIcon(
                            tooltip: 'Play',
                            icon: Icons.play_circle_fill,
                            color: Colors.greenAccent,
                            iconSize: 26,
                            size: 36,
                            onPressed: () => unawaited(
                                _playDownloadedAt(i, resetQueue: true)),
                          ),
                          const SizedBox(width: 2),
                          _compactActionIcon(
                            tooltip: 'Delete',
                            icon: Icons.delete_outline_rounded,
                            color: Colors.redAccent,
                            size: 34,
                            onPressed: () => unawaited(_deleteDownloadedAt(i)),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    ]);
  }

  // SETTINGS TAB
  Widget _buildSettingsTab(bool isDark) {
    return ListView(
        padding: EdgeInsets.only(bottom: _nowPlaying != null ? 80 : 20),
        children: [
          const Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Text('Settings',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold))),

          _settingsSectionHeader('AI & Experiments'),
          _settingsCard([
            _settingsTile(
              icon: Icons.science_rounded,
              iconColor: Colors.cyanAccent,
              title: 'Experiments',
              subtitle: _experimentsEnabled ? 'Enabled' : 'Disabled',
              trailing: Switch(
                value: _experimentsEnabled,
                activeThumbColor: Colors.greenAccent,
                onChanged: (v) {
                  setState(() => _experimentsEnabled = v);
                  _scheduleSave();
                },
              ),
            ),
            const Divider(color: Color(0xFF252525), height: 1, indent: 60),
            _settingsTile(
              icon: Icons.tune_rounded,
              iconColor: Colors.lightGreenAccent,
              title: 'Quick Picks Variant',
              subtitle: _qpVariant,
              trailing:
                  const Icon(Icons.chevron_right_rounded, color: Colors.grey),
              onTap: () {
                showModalBottomSheet(
                  context: context,
                  backgroundColor: const Color(0xFF141414),
                  shape: const RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.vertical(top: Radius.circular(20))),
                  builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
                    final options = ['control', 'bandit'];
                    return Column(mainAxisSize: MainAxisSize.min, children: [
                      _sheetHandle(),
                      _sheetHeader(
                        icon: Icons.tune_rounded,
                        color: Colors.greenAccent,
                        title: 'Quick Picks Variant',
                      ),
                      ...options.map((opt) {
                        final active = _qpVariant == opt;
                        return ListTile(
                          leading: Icon(Icons.radio_button_checked,
                              color: active
                                  ? Colors.greenAccent
                                  : Colors.grey[700]),
                          title: Text(opt,
                              style: TextStyle(
                                  color: active
                                      ? Colors.greenAccent
                                      : Colors.white)),
                          trailing: active
                              ? const Icon(Icons.check_circle_rounded,
                                  color: Colors.greenAccent)
                              : null,
                          onTap: () {
                            setState(() => _qpVariant = opt);
                            setSheet(() {});
                            Navigator.pop(ctx);
                            _scheduleSave();
                          },
                        );
                      }),
                      const SizedBox(height: 12),
                    ]);
                  }),
                );
              },
            ),
            const Divider(color: Color(0xFF252525), height: 1, indent: 60),
            Builder(builder: (context) {
              final exp = (_quickMetrics['exposures'] ?? 0).toDouble();
              final clicks = (_quickMetrics['clicks'] ?? 0).toDouble();
              final skips = (_quickMetrics['skipsEarly'] ?? 0).toDouble();
              final comps = (_quickMetrics['completions'] ?? 0).toDouble();
              final ctr = exp > 0 ? (clicks / exp) : 0.0;
              final skipRate = exp > 0 ? (skips / exp) : 0.0;
              final compRate = exp > 0 ? (comps / exp) : 0.0;
              final subtitle =
                  'Exposures: ${exp.toInt()} • CTR: ${(ctr * 100).toStringAsFixed(1)}% • Skips: ${(skipRate * 100).toStringAsFixed(1)}% • Completions: ${(compRate * 100).toStringAsFixed(1)}%';
              return _settingsTile(
                icon: Icons.analytics_rounded,
                iconColor: Colors.orangeAccent,
                title: 'Quick Picks Metrics',
                subtitle: subtitle,
                trailing: IconButton(
                  icon: const Icon(Icons.restart_alt_rounded,
                      color: Colors.grey, size: 18),
                  onPressed: _resetAiStats,
                ),
              );
            }),
            const Divider(color: Color(0xFF252525), height: 1, indent: 60),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Bandit Arms',
                      style: TextStyle(
                          color: Colors.grey[400],
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  ..._banditQuickArms.entries.map((e) {
                    final count = (e.value['count'] as num? ?? 0).toInt();
                    final sum = (e.value['sum'] as num? ?? 0).toDouble();
                    final avg = count > 0 ? (sum / count) : 0.0;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        children: [
                          Expanded(
                              child: Text(e.key,
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 12))),
                          Text('n=$count  avg=${avg.toStringAsFixed(2)}',
                              style: TextStyle(
                                  color: Colors.grey[500], fontSize: 11)),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
          ]),

          _settingsSectionHeader('Appearance'),
          _settingsCard([
            _settingsTile(
              icon: isDark ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
              iconColor: Colors.deepPurpleAccent,
              title: 'Theme',
              subtitle: isDark ? 'Dark mode' : 'Light mode',
              trailing: Switch(
                  value: isDark,
                  activeThumbColor: Colors.greenAccent,
                  onChanged: (v) {
                    _isDarkNotifier.value = v;
                    setState(() {});
                    _scheduleSave();
                  }),
            ),
          ]),

          // YouTube Music Account
          _settingsSectionHeader('YouTube Music Account'),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: const Color(0xFF141414),
              borderRadius: BorderRadius.circular(14),
              border: _ytAccountEmail != null
                  ? Border.all(color: Colors.greenAccent.withValues(alpha: 0.3))
                  : null,
            ),
            child: _ytAccountEmail == null
                // Not connected
                ? Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: LinearGradient(
                                  colors: [
                                    Color(0xFFFF0000),
                                    Color(0xFFCC0000)
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                              ),
                              child: const Icon(Icons.music_note_rounded,
                                  color: Colors.white, size: 22),
                            ),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Connect YouTube Music',
                                        style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 15,
                                            fontWeight: FontWeight.w700)),
                                    SizedBox(height: 2),
                                    Text(
                                        'Import your liked songs & get smarter AI picks',
                                        style: TextStyle(
                                            color: Color(0xFF888888),
                                            fontSize: 12)),
                                  ]),
                            ),
                          ]),
                          const SizedBox(height: 16),
                          // Feature bullets
                          ...[
                            (
                              'Your liked songs imported automatically',
                              Icons.favorite_rounded,
                              Colors.pinkAccent
                            ),
                            (
                              'AI trained on YOUR taste, not just the current song',
                              Icons.auto_awesome_rounded,
                              Colors.greenAccent
                            ),
                            (
                              'Subscribed artists appear in your Quick Picks',
                              Icons.queue_music_rounded,
                              Colors.cyanAccent
                            ),
                          ].map((f) => Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Row(children: [
                                  Icon(f.$2, color: f.$3, size: 14),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      f.$1,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: Color(0xFFAAAAAA),
                                          fontSize: 12),
                                    ),
                                  ),
                                ]),
                              )),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            child: _ytSigningIn
                                ? const Center(
                                    child: CircularProgressIndicator(
                                        color: Colors.greenAccent,
                                        strokeWidth: 2))
                                : ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.greenAccent,
                                      foregroundColor: Colors.black,
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 12),
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(10)),
                                    ),
                                    icon: const Icon(Icons.link_rounded,
                                        size: 18),
                                    label: const Text('Connect Account',
                                        style: TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 14)),
                                    onPressed: _ytSignIn,
                                  ),
                          ),
                        ]),
                  )
                // Connected
                : Column(children: [
                    ListTile(
                      leading: CircleAvatar(
                        radius: 20,
                        backgroundImage: _ytAccountPhoto != null
                            ? NetworkImage(_ytAccountPhoto!)
                            : null,
                        backgroundColor: Colors.grey[800],
                        child: _ytAccountPhoto == null
                            ? const Icon(Icons.person_rounded,
                                color: Colors.white, size: 22)
                            : null,
                      ),
                      title: Text(_ytAccountName ?? 'YouTube Account',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 14)),
                      subtitle: Text(_ytAccountEmail ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              TextStyle(color: Colors.grey[500], fontSize: 11)),
                      trailing: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.greenAccent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text('Connected',
                            style: TextStyle(
                                color: Colors.greenAccent,
                                fontSize: 11,
                                fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const Divider(color: Color(0xFF252525), height: 1),
                    // Stats row
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                      child: Wrap(
                        spacing: 16,
                        runSpacing: 10,
                        children: [
                          _ytStatBadge('${_ytLikedVideos.length}',
                              'Liked Songs', Colors.pinkAccent),
                          _ytStatBadge(
                              'Active', 'AI Training', Colors.greenAccent),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                      child: Row(children: [
                        Icon(
                          Icons.cloud_done_rounded,
                          color: _cloudSyncError == null
                              ? Colors.lightBlueAccent
                              : Colors.orangeAccent,
                          size: 14,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _cloudSyncStatusText(),
                            style: TextStyle(
                              color: Colors.grey[500],
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ]),
                    ),
                    const Divider(color: Color(0xFF252525), height: 1),
                    // Actions
                    Row(children: [
                      Expanded(
                        child: TextButton.icon(
                          style: TextButton.styleFrom(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 14)),
                          icon: const Icon(Icons.refresh_rounded,
                              color: Colors.greenAccent, size: 16),
                          label: const Text('Sync',
                              style: TextStyle(
                                  color: Colors.greenAccent, fontSize: 13)),
                          onPressed: _ytDataLoading || _ytSigningIn
                              ? null
                              : () {
                                  unawaited(_syncYouTubeAccount());
                                },
                        ),
                      ),
                      Container(
                          width: 1, height: 40, color: const Color(0xFF252525)),
                      Expanded(
                        child: TextButton.icon(
                          style: TextButton.styleFrom(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 14)),
                          icon: Icon(Icons.logout_rounded,
                              color: Colors.grey[500], size: 16),
                          label: Text('Disconnect',
                              style: TextStyle(
                                  color: Colors.grey[500], fontSize: 13)),
                          onPressed: () {
                            unawaited(_ytSignOut());
                          },
                        ),
                      ),
                    ]),
                  ]),
          ),

          _settingsCard([
            _settingsTile(
              icon: Icons.cookie_outlined,
              iconColor: Colors.orangeAccent,
              title: 'YT Music Cookie',
              subtitle: _ytMusicSessionSubtitle(),
              trailing: _ytMusicSessionChecking
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.greenAccent,
                      ),
                    )
                  : Icon(
                      _ytMusicSessionValid
                          ? Icons.verified_rounded
                          : Icons.chevron_right_rounded,
                      color: _ytMusicSessionValid
                          ? Colors.greenAccent
                          : Colors.grey,
                    ),
              onTap: _showYtMusicCookieDialog,
            ),
            const Divider(color: Color(0xFF252525), height: 1, indent: 60),
            _settingsTile(
              icon: Icons.phone_android_rounded,
              iconColor: Colors.greenAccent,
              title: 'Phone-only mode',
              subtitle: _ytMusicPhoneOnlyMode
                  ? 'Uses WebView + local clients only'
                  : 'Allows backend path if configured',
              trailing: Switch(
                value: _ytMusicPhoneOnlyMode,
                activeThumbColor: Colors.greenAccent,
                onChanged: (value) {
                  setState(() {
                    _ytMusicPhoneOnlyMode = value;
                    _ytMusicBackendRetryAfter = null;
                  });
                  _scheduleSave();
                },
              ),
            ),
            if (!_ytMusicPhoneOnlyMode) ...[
              const Divider(color: Color(0xFF252525), height: 1, indent: 60),
              _settingsTile(
              icon: Icons.cloud_outlined,
              iconColor: Colors.lightBlueAccent,
              title: 'YT Music Backend',
              subtitle: _ytMusicBackendSettingsSubtitle(),
              trailing:
                  const Icon(Icons.chevron_right_rounded, color: Colors.grey),
              onTap: _showYtMusicBackendDialog,
              ),
            ],
            if ((_ytMusicCookie ?? '').trim().isNotEmpty) ...[
              const Divider(color: Color(0xFF252525), height: 1, indent: 60),
              _settingsTile(
                icon: _ytMusicSessionValid
                    ? Icons.person_rounded
                    : Icons.sync_problem_rounded,
                iconColor: _ytMusicSessionValid
                    ? Colors.greenAccent
                    : Colors.orangeAccent,
                title: _ytMusicSessionValid
                    ? (_ytMusicSessionName ?? 'YT Music Session')
                    : 'Verify Session',
                subtitle: _ytMusicSessionValid
                    ? ((_ytMusicSessionEmail ?? _ytMusicSessionHandle ?? '')
                            .trim()
                            .isNotEmpty
                        ? (_ytMusicSessionEmail ?? _ytMusicSessionHandle!)
                            .trim()
                        : 'Official YT Music personalized feed enabled')
                    : ((_ytMusicSessionError ?? '').trim().isNotEmpty
                        ? _ytMusicSessionError!.trim()
                        : 'Check whether this cookie is still logged in'),
                trailing: IconButton(
                  icon: const Icon(Icons.refresh_rounded,
                      color: Colors.greenAccent, size: 18),
                  onPressed: _ytMusicSessionChecking
                      ? null
                      : () => unawaited(
                            _refreshYtMusicSession(
                              reloadHome: true,
                              showToast: true,
                            ),
                          ),
                ),
                onTap: _ytMusicSessionChecking
                    ? null
                    : () => unawaited(
                          _refreshYtMusicSession(
                            reloadHome: true,
                            showToast: true,
                          ),
                        ),
              ),
            ],
          ]),

          _settingsSectionHeader('Audio'),
          _settingsCard([
            _settingsTile(
              icon: Icons.high_quality_rounded,
              iconColor: Colors.blueAccent,
              title: 'Audio Quality',
              subtitle:
                  '${_audioQualityLabels[_audioQuality]} - applies on next song',
              trailing:
                  const Icon(Icons.chevron_right_rounded, color: Colors.grey),
              onTap: _showAudioQualitySheet,
            ),
            const Divider(color: Color(0xFF252525), height: 1, indent: 60),
            _settingsTile(
              icon: Icons.equalizer_rounded,
              iconColor: Colors.greenAccent,
              title: 'Equalizer',
              subtitle: _eqEnabled ? 'On' : 'Off',
              trailing:
                  const Icon(Icons.chevron_right_rounded, color: Colors.grey),
              onTap: _showEqualizerSheet,
            ),
            const Divider(color: Color(0xFF252525), height: 1, indent: 60),
            _settingsTile(
              icon: Icons.speaker_rounded,
              iconColor: Colors.orangeAccent,
              title: 'Bass Boost',
              subtitle: _bassBoostEnabled
                  ? 'On - ${_bassBoostDisplayDb(_bassBoostGain).toStringAsFixed(1)} dB'
                  : 'Off',
              trailing: Switch(
                  value: _bassBoostEnabled,
                  activeThumbColor: Colors.greenAccent,
                  onChanged: (v) async {
                    setState(() => _bassBoostEnabled = v);
                    try {
                      await _androidLoudnessEnhancer.setEnabled(v);
                    } catch (e) {
                      debugPrint('[Bass] $e');
                    }
                    if (v) {
                      await _applyBassBoostGain(_bassBoostGain);
                    }
                    _scheduleSave();
                  }),
            ),
            const Divider(color: Color(0xFF252525), height: 1, indent: 60),
            _settingsTile(
              icon: Icons.graphic_eq_rounded,
              iconColor: Colors.lightBlueAccent,
              title: 'Loudness Normalization',
              subtitle: _loudnessNormalizationOn
                  ? 'On - ${(_loudnessNormalizationStrength * 100).round()}% leveling'
                  : 'Off',
              trailing:
                  const Icon(Icons.chevron_right_rounded, color: Colors.grey),
              onTap: _showLoudnessNormalizationSheet,
            ),
            const Divider(color: Color(0xFF252525), height: 1, indent: 60),
            _settingsTile(
              icon: Icons.blur_on_rounded,
              iconColor: Colors.cyanAccent,
              title: 'Crossfade',
              subtitle: _crossfadeOn
                  ? 'On - ${_crossfadeSecs.toStringAsFixed(1)}s'
                  : 'Off',
              trailing:
                  const Icon(Icons.chevron_right_rounded, color: Colors.grey),
              onTap: _showCrossfadeSheet,
            ),
          ]),

          _settingsSectionHeader('Storage'),
          _settingsCard([
            _settingsTile(
              icon: Icons.folder_rounded,
              iconColor: Colors.amberAccent,
              title: 'Download Location',
              subtitle: _downloadPath.length > 38
                  ? '...${_downloadPath.substring(_downloadPath.length - 36)}'
                  : (_downloadPath.isEmpty ? 'Not set' : _downloadPath),
              trailing:
                  const Icon(Icons.chevron_right_rounded, color: Colors.grey),
              onTap: _showDownloadLocationSheet,
            ),
            const Divider(color: Color(0xFF252525), height: 1, indent: 60),
            _settingsTile(
              icon: Icons.download_done_rounded,
              iconColor: Colors.greenAccent,
              title: 'Downloaded Songs',
              subtitle: '${_downloads.length} songs saved',
              trailing:
                  const Icon(Icons.chevron_right_rounded, color: Colors.grey),
              onTap: () => setState(() => _selectedTab = 4),
            ),
          ]),

          _settingsSectionHeader('Playback'),
          _settingsCard([
            _settingsTile(
              icon: Icons.auto_awesome_motion_rounded,
              iconColor: Colors.cyanAccent,
              title: 'Smart Transitions',
              subtitle: _smartTransitionsOn
                  ? 'On - adaptive crossfade + gapless handoff'
                  : 'Off',
              trailing: Switch(
                  value: _smartTransitionsOn,
                  activeThumbColor: Colors.greenAccent,
                  onChanged: (v) {
                    setState(() => _smartTransitionsOn = v);
                    _scheduleSave();
                  }),
            ),
            const Divider(color: Color(0xFF252525), height: 1, indent: 60),
            _settingsTile(
              icon: Icons.speed_rounded,
              iconColor: Colors.pinkAccent,
              title: 'Playback Speed',
              subtitle:
                  _playbackSpeed == 1.0 ? 'Normal (1x)' : '${_playbackSpeed}x',
              trailing:
                  const Icon(Icons.chevron_right_rounded, color: Colors.grey),
              onTap: _showSpeedSheet,
            ),
            const Divider(color: Color(0xFF252525), height: 1, indent: 60),
            _settingsTile(
              icon: Icons.bedtime_rounded,
              iconColor: Colors.indigo,
              title: 'Sleep Timer',
              subtitle: _sleepTimer != null
                  ? 'Active - ${_sleepAt?.difference(DateTime.now()).inMinutes ?? 0}m left'
                  : 'Off',
              trailing:
                  const Icon(Icons.chevron_right_rounded, color: Colors.grey),
              onTap: _showSleepTimerSheet,
            ),
          ]),

          _settingsSectionHeader('About'),
          _settingsCard([
            _settingsTile(
                icon: Icons.music_note_rounded,
                iconColor: Colors.greenAccent,
                title: 'Beast Music',
                subtitle: 'Version 1.0.0 | No ads, no limits',
                leading: _appLogoImage(
                  size: 22,
                  borderRadius: BorderRadius.circular(6),
                )),
            const Divider(color: Color(0xFF252525), height: 1, indent: 60),
            _settingsTile(
                icon: Icons.code_rounded,
                iconColor: Colors.blueAccent,
                title: 'Built with Flutter',
                subtitle: 'Powered by YouTube | just_audio'),
          ]),
          const SizedBox(height: 20),
        ]);
  }

  void _resetAiStats() {
    setState(() {
      _banditQuickArms.clear();
      _quickMetrics.updateAll((key, value) => 0);
      _cfCounts.clear();
    });
    _scheduleSave();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('AI stats reset'), duration: Duration(seconds: 1)));
  }

  Widget _settingsSectionHeader(String label) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Text(label,
          style: TextStyle(
              color: Colors.grey[500],
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5)));

  Widget _settingsCard(List<Widget> children) => Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
          color: const Color(0xFF141414),
          borderRadius: BorderRadius.circular(14)),
      child: Column(children: children));

  Widget _ytStatBadge(String value, String label, Color color) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value,
            style: TextStyle(
                color: color, fontSize: 16, fontWeight: FontWeight.w800)),
        Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Colors.grey[500], fontSize: 11)),
      ]);

  Widget _settingsTile(
      {required IconData icon,
      required Color iconColor,
      required String title,
      required String subtitle,
      Widget? leading,
      Widget? trailing,
      VoidCallback? onTap}) {
    return ListTile(
      leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10)),
          child: Center(
            child: leading ?? Icon(icon, color: iconColor, size: 20),
          )),
      title: Text(title,
          style: const TextStyle(
              color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
      subtitle: Text(subtitle,
          style: TextStyle(color: Colors.grey[500], fontSize: 11),
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
      trailing: trailing,
      onTap: onTap,
    );
  }

  // Audio quality sheet
  void _showAudioQualitySheet() {
    showModalBottomSheet(
        context: context,
        backgroundColor: const Color(0xFF141414),
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setSheet) =>
                Column(mainAxisSize: MainAxisSize.min, children: [
                  _sheetHandle(),
                  _sheetHeader(
                    icon: Icons.high_quality_rounded,
                    color: Colors.greenAccent,
                    title: 'Audio Quality',
                    subtitle:
                        'Changes apply to the next song. Higher quality uses more data.',
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  ),
                  ...List.generate(3, (i) {
                    final details = [
                      '~64 kbps - saves data',
                      '~128 kbps - balanced',
                      'Best available - best sound'
                    ];
                    final active = _audioQuality == i;
                    return ListTile(
                      leading: Icon(
                          i == 0
                              ? Icons.looks_one_rounded
                              : i == 1
                                  ? Icons.looks_two_rounded
                                  : Icons.looks_3_rounded,
                          color:
                              active ? Colors.greenAccent : Colors.grey[600]),
                      title: Text(_audioQualityLabels[i],
                          style: TextStyle(
                              color: active ? Colors.greenAccent : Colors.white,
                              fontWeight: active
                                  ? FontWeight.bold
                                  : FontWeight.normal)),
                      subtitle: Text(details[i],
                          style:
                              TextStyle(color: Colors.grey[600], fontSize: 11)),
                      trailing: active
                          ? const Icon(Icons.check_circle_rounded,
                              color: Colors.greenAccent)
                          : null,
                      onTap: () {
                        setState(() => _audioQuality = i);
                        setSheet(() {});
                        Navigator.pop(ctx);
                        _scheduleSave();
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text('Quality: ${_audioQualityLabels[i]}'),
                            duration: const Duration(seconds: 1)));
                      },
                    );
                  }),
                  const SizedBox(height: 12),
                ])));
  }

  // Download location sheet
  void _showDownloadLocationSheet() async {
    final options = <Map<String, String>>[];

    // Public Music dir survives reinstall on Android (no extra permissions needed on API 29+)
    const publicMusic = '/storage/emulated/0/Music/BeastMusic';
    try {
      final d = Directory(publicMusic);
      if (!await d.exists()) await d.create(recursive: true);
      options.add({
        'label': 'Music / BeastMusic - survives reinstall',
        'path': publicMusic
      });
    } catch (_) {}

    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        options.add({'label': 'App External Storage', 'path': ext.path});
      }
    } catch (_) {}
    try {
      final app = await getApplicationDocumentsDirectory();
      options.add({'label': 'App Documents', 'path': app.path});
    } catch (_) {}
    try {
      final tmp = await getTemporaryDirectory();
      options.add({'label': 'Temporary (cache)', 'path': tmp.path});
    } catch (_) {}
    if (!mounted) return;
    showModalBottomSheet(
        context: context,
        backgroundColor: const Color(0xFF141414),
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setSheet) =>
                Column(mainAxisSize: MainAxisSize.min, children: [
                  _sheetHandle(),
                  _sheetHeader(
                    icon: Icons.folder_rounded,
                    color: Colors.greenAccent,
                    title: 'Download Location',
                    subtitle:
                        'Current: ${_downloadPath.length > 40 ? '...${_downloadPath.substring(_downloadPath.length - 38)}' : _downloadPath}',
                  ),
                  ...options.map((o) {
                    final active = _downloadPath == o['path'];
                    return ListTile(
                      leading: Icon(Icons.folder_open_rounded,
                          color:
                              active ? Colors.greenAccent : Colors.grey[600]),
                      title: Text(o['label']!,
                          style: TextStyle(
                              color: active ? Colors.greenAccent : Colors.white,
                              fontWeight: active
                                  ? FontWeight.bold
                                  : FontWeight.normal)),
                      subtitle: Text(o['path']!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              TextStyle(color: Colors.grey[600], fontSize: 11)),
                      trailing: active
                          ? const Icon(Icons.check_circle_rounded,
                              color: Colors.greenAccent)
                          : null,
                      onTap: () {
                        setState(() => _downloadPath = o['path']!);
                        setSheet(() {});
                        Navigator.pop(ctx);
                        _scheduleSave();
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text('${o['label']}',
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            duration: const Duration(seconds: 1)));
                      },
                    );
                  }),
                  const SizedBox(height: 12),
                ])));
  }

  // Equalizer sheet
  void _showEqualizerSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141414),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
          builder: (ctx, setSheet) => DraggableScrollableSheet(
                initialChildSize: 0.75,
                minChildSize: 0.5,
                maxChildSize: 0.95,
                expand: false,
                builder: (ctx, scrollCtrl) => ListView(
                    controller: scrollCtrl,
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [
                      _sheetHandle(),
                      _sheetHeader(
                        icon: Icons.equalizer_rounded,
                        color: Colors.greenAccent,
                        title: 'Equalizer',
                        trailing: Switch(
                          value: _eqEnabled,
                          activeThumbColor: Colors.greenAccent,
                          onChanged: (v) async {
                            setState(() => _eqEnabled = v);
                            setSheet(() {});
                            try {
                              await _androidEqualizer.setEnabled(v);
                            } catch (e) {
                              debugPrint('[EQ] $e');
                            }
                            _scheduleSave();
                          },
                        ),
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                      ),

                      if (_eqParams == null)
                        Padding(
                            padding: const EdgeInsets.all(20),
                            child: Center(
                                child: Text(
                                    'Equalizer not available on this device',
                                    style: TextStyle(color: Colors.grey[600]))))
                      else ...[
                        // Band sliders
                        Padding(
                            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Frequency Bands',
                                      style: TextStyle(
                                          color: Colors.grey[400],
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500)),
                                  const SizedBox(height: 4),
                                  Text(
                                      'Drag sliders to boost or cut each frequency range',
                                      style: TextStyle(
                                          color: Colors.grey[700],
                                          fontSize: 11)),
                                  const SizedBox(height: 12),
                                  ..._eqParams!.bands.map((band) {
                                    final freq = band.centerFrequency.toInt();
                                    final freqLabel = freq >= 1000
                                        ? '${(freq / 1000).toStringAsFixed(freq % 1000 == 0 ? 0 : 1)}kHz'
                                        : '${freq}Hz';
                                    final minDb = _eqParams!.minDecibels;
                                    final maxDb = _eqParams!.maxDecibels;
                                    return Padding(
                                        padding:
                                            const EdgeInsets.only(bottom: 2),
                                        child: Row(children: [
                                          SizedBox(
                                              width: 52,
                                              child: Text(freqLabel,
                                                  style: TextStyle(
                                                      color: Colors.grey[500],
                                                      fontSize: 11))),
                                          Expanded(
                                              child: SliderTheme(
                                            data: SliderTheme.of(ctx).copyWith(
                                              trackHeight: 3,
                                              thumbColor: Colors.greenAccent,
                                              activeTrackColor:
                                                  Colors.greenAccent,
                                              inactiveTrackColor:
                                                  Colors.grey[800],
                                              thumbShape:
                                                  const RoundSliderThumbShape(
                                                      enabledThumbRadius: 7),
                                            ),
                                            child: Slider(
                                              value:
                                                  band.gain.clamp(minDb, maxDb),
                                              min: minDb,
                                              max: maxDb,
                                              onChanged: _eqEnabled
                                                  ? (v) async {
                                                      try {
                                                        await band.setGain(v);
                                                        _savedEqBandGains[
                                                            freq] = v;
                                                        if (mounted) {
                                                          setState(() {});
                                                        }
                                                        setSheet(() {});
                                                        _scheduleSave();
                                                      } catch (e) {
                                                        debugPrint(
                                                            '[EQ band] $e');
                                                      }
                                                    }
                                                  : null,
                                            ),
                                          )),
                                          SizedBox(
                                              width: 44,
                                              child: Text(
                                                  '${band.gain.toStringAsFixed(1)} dB',
                                                  textAlign: TextAlign.right,
                                                  style: TextStyle(
                                                      color: Colors.grey[500],
                                                      fontSize: 10))),
                                        ]));
                                  }),
                                  // Reset button
                                  const SizedBox(height: 8),
                                  Center(
                                      child: TextButton.icon(
                                    icon: const Icon(Icons.restart_alt_rounded,
                                        size: 16, color: Colors.grey),
                                    label: Text('Reset all bands',
                                        style: TextStyle(
                                            color: Colors.grey[500],
                                            fontSize: 12)),
                                    onPressed: _eqEnabled
                                        ? () async {
                                            for (final band
                                                in _eqParams!.bands) {
                                              try {
                                                await band.setGain(0.0);
                                                _savedEqBandGains[band
                                                    .centerFrequency
                                                    .toInt()] = 0.0;
                                              } catch (_) {}
                                            }
                                            if (mounted) setState(() {});
                                            setSheet(() {});
                                            _scheduleSave();
                                          }
                                        : null,
                                  )),
                                ])),
                      ],

                      // Bass Boost
                      const Padding(
                          padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                          child: Divider(color: Color(0xFF252525))),
                      _sheetHeader(
                        icon: Icons.speaker_rounded,
                        color: Colors.greenAccent,
                        title: 'Bass Boost',
                        trailing: Switch(
                          value: _bassBoostEnabled,
                          activeThumbColor: Colors.greenAccent,
                          onChanged: (v) async {
                            setState(() => _bassBoostEnabled = v);
                            setSheet(() {});
                            try {
                              await _androidLoudnessEnhancer.setEnabled(v);
                            } catch (e) {
                              debugPrint('[Bass] $e');
                            }
                            if (v) {
                              await _applyBassBoostGain(_bassBoostGain);
                            }
                            _scheduleSave();
                          },
                        ),
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                      ),
                      if (_bassBoostEnabled)
                        Padding(
                            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                      'Gain: ${_bassBoostDisplayDb(_bassBoostGain).toStringAsFixed(1)} dB',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          color: Colors.grey[400],
                                          fontSize: 12)),
                                  const SizedBox(height: 6),
                                  SliderTheme(
                                    data: SliderTheme.of(ctx).copyWith(
                                        activeTrackColor: Colors.greenAccent,
                                        inactiveTrackColor: Colors.grey[800],
                                        thumbColor: Colors.greenAccent),
                                    child: Slider(
                                        value: _bassBoostGain,
                                        min: 0,
                                        max: _bassBoostMaxNormalized,
                                        onChanged: (v) async {
                                          setState(() => _bassBoostGain =
                                              _clampedBassBoostGain(v));
                                          setSheet(() {});
                                          await _applyBassBoostGain(v);
                                          _scheduleSave();
                                        }),
                                  ),
                                ])),
                    ]),
              )),
    );
  }

  // Generic song list
  Widget _buildSongList(
    List<Video> videos,
    bool isPlaying, {
    bool playWholeListOnTap = true,
    String tapSource = 'song_list_tap',
  }) {
    return ListView.builder(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.only(bottom: _nowPlaying != null ? 16 : 8),
      itemCount: videos.length,
      itemBuilder: (ctx, index) {
        final video = videos[index];
        final isActive = _nowPlaying?.id == video.id;
        final isDownloaded = _isVideoDownloaded(video);
        final cleanName = _cleanTitle(video.title, author: video.author);
        final cleanArtist = _cleanAuthor(video.author);
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: isActive
                ? Colors.green.shade900.withValues(alpha: 0.5)
                : const Color(0xFF151515),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isActive
                  ? Colors.greenAccent.withValues(alpha: 0.45)
                  : const Color(0xFF222222),
              width: 0.9,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              splashColor: Colors.greenAccent.withValues(alpha: 0.08),
              highlightColor: Colors.greenAccent.withValues(alpha: 0.04),
              onTap: () {
                setState(() {
                  _playQueue =
                      playWholeListOnTap ? List<Video>.from(videos) : [video];
                  _radioMode = false;
                });
                _notifyQueueChanged();
                if (isActive && isPlaying) {
                  _player.pause();
                } else if (isActive && !isPlaying && !_isBuffering) {
                  _player.play();
                } else {
                  _playFromUserAction(
                    video,
                    playWholeListOnTap ? index : 0,
                    source: tapSource,
                  );
                }
              },
              onLongPress: () => _showSongMenu(video),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                child: Row(children: [
                  // Thumbnail
                  SizedBox(
                    width: 58,
                    height: 58,
                    child: Stack(children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(9),
                        child: CachedNetworkImage(
                          imageUrl: video.thumbnails.mediumResUrl,
                          width: 58,
                          height: 58,
                          fit: BoxFit.cover,
                          placeholder: (_, __) =>
                              _shimmerBox(58, 58, radius: 9),
                          errorWidget: (_, __, ___) => Container(
                              color: Colors.grey[850],
                              width: 58,
                              height: 58,
                              child: const Icon(Icons.music_note,
                                  color: Colors.grey)),
                        ),
                      ),
                      if (isActive)
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(9),
                                color: Colors.black.withValues(alpha: 0.4)),
                            child: Center(
                              child: isActive && _isBuffering
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          color: Colors.greenAccent,
                                          strokeWidth: 2))
                                  : isPlaying
                                      ? _buildEqualizerBars(
                                          size: 16, color: Colors.greenAccent)
                                      : const Icon(Icons.pause_rounded,
                                          color: Colors.white, size: 18),
                            ),
                          ),
                        ),
                      if (isDownloaded)
                        Positioned(
                          right: 3,
                          bottom: 3,
                          child: Container(
                            width: 16,
                            height: 16,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.greenAccent,
                              border: Border.all(color: Colors.black, width: 1),
                            ),
                            child: const Icon(Icons.check_rounded,
                                color: Colors.black, size: 12),
                          ),
                        ),
                    ]),
                  ),
                  const SizedBox(width: 12),
                  // Title + author
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(cleanName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: isActive
                                      ? Colors.greenAccent
                                      : Colors.white,
                                  fontWeight: isActive
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  fontSize: 14.5,
                                  letterSpacing: -0.15)),
                          const SizedBox(height: 2),
                          GestureDetector(
                            onTap: () => _openArtistPage(video.author),
                            child:
                                Row(mainAxisSize: MainAxisSize.min, children: [
                              const Icon(Icons.person_outline_rounded,
                                  size: 11, color: Colors.greenAccent),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(cleanArtist,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: Colors.greenAccent
                                            .withValues(alpha: 0.7),
                                        fontSize: 12)),
                              ),
                              if (isDownloaded) ...[
                                const SizedBox(width: 6),
                                const Icon(Icons.download_done_rounded,
                                    size: 12, color: Colors.greenAccent),
                              ],
                            ]),
                          ),
                        ]),
                  ),
                  // Like + menu
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    GestureDetector(
                      onTap: () => _toggleLike(video),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          child: Icon(
                            _isLiked(video)
                                ? Icons.favorite_rounded
                                : Icons.favorite_border_rounded,
                            key: ValueKey(_isLiked(video)),
                            color: _isLiked(video)
                                ? Colors.pinkAccent
                                : Colors.grey[700],
                            size: 19,
                          ),
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => _showSongMenu(video),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 2),
                        child: Icon(Icons.more_vert_rounded,
                            color: Colors.grey[600], size: 20),
                      ),
                    ),
                  ]),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Shimmer placeholder box
  Widget _shimmerBox(double w, double h, {double radius = 4}) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.3, end: 0.6),
      duration: const Duration(milliseconds: 900),
      builder: (_, v, __) => Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          color: Color.lerp(Colors.grey[900], Colors.grey[800], v),
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
      onEnd: () {},
    );
  }

  Widget _buildSearchSuggestionsPanel({String? emptyMessage}) {
    if (_searchSuggestions.isEmpty) {
      return Center(
        child: Text(
          emptyMessage ?? 'Start typing to search songs',
          style: TextStyle(color: Colors.grey[600], fontSize: 14),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      itemCount: _searchSuggestions.length,
      separatorBuilder: (_, __) => Divider(color: Colors.grey[900], height: 1),
      itemBuilder: (ctx, i) {
        final suggestion = _searchSuggestions[i];
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _applySearchSuggestion(suggestion),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
              child: Row(
                children: [
                  Icon(Icons.search_rounded, color: Colors.grey[500], size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      suggestion,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  Icon(Icons.north_west_rounded,
                      color: Colors.grey[600], size: 16),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // Search results
  Widget _buildSearchResults(bool isPlaying) {
    if (_isLoading) {
      return const Center(
          child: CircularProgressIndicator(color: Colors.greenAccent));
    }

    final currentQuery = _searchController.text.trim();
    final playlistMatches = _playlistMatchesForSearch(
      currentQuery.isNotEmpty ? currentQuery : (_searchDidYouMean ?? ''),
    );
    if (_searchResults.isEmpty && playlistMatches.isEmpty) {
      if (_searchSuggestions.isNotEmpty || currentQuery.isNotEmpty) {
        return _buildSearchSuggestionsPanel(
          emptyMessage: currentQuery.isNotEmpty
              ? 'No exact matches. Try one of these.'
              : 'Try a song, artist, or mood',
        );
      }
      return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.search_rounded, color: Colors.grey[700], size: 64),
        const SizedBox(height: 12),
        Text('No results found',
            style: TextStyle(color: Colors.grey[600], fontSize: 16)),
      ]));
    }

    final showDidYouMean = _searchDidYouMean != null &&
        _searchDidYouMean!.isNotEmpty &&
        _normalizeSignalKey(_searchDidYouMean!) !=
            _normalizeSignalKey(currentQuery);
    final ranked = _rankSearchResults(
      _searchResults,
      currentQuery.isNotEmpty ? currentQuery : (_searchDidYouMean ?? ''),
      personalize: true,
      preferSongFirst: true,
    );
    final officialOnly = ranked.where((v) {
      final t = _normalizeSignalKey(_cleanTitle(v.title));
      return _looksOfficialMusicChannel(v.author) ||
          t.contains('official') ||
          t.contains('official audio') ||
          t.contains('topic');
    }).toList();
    final primaryOnly = ranked.where((v) {
      final text = _normalizeSignalKey('${v.title} ${v.author}');
      if (_isAlternateVersionSearchResult(v)) return false;
      if (_looksLikeCompilation(_cleanTitle(v.title))) return false;
      if (text.contains('full song') && !_looksOfficialMusicChannel(v.author)) {
        return false;
      }
      if (text.contains('dj ') ||
          text.contains('dj_') ||
          text.contains('dj-')) {
        return false;
      }
      if (text.contains('#')) return false;
      if (!_isDurationMusicFriendly(v.duration, strictSingles: false)) {
        return false;
      }
      return !text.contains('fan made') && !text.contains('tribute');
    }).toList();
    final displayList = switch (_searchResultView) {
      'official' => officialOnly.isNotEmpty ? officialOnly : primaryOnly,
      'all' => ranked,
      _ => primaryOnly.isNotEmpty ? primaryOnly : ranked,
    };
    final bestMatch = displayList.isNotEmpty ? displayList.first : null;

    Widget resultList() {
      return _buildSongList(
        displayList,
        isPlaying,
        playWholeListOnTap: false,
        tapSource: 'search_result_tap',
      );
    }

    final content = Column(
      children: [
        if (showDidYouMean)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 6),
            child: Row(
              children: [
                Icon(Icons.auto_fix_high_rounded,
                    color: Colors.greenAccent.withValues(alpha: 0.8), size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Typo-tolerant search used: "${_searchDidYouMean!}"',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.grey[400], fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _searchViewChip('Top', 'top', Icons.flash_on_rounded),
                const SizedBox(width: 8),
                _searchViewChip('Official', 'official', Icons.verified_rounded),
                const SizedBox(width: 8),
                _searchViewChip('All', 'all', Icons.view_list_rounded),
              ],
            ),
          ),
        ),
        if (playlistMatches.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
            child: Row(
              children: [
                const Text(
                  'Playlists',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                  ),
                ),
                const Spacer(),
                Text(
                  '${playlistMatches.length}',
                  style: TextStyle(color: Colors.grey[500], fontSize: 12),
                ),
              ],
            ),
          ),
        if (playlistMatches.isNotEmpty)
          ...playlistMatches
              .take(4)
              .map((playlist) => _buildSearchPlaylistMatchTile(playlist)),
        if (bestMatch != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
            child: Text(
              'Top result',
              style: TextStyle(
                color: Colors.grey[500],
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.18,
              ),
            ),
          ),
        if (bestMatch != null)
          _buildSearchBestMatchCard(bestMatch, displayList, isPlaying),
        if (displayList.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
            child: Row(
              children: [
                Text(
                  _searchResultView == 'official'
                      ? 'Official songs'
                      : _searchResultView == 'all'
                          ? 'All songs'
                          : 'Songs',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: displayList.isNotEmpty
              ? resultList()
              : Center(
                  child: Text(
                    playlistMatches.isNotEmpty
                        ? 'No song matches. Open a playlist above.'
                        : 'No song matches',
                    style: TextStyle(color: Colors.grey[600], fontSize: 13),
                  ),
                ),
        ),
      ],
    );
    return content;
  }

  bool _isAlternateVersionSearchResult(Video video) {
    final text = _normalizeSignalKey('${video.title} ${video.author}');
    return text.contains('cover') ||
        text.contains('karaoke') ||
        text.contains('tribute') ||
        text.contains('reaction') ||
        text.contains('8d') ||
        text.contains('slowed') ||
        text.contains('reverb') ||
        text.contains('remix') ||
        text.contains('live') ||
        text.contains('lofi mix') ||
        text.contains('bass boosted');
  }

  Widget _searchViewChip(String label, String value, IconData icon) {
    final active = _searchResultView == value;
    return GestureDetector(
      onTap: () => setState(() => _searchResultView = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: active ? Colors.greenAccent : const Color(0xFF181818),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: active ? Colors.greenAccent : Colors.grey.shade800,
            width: 0.8,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 15,
              color: active ? Colors.black : Colors.grey[400],
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: active ? Colors.black : Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBestMatchCard(
    Video bestMatch,
    List<Video> source,
    bool isPlaying,
  ) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1B1B1B), Color(0xFF111111)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF2B2B2B)),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: CachedNetworkImage(
              imageUrl: bestMatch.thumbnails.mediumResUrl,
              width: 64,
              height: 64,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => Container(
                width: 64,
                height: 64,
                color: Colors.grey[850],
                child: const Icon(Icons.music_note_rounded, color: Colors.grey),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _cleanTitle(bestMatch.title),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _cleanAuthor(bestMatch.author),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: Colors.grey[500],
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          TextButton.icon(
            onPressed: () {
              setState(() {
                _playQueue = [bestMatch];
                _radioMode = false;
              });
              _notifyQueueChanged();
              _playFromUserAction(
                bestMatch,
                0,
                source: 'search_best_match',
              );
            },
            style: TextButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: const Text(
              'Play',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEqualizerBars(
          {double size = 16, Color color = Colors.greenAccent}) =>
      _EqualizerBars(size: size, color: color);

  // Mini player
  Widget _buildMiniPlayer(bool isPlaying, double progress, bool isDark) {
    final compact = MediaQuery.sizeOf(context).width < 372;
    return GestureDetector(
      onTap: () => setState(() => _showNowPlaying = true),
      onVerticalDragEnd: (d) {
        if (d.primaryVelocity != null && d.primaryVelocity! < -300) {
          setState(() => _showNowPlaying = true);
        }
      },
      onHorizontalDragEnd: (d) {
        if (d.primaryVelocity == null) return;
        if (d.primaryVelocity! < -400) {
          if (_isDownloadPlayback) {
            _playNext(userInitiated: true);
          } else if (_currentIndex < _playQueue.length - 1) {
            _playNext(userInitiated: true);
          } else {
            _registerManualSkipFeedbackForCurrent();
            unawaited(_playRadioNext());
          }
        } else if (d.primaryVelocity! > 400 &&
            _canSkipPreviousInCurrentContext) {
          _playPrevious();
        }
      },
      child: Container(
        height: 68,
        decoration: BoxDecoration(
          color: const Color(0xFF161616),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.6),
                blurRadius: 24,
                offset: const Offset(0, 6))
          ],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Progress bar flush to top
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 2,
              backgroundColor: Colors.grey[900],
              valueColor: const AlwaysStoppedAnimation(Colors.greenAccent),
            ),
          ),
          Expanded(
            child: Padding(
              padding:
                  EdgeInsets.fromLTRB(compact ? 8 : 12, 0, compact ? 4 : 8, 0),
              child: Row(children: [
                // Album art
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: CachedNetworkImage(
                    imageUrl: _nowPlaying!.thumbnails.mediumResUrl,
                    width: 44,
                    height: 44,
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) => Container(
                        color: Colors.grey[850], width: 44, height: 44),
                  ),
                ),
                SizedBox(width: compact ? 8 : 10),
                // Equalizer + title
                Expanded(
                    child: Row(children: [
                  if (isPlaying && !_isBuffering)
                    Padding(
                      padding: const EdgeInsets.only(right: 7),
                      child: _buildEqualizerBars(
                          size: 13, color: Colors.greenAccent),
                    ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                            _cleanTitle(_nowPlaying!.title,
                                author: _nowPlaying!.author),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 13.5,
                                letterSpacing: -0.1)),
                        const SizedBox(height: 1),
                        Text(_cleanAuthor(_nowPlaying!.author),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: Colors.grey[500], fontSize: 11.5)),
                      ],
                    ),
                  ),
                ])),
                // Like
                IconButton(
                  icon: Icon(
                      _isLiked(_nowPlaying)
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      color: _isLiked(_nowPlaying)
                          ? Colors.pinkAccent
                          : Colors.grey[600],
                      size: 20),
                  onPressed: () => _toggleLike(_nowPlaying!),
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints(
                      minWidth: compact ? 32 : 36, minHeight: 36),
                ),
                // Play/Pause or buffer
                if (_isBuffering)
                  const SizedBox(
                      width: 36,
                      height: 36,
                      child: Padding(
                          padding: EdgeInsets.all(9),
                          child: CircularProgressIndicator(
                              color: Colors.greenAccent, strokeWidth: 2.5)))
                else
                  IconButton(
                    icon: Icon(
                        isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 30),
                    onPressed: () =>
                        isPlaying ? _player.pause() : _player.play(),
                    padding: EdgeInsets.zero,
                    constraints: BoxConstraints(
                        minWidth: compact ? 32 : 36, minHeight: 36),
                  ),
                // Next
                IconButton(
                  icon: Icon(Icons.skip_next_rounded,
                      color: Colors.grey[400], size: 24),
                  onPressed: _isBuffering
                      ? null
                      : () {
                          if (_isDownloadPlayback) {
                            _playNext(userInitiated: true);
                          } else if (_currentIndex < _playQueue.length - 1) {
                            _playNext(userInitiated: true);
                          } else {
                            _registerManualSkipFeedbackForCurrent();
                            unawaited(_playRadioNext());
                          }
                        },
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints(
                      minWidth: compact ? 30 : 32, minHeight: 36),
                ),
                // Queue
                IconButton(
                  icon: Icon(Icons.queue_music_rounded,
                      color: Colors.grey[700], size: 20),
                  onPressed: _showQueueSheet,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 36),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  // Full-screen now-playing overlay
  Widget _buildNowPlayingScreen(bool isPlaying, double progress,
      Duration position, Duration duration, bool isDark, Color textColor) {
    final bg = isDark ? const Color(0xFF0A0A0A) : const Color(0xFFF0F0F0);
    final liked = _isLiked(_nowPlaying);

    return GestureDetector(
      onVerticalDragEnd: (d) {
        if (d.primaryVelocity != null && d.primaryVelocity! > 300) {
          setState(() => _showNowPlaying = false);
        }
      },
      onHorizontalDragEnd: (d) {
        if (d.primaryVelocity == null) return;
        if (d.primaryVelocity! < -400) {
          if (_isDownloadPlayback) {
            _playNext(userInitiated: true);
          } else if (_currentIndex < _playQueue.length - 1) {
            _playNext(userInitiated: true);
          } else {
            _registerManualSkipFeedbackForCurrent();
            unawaited(_playRadioNext());
          }
        } else if (d.primaryVelocity! > 400 &&
            _canSkipPreviousInCurrentContext) {
          _playPrevious();
        }
      },
      child: Container(
        color: bg,
        child: SafeArea(
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: Column(children: [
              // Top bar
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
                child: Row(children: [
                  IconButton(
                    icon: Icon(Icons.keyboard_arrow_down_rounded,
                        color: textColor, size: 30),
                    onPressed: () => setState(() => _showNowPlaying = false),
                  ),
                  Expanded(
                      child: Column(children: [
                    Text('Now Playing',
                        style: TextStyle(
                            color: isDark ? Colors.grey[500] : Colors.grey[600],
                            fontSize: 11,
                            letterSpacing: 1.2)),
                    if (_radioMode)
                      const Text('Radio',
                          style: TextStyle(
                              color: Colors.greenAccent,
                              fontSize: 10,
                              fontWeight: FontWeight.bold)),
                  ])),
                  IconButton(
                    icon: Icon(Icons.more_vert_rounded, color: textColor),
                    onPressed: () => _showSongMenu(_nowPlaying!),
                  ),
                ]),
              ),

              const SizedBox(height: 16),

              // Big artwork
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Hero(
                    tag: 'now_playing_thumb',
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: CachedNetworkImage(
                        imageUrl: _nowPlaying!.thumbnails.highResUrl,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => CachedNetworkImage(
                          imageUrl: _nowPlaying!.thumbnails.mediumResUrl,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => Container(
                              color: Colors.grey[900],
                              child: const Icon(Icons.music_note,
                                  color: Colors.grey, size: 60)),
                        ),
                        errorWidget: (_, __, ___) => Container(
                            color: Colors.grey[900],
                            child: const Icon(Icons.music_note,
                                color: Colors.grey, size: 60)),
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // Song info + like
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Row(children: [
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(
                            _cleanTitle(_nowPlaying!.title,
                                author: _nowPlaying!.author),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: textColor,
                                fontWeight: FontWeight.bold,
                                fontSize: 20)),
                        const SizedBox(height: 4),
                        GestureDetector(
                          onTap: () {
                            setState(() => _showNowPlaying = false);
                            _openArtistPage(_nowPlaying!.author);
                          },
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.person_rounded,
                                size: 14,
                                color:
                                    Colors.greenAccent.withValues(alpha: 0.8)),
                            const SizedBox(width: 4),
                            Flexible(
                                child: Text(_cleanAuthor(_nowPlaying!.author),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: Colors.greenAccent
                                            .withValues(alpha: 0.8),
                                        fontSize: 14,
                                        decoration: TextDecoration.underline,
                                        decorationColor: Colors.greenAccent
                                            .withValues(alpha: 0.4)))),
                          ]),
                        ),
                      ])),
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: () => _toggleLike(_nowPlaying!),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: Icon(
                        liked
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        key: ValueKey(liked),
                        color: liked
                            ? Colors.pinkAccent
                            : (isDark ? Colors.grey[500] : Colors.grey[600]),
                        size: 28,
                      ),
                    ),
                  ),
                ]),
              ),

              const SizedBox(height: 16),

              // Seek bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 4,
                      thumbShape: _isBuffering
                          ? SliderComponentShape.noThumb
                          : const RoundSliderThumbShape(enabledThumbRadius: 7),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 16),
                      activeTrackColor: Colors.greenAccent,
                      inactiveTrackColor:
                          isDark ? Colors.grey[800] : Colors.grey[300],
                      thumbColor: Colors.greenAccent,
                      overlayColor: Colors.greenAccent.withValues(alpha: 0.2),
                    ),
                    child: Slider(
                      value: _isBuffering
                          ? _bufferProgress.clamp(0.0, 1.0)
                          : progress,
                      onChanged: _isBuffering
                          ? null
                          : (v) {
                              final ms = _player.duration?.inMilliseconds ?? 0;
                              if (ms > 0) {
                                _player.seek(
                                    Duration(milliseconds: (v * ms).round()));
                              }
                            },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          if (_isBuffering)
                            Expanded(
                                child: Text(_bufferLabel,
                                    style: const TextStyle(
                                        color: Colors.greenAccent,
                                        fontSize: 11)))
                          else ...[
                            Text(_fmt(position),
                                style: TextStyle(
                                    color: isDark
                                        ? Colors.grey[500]
                                        : Colors.grey[600],
                                    fontSize: 11)),
                            Text(_fmt(duration),
                                style: TextStyle(
                                    color: isDark
                                        ? Colors.grey[500]
                                        : Colors.grey[600],
                                    fontSize: 11)),
                          ],
                        ]),
                  ),
                ]),
              ),

              const SizedBox(height: 4),

              // Secondary controls
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    _playerCtrlBtn(
                        icon: Icons.shuffle_rounded,
                        active: _shuffleActiveInCurrentContext,
                        onTap: _toggleShuffle,
                        tooltip: 'Shuffle'),
                    const SizedBox(width: 12),
                    _playerCtrlBtn(
                        icon: _repeatMode == 2
                            ? Icons.repeat_one_rounded
                            : Icons.repeat_rounded,
                        active: _repeatMode > 0,
                        onTap: _cycleRepeat,
                        tooltip: [
                          'Off',
                          'Repeat all',
                          'Repeat one'
                        ][_repeatMode]),
                    const SizedBox(width: 12),
                    GestureDetector(
                      onTap: _showSpeedSheet,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: _playbackSpeed != 1.0
                              ? Colors.greenAccent.withValues(alpha: 0.15)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: _playbackSpeed != 1.0
                                  ? Colors.greenAccent.withValues(alpha: 0.4)
                                  : (isDark
                                      ? Colors.grey.shade800
                                      : Colors.grey.shade300)),
                        ),
                        child: Text(
                            _playbackSpeed == 1.0 ? '1x' : '${_playbackSpeed}x',
                            style: TextStyle(
                                color: _playbackSpeed != 1.0
                                    ? Colors.greenAccent
                                    : (isDark
                                        ? Colors.grey[500]
                                        : Colors.grey[600]),
                                fontSize: 12,
                                fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    GestureDetector(
                      onTap: _showSleepTimerSheet,
                      child: Stack(clipBehavior: Clip.none, children: [
                        Icon(Icons.bedtime_rounded,
                            size: 22,
                            color: _sleepTimer != null
                                ? Colors.greenAccent
                                : (isDark
                                    ? Colors.grey[600]
                                    : Colors.grey[500])),
                        if (_sleepTimer != null && _sleepAt != null)
                          Positioned(
                              right: -6,
                              top: -6,
                              child: StreamBuilder<void>(
                                stream:
                                    Stream.periodic(const Duration(seconds: 1)),
                                builder: (_, __) {
                                  final rem =
                                      _sleepAt!.difference(DateTime.now());
                                  return Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 3, vertical: 1),
                                    decoration: BoxDecoration(
                                        color: Colors.greenAccent,
                                        borderRadius: BorderRadius.circular(6)),
                                    child: Text('${rem.inMinutes + 1}m',
                                        style: const TextStyle(
                                            color: Colors.black,
                                            fontSize: 7,
                                            fontWeight: FontWeight.bold)),
                                  );
                                },
                              )),
                      ]),
                    ),
                    const SizedBox(width: 12),
                    _playerCtrlBtn(
                        icon: Icons.blur_on_rounded,
                        active: _crossfadeOn,
                        onTap: _showCrossfadeSheet,
                        tooltip: 'Crossfade'),
                  ]),
                ),
              ),

              const SizedBox(height: 12),

              // Main transport
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                IconButton(
                  icon: Icon(Icons.skip_previous_rounded,
                      size: 42,
                      color: _canSkipPreviousInCurrentContext
                          ? textColor
                          : (isDark ? Colors.grey[700] : Colors.grey[400])),
                  onPressed: (!_isBuffering && _canSkipPreviousInCurrentContext)
                      ? _playPrevious
                      : null,
                ),
                Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.greenAccent,
                    boxShadow: [
                      BoxShadow(
                          color: Colors.greenAccent.withValues(alpha: 0.4),
                          blurRadius: 20,
                          spreadRadius: 2)
                    ],
                  ),
                  child: _isBuffering
                      ? const Padding(
                          padding: EdgeInsets.all(16),
                          child: CircularProgressIndicator(
                              color: Colors.black, strokeWidth: 2.5))
                      : IconButton(
                          padding: EdgeInsets.zero,
                          icon: Icon(
                              isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              color: Colors.black,
                              size: 38),
                          onPressed: () =>
                              isPlaying ? _player.pause() : _player.play()),
                ),
                IconButton(
                  icon:
                      Icon(Icons.skip_next_rounded, size: 42, color: textColor),
                  onPressed: _isBuffering
                      ? null
                      : () {
                          if (_isDownloadPlayback) {
                            _playNext(userInitiated: true);
                          } else if (_currentIndex < _playQueue.length - 1) {
                            _playNext(userInitiated: true);
                          } else {
                            _registerManualSkipFeedbackForCurrent();
                            unawaited(_playRadioNext());
                          }
                        },
                ),
                IconButton(
                  icon: Icon(
                    Icons.queue_music_rounded,
                    size: 28,
                    color: isDark ? Colors.grey[400] : Colors.grey[700],
                  ),
                  onPressed: _showQueueSheet,
                ),
              ]),

              const SizedBox(height: 8),

              // Add to playlist + download
              Wrap(alignment: WrapAlignment.center, spacing: 8, children: [
                TextButton.icon(
                  icon: Icon(Icons.playlist_add_rounded,
                      color: isDark ? Colors.grey[500] : Colors.grey[600],
                      size: 20),
                  label: Text('Add to playlist',
                      style: TextStyle(
                          color: isDark ? Colors.grey[500] : Colors.grey[600],
                          fontSize: 12)),
                  onPressed: () => _showAddToPlaylist(_nowPlaying!),
                ),
                Builder(builder: (context) {
                  final task = _taskForVideoId(_nowPlaying!.id.value);
                  if (task != null) {
                    if (task.state == _DownloadTaskState.downloading &&
                        _isTaskActive(task)) {
                      return IconButton(
                        tooltip: 'Pause download',
                        icon: Stack(
                          alignment: Alignment.center,
                          children: [
                            SizedBox(
                              width: 30,
                              height: 30,
                              child: CircularProgressIndicator(
                                value: task.progress > 0 ? task.progress : null,
                                color: Colors.greenAccent,
                                strokeWidth: 2.2,
                              ),
                            ),
                            const Icon(Icons.pause_rounded,
                                color: Colors.amberAccent, size: 16),
                          ],
                        ),
                        onPressed: () => _requestPauseDownloadTask(task),
                      );
                    }
                    if (task.state == _DownloadTaskState.paused) {
                      return IconButton(
                        tooltip: 'Resume download',
                        icon: const Icon(Icons.play_arrow_rounded,
                            color: Colors.greenAccent, size: 24),
                        onPressed: () => _resumeDownloadTask(task),
                      );
                    }
                    if (task.state == _DownloadTaskState.failed) {
                      return IconButton(
                        tooltip: 'Retry download',
                        icon: const Icon(Icons.refresh_rounded,
                            color: Colors.lightBlueAccent, size: 24),
                        onPressed: () => _retryDownloadTask(task),
                      );
                    }
                    return IconButton(
                      tooltip: 'Queued',
                      icon: Icon(Icons.schedule_rounded,
                          color: isDark ? Colors.grey[500] : Colors.grey[600],
                          size: 24),
                      onPressed: () => _cancelDownloadTask(task),
                    );
                  }
                  if (_isVideoDownloaded(_nowPlaying!)) {
                    return const Icon(Icons.download_done_rounded,
                        color: Colors.greenAccent, size: 24);
                  }
                  return IconButton(
                    icon: Icon(Icons.download_rounded,
                        color: isDark ? Colors.grey[500] : Colors.grey[600],
                        size: 24),
                    onPressed: () => _downloadAudio(_nowPlaying!),
                  );
                }),
              ]),

              // NEW: Lyrics / Credits / Share / Bio
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 4,
                  runSpacing: 2,
                  children: [
                    _nowPlayingActionBtn(
                      icon: Icons.lyrics_rounded,
                      label: 'Lyrics',
                      onTap: () => _showLyricsSheet(_nowPlaying!),
                      isDark: isDark,
                    ),
                    _nowPlayingActionBtn(
                      icon: Icons.info_outline_rounded,
                      label: 'Credits',
                      onTap: () => _showSongCreditsSheet(_nowPlaying!),
                      isDark: isDark,
                    ),
                    _nowPlayingActionBtn(
                      icon: Icons.share_rounded,
                      label: 'Share',
                      onTap: () => _shareSong(_nowPlaying!),
                      isDark: isDark,
                    ),
                    _nowPlayingActionBtn(
                      icon: Icons.account_circle_outlined,
                      label: 'Artist Bio',
                      onTap: () => _showArtistBioSheet(_nowPlaying!.author),
                      isDark: isDark,
                    ),
                  ],
                ),
              ),

              // NEW: Related Artists row
              if (_relatedArtists.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                  child: Row(children: [
                    Icon(Icons.people_rounded,
                        color: Colors.grey[600], size: 14),
                    const SizedBox(width: 6),
                    Text('Related Artists',
                        style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 12,
                            fontWeight: FontWeight.w500)),
                  ]),
                ),
                SizedBox(
                  height: 36,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: _relatedArtists.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (ctx, i) {
                      final artist = _relatedArtists[i];
                      return GestureDetector(
                        onTap: () {
                          setState(() => _showNowPlaying = false);
                          _openArtistPage(artist);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 7),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1A1A1A),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                                color:
                                    Colors.greenAccent.withValues(alpha: 0.3)),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.person_outline_rounded,
                                size: 12,
                                color:
                                    Colors.greenAccent.withValues(alpha: 0.8)),
                            const SizedBox(width: 5),
                            Text(artist,
                                style: TextStyle(
                                    color: Colors.grey[300], fontSize: 11)),
                          ]),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 4),
              ],
            ]),
          ), // closes SingleChildScrollView
        ),
      ),
    );
  }

  Widget _playerCtrlBtn({
    required IconData icon,
    required bool active,
    required VoidCallback onTap,
    required String tooltip,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Tooltip(
        message: tooltip,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: active
                ? Colors.greenAccent.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon,
              size: 22, color: active ? Colors.greenAccent : Colors.grey[600]),
        ),
      ),
    );
  }

  Widget _nowPlayingActionBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required bool isDark,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon,
              size: 20, color: isDark ? Colors.grey[500] : Colors.grey[600]),
          const SizedBox(height: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 10,
                  color: isDark ? Colors.grey[600] : Colors.grey[500])),
        ]),
      ),
    );
  }
}

// Animated equalizer bars
// ---
// Dot pattern painter
// ---
