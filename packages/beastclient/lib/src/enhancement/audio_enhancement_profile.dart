class AudioEnhancementProfile {
  const AudioEnhancementProfile({
    this.enableEnhancement = false,
    this.eqBandGainsDb = const <double>[0, 0, 0, 0, 0],
    this.compressorRatio = 1.0,
    this.preAmpDb = 0.0,
  });

  final bool enableEnhancement;
  final List<double> eqBandGainsDb;
  final double compressorRatio;
  final double preAmpDb;
}
