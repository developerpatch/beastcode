part of 'package:beastcode/main.dart';

class _WrappedStorySlideData {
  final String kicker;
  final String title;
  final String subtitle;
  final IconData icon;
  final List<String> points;
  final List<Color> palette;

  const _WrappedStorySlideData({
    required this.kicker,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.points,
    required this.palette,
  });
}

class _WrappedStoryViewer extends StatefulWidget {
  final String periodLabel;
  final String periodWindowLabel;
  final String periodEmoji;
  final Map<String, dynamic> stats;
  final String? heroArtUrl;

  const _WrappedStoryViewer({
    required this.periodLabel,
    required this.periodWindowLabel,
    required this.periodEmoji,
    required this.stats,
    this.heroArtUrl,
  });

  @override
  State<_WrappedStoryViewer> createState() => _WrappedStoryViewerState();
}

class _WrappedStoryViewerState extends State<_WrappedStoryViewer> {
  static const Duration _slideDuration = Duration(seconds: 5);
  static const Duration _slideTick = Duration(milliseconds: 50);

  late final List<_WrappedStorySlideData> _slides;
  Timer? _progressTimer;
  int _slideIndex = 0;
  double _slideProgress = 0;

  @override
  void initState() {
    super.initState();
    _slides = _buildSlides();
    _restartProgress();
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    super.dispose();
  }

