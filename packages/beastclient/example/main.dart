import 'package:beastclient/beastclient.dart';

Future<void> main() async {
  final tracks = <AudioTrack>[
    AudioTrack(
      id: 'intro',
      uri: Uri.parse('https://cdn.example.com/audio/intro.mp3'),
      title: 'Intro',
    ),
    AudioTrack(
      id: 'loop',
      uri: Uri.parse('https://cdn.example.com/audio/loop.flac'),
      title: 'Loop',
    ),
  ];

  final client = BeastClient(
    engine: JustAudioEngine(),
    config: const BeastClientConfig(
      startupTarget: Duration(milliseconds: 50),
      prebufferTrackCount: 2,
      crossfadeDuration: Duration(milliseconds: 200),
      maxRetries: 2,
    ),
  );

  await client.initialize();
  await client.setQueue(tracks);

  final metrics = await client.playTrack(
    tracks.first,
    enhancementProfile: const AudioEnhancementProfile(
      enableEnhancement: true,
      eqBandGainsDb: <double>[1.5, 0.8, 0.0, -0.2, 0.6],
      compressorRatio: 1.2,
      preAmpDb: 0.5,
    ),
  );

  print('Startup latency: ${metrics.startupLatency.inMilliseconds}ms');
  await client.dispose();
}
