import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_esc_pos_utils/flutter_esc_pos_utils.dart';
import 'package:thermal_printer_usb/thermal_printer_usb.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThermalPrinterUsb.instance.initialize();
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Thermal Printer USB Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const PrinterDemoScreen(),
      builder: (context, child) {
        return PaperWarningListener(child: child ?? const SizedBox.shrink());
      },
    );
  }
}

// ═══════════════════════════════════════════════════════
//  Main screen
// ═══════════════════════════════════════════════════════

class PrinterDemoScreen extends StatefulWidget {
  const PrinterDemoScreen({super.key});

  @override
  State<PrinterDemoScreen> createState() => _PrinterDemoScreenState();
}

class _PrinterDemoScreenState extends State<PrinterDemoScreen> {
  final _printer = ThermalPrinterUsb.instance;
  List<UsbPrinterDevice> _devices = [];
  PrinterStatus? _status;
  bool _loading = false;

  late StreamSubscription<PrinterConnectionState> _stateSub;
  PrinterConnectionState _connectionState = PrinterConnectionState.disconnected;

  @override
  void initState() {
    super.initState();
    _stateSub = _printer.connectionStateStream.listen((state) {
      if (mounted) setState(() => _connectionState = state);
    });
    _refreshDevices();
  }

  @override
  void dispose() {
    _stateSub.cancel();
    super.dispose();
  }

  Future<void> _refreshDevices() async {
    final devices = await _printer.getDevices();
    if (mounted) setState(() => _devices = devices);
  }