  List<_WrappedStorySlideData> _buildSlides() {
    final plays = (widget.stats['plays'] as int?) ?? 0;
    final minutes = (widget.stats['minutes'] as int?) ?? 0;
    final uniqueSongs = (widget.stats['uniqueSongs'] as int?) ?? 0;
    final uniqueArtists = (widget.stats['uniqueArtists'] as int?) ?? 0;

    final topArtists = ((widget.stats['topArtists'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
    final topSongs = ((widget.stats['topSongs'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
    final personality = ((widget.stats['personality'] as List?) ?? const [])
        .whereType<String>()
        .toList();

    final topSong = topSongs.isNotEmpty ? topSongs.first : null;
    final topSongTitle = (topSong?['title'] as String? ?? 'Unknown').trim();
    final topSongArtist = (topSong?['artist'] as String? ?? 'Unknown').trim();
    final topSongPlays = (topSong?['plays'] as int?) ?? 0;

    final slides = <_WrappedStorySlideData>[
      _WrappedStorySlideData(
        kicker: 'BEAST WRAPPED',
        title: '${widget.periodEmoji} ${widget.periodLabel} Wrap',
        subtitle: '${widget.periodWindowLabel} • Here is your vibe snapshot',
        icon: Icons.auto_awesome_rounded,
        points: [
          '$minutes minutes listened',
          '$plays total plays',
          '$uniqueSongs songs across $uniqueArtists artists',
        ],
        palette: const [
          Color(0xFF004a8f),
          Color(0xFF007f9a),
          Color(0xFF001c30),
        ],
      ),
      _WrappedStorySlideData(
        kicker: 'MOST PLAYED TRACK',
        title: topSongTitle,
        subtitle: '$topSongArtist • played $topSongPlays times',
        icon: Icons.graphic_eq_rounded,
        points: topSongs
            .take(3)
            .map((s) => '${s['title']} · ${s['artist']} (${s['plays']} plays)')
            .toList(),
        palette: const [
          Color(0xFF2a176d),
          Color(0xFF5d2a9e),
          Color(0xFF130722),
        ],
      ),
      _WrappedStorySlideData(
        kicker: 'TOP ARTISTS',
        title: topArtists.isEmpty
            ? 'Building your artist profile'
            : '${topArtists.first['name']} led your rotation',
        subtitle: 'Artists you kept coming back to',
        icon: Icons.mic_external_on_rounded,
        points: topArtists
            .take(5)
            .toList()
            .asMap()
            .entries
            .map((e) =>
                '${e.key + 1}. ${e.value['name']} • ${e.value['plays']} plays')
            .toList(),
        palette: const [
          Color(0xFF522207),
          Color(0xFFb84f12),
          Color(0xFF2a1004),
        ],
      ),
    ];

    slides.add(
      _WrappedStorySlideData(
        kicker: 'LISTENER DNA',
        title:
            personality.isEmpty ? 'Steady Listener' : personality.join(' · '),
        subtitle: 'Your personality tags for this period',
        icon: Icons.psychology_alt_rounded,
        points: [
          'Keep this streak alive for your next wrap',
          'Tap anywhere on right side to move ahead',
          'Tap left side to go back anytime',
        ],
        palette: const [
          Color(0xFF063f3b),
          Color(0xFF178f7c),
          Color(0xFF041e1b),
        ],
      ),
    );

    return slides.where((s) => s.points.isNotEmpty).toList();
  }

  void _restartProgress() {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(_slideTick, (timer) {
      if (!mounted) return;
      final inc = _slideTick.inMilliseconds / _slideDuration.inMilliseconds;
      setState(() => _slideProgress += inc);
      if (_slideProgress >= 1) {
        _nextSlide();
      }
    });
  }

  void _nextSlide() {
    if (_slideIndex >= _slides.length - 1) {
      _progressTimer?.cancel();
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _slideIndex++;
      _slideProgress = 0;
    });
    _restartProgress();
  }

  void _previousSlide() {
    if (_slideIndex <= 0) {
      setState(() => _slideProgress = 0);
      _restartProgress();
      return;
    }
    setState(() {
      _slideIndex--;
      _slideProgress = 0;
    });
    _restartProgress();
  }

  void _onTapDown(TapDownDetails details) {
    final width = MediaQuery.of(context).size.width;
    if (details.localPosition.dx < width * 0.35) {
      _previousSlide();
    } else {
      _nextSlide();
    }
  }

  double _segmentProgress(int index) {
    if (index < _slideIndex) return 1;
    if (index == _slideIndex) return _slideProgress.clamp(0, 1);
    return 0;
  }

  Widget _buildSlide(_WrappedStorySlideData slide) {
    return Container(
      key: ValueKey<int>(_slideIndex),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: slide.palette,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Stack(children: [
        if (widget.heroArtUrl != null)
          Positioned.fill(
            child: Opacity(
              opacity: 0.27,
              child: Image.network(
                widget.heroArtUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox(),
              ),
            ),
          ),
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.black.withValues(alpha: 0.12),
                  Colors.black.withValues(alpha: 0.22),
                  Colors.black.withValues(alpha: 0.55),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
        ),
        Positioned(
          top: -40,
          right: -24,
          child: Container(
            width: 180,
            height: 180,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
          ),
        ),
        Positioned(
          bottom: -30,
          left: -30,
          child: Container(
            width: 160,
            height: 160,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 72, 20, 36),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                    border:
                        Border.all(color: Colors.white.withValues(alpha: 0.16)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(slide.icon, color: Colors.white, size: 13),
                    const SizedBox(width: 6),
                    Text(
                      slide.kicker,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ]),
                ),
                const Spacer(),
                Text(
                  slide.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 34,
                    height: 1.08,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  slide.subtitle,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.86),
                    fontSize: 13,
                    height: 1.25,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 18),
                ...slide.points.take(5).map((p) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.24),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                              color: Colors.white.withValues(alpha: 0.12)),
                        ),
                        child: Text(
                          p,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    )),
              ],
            ),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final slide = _slides[_slideIndex];
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _onTapDown,
        child: Stack(children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 340),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: _buildSlide(slide),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(children: [
                Row(children: [
                  Expanded(
                    child: Row(
                      children: List.generate(_slides.length, (i) {
                        return Expanded(
                          child: Container(
                            height: 3,
                            margin: EdgeInsets.only(
                                right: i == _slides.length - 1 ? 0 : 4),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(999),
                              color: Colors.white.withValues(alpha: 0.22),
                            ),
                            child: FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: _segmentProgress(i),
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(999),
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close_rounded,
                        color: Colors.white, size: 20),
                  ),
                ]),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.18),
                    ),
                  ),
                  child: Text(
                    'Tap right for next · Tap left for previous',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.88),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
