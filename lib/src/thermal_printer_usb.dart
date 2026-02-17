import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/print_job.dart';
import 'models/printer_log.dart';
import 'models/printer_status.dart';
import 'models/usb_device.dart';
import 'usb_event.dart';

/// Flutter plugin for USB thermal printers (ESC/POS).
///
/// Provides a complete, production-ready interface for discovering, connecting
/// to, and printing on USB thermal printers via the Android USB Host API.
///
/// ## Features
/// - 🔍 **Device discovery** — list all connected USB devices
/// - 🔌 **Connect/disconnect** — with automatic permission handling
/// - 🖨️ **Raw byte printing** — chunked 16KB transfers with metrics
/// - 📊 **Hardware status** — DLE EOT 2/3/4 (paper, cover, errors)
/// - 🔄 **Auto-reconnect** — by VID/PID when device is re-plugged
/// - 📋 **Print queue** — failed jobs are queued and retried (max 3)
/// - ⚠️ **Paper alerts** — stream-based paper warnings before each print
/// - 📝 **Structured logging** — circular buffer, persisted to disk
///
/// ## Quick start
///
/// ```dart
/// final printer = ThermalPrinterUsb.instance;
/// await printer.initialize();
///
/// // List devices
/// final devices = await printer.getDevices();
///
/// // Connect
/// await printer.connect(devices.first);
///
/// // Print raw ESC/POS bytes
/// await printer.printRaw(myEscPosBytes);
///
/// // Check status
/// final status = await printer.getPrinterStatus();
/// print(status.summaryText); // "OK" or "NO PAPER • COVER OPEN"
/// ```
///
/// ## Streams
///
/// ```dart
/// // USB events (plug/unplug)
/// printer.usbEventStream.listen((event) { ... });
///
/// // Connection state changes
/// printer.connectionStateStream.listen((state) { ... });
///
/// // Paper warnings (before each print)
/// printer.paperWarningStream.listen((warning) { ... });
/// ```
class ThermalPrinterUsb {
  // ─────────── Singleton ───────────

  static final ThermalPrinterUsb _instance = ThermalPrinterUsb._internal();

  /// The shared singleton instance.
  ///
  /// Use this for most apps. If you need multiple independent instances
  /// (rare), use the [ThermalPrinterUsb.custom] constructor.
  static ThermalPrinterUsb get instance => _instance;

  ThermalPrinterUsb._internal();

  /// Creates a custom instance with a specific channel name.
  ///
  /// Useful for apps that need to communicate with multiple printers
  /// on different channels simultaneously.
  ///
  /// ```dart
  /// final secondPrinter = ThermalPrinterUsb.custom(
  ///   methodChannelName: 'my_app/second_printer',
  ///   eventChannelName: 'my_app/second_printer_events',
  /// );
  /// ```
  ThermalPrinterUsb.custom({
    String methodChannelName = 'thermal_printer_usb/method',
    String eventChannelName = 'thermal_printer_usb/events',
  }) : _channel = MethodChannel(methodChannelName),
       _eventChannel = EventChannel(eventChannelName);

  // ─────────── Channels ───────────

  MethodChannel _channel = const MethodChannel('thermal_printer_usb/method');
  EventChannel _eventChannel = const EventChannel('thermal_printer_usb/events');

  // ─────────── State ───────────

  bool _isConnected = false;
  UsbPrinterDevice? _connectedDevice;
  bool _autoReconnecting = false;
  bool _eventChannelInitialized = false;
  PrinterConnectionState _currentState = PrinterConnectionState.disconnected;
  List<UsbPrinterDevice> _lastKnownDevices = [];

  // ─────────── Print queue ───────────

  final List<PrintJob> _printQueue = [];

  // ─────────── Logging ───────────

  final List<PrinterLogEntry> _logs = [];
  static const int _maxLogEntries = 100;

  // ─────────── Persistence keys ───────────

