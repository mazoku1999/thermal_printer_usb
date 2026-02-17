import 'models/usb_device.dart';

/// Connection state of the USB printer.
///
/// Emitted by [ThermalPrinterUsb.connectionStateStream] whenever the
/// connection status changes.
///
/// ```dart
/// printer.connectionStateStream.listen((state) {
///   switch (state) {
///     case PrinterConnectionState.connected:
///       print('Ready to print!');
///     case PrinterConnectionState.connectionLost:
///       print('Printer disconnected!');
///     default:
///       break;
///   }
/// });
/// ```
enum PrinterConnectionState {
  /// No printer is connected.
  disconnected,

  /// A connection attempt is in progress.
  connecting,

  /// Successfully connected and ready to print.
  connected,

  /// Attempting to reconnect after connection loss.
  reconnecting,

  /// Connection was lost unexpectedly (cable pulled, etc.).
  connectionLost,
}

/// A native USB event received from the Android USB subsystem.
///
/// Events are emitted by [ThermalPrinterUsb.usbEventStream] whenever
/// a USB device is plugged in, unplugged, or the connection is lost.
///
/// ## Event types:
/// - `devices` — Initial snapshot of all connected USB devices
/// - `attached` — A new USB device was plugged in
/// - `detached` — A USB device was unplugged (not the connected printer)
/// - `connection_lost` — The currently connected printer was unplugged
///
/// ```dart
/// printer.usbEventStream.listen((event) {
///   print('Event: ${event.type}, devices: ${event.devices.length}');
/// });
/// ```
class UsbEvent {
  /// Event type: `'devices'`, `'attached'`, `'detached'`, or `'connection_lost'`.
  final String type;

  /// The specific device involved in this event (may be `null` for `devices`).
  final UsbPrinterDevice? device;

  /// Current list of all connected USB devices after this event.
  final List<UsbPrinterDevice> devices;

  /// Vendor ID of the lost device (only set for `connection_lost`).
  final int? vendorId;

  /// Product ID of the lost device (only set for `connection_lost`).
  final int? productId;

  /// Creates a [UsbEvent].
  UsbEvent({
    required this.type,
    this.device,
    this.devices = const [],
    this.vendorId,
    this.productId,
  });

  @override
  String toString() =>
      'UsbEvent($type, device: $device, count: ${devices.length})';
}
