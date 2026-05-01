enum BeastClientErrorCode {
  networkInterruption,
  corruptedAudio,
  unsupportedFormat,
  playbackFailure,
  timeout,
  unknown,
}

class BeastClientException implements Exception {
  const BeastClientException(
    this.code,
    this.message, {
    this.cause,
  });

  final BeastClientErrorCode code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'BeastClientException($code): $message';
}