  static const String _prefVendorId = 'thermal_printer_usb_vid';
  static const String _prefProductId = 'thermal_printer_usb_pid';
  static const String _prefProductName = 'thermal_printer_usb_name';

  int? _savedVendorId;
  int? _savedProductId;
  String? _savedProductName;

  // ─────────── Streams ───────────

  final StreamController<UsbEvent> _usbController =
      StreamController<UsbEvent>.broadcast();
  final StreamController<PrinterConnectionState> _stateController =
      StreamController<PrinterConnectionState>.broadcast();
  final StreamController<PaperWarning> _paperWarningController =
      StreamController<PaperWarning>.broadcast();

  PrinterStatus? _lastStatus;

  // ─────────── USB Event Stream ───────────

  /// Stream of native USB events (attach, detach, connection_lost).
  ///
  /// The first event is always a `devices` snapshot with all currently
  /// connected USB devices.
  ///
  /// ```dart
  /// printer.usbEventStream.listen((event) {
  ///   if (event.type == 'connection_lost') {
  ///     showSnackbar('Printer disconnected!');
  ///   }
  /// });
  /// ```
  Stream<UsbEvent> get usbEventStream async* {
    _ensureEventChannelInitialized();
    // Emit current state immediately
    yield UsbEvent(type: 'devices', devices: _lastKnownDevices);
    yield* _usbController.stream;
  }

  /// Stream of connection state changes.
  ///
  /// Emits the current state immediately on subscription, then updates
  /// on every change.
  ///
  /// ```dart
  /// printer.connectionStateStream.listen((state) {
  ///   updateUI(state);
  /// });
  /// ```
  Stream<PrinterConnectionState> get connectionStateStream async* {
    yield _currentState;
    yield* _stateController.stream;
  }

  /// Stream of paper warnings emitted before each print operation.
  ///
  /// Listen to this stream to show alerts when paper is low or empty.
  /// Only emits [PaperWarning.nearEnd] and [PaperWarning.empty] — never
  /// [PaperWarning.ok].
  ///
  /// ```dart
  /// printer.paperWarningStream.listen((warning) {
  ///   if (warning == PaperWarning.empty) {
  ///     showDialog('No paper! Replace the roll before printing.');
  ///   }
  /// });
  /// ```
  Stream<PaperWarning> get paperWarningStream => _paperWarningController.stream;

  // ─────────── Event Channel ───────────

  void _ensureEventChannelInitialized() {
    if (_eventChannelInitialized) return;
    _eventChannelInitialized = true;

    _eventChannel.receiveBroadcastStream().listen(
      (event) {
        try {
          final map = event as Map<dynamic, dynamic>;
          final type = map['event'] as String;

          UsbPrinterDevice? device;
          if (map['device'] != null) {
            device = UsbPrinterDevice.fromMap(
              map['device'] as Map<dynamic, dynamic>,
            );
          }

          final devicesList =
              (map['devices'] as List<dynamic>?)
                  ?.map(
                    (d) => UsbPrinterDevice.fromMap(d as Map<dynamic, dynamic>),
                  )
                  .toList() ??
              [];

          _lastKnownDevices = devicesList;

          final usbEvent = UsbEvent(
            type: type,
            device: device,
            devices: devicesList,
            vendorId: map['vendorId'] as int?,
            productId: map['productId'] as int?,
          );

          _usbController.add(usbEvent);
          _handleUsbEvent(usbEvent);
        } catch (e) {
          debugPrint('ThermalPrinterUsb: Error processing USB event: $e');
        }
      },
      onError: (error) {
        debugPrint('ThermalPrinterUsb: EventChannel error: $error');
      },
    );
  }

  /// Handle USB events for auto-reconnection
  void _handleUsbEvent(UsbEvent event) {
    if (event.type == 'connection_lost') {
      _isConnected = false;
      _connectedDevice = null;
      _updateState(PrinterConnectionState.connectionLost);
      _log(
        'connection_lost',
        false,
        details: 'VID:${event.vendorId} PID:${event.productId} disconnected',
      );
      debugPrint(
        '🔴 ThermalPrinterUsb: Connection lost (VID:${event.vendorId}, PID:${event.productId})',
      );
    } else if (event.type == 'attached' && !_isConnected) {
      _tryAutoReconnect(event.device);
    }
  }

