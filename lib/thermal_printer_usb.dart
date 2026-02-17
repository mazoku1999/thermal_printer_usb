/// Flutter plugin for USB thermal printers (ESC/POS).
///
/// Provides device discovery, connection management, raw byte printing,
/// hardware status monitoring (DLE EOT), auto-reconnect, print queue
/// with retries, and paper alerts — all via the Android USB Host API.
///
/// ## Quick start
///
/// ```dart
/// import 'package:thermal_printer_usb/thermal_printer_usb.dart';
///
/// final printer = ThermalPrinterUsb.instance;
/// await printer.initialize();
///
/// final devices = await printer.getDevices();
/// await printer.connect(devices.first);
/// await printer.printRaw(myEscPosBytes);
///
/// final status = await printer.getPrinterStatus();
/// print(status.summaryText);
/// ```
///
/// See the [README](https://github.com/mazoku1999/thermal_printer_usb)
/// for full documentation and examples.
library;

export 'src/thermal_printer_usb.dart';
export 'src/usb_event.dart';
export 'src/models/usb_device.dart';
export 'src/models/printer_status.dart';
export 'src/models/print_job.dart';
export 'src/models/printer_log.dart';
