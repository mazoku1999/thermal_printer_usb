import 'dart:typed_data';

/// A print job waiting in the retry queue.
///
/// When a print operation fails (e.g., the cable was momentarily disconnected),
/// the job is placed in a queue and retried when the connection is restored.
///
/// Jobs are discarded after [maxRetries] attempts to prevent infinite loops.
///
/// ```dart
/// print('Pending jobs: ${printer.pendingJobCount}');
/// for (final job in printer.pendingJobs) {
///   print('${job.description} — attempt ${job.retryCount}/${PrintJob.maxRetries}');
/// }
/// ```
class PrintJob {
  /// Maximum retry attempts before a job is discarded.
  static const int maxRetries = 3;

  /// Raw bytes to send to the printer.
  final Uint8List bytes;

  /// Human-readable label for this job (e.g., "receipt", "label").
  final String description;

  /// Timestamp when the job was created.
  final DateTime createdAt;

  /// Number of retries performed so far.
  int retryCount;

  /// Creates a [PrintJob] with the given [bytes] and [description].
  PrintJob({required this.bytes, this.description = 'raw'})
    : createdAt = DateTime.now(),
      retryCount = 0;

  /// Whether this job can still be retried.
  bool get canRetry => retryCount < maxRetries;

  @override
  String toString() =>
      'PrintJob($description, ${bytes.length} bytes, retry $retryCount/$maxRetries)';
}