  /// Attempt auto-reconnect if device matches saved printer
  Future<void> _tryAutoReconnect(UsbPrinterDevice? device) async {
    if (device == null || _autoReconnecting) return;

    final targetVid = _savedVendorId;
    final targetPid = _savedProductId;

    if (targetVid == null || targetPid == null) return;
    if (device.vendorId != targetVid || device.productId != targetPid) return;

    _autoReconnecting = true;
    _updateState(PrinterConnectionState.reconnecting);
    debugPrint(
      '🔄 ThermalPrinterUsb: Auto-reconnecting to ${device.productName}...',
    );

    try {
      await Future.delayed(const Duration(milliseconds: 500));
      final success = await connect(device, autoReconnect: true);
      if (success) {
        _log('auto_reconnect', true, details: device.productName);
        debugPrint('🟢 ThermalPrinterUsb: Auto-reconnect successful');
        await _processQueue();
      } else {
        _log(
          'auto_reconnect',
          false,
          details: 'Failed to reconnect to ${device.productName}',
        );
      }
    } catch (e) {
      _log('auto_reconnect', false, details: e.toString());
    } finally {
      _autoReconnecting = false;
    }
  }

  void _updateState(PrinterConnectionState state) {
    _currentState = state;
    _stateController.add(state);
  }

  // ─────────── Public getters ───────────

  /// Whether a printer is currently connected.
  bool get isConnected => _isConnected;

  /// The currently connected device, or `null`.
  UsbPrinterDevice? get connectedDevice => _connectedDevice;

  /// Number of jobs waiting in the retry queue.
  int get pendingJobCount => _printQueue.length;

  /// Unmodifiable list of pending print jobs.
  List<PrintJob> get pendingJobs => List.unmodifiable(_printQueue);

  /// Unmodifiable list of recent log entries.
  List<PrinterLogEntry> get logs => List.unmodifiable(_logs);

  /// Current connection state.
  PrinterConnectionState get currentState => _currentState;

  /// Last known printer status (from the most recent status query).
  PrinterStatus? get lastStatus => _lastStatus;

  // ─────────── Initialization ───────────

  /// Initialize the plugin: load saved printer, start event channel,
  /// and attempt auto-connect.
  ///
  /// Call this once at app startup (e.g., in `main()` or a service locator).
  ///
  /// ```dart
  /// void main() async {
  ///   WidgetsFlutterBinding.ensureInitialized();
  ///   await ThermalPrinterUsb.instance.initialize();
  ///   runApp(MyApp());
  /// }
  /// ```
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();

    _savedVendorId = prefs.getInt(_prefVendorId);
    _savedProductId = prefs.getInt(_prefProductId);
    _savedProductName = prefs.getString(_prefProductName);

    await _loadLogs();
    _ensureEventChannelInitialized();

