class LogEntry {
  final String timestamp;
  final String message;

  LogEntry({
    required this.timestamp,
    required this.message,
  });

  Map<String, dynamic> toMap() {
    return {
      'timestamp': timestamp,
      'message': message,
    };
  }

  factory LogEntry.fromMap(Map<String, dynamic> map) {
    return LogEntry(
      timestamp: map['timestamp'] as String,
      message: map['message'] as String,
    );
  }
}