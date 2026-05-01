enum AudioFormat {
  mp3,
  flac,
  aac,
  wav,
  ogg,
  unknown,
}

AudioFormat inferAudioFormat(Uri uri) {
  final path = uri.path.toLowerCase();
  if (path.endsWith('.mp3')) return AudioFormat.mp3;
  if (path.endsWith('.flac')) return AudioFormat.flac;
  if (path.endsWith('.aac') || path.endsWith('.m4a')) return AudioFormat.aac;
  if (path.endsWith('.wav')) return AudioFormat.wav;
  if (path.endsWith('.ogg') || path.endsWith('.oga')) return AudioFormat.ogg;
  return AudioFormat.unknown;
}
