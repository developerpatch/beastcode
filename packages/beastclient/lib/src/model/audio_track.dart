import 'audio_format.dart';

class AudioTrack {
  const AudioTrack({
    required this.id,
    required this.uri,
    this.title,
    this.artist,
    AudioFormat? format,
    this.durationHint,
    this.headers = const <String, String>{},
  }) : format = format ?? AudioFormat.unknown;

  final String id;
  final Uri uri;
  final String? title;
  final String? artist;
  final AudioFormat format;
  final Duration? durationHint;
  final Map<String, String> headers;

  AudioTrack withInferredFormat() {
    if (format != AudioFormat.unknown) return this;
    return AudioTrack(
      id: id,
      uri: uri,
      title: title,
      artist: artist,
      format: inferAudioFormat(uri),
      durationHint: durationHint,
      headers: headers,
    );
  }
}
