import 'package:flutter/foundation.dart';

/// Types of printer alerts that the host app can react to.
///
/// These are emitted on [ThermalPrinterUsb.printerAlertStream] and are
/// meant to drive UI notifications (dialogs, snackbars, etc.).
enum PrinterAlertType {
  /// The printer cover/lid is open.  The user should close it.
  coverOpen,

  /// The printer cover/lid was closed (resolved).
  coverClosed,

  /// The printer has no paper.
  noPaper,

  /// The printer paper is near its end.
  paperNearEnd,

  /// Paper status recovered (paper is OK again).
  paperOk,

  /// Data transfer to the printer was unusually slow (> 2 s).
  /// This usually indicates a damaged or low-quality USB cable.
  slowTransfer,

  /// A print job failed and was added to the retry queue.
  /// It will be retried automatically when the connection is restored.
  jobQueued,
}

/// A lightweight alert emitted by [ThermalPrinterUsb] when something
/// noteworthy happens during printing or status checks.
@immutable
class PrinterAlert {
  /// What happened.
  final PrinterAlertType type;

  /// Optional human-readable details.
  final String? message;

  /// Transfer time in milliseconds (only for [PrinterAlertType.slowTransfer]).
  final int? transferTimeMs;

  /// Number of pending jobs (only for [PrinterAlertType.jobQueued]).
  final int? pendingJobs;

  /// Creates a [PrinterAlert].
  const PrinterAlert(
    this.type, {
    this.message,
    this.transferTimeMs,
    this.pendingJobs,
  });

  @override
  String toString() =>
      'PrinterAlert($type${message != null ? ', $message' : ''})';
}
