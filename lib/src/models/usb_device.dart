/// A USB device discovered on the Android USB bus.
///
/// Created from native [MethodChannel] data. Each device has a unique
/// [deviceId] within the current session, plus permanent [vendorId] and
/// [productId] identifiers that survive reconnections.
///
/// ```dart
/// final devices = await printer.getDevices();
/// for (final d in devices) {
///   print('${d.productName} (VID:${d.vendorId} PID:${d.productId})');
/// }
/// ```
class UsbPrinterDevice {
  /// System-assigned device ID (changes between sessions).
  final int deviceId;

  /// USB Vendor ID — unique to the manufacturer (persistent).
  final int vendorId;

  /// USB Product ID — unique to the product model (persistent).
  final int productId;

  /// System device path (e.g. `/dev/bus/usb/001/003`).
  final String deviceName;

  /// Manufacturer name reported by the device (may be empty).
  final String manufacturerName;

  /// Product name reported by the device (e.g. "TM-T20IIIL").
  final String productName;

  /// Number of USB interfaces on this device.
  final int interfaceCount;

  /// Whether the app currently has USB permission for this device.
  final bool hasPermission;

  /// Creates a [UsbPrinterDevice] with all required fields.
  const UsbPrinterDevice({
    required this.deviceId,
    required this.vendorId,
    required this.productId,
    required this.deviceName,
    required this.manufacturerName,
    required this.productName,
    required this.interfaceCount,
    required this.hasPermission,
  });

  /// Creates a [UsbPrinterDevice] from a native platform map.
  ///
  /// All fields have safe defaults so a partially-populated map
  /// won't cause a crash.
  factory UsbPrinterDevice.fromMap(Map<dynamic, dynamic> map) {
    return UsbPrinterDevice(
      deviceId: map['deviceId'] as int,
      vendorId: map['vendorId'] as int,
      productId: map['productId'] as int,
      deviceName: map['deviceName'] as String? ?? '',
      manufacturerName: map['manufacturerName'] as String? ?? '',
      productName: map['productName'] as String? ?? 'USB Device',
      interfaceCount: map['interfaceCount'] as int? ?? 0,
      hasPermission: map['hasPermission'] as bool? ?? false,
    );
  }

  @override
  String toString() =>
      'UsbPrinterDevice($productName, VID:$vendorId, PID:$productId)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UsbPrinterDevice &&
          vendorId == other.vendorId &&
          productId == other.productId;

  @override
  int get hashCode => vendorId.hashCode ^ productId.hashCode;
}