    if (_savedVendorId != null && _savedProductId != null) {
      debugPrint(
        '🔄 ThermalPrinterUsb: Looking for saved printer $_savedProductName '
        '(VID:$_savedVendorId PID:$_savedProductId)',
      );
      await _autoConnectSaved();
    }
  }

  Future<void> _autoConnectSaved() async {
    try {
      final devices = await getDevices();
      final saved = devices.where(
        (d) => d.vendorId == _savedVendorId && d.productId == _savedProductId,
      );
      if (saved.isNotEmpty) {
        _updateState(PrinterConnectionState.connecting);
        final success = await connect(saved.first, autoReconnect: true);
        if (success) {
          _log('auto_connect', true, details: saved.first.productName);
          debugPrint(
            '🟢 ThermalPrinterUsb: Auto-connected to ${saved.first.productName}',
          );
        }
      } else {
        debugPrint('⚠️ ThermalPrinterUsb: Saved printer not found');
      }
    } catch (e) {
      debugPrint('ThermalPrinterUsb: Auto-connect error: $e');
    }
  }

  // ─────────── Device discovery ───────────

  /// List all USB devices currently connected to the Android device.
  ///
  /// Returns an empty list if no devices are found or if an error occurs.
  ///
  /// ```dart
  /// final devices = await printer.getDevices();
  /// for (final d in devices) {
  ///   print('${d.productName} (VID:${d.vendorId})');
  /// }
  /// ```
  Future<List<UsbPrinterDevice>> getDevices() async {
    try {
      final List<dynamic> result = await _channel.invokeMethod('getDevices');
      return result
          .map((d) => UsbPrinterDevice.fromMap(d as Map<dynamic, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('ThermalPrinterUsb: Error listing devices: $e');
      return [];
    }
  }

  // ─────────── Connection ───────────

  /// Connect to a USB printer device.
  ///
  /// Handles permission requests automatically. The connection is persisted
  /// (VID/PID) so that auto-reconnect works after cable disconnects.
  ///
  /// Returns `true` if the connection was successful.
  ///
  /// ```dart
  /// final success = await printer.connect(device);
  /// if (success) {
  ///   print('Connected to ${device.productName}!');
  /// }
  /// ```
  Future<bool> connect(
    UsbPrinterDevice device, {
    bool autoReconnect = false,
  }) async {
    try {
      if (!autoReconnect) {
        _updateState(PrinterConnectionState.connecting);
      }
      debugPrint('ThermalPrinterUsb: Connecting to ${device.productName}');

      await disconnect(clearSaved: false);

      final result = await _channel.invokeMethod('connect', {
        'deviceId': device.deviceId,
      });

      if (result is Map && result['success'] == true) {
        _connectedDevice = device;
        _isConnected = true;
        _updateState(PrinterConnectionState.connected);
        await _saveSelectedPrinter(device);
        _log('connect', true, details: device.productName);
        debugPrint('ThermalPrinterUsb: Connected to ${result['deviceName']}');
        return true;
      }

      _updateState(PrinterConnectionState.disconnected);
      _log('connect', false, details: 'Unexpected result');
      return false;
    } catch (e) {
      debugPrint('ThermalPrinterUsb: Connect error: $e');
      _connectedDevice = null;
      _isConnected = false;
      _updateState(PrinterConnectionState.disconnected);
      _log('connect', false, details: e.toString());
      return false;
    }
  }

  /// Disconnect from the current printer.
  ///
  /// If [clearSaved] is `true` (default), the saved printer preference
  /// is also removed, disabling auto-reconnect for this device.
  ///
  /// ```dart
  /// await printer.disconnect();
  /// ```
  Future<void> disconnect({bool clearSaved = true}) async {
    try {
      await _channel.invokeMethod('disconnect');
    } catch (e) {
      debugPrint('ThermalPrinterUsb: Disconnect error: $e');
    }
    _connectedDevice = null;
    _isConnected = false;
    _updateState(PrinterConnectionState.disconnected);

    if (clearSaved) {
      _savedVendorId = null;
      _savedProductId = null;
      _savedProductName = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefVendorId);
      await prefs.remove(_prefProductId);
      await prefs.remove(_prefProductName);
    }
  }

  Future<void> _saveSelectedPrinter(UsbPrinterDevice device) async {
    _savedVendorId = device.vendorId;
    _savedProductId = device.productId;
    _savedProductName = device.productName;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefVendorId, device.vendorId);
    await prefs.setInt(_prefProductId, device.productId);
    await prefs.setString(_prefProductName, device.productName);
  }

  // ─────────── Real connection check ───────────

  /// Verify the USB connection is alive via a real bulk transfer test.
  ///
  /// Unlike [isConnected], which is a cached boolean, this method performs
  /// an actual USB operation to detect silently-disconnected cables.
  ///
  /// ```dart
  /// if (await printer.checkRealConnection()) {
  ///   print('Connection is alive!');
  /// }
  /// ```
  Future<bool> checkRealConnection() async {
    try {
      final result = await _channel.invokeMethod('isConnected');
      if (result is Map) {
        final connected = result['connected'] as bool? ?? false;
        if (!connected && _isConnected) {
          _isConnected = false;
          _connectedDevice = null;
          _updateState(PrinterConnectionState.connectionLost);
          _log('check_connection', false, details: 'Dead connection detected');
        }
        return connected;
      }
      return false;
    } catch (e) {
      _isConnected = false;
      return false;
    }
  }

  // ─────────── Printer status ───────────

  /// Read the physical printer status via ESC/POS DLE EOT commands.
  ///
  /// Returns a [PrinterStatus] with paper, cover, and error information.
  /// If the printer doesn't support status commands, [PrinterStatus.supported]
  /// will be `false`.
  ///
  /// ```dart
  /// final status = await printer.getPrinterStatus();
  /// if (!status.paperOk) {
  ///   print('OUT OF PAPER!');
  /// }
  /// if (status.hasAnyError) {
  ///   print('Issues: ${status.summaryText}');
  /// }
  /// ```
  Future<PrinterStatus> getPrinterStatus() async {
    try {
      final result = await _channel.invokeMethod('getPrinterStatus');
      if (result is Map) {
        final status = PrinterStatus.fromMap(result);
        _lastStatus = status;
        return status;
      }
      return const PrinterStatus(
        supported: false,
        paperOk: true,
        coverClosed: true,
        online: true,
      );
    } catch (e) {
      return const PrinterStatus(
        supported: false,
        paperOk: true,
        coverClosed: true,
        online: true,
      );
    }
  }

  // ─────────── Printing ───────────

  /// Send raw bytes to the printer.
  ///
  /// This is the core print method. Pass any ESC/POS-encoded byte array.
  /// If the connection is dead, the job is automatically queued for retry.
  ///
  /// Set [checkPaper] to `false` to skip the pre-print paper status check.
  ///
  /// Returns `true` if the print was successful.
  ///
  /// ```dart
  /// final escPosBytes = myTicketGenerator.generate();
  /// final success = await printer.printRaw(
  ///   Uint8List.fromList(escPosBytes),
  ///   description: 'receipt_#1234',
  /// );
  /// ```
  Future<bool> printRaw(
    Uint8List data, {
    String description = 'raw',
    bool checkPaper = true,
  }) async {
    // Real connection check before printing
    if (!_isConnected || !await checkRealConnection()) {
      debugPrint('ThermalPrinterUsb: Not connected — queuing job');
      _enqueueJob(data, description);
      return false;
    }

    // Pre-print paper check
    if (checkPaper) {
      await _checkPaperBeforePrint();
    }

    try {
      final result = await _channel.invokeMethod('printBytes', {'bytes': data});

      if (result is Map && result['success'] == true) {
        final transferTimeMs = result['transferTimeMs'] as int?;
        _log(
          'print',
          true,
          details: '$description (${data.length} bytes)',
          transferTimeMs: transferTimeMs,
        );

        if (transferTimeMs != null && transferTimeMs > 2000) {
          debugPrint(
            '⚠️ ThermalPrinterUsb: Slow transfer (${transferTimeMs}ms) — possible cable issue',
          );
          _log(
            'warning',
            false,
            details: 'Slow transfer: ${transferTimeMs}ms',
            transferTimeMs: transferTimeMs,
          );
        }

        return true;
      }

      _log('print', false, details: 'Unexpected result');
      _enqueueJob(data, description);
      return false;
    } catch (e) {
      debugPrint('ThermalPrinterUsb: Print error: $e');
      _isConnected = false;
      _updateState(PrinterConnectionState.connectionLost);
      _log('print', false, details: e.toString());
      _enqueueJob(data, description);
      return false;
    }
  }

  /// Send a list of bytes to the printer (convenience wrapper).
  ///
  /// ```dart
  /// await printer.printBytes(myEscPosBytes, description: 'label');
  /// ```
  Future<bool> printBytes(List<int> bytes, {String description = 'raw'}) async {
    return printRaw(Uint8List.fromList(bytes), description: description);
  }

  // ─────────── Text encoding ───────────

  /// Encode a Unicode string into printer-compatible bytes using a native charset.
  ///
  /// Thermal printers do **not** understand UTF-8. They use single-byte code
  /// pages like CP850, CP437, or CP1252. This method uses the Android platform's
  /// `java.nio.charset.Charset` to perform complete, correct encoding — no
  /// manual character maps needed.
  ///
  /// ## Common charsets:
  /// | Charset | Description |
  /// |---------|-------------|
  /// | `Cp850` | **Default.** Western European (Spanish, French, Portuguese). |
  /// | `Cp437` | Original IBM PC. Good for box-drawing characters. |
  /// | `Cp1252` | Windows Western European. |
  /// | `ISO-8859-1` | Latin-1. |
  /// | `ISO-8859-15` | Latin-9 (adds € sign). |
  ///
  /// ```dart
  /// // Encode Spanish text to CP850 for raw printing
  /// final bytes = await printer.encodeText('Hola ñáéíóú ¡¿');
  ///
  /// // Or use a different charset
  /// final bytes1252 = await printer.encodeText('Hello €', charset: 'Cp1252');
  /// ```
  ///
  /// Returns the encoded bytes, or an empty [Uint8List] if encoding fails.
  Future<Uint8List> encodeText(String text, {String charset = 'Cp850'}) async {
    try {
      final result = await _channel.invokeMethod<dynamic>('encodeText', {
        'text': text,
        'charset': charset,
      });
      if (result is Uint8List) return result;
      if (result is List) return Uint8List.fromList(result.cast<int>());
      return Uint8List(0);
    } catch (e) {
      debugPrint('ThermalPrinterUsb: encodeText error: $e');
      return Uint8List(0);
    }
  }

  /// List the charsets supported by the native platform.
  ///
  /// Useful for letting users pick the right encoding for their printer model.
  ///
  /// ```dart
  /// final charsets = await printer.getSupportedCharsets();
  /// print(charsets); // [Cp850, Cp437, Cp1252, ...]
  /// ```
  Future<List<String>> getSupportedCharsets() async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>(
        'getSupportedCharsets',
      );
      return result?.cast<String>() ?? [];
    } catch (e) {
      debugPrint('ThermalPrinterUsb: getSupportedCharsets error: $e');
      return [];
    }
  }

  /// Check paper before printing and emit warning if needed.
  Future<void> _checkPaperBeforePrint() async {
    try {
      final status = await getPrinterStatus();
      _lastStatus = status;
      if (!status.supported) return;

      if (!status.paperOk) {
        _paperWarningController.add(PaperWarning.empty);
        _log('paper_check', false, details: 'NO PAPER');
      } else if (status.paperNearEnd) {
        _paperWarningController.add(PaperWarning.nearEnd);
        _log('paper_check', false, details: 'Paper near end');
      }
    } catch (e) {
      debugPrint('ThermalPrinterUsb: Paper check error: $e');
    }
  }

  // ─────────── Print queue ───────────

  void _enqueueJob(Uint8List bytes, String description) {
    _printQueue.add(PrintJob(bytes: bytes, description: description));
    _log(
      'enqueue',
      true,
      details: '$description (${_printQueue.length} in queue)',
    );
    debugPrint(
      '📋 ThermalPrinterUsb: Job queued. Queue: ${_printQueue.length} pending',
    );
  }

  /// Process the pending print queue.
  ///
  /// Called automatically after a successful auto-reconnect. You can also
  /// call this manually to retry failed prints.
  ///
  /// ```dart
  /// await printer.processQueue();
  /// ```
  Future<void> processQueue() async => _processQueue();

  Future<void> _processQueue() async {
    if (_printQueue.isEmpty || !_isConnected) return;

    debugPrint(
      '📋 ThermalPrinterUsb: Processing queue (${_printQueue.length} pending)',
    );

    final jobsToProcess = List<PrintJob>.from(_printQueue);
    _printQueue.clear();

    for (final job in jobsToProcess) {
      job.retryCount++;

      if (!_isConnected) {
        if (job.canRetry) _printQueue.add(job);
        final remaining = jobsToProcess.sublist(jobsToProcess.indexOf(job) + 1);
        for (final r in remaining) {
          if (r.canRetry) _printQueue.add(r);
        }
        break;
      }

      try {
        final result = await _channel.invokeMethod('printBytes', {
          'bytes': job.bytes,
        });
        if (result is Map && result['success'] == true) {
          _log(
            'retry_print',
            true,
            details:
                '${job.description} (attempt ${job.retryCount}/${PrintJob.maxRetries})',
          );
        } else if (job.canRetry) {
          _printQueue.add(job);
        }
      } catch (e) {
        if (job.canRetry) {
          _printQueue.add(job);
        } else {
          _log(
            'retry_failed',
            false,
            details:
                '${job.description} dropped after ${PrintJob.maxRetries} attempts',
          );
        }
      }
    }
  }

  /// Clear all pending print jobs from the queue.
  ///
  /// ```dart
  /// printer.clearQueue();
  /// print('Queue cleared: ${printer.pendingJobCount} remaining');
  /// ```
  void clearQueue() {
    _printQueue.clear();
    _log('clear_queue', true);
  }

  // ─────────── Logging ───────────

  void _log(
    String operation,
    bool success, {
    String? details,
    int? transferTimeMs,
  }) {
    final entry = PrinterLogEntry(
      operation: operation,
      success: success,
      details: details,
      transferTimeMs: transferTimeMs,
    );

    _logs.add(entry);
    if (_logs.length > _maxLogEntries) {
      _logs.removeAt(0);
    }

    // Persist async (fire-and-forget)
    _saveLogs();
  }

  Future<void> _saveLogs() async {
    try {
      final dir = await _getLogDirectory();
      final file = File('${dir.path}/thermal_printer_logs.json');
      final jsonList = _logs.map((e) => e.toJson()).toList();
      await file.writeAsString(jsonEncode(jsonList));
    } catch (_) {}
  }

  Future<void> _loadLogs() async {
    try {
      final dir = await _getLogDirectory();
      final file = File('${dir.path}/thermal_printer_logs.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        final List<dynamic> jsonList = jsonDecode(content);
        _logs.clear();
        _logs.addAll(
          jsonList.map(
            (e) => PrinterLogEntry.fromJson(e as Map<String, dynamic>),
          ),
        );
      }
    } catch (_) {}
  }

  Future<Directory> _getLogDirectory() async {
    // Use app's documents directory for log persistence
    final path = Directory('/data/data/${await _getPackageName()}/files');
    if (await path.exists()) return path;
    // Fallback: use temp directory
    return Directory.systemTemp;
  }

  Future<String> _getPackageName() async {
    try {
      // We don't want to add path_provider as a hard dependency
      // so we use a lightweight approach
      await _channel.invokeMethod('getDevices');
      // If we got here, the channel works. Use a deterministic path.
      return 'thermal_printer_usb';
    } catch (_) {
      return 'thermal_printer_usb';
    }
  }

  /// Clear all stored logs.
  ///
  /// ```dart
  /// printer.clearLogs();
  /// ```
  void clearLogs() {
    _logs.clear();
    _saveLogs();
  }

  // ─────────── Cleanup ───────────

  /// Release all resources.
  ///
  /// Call this when the plugin is no longer needed (e.g., in a widget's
  /// `dispose()` method or when the app is shutting down).
  ///
  /// ```dart
  /// @override
  /// void dispose() {
  ///   ThermalPrinterUsb.instance.dispose();
  ///   super.dispose();
  /// }
  /// ```
  void dispose() {
    disconnect();
    _usbController.close();
    _stateController.close();
    _paperWarningController.close();
  }
}
