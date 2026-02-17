# thermal_printer_usb

[![pub package](https://img.shields.io/pub/v/thermal_printer_usb.svg)](https://pub.dev/packages/thermal_printer_usb)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Flutter plugin for **USB thermal printers** (ESC/POS) on Android. Discover, connect, print raw bytes, read hardware status, auto-reconnect, and get paper alerts — all via the native Android USB Host API.

## Features

| Feature | Description |
|---------|-------------|
| 🔍 Device discovery | List all connected USB devices with VID, PID, manufacturer, permissions |
| 🔌 Connect/disconnect | Automatic permission handling with 30s timeout |
| 🖨️ Raw byte printing | Chunked 16KB transfers with speed metrics |
| 📊 Hardware status | DLE EOT 2/3/4 — paper, cover, cutter, errors, raw bytes |
| 🔄 Auto-reconnect | Restores connection by VID/PID on re-plug |
| 📋 Print queue | Failed jobs queued with 3 retries |
| ⚠️ Paper alerts | Stream-based warnings before each print |
| 🔤 Text encoding | Native charset conversion (CP850, CP437, CP1252, etc.) |
| 📝 Structured logging | Circular buffer (100 entries), persisted to disk as JSON |
| 🔌 Real connection check | Zero-byte bulk transfer to detect dead cables |
| 🧩 Multiple instances | Custom channel support for multi-printer setups |

## Platform support

| Android | iOS | Web | macOS | Windows | Linux |
|:-------:|:---:|:---:|:-----:|:-------:|:-----:|
| ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |

> USB Host API is only available on Android.

---

## Getting started

### 1. Add dependency

```yaml
dependencies:
  thermal_printer_usb: ^1.0.0
```

### 2. Android setup

#### What the plugin does automatically

The plugin's `AndroidManifest.xml` declares `<uses-feature android:name="android.hardware.usb.host">` which is **merged automatically** by Android's manifest merger. You don't need to add this yourself.

The plugin also registers itself automatically via `FlutterPlugin` — no need to edit `MainActivity.kt`.

#### What you need to do manually (optional but recommended)

If you want your app to **open automatically** when a USB printer is plugged in, add the following to your app's `android/app/src/main/AndroidManifest.xml` inside the `<activity>` tag:

```xml
<activity android:name=".MainActivity" ...>
    <!-- ... existing intent-filters ... -->

    <!-- AUTO-OPEN: Launch app when USB device is connected -->
    <intent-filter>
        <action android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED"/>
    </intent-filter>
    <meta-data
        android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED"
        android:resource="@xml/device_filter"/>
</activity>
```

Then create the USB device filter file at `android/app/src/main/res/xml/device_filter.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- Accept any USB device -->
    <usb-device />
</resources>
```

> **Tip:** You can restrict to specific printers by vendor/product ID:
> ```xml
> <resources>
>     <usb-device vendor-id="1208" product-id="514" />  <!-- Epson -->
>     <usb-device vendor-id="1046" product-id="20497" /> <!-- Star -->
> </resources>
> ```

#### minSdkVersion

Make sure your `minSdkVersion` is at least **21** in `android/app/build.gradle`.

### 3. Initialize

```dart
import 'package:thermal_printer_usb/thermal_printer_usb.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThermalPrinterUsb.instance.initialize();
  runApp(MyApp());
}
```

---

## Usage

### Discover & connect

```dart
final printer = ThermalPrinterUsb.instance;

// List all USB devices
final devices = await printer.getDevices();

for (final d in devices) {
  print('${d.productName} (VID:${d.vendorId} PID:${d.productId})');
  print('  Manufacturer: ${d.manufacturerName}');
  print('  Permission: ${d.hasPermission}');
  print('  Interfaces: ${d.interfaceCount}');
}

// Connect (handles permission automatically with 30s timeout)
final success = await printer.connect(devices.first);
```

### Print raw ESC/POS bytes

```dart
// Build your ESC/POS bytes (using any library or manually)
final bytes = <int>[
  0x1B, 0x40,             // ESC @ — Initialize printer
  0x1B, 0x61, 0x01,       // ESC a 1 — Center alignment
  ...myTextBytes,
  0x1D, 0x56, 0x00,       // GS V 0 — Full cut
];

final success = await printer.printRaw(
  Uint8List.fromList(bytes),
  description: 'receipt_1234', // for logs
);

// Or use the List<int> convenience wrapper
await printer.printBytes(bytes, description: 'label');
```

> **Tip:** You can use [`flutter_esc_pos_utils`](https://pub.dev/packages/flutter_esc_pos_utils) for formatting (bold, alignment, `hr()`, `cut()`), but its `setGlobalCodeTable()` does **not** reliably encode Spanish/accented characters on all printers. Use `encodeText()` for text content and the Generator only for formatting commands.

### Encode text for thermal printers

Thermal printers **do not understand UTF-8**. They use single-byte code pages like CP850. The plugin provides native charset encoding via `java.nio.charset.Charset` — complete and correct, no manual character maps needed:

```dart
// Encode Spanish text to CP850 (default)
final bytes = await printer.encodeText('Hola ñáéíóú ¡Bienvenido!');

// Use a different charset
final bytes1252 = await printer.encodeText('Prix: 5€', charset: 'Cp1252');

// Build a raw ticket with proper encoding
final ticket = <int>[
  0x1B, 0x40,             // ESC @ — Initialize
  0x1B, 0x74, 0x02,       // ESC t 2 — Select CP850 code page
  ...await printer.encodeText('Página de prueba\n'),
  ...await printer.encodeText('Español: áéíóúñü ÁÉÍÓÚÑÜ\n'),
  0x1D, 0x56, 0x00,       // Full cut
];
await printer.printRaw(Uint8List.fromList(ticket));
```

**Supported charsets:**

| Charset | Description |
|---------|-------------|
| `Cp850` | **Default.** Western European (Spanish, Portuguese, French) |
| `Cp437` | Original IBM PC. Box-drawing characters |
| `Cp1252` | Windows Western European |
| `ISO-8859-1` | Latin-1 |
| `ISO-8859-15` | Latin-9 (adds € sign) |

```dart
// List all supported charsets on this device
final charsets = await printer.getSupportedCharsets();
print(charsets); // [Cp850, Cp437, Cp1252, ...]
```

### Check printer status (DLE EOT)

The plugin reads the full hardware status from three ESC/POS DLE EOT commands:

```dart
final status = await printer.getPrinterStatus();

if (!status.supported) {
  print('Printer does not support DLE EOT status commands');
  return;
}

// ── Paper status (DLE EOT 4) ──
print('Paper OK: ${status.paperOk}');         // true = paper present
print('Paper near end: ${status.paperNearEnd}'); // true = running low
print('Paper warning: ${status.paperWarning}');  // PaperWarning.ok/nearEnd/empty

// ── Cover & offline (DLE EOT 2) ──
print('Cover closed: ${status.coverClosed}');
print('Online: ${status.online}');                 // derived: !(errors)
print('Feed button: ${status.feedButtonPressed}');
print('Error stopped: ${status.printingErrorStopped}');
print('Error occurred: ${status.errorOccurred}');

// ── Hardware errors (DLE EOT 3) ──
print('Cutter error: ${status.autoCutterError}');
print('Unrecoverable: ${status.unrecoverableError}');
print('Auto-recoverable: ${status.autoRecoverableError}');

// ── Convenience getters ──
print('Has any error: ${status.hasAnyError}');
print('Summary: ${status.summaryText}');
// "OK" or "NO PAPER • COVER OPEN • CUTTER ERROR"
```

> **Note:** Printers that don't support DLE EOT commands will return `supported: false` with safe defaults (all OK). The plugin degrades gracefully — it never crashes.

### Listen to streams

```dart
// ── USB events (plug/unplug) ──
printer.usbEventStream.listen((event) {
  // First event is always 'devices' with current snapshot
  switch (event.type) {
    case 'devices':
      print('Current devices: ${event.devices.length}');
    case 'attached':
      print('New device: ${event.device?.productName}');
    case 'detached':
      print('Device removed: ${event.device?.productName}');
    case 'connection_lost':
      print('Connected printer unplugged! VID:${event.vendorId}');
  }
});

// ── Connection state ──
printer.connectionStateStream.listen((state) {
  switch (state) {
    case PrinterConnectionState.disconnected:
      print('Not connected');
    case PrinterConnectionState.connecting:
      print('Connecting...');
    case PrinterConnectionState.connected:
      print('Ready to print!');
    case PrinterConnectionState.reconnecting:
      print('Auto-reconnecting...');
    case PrinterConnectionState.connectionLost:
      print('Connection lost!');
  }
});

// ── Paper warnings (before each print) ──
printer.paperWarningStream.listen((warning) {
  if (warning == PaperWarning.empty) {
    showAlert('No paper! Replace the roll.');
  } else if (warning == PaperWarning.nearEnd) {
    showAlert('Paper running low!');
  }
});
```

### Global paper alert widget (optional)

Wrap your app with the `PaperWarningListener` widget to show automatic dialogs:

```dart
MaterialApp(
  home: const MyHomePage(),
  builder: (context, child) {
    return PaperWarningListener(
      child: child ?? const SizedBox.shrink(),
      cooldown: const Duration(seconds: 30), // prevent spam
    );
  },
);
```

> See the [example app](example/lib/main.dart) for the full `PaperWarningListener` implementation.

### Verify connection

```dart
// Cached boolean (fast, but may be stale if cable was pulled silently)
if (printer.isConnected) { ... }

// Real USB test — sends zero-byte bulk transfer to detect dead cables
if (await printer.checkRealConnection()) {
  print('Connection is alive!');
} else {
  print('Cable disconnected or printer off');
}
```

### Auto-reconnect

When a printer is connected, its VID/PID is saved to `SharedPreferences`. On next app launch, `initialize()` automatically finds and reconnects. If the printer is unplugged and re-plugged during a session, the `EventChannel` auto-reconnects.

```dart
// Connect with auto-reconnect (default)
await printer.connect(device);

// Disconnect and CLEAR saved printer (disable auto-reconnect)
await printer.disconnect(clearSaved: true);

// Disconnect but KEEP saved (will reconnect on next launch)
await printer.disconnect(clearSaved: false);
```

### Print queue

When a print fails (cable disconnected, etc.), the job is automatically queued and retried on reconnect (up to 3 attempts).

```dart
print('Pending jobs: ${printer.pendingJobCount}');
for (final job in printer.pendingJobs) {
  print('${job.description} — retry ${job.retryCount}/${PrintJob.maxRetries}');
  print('  Created: ${job.createdAt}');
  print('  Bytes: ${job.bytes.length}');
}

// Manual retry
await printer.processQueue();

// Clear queue
printer.clearQueue();
```

### Structured logs

Every operation is logged to a circular buffer (max 100) and persisted to disk as JSON.

```dart
for (final log in printer.logs) {
  print('[${log.timestamp}] ${log.operation}: '
      '${log.success ? "OK" : "FAIL"}'
      '${log.details != null ? " — ${log.details}" : ""}'
      '${log.transferTimeMs != null ? " (${log.transferTimeMs}ms)" : ""}');
}

// Example output:
// [2026-02-17T04:10:00] connect: OK — TM-T20IIIL
// [2026-02-17T04:10:01] print: OK — receipt_1234 (1024 bytes) (45ms)
// [2026-02-17T04:10:02] paper_check: FAIL — Paper near end

// Clear all logs
printer.clearLogs();
```

### Multiple printer instances (advanced)

For apps controlling multiple printers simultaneously:

```dart
final printer1 = ThermalPrinterUsb.instance; // default channels
final printer2 = ThermalPrinterUsb.custom(
  methodChannelName: 'my_app/printer_2',
  eventChannelName: 'my_app/printer_2_events',
);
```

> Note: Custom instances require a matching native plugin registration on the Kotlin side.

---

## API Reference

### ThermalPrinterUsb — Methods

| Method | Returns | Description |
|--------|---------|-------------|
| `initialize()` | `Future<void>` | Load saved printer, start events, auto-connect |
| `getDevices()` | `Future<List<UsbPrinterDevice>>` | List connected USB devices |
| `connect(device)` | `Future<bool>` | Connect with automatic permission handling |
| `disconnect({clearSaved})` | `Future<void>` | Disconnect; clear saved printer if `true` |
| `printRaw(bytes, {description, checkPaper})` | `Future<bool>` | Send raw bytes with optional paper check |
| `printBytes(bytes, {description})` | `Future<bool>` | Convenience wrapper for `List<int>` |
| `getPrinterStatus()` | `Future<PrinterStatus>` | Read DLE EOT 2/3/4 status |
| `checkRealConnection()` | `Future<bool>` | Zero-byte USB transfer to verify cable |
| `encodeText(text, {charset})` | `Future<Uint8List>` | Encode Unicode → code page bytes (default: CP850) |
| `getSupportedCharsets()` | `Future<List<String>>` | List available charset names |
| `processQueue()` | `Future<void>` | Retry pending print jobs |
| `clearQueue()` | `void` | Discard all queued jobs |
| `clearLogs()` | `void` | Clear log history |
| `dispose()` | `void` | Release all resources and streams |

### ThermalPrinterUsb — Properties

| Property | Type | Description |
|----------|------|-------------|
| `isConnected` | `bool` | Cached connection status |
| `connectedDevice` | `UsbPrinterDevice?` | Currently connected device |
| `currentState` | `PrinterConnectionState` | Current connection state |
| `lastStatus` | `PrinterStatus?` | Last status query result |
| `pendingJobCount` | `int` | Number of queued jobs |
| `pendingJobs` | `List<PrintJob>` | Unmodifiable list of queued jobs |
| `logs` | `List<PrinterLogEntry>` | Unmodifiable list of log entries |

### ThermalPrinterUsb — Streams

| Stream | Type | Description |
|--------|------|-------------|
| `usbEventStream` | `UsbEvent` | Attach/detach/connection_lost (first event = snapshot) |
| `connectionStateStream` | `PrinterConnectionState` | Lifecycle changes (first event = current) |
| `paperWarningStream` | `PaperWarning` | Paper alerts before each print |

---

### UsbPrinterDevice

Represents a discovered USB device.

| Field | Type | Description |
|-------|------|-------------|
| `deviceId` | `int` | System-assigned ID (changes between sessions) |
| `vendorId` | `int` | USB Vendor ID — persistent, identifies manufacturer |
| `productId` | `int` | USB Product ID — persistent, identifies model |
| `deviceName` | `String` | System device path (e.g. `/dev/bus/usb/001/003`) |
| `manufacturerName` | `String` | Manufacturer name (may be empty) |
| `productName` | `String` | Product name (e.g. "TM-T20IIIL") |
| `interfaceCount` | `int` | Number of USB interfaces |
| `hasPermission` | `bool` | Whether the app has USB permission |

> Equality is based on `vendorId` + `productId`, so the same physical printer is always `==` even after reconnection.

---

### PrinterStatus

Physical status from ESC/POS DLE EOT commands.

| Field | Type | Source | Description |
|-------|------|--------|-------------|
| `supported` | `bool` | — | Whether printer supports DLE EOT |
| `paperOk` | `bool` | DLE EOT 4 (bits 5,6) | Paper present and ready |
| `paperNearEnd` | `bool` | DLE EOT 4 (bits 2,3) | Paper roll is near end |
| `coverClosed` | `bool` | DLE EOT 2 (bit 2) | Printer cover is closed |
| `online` | `bool` | Derived | `!(printingErrorStopped \|\| unrecoverableError)` |
| `feedButtonPressed` | `bool` | DLE EOT 2 (bit 3) | Feed button is pressed |
| `printingErrorStopped` | `bool` | DLE EOT 2 (bit 5) | Printing stopped by error |
| `errorOccurred` | `bool` | DLE EOT 2 (bit 6) | General error flag |
| `autoCutterError` | `bool` | DLE EOT 3 (bit 2) | Paper jam in auto-cutter |
| `unrecoverableError` | `bool` | DLE EOT 3 (bit 3) | Requires service |
| `autoRecoverableError` | `bool` | DLE EOT 3 (bit 5) | Will clear automatically |

**Convenience getters:**

| Getter | Type | Description |
|--------|------|-------------|
| `hasAnyError` | `bool` | Any error condition active |
| `paperWarning` | `PaperWarning` | `.ok`, `.nearEnd`, or `.empty` |
| `summaryText` | `String` | `"OK"` or `"NO PAPER • COVER OPEN • ..."` |

> **Raw bytes:** The native plugin also returns `rawOffline`, `rawError`, and `rawPaper` (raw status bytes from each DLE EOT command) for advanced debugging — accessible via the native map.

---

### UsbEvent

| Field | Type | Description |
|-------|------|-------------|
| `type` | `String` | `'devices'`, `'attached'`, `'detached'`, or `'connection_lost'` |
| `device` | `UsbPrinterDevice?` | Device involved (null for `'devices'`) |
| `devices` | `List<UsbPrinterDevice>` | All connected devices after event |
| `vendorId` | `int?` | VID of disconnected device (for `connection_lost`) |
| `productId` | `int?` | PID of disconnected device (for `connection_lost`) |

### PrinterConnectionState

| Value | Description |
|-------|-------------|
| `disconnected` | No printer connected |
| `connecting` | Connection in progress |
| `connected` | Ready to print |
| `reconnecting` | Auto-reconnect in progress |
| `connectionLost` | Cable pulled or printer turned off |

### PaperWarning

| Value | Description |
|-------|-------------|
| `ok` | Paper level normal |
| `nearEnd` | Paper roll running low |
| `empty` | No paper detected |

### PrintJob

| Field | Type | Description |
|-------|------|-------------|
| `bytes` | `Uint8List` | Raw bytes to send |
| `description` | `String` | Human label for logs |
| `createdAt` | `DateTime` | When the job was created |
| `retryCount` | `int` | Attempts so far |
| `canRetry` | `bool` | `retryCount < 3` |

### PrinterLogEntry

| Field | Type | Description |
|-------|------|-------------|
| `operation` | `String` | e.g. `'connect'`, `'print'`, `'paper_check'` |
| `success` | `bool` | Whether it succeeded |
| `timestamp` | `DateTime` | When it occurred |
| `details` | `String?` | Error message, device name, etc. |
| `transferTimeMs` | `int?` | Transfer speed (print ops only) |

---

## Example app

The [example app](example/) includes:
- Device list with permission status
- Connect/disconnect with state indicator
- Status display with color-coded chips
- Test page printing with raw ESC/POS
- Logs viewer
- `PaperWarningListener` widget

### Example files reference

| File | Purpose |
|------|---------|
| [example/lib/main.dart](example/lib/main.dart) | Full working app with all features |
| [example/android/app/src/main/AndroidManifest.xml](example/android/app/src/main/AndroidManifest.xml) | Complete manifest with USB intent filter |
| [example/android/app/src/main/res/xml/device_filter.xml](example/android/app/src/main/res/xml/device_filter.xml) | USB device filter (accepts any device) |

## Tested printers

| Printer | Status | Notes |
|---------|--------|-------|
| Epson TM-T20IIIL | ✅ Full | DLE EOT 2/3/4, auto-cutter, paper sensor |

> The plugin uses standard ESC/POS commands and should work with most thermal printers. Status commands (DLE EOT) may not be supported on all models — the plugin degrades gracefully by returning `supported: false` with safe defaults.

## License

MIT — see [LICENSE](LICENSE) for details.
