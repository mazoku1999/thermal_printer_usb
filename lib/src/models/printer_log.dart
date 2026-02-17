/// A structured log entry for printer operations.
///
/// Logs are stored in a circular buffer (default: 100 entries) and persisted
/// to disk as JSON. Useful for debugging connection issues, tracking print
/// performance, and monitoring paper status.
///
/// ```dart
/// for (final log in printer.logs) {
///   print('[${log.timestamp}] ${log.operation}: ${log.success ? "OK" : "FAIL"}'
///       '${log.details != null ? " — ${log.details}" : ""}');
/// }
/// ```
class PrinterLogEntry {
  /// Operation type (e.g., "connect", "print", "paper_check").
  final String operation;

  /// Whether the operation succeeded.
  final bool success;

  /// When the operation occurred.
  final DateTime timestamp;

  /// Optional details (e.g., error message, device name).
  final String? details;

  /// Transfer time in milliseconds (only for print operations).
  final int? transferTimeMs;

  /// Creates a [PrinterLogEntry].
  PrinterLogEntry({
    required this.operation,
    required this.success,
    this.details,
    this.transferTimeMs,
  }) : timestamp = DateTime.now();

  /// Creates a [PrinterLogEntry] from a JSON map (for deserialization).
  factory PrinterLogEntry.fromJson(Map<String, dynamic> json) {
    final entry = PrinterLogEntry(
      operation: json['op'] as String,
      success: json['ok'] as bool,
      details: json['d'] as String?,
      transferTimeMs: json['ms'] as int?,
    );
    return entry;
  }

  /// Serializes this entry to a compact JSON map.
  Map<String, dynamic> toJson() => {
    'op': operation,
    'ok': success,
    't': timestamp.toIso8601String(),
    if (details != null) 'd': details,
    if (transferTimeMs != null) 'ms': transferTimeMs,
  };

  @override
  String toString() {
    final buffer = StringBuffer(
      '[${timestamp.toIso8601String()}] $operation: ',
    );
    buffer.write(success ? 'OK' : 'FAIL');
    if (details != null) buffer.write(' — $details');
    if (transferTimeMs != null) buffer.write(' (${transferTimeMs}ms)');
    return buffer.toString();
  }
}