  Future<void> _connect(UsbPrinterDevice device) async {
    setState(() => _loading = true);
    final success = await _printer.connect(device);
    if (success) {
      _status = await _printer.getPrinterStatus();
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _disconnect() async {
    await _printer.disconnect();
    if (mounted) setState(() => _status = null);
  }

  Future<void> _refreshStatus() async {
    final status = await _printer.getPrinterStatus();
    if (mounted) setState(() => _status = status);
  }

  // ─── Raw bytes test (no extra dependencies) ───
  Future<void> _printTestPage() async {
    final bytes = <int>[];
    bytes.addAll([0x1B, 0x40]); // ESC @ — Initialize
    bytes.addAll([0x1B, 0x45, 0x01]); // Bold ON
    bytes.addAll([0x1B, 0x61, 0x01]); // Center
    bytes.addAll('=== THERMAL_PRINTER_USB ===\n'.codeUnits);
    bytes.addAll([0x1B, 0x45, 0x00]); // Bold OFF
    bytes.addAll('Plugin Test Page\n'.codeUnits);
    bytes.addAll('--------------------------------\n'.codeUnits);
    bytes.addAll([0x1B, 0x61, 0x00]); // Left
    bytes.addAll(
      'Device: ${_printer.connectedDevice?.productName ?? "?"}\n'.codeUnits,
    );
    bytes.addAll('VID: ${_printer.connectedDevice?.vendorId ?? 0}\n'.codeUnits);
    bytes.addAll(
      'PID: ${_printer.connectedDevice?.productId ?? 0}\n'.codeUnits,
    );
    if (_status != null && _status!.supported) {
      bytes.addAll('--------------------------------\n'.codeUnits);
      bytes.addAll('Paper: ${_status!.paperOk ? "OK" : "EMPTY"}\n'.codeUnits);
      bytes.addAll(
        'Cover:  ${_status!.coverClosed ? "Closed" : "OPEN"}\n'.codeUnits,
      );
      bytes.addAll('Status: ${_status!.summaryText}\n'.codeUnits);
    }
    bytes.addAll('--------------------------------\n'.codeUnits);
    bytes.addAll([0x1B, 0x61, 0x01]); // Center
    bytes.addAll('github.com/mazoku1999\n'.codeUnits);
    bytes.addAll('/thermal_printer_usb\n'.codeUnits);
    bytes.addAll([0x0A, 0x0A, 0x0A]); // Feed
    bytes.addAll([0x1D, 0x56, 0x00]); // GS V 0 (full cut)

    final success = await _printer.printRaw(
      Uint8List.fromList(bytes),
      description: 'test_page_raw',
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? '✅ Raw test printed!' : '❌ Print failed'),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }

  // ─── Diagnostic ticket using flutter_esc_pos_utils ───
  //
  // This demonstrates how to use the Generator class to build
  // a real formatted ticket with styles, code tables, and cuts.
  Future<void> _printDiagnosticTicket() async {
    try {
      final profile = await CapabilityProfile.load();
      final gen = Generator(PaperSize.mm80, profile);
      List<int> bytes = [];

      bytes += gen.setGlobalCodeTable('CP1252');

      // Header
      bytes += gen.text(
        '=== DIAGNOSTIC TICKET ===',
        styles: const PosStyles(
          align: PosAlign.center,
          bold: true,
          height: PosTextSize.size2,
          width: PosTextSize.size1,
        ),
      );
      bytes += gen.hr();

      // Device info
      bytes += gen.text('Printer:', styles: const PosStyles(bold: true));
      bytes += gen.text(
        '  ${_printer.connectedDevice?.productName ?? "Unknown"}',
      );
      bytes += gen.text('  VID: ${_printer.connectedDevice?.vendorId ?? 0}');
      bytes += gen.text('  PID: ${_printer.connectedDevice?.productId ?? 0}');
      bytes += gen.text(
        '  Mfr: ${_printer.connectedDevice?.manufacturerName ?? "N/A"}',
      );
      bytes += gen.hr();

      // Configuration
      bytes += gen.text('Configuration:', styles: const PosStyles(bold: true));
      bytes += gen.text('  Paper width: 80mm');
      bytes += gen.text('  Date: ${_formatDate(DateTime.now())}');
      bytes += gen.hr();

      // Live status
      final status = await _printer.getPrinterStatus();
      if (mounted) setState(() => _status = status);

      bytes += gen.text('Status:', styles: const PosStyles(bold: true));
      bytes += gen.text(
        '  Supports status: ${status.supported ? "Yes" : "No"}',
      );
      if (status.supported) {
        bytes += gen.text('  Paper: ${status.paperOk ? "OK" : "EMPTY"}');
        if (status.paperNearEnd) bytes += gen.text('  >> Paper near end');
        bytes += gen.text('  Cover: ${status.coverClosed ? "Closed" : "OPEN"}');
        bytes += gen.text('  Online: ${status.online ? "Yes" : "No"}');
        if (status.autoCutterError) bytes += gen.text('  >> Cutter error');
        if (status.unrecoverableError) {
          bytes += gen.text('  >> Unrecoverable error');
        }
        if (status.autoRecoverableError) {
          bytes += gen.text('  >> Auto-recoverable error');
        }
        bytes += gen.text('  Summary: ${status.summaryText}');
      }
      bytes += gen.hr();

      // Print queue
      bytes += gen.text('Queue:', styles: const PosStyles(bold: true));
      bytes += gen.text('  Pending jobs: ${_printer.pendingJobCount}');
      bytes += gen.hr();

      // Character test
      bytes += gen.text('Character test:', styles: const PosStyles(bold: true));
      bytes += gen.text('  ABCDEFGHIJKLMNOPQRSTUVWXYZ');
      bytes += gen.text('  abcdefghijklmnopqrstuvwxyz');
      bytes += gen.text('  0123456789');
      bytes += gen.text('  100.50 - Total: 1,250.00');
      bytes += gen.hr();

      // Partial cut
      bytes += gen.text(
        '--- PARTIAL CUT ---',
        styles: const PosStyles(align: PosAlign.center),
      );
      bytes += gen.feed(2);
      bytes += gen.cut(mode: PosCutMode.partial);

      // Full cut
      bytes += gen.text(
        '--- FULL CUT ---',
        styles: const PosStyles(align: PosAlign.center),
      );
      bytes += gen.feed(3);
      bytes += gen.cut();

      final success = await _printer.printBytes(
        bytes,
        description: 'diagnostic_ticket',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              success
                  ? '✅ Diagnostic ticket printed!'
                  : '❌ Print failed — check connection',
            ),
            backgroundColor: success ? Colors.green : Colors.red,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  String _formatDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/'
        '${date.year} '
        '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = _connectionState == PrinterConnectionState.connected;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Thermal Printer USB'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshDevices,
            tooltip: 'Refresh devices',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ─── Connection status card ───
          Card(
            color: _stateColor.withAlpha(30),
            child: ListTile(
              leading: Icon(_stateIcon, color: _stateColor, size: 32),
              title: Text(
                _stateLabel,
                style: TextStyle(
                  color: _stateColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
              subtitle: Text(
                _printer.connectedDevice?.productName ?? 'No printer connected',
              ),
              trailing: isConnected
                  ? FilledButton.tonal(
                      onPressed: _disconnect,
                      child: const Text('Disconnect'),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 16),

          // ─── Devices list ───
          Text(
            'USB Devices',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          if (_devices.isEmpty)
            Card(
              child: ListTile(
                leading: const Icon(Icons.usb_off),
                title: const Text('No USB devices found'),
                subtitle: const Text('Connect a printer and tap refresh'),
              ),
            )
          else
            ..._devices.map(
              (device) => Card(
                child: ListTile(
                  leading: Icon(
                    Icons.print,
                    color:
                        isConnected &&
                            _printer.connectedDevice?.vendorId ==
                                device.vendorId &&
                            _printer.connectedDevice?.productId ==
                                device.productId
                        ? Colors.green
                        : null,
                  ),
                  title: Text(device.productName),
                  subtitle: Text(
                    'VID:${device.vendorId} PID:${device.productId} • '
                    '${device.hasPermission ? "Permission granted" : "No permission"}',
                  ),
                  trailing: _loading
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : isConnected
                      ? null
                      : FilledButton(
                          onPressed: () => _connect(device),
                          child: const Text('Connect'),
                        ),
                ),
              ),
            ),
          const SizedBox(height: 24),

          // ─── Status section ───
          if (isConnected) ...[
            Text(
              'Printer Status',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _status == null
                    ? const Text('Tap "Refresh Status" to read printer status')
                    : _status!.supported
                    ? Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _statusChip(
                            'Paper',
                            _status!.paperOk ? 'OK' : 'EMPTY',
                            _status!.paperOk,
                          ),
                          if (_status!.paperNearEnd)
                            _statusChip(
                              'Paper',
                              'Near End',
                              false,
                              warning: true,
                            ),
                          _statusChip(
                            'Cover',
                            _status!.coverClosed ? 'Closed' : 'OPEN',
                            _status!.coverClosed,
                          ),
                          _statusChip(
                            'Online',
                            _status!.online ? 'Yes' : 'No',
                            _status!.online,
                          ),
                          if (_status!.autoCutterError)
                            _statusChip('Cutter', 'ERROR', false),
                          if (_status!.unrecoverableError)
                            _statusChip('Fatal', 'ERROR', false),
                          if (_status!.autoRecoverableError)
                            _statusChip(
                              'Auto',
                              'Recoverable',
                              false,
                              warning: true,
                            ),
                          if (!_status!.hasAnyError)
                            _statusChip('Overall', 'OK', true),
                        ],
                      )
                    : const Text(
                        'This printer does not support status commands',
                      ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _refreshStatus,
                    icon: const Icon(Icons.health_and_safety),
                    label: const Text('Refresh Status'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _printTestPage,
                    icon: const Icon(Icons.print),
                    label: const Text('Raw Test'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _printDiagnosticTicket,
                icon: const Icon(Icons.receipt_long),
                label: const Text('Diagnostic Ticket (esc_pos_utils)'),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.deepPurple,
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],

          // ─── Logs section ───
          Row(
            children: [
              Expanded(
                child: Text(
                  'Logs (${_printer.logs.length})',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              TextButton(
                onPressed: () {
                  _printer.clearLogs();
                  setState(() {});
                },
                child: const Text('Clear'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ..._printer.logs.reversed
              .take(20)
              .map(
                (log) => Card(
                  child: ListTile(
                    dense: true,
                    leading: Icon(
                      log.success ? Icons.check_circle : Icons.error,
                      color: log.success ? Colors.green : Colors.red,
                      size: 20,
                    ),
                    title: Text(
                      log.operation,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(log.details ?? ''),
                    trailing: log.transferTimeMs != null
                        ? Text(
                            '${log.transferTimeMs}ms',
                            style: theme.textTheme.bodySmall,
                          )
                        : null,
                  ),
                ),
              ),
        ],
      ),
    );
  }

  Widget _statusChip(
    String label,
    String value,
    bool ok, {
    bool warning = false,
  }) {
    final color = ok
        ? Colors.green
        : warning
        ? Colors.orange
        : Colors.red;
    return Chip(
      avatar: Icon(
        ok
            ? Icons.check_circle
            : warning
            ? Icons.warning
            : Icons.error,
        color: color,
        size: 18,
      ),
      label: Text('$label: $value'),
      side: BorderSide(color: color.withAlpha(80)),
    );
  }

  Color get _stateColor {
    switch (_connectionState) {
      case PrinterConnectionState.connected:
        return Colors.green;
      case PrinterConnectionState.connecting:
      case PrinterConnectionState.reconnecting:
        return Colors.orange;
      case PrinterConnectionState.connectionLost:
        return Colors.red;
      case PrinterConnectionState.disconnected:
        return Colors.grey;
    }
  }

  IconData get _stateIcon {
    switch (_connectionState) {
      case PrinterConnectionState.connected:
        return Icons.usb;
      case PrinterConnectionState.connecting:
      case PrinterConnectionState.reconnecting:
        return Icons.sync;
      case PrinterConnectionState.connectionLost:
        return Icons.usb_off;
      case PrinterConnectionState.disconnected:
        return Icons.usb_off;
    }
  }

  String get _stateLabel {
    switch (_connectionState) {
      case PrinterConnectionState.connected:
        return 'Connected';
      case PrinterConnectionState.connecting:
        return 'Connecting...';
      case PrinterConnectionState.reconnecting:
        return 'Reconnecting...';
      case PrinterConnectionState.connectionLost:
        return 'Connection Lost';
      case PrinterConnectionState.disconnected:
        return 'Disconnected';
    }
  }
}

// ═══════════════════════════════════════════════════════
//  Paper Warning Listener (global alert dialog)
// ═══════════════════════════════════════════════════════

/// Example widget that listens to paper warnings and shows a dialog.
///
/// Wrap your [MaterialApp]'s child with this widget using the `builder`
/// property to get global paper alerts before each print.
///
/// ```dart
/// MaterialApp(
///   home: const MyHomePage(),
///   builder: (context, child) {
///     return PaperWarningListener(
///       child: child ?? const SizedBox.shrink(),
///     );
///   },
/// );
/// ```
class PaperWarningListener extends StatefulWidget {
  /// The child widget tree.
  final Widget child;

  /// Cooldown between consecutive warnings (default: 30 seconds).
  final Duration cooldown;

  /// Creates a [PaperWarningListener].
  const PaperWarningListener({
    super.key,
    required this.child,
    this.cooldown = const Duration(seconds: 30),
  });

  @override
  State<PaperWarningListener> createState() => _PaperWarningListenerState();
}

class _PaperWarningListenerState extends State<PaperWarningListener> {
  StreamSubscription<PaperWarning>? _subscription;
  bool _dialogShowing = false;
  DateTime? _lastWarningTime;

  @override
  void initState() {
    super.initState();
    _subscription = ThermalPrinterUsb.instance.paperWarningStream.listen(
      _onWarning,
    );
  }

  void _onWarning(PaperWarning warning) {
    if (!mounted || warning == PaperWarning.ok || _dialogShowing) return;

    final now = DateTime.now();
    if (_lastWarningTime != null &&
        now.difference(_lastWarningTime!) < widget.cooldown) {
      return;
    }

    _lastWarningTime = now;
    _dialogShowing = true;

    final isEmpty = warning == PaperWarning.empty;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(
          isEmpty ? Icons.error : Icons.warning,
          color: isEmpty ? Colors.red : Colors.orange,
          size: 48,
        ),
        title: Text(isEmpty ? 'No Paper!' : 'Paper Running Low'),
        content: Text(
          isEmpty
              ? 'The paper roll is empty. Replace it before printing.'
              : 'The paper roll is almost finished. Consider replacing it soon.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    ).then((_) {
      _dialogShowing = false;
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
