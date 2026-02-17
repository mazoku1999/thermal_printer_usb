/// Paper status level for global alerts.
///
/// Used by [ThermalPrinterUsb.paperWarningStream] to broadcast
/// paper conditions before each print operation.
///
/// ```dart
/// printer.paperWarningStream.listen((warning) {
///   if (warning == PaperWarning.nearEnd) {
///     showAlert('Paper is running low!');
///   }
/// });
/// ```
enum PaperWarning {
  /// Paper level is normal.
  ok,

  /// Paper roll is near its end — replace soon.
  nearEnd,

  /// Paper is empty or not detected — printing will fail.
  empty,
}

/// Physical status of the thermal printer, read via ESC/POS DLE EOT commands.
///
/// This model captures the full status from three DLE EOT queries:
/// - **DLE EOT 2** — Offline cause (cover, feed button, errors)
/// - **DLE EOT 3** — Error status (cutter, unrecoverable, auto-recoverable)
/// - **DLE EOT 4** — Paper sensor (near end, empty)
///
/// If a printer doesn't support status queries, [supported] will be `false`
/// and all other fields will have safe defaults.
///
/// ```dart
/// final status = await printer.getPrinterStatus();
/// if (status.hasAnyError) {
///   print('Issues: ${status.summaryText}');
/// }
/// ```
class PrinterStatus {
  /// Whether the printer supports DLE EOT status commands.
  final bool supported;

  /// `true` if paper is present and ready to print.
  final bool paperOk;

  /// `true` if the paper roll is near its end (DLE EOT 4, bits 2-3).
  final bool paperNearEnd;

  /// `true` if the printer cover is closed.
  final bool coverClosed;

  /// `true` if the printer is online and ready.
  final bool online;

  // ── DLE EOT 2: Offline cause ──

  /// `true` if the feed button is currently pressed.
  final bool feedButtonPressed;

  /// `true` if printing has stopped due to an error.
  final bool printingErrorStopped;

  /// `true` if a general error has occurred.
  final bool errorOccurred;

  // ── DLE EOT 3: Error status ──

  /// `true` if the auto-cutter has an error (paper jam, etc.).
  final bool autoCutterError;

  /// `true` if an unrecoverable error has occurred (requires service).
  final bool unrecoverableError;

  /// `true` if an auto-recoverable error has occurred (will clear itself).
  final bool autoRecoverableError;

  /// Creates a [PrinterStatus] with all fields.
  const PrinterStatus({
    required this.supported,
    required this.paperOk,
    required this.coverClosed,
    required this.online,
    this.paperNearEnd = false,
    this.feedButtonPressed = false,
    this.printingErrorStopped = false,
    this.errorOccurred = false,
    this.autoCutterError = false,
    this.unrecoverableError = false,
    this.autoRecoverableError = false,
  });

  /// Creates a [PrinterStatus] from a native platform map.
  factory PrinterStatus.fromMap(Map<dynamic, dynamic> map) {
    return PrinterStatus(
      supported: map['supported'] as bool? ?? false,
      paperOk: map['paperOk'] as bool? ?? true,
      paperNearEnd: map['paperNearEnd'] as bool? ?? false,
      coverClosed: map['coverClosed'] as bool? ?? true,
      online: map['online'] as bool? ?? true,
      feedButtonPressed: map['feedButtonPressed'] as bool? ?? false,
      printingErrorStopped: map['printingErrorStopped'] as bool? ?? false,
      errorOccurred: map['errorOccurred'] as bool? ?? false,
      autoCutterError: map['autoCutterError'] as bool? ?? false,
      unrecoverableError: map['unrecoverableError'] as bool? ?? false,
      autoRecoverableError: map['autoRecoverableError'] as bool? ?? false,
    );
  }

  /// `true` if any error condition is active.
  ///
  /// Checks: paper empty, cover open, cutter error, unrecoverable error,
  /// and printing stopped.
  bool get hasAnyError =>
      !paperOk ||
      !coverClosed ||
      autoCutterError ||
      unrecoverableError ||
      printingErrorStopped;

  /// Current paper warning level.
  ///
  /// Returns [PaperWarning.empty] if no paper, [PaperWarning.nearEnd]
  /// if running low, or [PaperWarning.ok] if paper is fine.
  PaperWarning get paperWarning {
    if (!paperOk) return PaperWarning.empty;
    if (paperNearEnd) return PaperWarning.nearEnd;
    return PaperWarning.ok;
  }

  /// Human-readable summary of all detected issues.
  ///
  /// Returns `'OK'` when no issues are found, otherwise a bullet-separated
  /// list of problems (e.g. `'NO PAPER • COVER OPEN • CUTTER ERROR'`).
  String get summaryText {
    final issues = <String>[];
    if (!paperOk) {
      issues.add('NO PAPER');
    } else if (paperNearEnd) {
      issues.add('Paper near end');
    }
    if (!coverClosed) {
      issues.add('COVER OPEN');
    }
    if (autoCutterError) {
      issues.add('CUTTER ERROR');
    }
    if (unrecoverableError) {
      issues.add('UNRECOVERABLE ERROR');
    }
    if (autoRecoverableError) {
      issues.add('Auto-recoverable error');
    }
    if (printingErrorStopped) {
      issues.add('PRINTING STOPPED');
    }
    return issues.isEmpty ? 'OK' : issues.join(' • ');
  }

  @override
  String toString() => 'PrinterStatus(supported: $supported, $summaryText)';
}
