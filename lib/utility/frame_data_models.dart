// Frame-specific data models and transmission results
class TransmissionResult {
  final bool success;
  final String? error;
  final int bytesTransmitted;
  final int chunkCount;
  final Duration elapsedTime;
  final String? response;

  TransmissionResult({
    required this.success,
    this.error,
    required this.bytesTransmitted,
    required this.chunkCount,
    required this.elapsedTime,
    this.response,
  });

  TransmissionResult copyWith({
    bool? success,
    String? error,
    int? bytesTransmitted,
    int? chunkCount,
    Duration? elapsedTime,
    String? response,
  }) {
    return TransmissionResult(
      success: success ?? this.success,
      error: error ?? this.error,
      bytesTransmitted: bytesTransmitted ?? this.bytesTransmitted,
      chunkCount: chunkCount ?? this.chunkCount,
      elapsedTime: elapsedTime ?? this.elapsedTime,
      response: response ?? this.response,
    );
  }
}

class ConnectionHealth {
  int successfulTransmissions = 0;
  int failedTransmissions = 0;
  DateTime? lastSuccessfulTransmission;
  DateTime? lastFailedTransmission;
  Duration averageLatency = Duration.zero;
  List<Duration> latencyHistory = [];

  double get successRate {
    final total = successfulTransmissions + failedTransmissions;
    return total > 0 ? successfulTransmissions / total : 0.0;
  }

  void recordSuccess(Duration latency) {
    successfulTransmissions++;
    lastSuccessfulTransmission = DateTime.now();
    latencyHistory.add(latency);
    if (latencyHistory.length > 10) {
      latencyHistory.removeAt(0);
    }
    _updateAverageLatency();
  }

  void recordFailure() {
    failedTransmissions++;
    lastFailedTransmission = DateTime.now();
  }

  void _updateAverageLatency() {
    if (latencyHistory.isNotEmpty) {
      final totalMs = latencyHistory.fold<int>(0, (sum, duration) => sum + duration.inMilliseconds);
      averageLatency = Duration(milliseconds: totalMs ~/ latencyHistory.length);
    }
  }
}