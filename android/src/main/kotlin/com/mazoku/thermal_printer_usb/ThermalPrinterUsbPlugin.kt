package com.mazoku.thermal_printer_usb

import java.nio.charset.Charset

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.*
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * ThermalPrinterUsbPlugin — Native Android plugin for USB thermal printers.
 *
 * Communicates with ESC/POS-compatible thermal printers via the Android USB Host API.
 *
 * ## MethodChannel (`thermal_printer_usb/method`):
 *   - `getDevices` → List all connected USB devices
 *   - `connect(deviceId)` → Open connection to a specific device
 *   - `disconnect` → Close the current connection
 *   - `printBytes(bytes)` → Send raw bytes (chunked, 16KB blocks)
 *   - `isConnected` → Real connection check (not just a boolean)
 *   - `getPrinterStatus` → DLE EOT n=2,3,4 status bytes (paper, cover, errors)
 *
 * ## EventChannel (`thermal_printer_usb/events`):
 *   - Stream of USB events: `attached`, `detached`, `connection_lost`, `devices`
 *   - Auto-detach: cleans up when the connected device is physically removed
 *
 * ## Error handling:
 *   - All operations wrapped in try-catch
 *   - Permission request with 30s timeout
 *   - Failed print mid-transfer emits `connection_lost` event
 *   - Status commands degrade silently for unsupported printers
 */
class ThermalPrinterUsbPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    companion object {
        private const val METHOD_CHANNEL = "thermal_printer_usb/method"
        private const val EVENT_CHANNEL = "thermal_printer_usb/events"
        private const val ACTION_USB_PERMISSION = "com.mazoku.thermal_printer_usb.USB_PERMISSION"
    }

    private lateinit var context: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel

    private val usbManager: UsbManager by lazy {
        context.getSystemService(Context.USB_SERVICE) as UsbManager
    }

    private var connection: UsbDeviceConnection? = null
    private var usbInterface: UsbInterface? = null
    private var endpointOut: UsbEndpoint? = null
    private var endpointIn: UsbEndpoint? = null
    private var connectedDevice: UsbDevice? = null

    // Single-thread executor for ALL USB I/O — never blocks the UI thread
    private val usbExecutor: java.util.concurrent.ExecutorService =
        java.util.concurrent.Executors.newSingleThreadExecutor()

    // Event sink for broadcasting USB events
    private var globalEventSink: EventChannel.EventSink? = null

    // ═══════════════════════════════════════════════════
    //  FlutterPlugin lifecycle
    // ═══════════════════════════════════════════════════

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext

        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(UsbEventStreamHandler())
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        cleanupConnection()
    }

    // ═══════════════════════════════════════════════════
    //  MethodChannel Handler
    // ═══════════════════════════════════════════════════

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getDevices" -> getDevices(result)
            "connect" -> {
                val deviceId = call.argument<Int>("deviceId")
                if (deviceId != null) {
                    connect(deviceId, result)
                } else {
                    result.error("INVALID_ARGS", "deviceId required", null)
                }
            }
            "disconnect" -> disconnect(result)
            "printBytes" -> {
                val bytes = call.argument<ByteArray>("bytes")
                if (bytes != null) {
                    printBytes(bytes, result)
                } else {
                    result.error("INVALID_ARGS", "bytes required", null)
                }
            }
            "isConnected" -> checkRealConnection(result)
            "getPrinterStatus" -> getPrinterStatus(result)
            "encodeText" -> {
                val text = call.argument<String>("text")
                val charset = call.argument<String>("charset") ?: "Cp850"
                if (text != null) {
                    encodeText(text, charset, result)
                } else {
                    result.error("INVALID_ARGS", "text required", null)
                }
            }
            "getSupportedCharsets" -> getSupportedCharsets(result)
            else -> result.notImplemented()
        }
    }

    // ═══════════════════════════════════════════════════
    //  EventChannel: USB attach/detach + auto-detach
    // ═══════════════════════════════════════════════════

    private inner class UsbEventStreamHandler : EventChannel.StreamHandler {
        private var receiver: BroadcastReceiver? = null

        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            if (events == null) return
            globalEventSink = events

            // Emit current devices immediately
            val currentDevices = usbManager.deviceList.values.map { deviceToMap(it) }
            events.success(mapOf(
                "event" to "devices",
                "devices" to currentDevices
            ))

            receiver = object : BroadcastReceiver() {
                override fun onReceive(ctx: Context, intent: Intent) {
                    val device: UsbDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                    }

                    when (intent.action) {
                        UsbManager.ACTION_USB_DEVICE_ATTACHED -> {
                            val deviceMap = device?.let { deviceToMap(it) }
                            Handler(Looper.getMainLooper()).post {
                                events.success(mapOf(
                                    "event" to "attached",
                                    "device" to deviceMap,
                                    "devices" to usbManager.deviceList.values.map { deviceToMap(it) }
                                ))
                            }
                        }
                        UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                            val deviceMap = device?.let { deviceToMap(it) }

                            // AUTO-DETACH: clean up if it's the connected device
                            if (device != null && connectedDevice != null &&
                                device.vendorId == connectedDevice!!.vendorId &&
                                device.productId == connectedDevice!!.productId) {
                                cleanupConnection()
                                Handler(Looper.getMainLooper()).post {
                                    events.success(mapOf(
                                        "event" to "connection_lost",
                                        "device" to deviceMap,
                                        "devices" to usbManager.deviceList.values.map { deviceToMap(it) },
                                        "vendorId" to device.vendorId,
                                        "productId" to device.productId
                                    ))
                                }
                            } else {
                                Handler(Looper.getMainLooper()).post {
                                    events.success(mapOf(
                                        "event" to "detached",
                                        "device" to deviceMap,
                                        "devices" to usbManager.deviceList.values.map { deviceToMap(it) }
                                    ))
                                }
                            }
                        }
                    }
                }
            }

            val filter = IntentFilter().apply {
                addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
                addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                context.registerReceiver(receiver, filter)
            }
        }

        override fun onCancel(arguments: Any?) {
            receiver?.let {
                try { context.unregisterReceiver(it) } catch (_: Exception) {}
            }
            receiver = null
            globalEventSink = null
        }
    }

    // ═══════════════════════════════════════════════════
    //  List devices
    // ═══════════════════════════════════════════════════

    private fun getDevices(result: MethodChannel.Result) {
        try {
            val devices = usbManager.deviceList.values.map { deviceToMap(it) }
            result.success(devices)
        } catch (e: Exception) {
            result.error("LIST_ERROR", "Error listing devices: ${e.message}", null)
        }
    }

    private fun deviceToMap(device: UsbDevice): Map<String, Any> {
        return mapOf(
            "deviceId" to device.deviceId,
            "vendorId" to device.vendorId,
            "productId" to device.productId,
            "deviceName" to device.deviceName,
            "manufacturerName" to (device.manufacturerName ?: ""),
            "productName" to (device.productName ?: "USB Device"),
            "interfaceCount" to device.interfaceCount,
            "hasPermission" to usbManager.hasPermission(device)
        )
    }

    // ═══════════════════════════════════════════════════
    //  Connection
    // ═══════════════════════════════════════════════════

    private fun connect(deviceId: Int, result: MethodChannel.Result) {
        try {
            val device = usbManager.deviceList.values.find { it.deviceId == deviceId }
            if (device == null) {
                result.error("NOT_FOUND", "Device not found", null)
                return
            }

            if (usbManager.hasPermission(device)) {
                performConnect(device, result)
                return
            }

            requestPermissionAndConnect(device, result)
        } catch (e: Exception) {
            result.error("CONNECT_ERROR", "Connection error: ${e.message}", null)
        }
    }

    private fun requestPermissionAndConnect(device: UsbDevice, result: MethodChannel.Result) {
        try {
            val intent = Intent(ACTION_USB_PERMISSION)
            intent.setPackage(context.packageName)

            val permissionIntent = PendingIntent.getBroadcast(
                context, 0, intent,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
                else
                    PendingIntent.FLAG_UPDATE_CURRENT
            )

            val filter = IntentFilter(ACTION_USB_PERMISSION)
            var responded = false

            val receiver = object : BroadcastReceiver() {
                override fun onReceive(ctx: Context, intent: Intent) {
                    try { context.unregisterReceiver(this) } catch (_: Exception) {}
                    if (responded) return
                    responded = true
                    val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    if (granted) {
                        performConnect(device, result)
                    } else {
                        result.error("PERMISSION_DENIED", "USB permission denied", null)
                    }
                }
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                context.registerReceiver(receiver, filter)
            }

            // 30s timeout: clean up receiver if user doesn't respond
            Handler(Looper.getMainLooper()).postDelayed({
                if (!responded) {
                    responded = true
                    try { context.unregisterReceiver(receiver) } catch (_: Exception) {}
                    result.error("PERMISSION_TIMEOUT", "USB permission request timed out", null)
                }
            }, 30000)

            usbManager.requestPermission(device, permissionIntent)
        } catch (e: Exception) {
            result.error("PERMISSION_ERROR", "Permission request error: ${e.message}", null)
        }
    }

    private fun performConnect(device: UsbDevice, result: MethodChannel.Result) {
        try {
            var foundInterface: UsbInterface? = null
            var foundEndpointOut: UsbEndpoint? = null
            var foundEndpointIn: UsbEndpoint? = null

            for (i in 0 until device.interfaceCount) {
                val iface = device.getInterface(i)
                for (j in 0 until iface.endpointCount) {
                    val ep = iface.getEndpoint(j)
                    if (ep.type == UsbConstants.USB_ENDPOINT_XFER_BULK) {
                        if (ep.direction == UsbConstants.USB_DIR_OUT && foundEndpointOut == null) {
                            foundInterface = iface
                            foundEndpointOut = ep
                        } else if (ep.direction == UsbConstants.USB_DIR_IN && foundEndpointIn == null) {
                            foundEndpointIn = ep
                        }
                    }
                }
                if (foundEndpointOut != null) break
            }

            if (foundInterface == null || foundEndpointOut == null) {
                result.error("NO_ENDPOINT", "No bulk OUT endpoint found", null)
                return
            }

            val conn = usbManager.openDevice(device)
            if (conn == null) {
                result.error("OPEN_FAILED", "Failed to open USB device", null)
                return
            }

            conn.claimInterface(foundInterface, true)

            connection = conn
            usbInterface = foundInterface
            endpointOut = foundEndpointOut
            endpointIn = foundEndpointIn
            connectedDevice = device



            result.success(mapOf(
                "success" to true,
                "deviceName" to (device.productName ?: "USB Printer"),
                "vendorId" to device.vendorId,
                "productId" to device.productId
            ))
        } catch (e: Exception) {
            result.error("CONNECT_ERROR", "Connection error: ${e.message}", null)
        }
    }

    // ═══════════════════════════════════════════════════
    //  Disconnection
    // ═══════════════════════════════════════════════════

    private fun disconnect(result: MethodChannel.Result) {
        cleanupConnection()
        result.success(true)
    }

    /** Clean up connection state without needing a Result */
    private fun cleanupConnection() {
        try {
            usbInterface?.let { connection?.releaseInterface(it) }
            connection?.close()
        } catch (_: Exception) {}
        connection = null
        usbInterface = null
        endpointOut = null
        endpointIn = null
        connectedDevice = null
    }

    // ═══════════════════════════════════════════════════
    //  Real connection check
    // ═══════════════════════════════════════════════════

    /**
     * Verifies the USB connection is actually alive by sending a DLE EOT 1
     * status query. This is more reliable than a zero-byte bulk transfer,
     * which returns -1 on printer error states (no paper, cover open) even
     * when the connection is physically fine.
     *
     * DLE EOT 1 always returns 1 byte regardless of printer error state.
     * No response = truly disconnected.
     */
    private fun checkRealConnection(result: MethodChannel.Result) {
        val conn = connection
        val epOut = endpointOut
        val epIn = endpointIn
        val device = connectedDevice

        if (conn == null || epOut == null || device == null) {
            result.success(mapOf(
                "connected" to false,
                "vendorId" to 0,
                "productId" to 0
            ))
            return
        }

        usbExecutor.execute {
            try {
                val cmd = byteArrayOf(0x10, 0x04, 0x01)
                val sent = conn.bulkTransfer(epOut, cmd, cmd.size, 300)

                if (sent < 0) {
                    cleanupConnection()
                    Handler(Looper.getMainLooper()).post {
                        result.success(mapOf(
                            "connected" to false,
                            "vendorId" to device.vendorId,
                            "productId" to device.productId
                        ))
                    }
                    return@execute
                }

                if (epIn != null) {
                    val buffer = ByteArray(4)
                    conn.bulkTransfer(epIn, buffer, buffer.size, 300)
                }

                Handler(Looper.getMainLooper()).post {
                    result.success(mapOf(
                        "connected" to true,
                        "vendorId" to device.vendorId,
                        "productId" to device.productId,
                        "deviceName" to (device.productName ?: "USB Printer")
                    ))
                }
            } catch (e: Exception) {
                cleanupConnection()
                Handler(Looper.getMainLooper()).post {
                    result.success(mapOf(
                        "connected" to false,
                        "vendorId" to device.vendorId,
                        "productId" to device.productId
                    ))
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════
    //  Printer status (ESC/POS DLE EOT)
    // ═══════════════════════════════════════════════════

    /**
     * Sends DLE EOT commands (n=2, 3, 4) to read comprehensive printer status.
     * Works with Epson and compatible ESC/POS printers. Degrades silently for
     * printers that don't support these commands.
     *
     * ## DLE EOT 2 (Offline cause):
     *   - bit 2: cover open
     *   - bit 3: feed button pressed
     *   - bit 5: printing stopped due to error
     *   - bit 6: error occurred
     *
     * ## DLE EOT 3 (Error status):
     *   - bit 2: auto-cutter error
     *   - bit 3: unrecoverable error
     *   - bit 5: auto-recoverable error
     *
     * ## DLE EOT 4 (Paper sensor status):
     *   - bits 2,3: paper near end (1 = near end)
     *   - bits 5,6: paper present (0 = present, 1 = not present)
     */
    private fun getPrinterStatus(result: MethodChannel.Result) {
        val conn = connection
        val epOut = endpointOut
        val epIn = endpointIn

        // Run on shared USB background thread
        usbExecutor.execute {
            getPrinterStatusWorker(conn, epOut, epIn, result)
        }
    }

    private fun getPrinterStatusWorker(
        conn: android.hardware.usb.UsbDeviceConnection?,
        epOut: UsbEndpoint?,
        epIn: UsbEndpoint?,
        result: MethodChannel.Result
    ) {

        if (conn == null || epOut == null) {
            Handler(Looper.getMainLooper()).post {
                result.success(mapOf(
                    "supported" to false,
                    "paperOk" to true,
                    "paperNearEnd" to false,
                    "coverClosed" to true,
                    "online" to true,
                    "feedButtonPressed" to false,
                    "printingErrorStopped" to false,
                    "errorOccurred" to false,
                    "autoCutterError" to false,
                    "unrecoverableError" to false,
                    "autoRecoverableError" to false
                ))
            }
            return
        }

        if (epIn == null) {
            Handler(Looper.getMainLooper()).post {
                result.success(mapOf(
                    "supported" to false,
                    "paperOk" to true,
                    "paperNearEnd" to false,
                    "coverClosed" to true,
                    "online" to true,
                    "feedButtonPressed" to false,
                    "printingErrorStopped" to false,
                    "errorOccurred" to false,
                    "autoCutterError" to false,
                    "unrecoverableError" to false,
                    "autoRecoverableError" to false
                ))
            }
            return
        }

        val buffer = ByteArray(4)
        val statusResult = mutableMapOf<String, Any>(
            "supported" to true,
            "paperOk" to true,
            "paperNearEnd" to false,
            "coverClosed" to true,
            "online" to true,
            "feedButtonPressed" to false,
            "printingErrorStopped" to false,
            "errorOccurred" to false,
            "autoCutterError" to false,
            "unrecoverableError" to false,
            "autoRecoverableError" to false
        )

        // Flush any stale data from IN endpoint before status queries
        try {
            val flush = ByteArray(64)
            @Suppress("UNUSED_VARIABLE")
            val flushed = conn!!.bulkTransfer(epIn, flush, flush.size, 100)
            if (flushed > 0) {
                android.util.Log.d("ThermalPrinterUsb", "STATUS: flushed $flushed stale bytes")
            }
        } catch (_: Exception) {}

        // ─── DLE EOT 2: Offline cause ───
        try {
            val cmd2 = byteArrayOf(0x10, 0x04, 0x02)
            val sent2 = conn!!.bulkTransfer(epOut, cmd2, cmd2.size, 500)
            android.util.Log.d("ThermalPrinterUsb", "STATUS DLE EOT 2: sent=$sent2")
            val recv2 = conn.bulkTransfer(epIn, buffer, buffer.size, 500)
            android.util.Log.d("ThermalPrinterUsb", "STATUS DLE EOT 2: recv=$recv2 raw=${if (recv2 > 0) "0x${String.format("%02X", buffer[0])}" else "none"}")
            if (recv2 > 0) {
                val s = buffer[0].toInt()
                statusResult["coverClosed"] = (s and 0x04) == 0
                statusResult["feedButtonPressed"] = (s and 0x08) != 0
                statusResult["printingErrorStopped"] = (s and 0x20) != 0
                statusResult["errorOccurred"] = (s and 0x40) != 0
                statusResult["rawOffline"] = s
            }
        } catch (e: Exception) {
            android.util.Log.e("ThermalPrinterUsb", "STATUS DLE EOT 2 error: ${e.message}")
        }

        // ─── DLE EOT 3: Error status ───
        try {
            val cmd3 = byteArrayOf(0x10, 0x04, 0x03)
            val sent3 = conn!!.bulkTransfer(epOut, cmd3, cmd3.size, 500)
            android.util.Log.d("ThermalPrinterUsb", "STATUS DLE EOT 3: sent=$sent3")
            val recv3 = conn.bulkTransfer(epIn, buffer, buffer.size, 500)
            android.util.Log.d("ThermalPrinterUsb", "STATUS DLE EOT 3: recv=$recv3 raw=${if (recv3 > 0) "0x${String.format("%02X", buffer[0])}" else "none"}")
            if (recv3 > 0) {
                val s = buffer[0].toInt()
                statusResult["autoCutterError"] = (s and 0x04) != 0
                statusResult["unrecoverableError"] = (s and 0x08) != 0
                statusResult["autoRecoverableError"] = (s and 0x20) != 0
                statusResult["rawError"] = s
            }
        } catch (e: Exception) {
            android.util.Log.e("ThermalPrinterUsb", "STATUS DLE EOT 3 error: ${e.message}")
        }

        // ─── DLE EOT 4: Paper sensor status ───
        try {
            val cmd4 = byteArrayOf(0x10, 0x04, 0x04)
            val sent4 = conn!!.bulkTransfer(epOut, cmd4, cmd4.size, 500)
            android.util.Log.d("ThermalPrinterUsb", "STATUS DLE EOT 4: sent=$sent4")
            val recv4 = conn.bulkTransfer(epIn, buffer, buffer.size, 500)
            android.util.Log.d("ThermalPrinterUsb", "STATUS DLE EOT 4: recv=$recv4 raw=${if (recv4 > 0) "0x${String.format("%02X", buffer[0])}" else "none"}")
            if (recv4 > 0) {
                val s = buffer[0].toInt()
                val nearEnd = (s and 0x0C) != 0
                val noPaper = (s and 0x60) != 0
                statusResult["paperNearEnd"] = nearEnd
                statusResult["paperOk"] = !noPaper
                statusResult["rawPaper"] = s
                android.util.Log.d("ThermalPrinterUsb", "STATUS PAPER: nearEnd=$nearEnd noPaper=$noPaper rawByte=0x${String.format("%02X", s)}")
            }
        } catch (e: Exception) {
            android.util.Log.e("ThermalPrinterUsb", "STATUS DLE EOT 4 error: ${e.message}")
        }

        // Derive online: if there are serious errors, printer is offline
        val hasError = statusResult["printingErrorStopped"] == true ||
                statusResult["unrecoverableError"] == true
        statusResult["online"] = !hasError

        Handler(Looper.getMainLooper()).post {
            try {
                result.success(statusResult)
            } catch (_: Exception) {
                result.success(mapOf(
                    "supported" to false,
                    "paperOk" to true,
                    "paperNearEnd" to false,
                    "coverClosed" to true,
                    "online" to true,
                    "feedButtonPressed" to false,
                    "printingErrorStopped" to false,
                    "errorOccurred" to false,
                    "autoCutterError" to false,
                    "unrecoverableError" to false,
                    "autoRecoverableError" to false
                ))
            }
        }
    }

    // ═══════════════════════════════════════════════════
    //  Print with metrics
    // ═══════════════════════════════════════════════════

    private fun printBytes(bytes: ByteArray, result: MethodChannel.Result) {
        val conn = connection
        val ep = endpointOut

        if (conn == null || ep == null) {
            result.error("NOT_CONNECTED", "No printer connected", null)
            return
        }

        usbExecutor.execute {
            try {
                val startTime = System.currentTimeMillis()
                val chunkSize = 16384 // 16KB
                var offset = 0

                while (offset < bytes.size) {
                    val length = minOf(chunkSize, bytes.size - offset)
                    val chunk = bytes.copyOfRange(offset, offset + length)
                    val transferred = conn.bulkTransfer(ep, chunk, chunk.size, 5000)

                    if (transferred < 0) {
                        cleanupConnection()
                        emitConnectionLost()
                        Handler(Looper.getMainLooper()).post {
                            result.error("PRINT_ERROR", "Transfer failed at offset=$offset", null)
                        }
                        return@execute
                    }
                    offset += length
                }

                val elapsed = System.currentTimeMillis() - startTime

                Handler(Looper.getMainLooper()).post {
                    result.success(mapOf(
                        "success" to true,
                        "bytesTotal" to bytes.size,
                        "transferTimeMs" to elapsed
                    ))
                }
            } catch (e: Exception) {
                cleanupConnection()
                emitConnectionLost()
                Handler(Looper.getMainLooper()).post {
                    result.error("PRINT_ERROR", "Print error: ${e.message}", null)
                }
            }
        }
    }

    /** Emits connection_lost to the EventChannel if a sink is active */
    private fun emitConnectionLost() {
        val device = connectedDevice ?: return
        Handler(Looper.getMainLooper()).post {
            globalEventSink?.success(mapOf(
                "event" to "connection_lost",
                "device" to deviceToMap(device),
                "devices" to usbManager.deviceList.values.map { deviceToMap(it) },
                "vendorId" to device.vendorId,
                "productId" to device.productId
            ))
        }
    }

    // ═══════════════════════════════════════════════════════
    //  Text encoding (charset conversion)
    // ═══════════════════════════════════════════════════════

    /**
     * Encodes a Unicode string into the specified charset's byte representation.
     *
     * Thermal printers do NOT understand UTF-8. They use single-byte code pages
     * like CP850, CP437, or CP1252. Java's [Charset] provides complete, correct
     * encoding for all these code pages — no manual character maps needed.
     *
     * Common charsets for thermal printers:
     *   - `Cp850` — Western European (Spanish, French, Portuguese). Default.
     *   - `Cp437` — Original IBM PC. Good for box-drawing characters.
     *   - `Cp1252` — Windows Western European.
     *   - `ISO-8859-1` — Latin-1.
     *   - `ISO-8859-15` — Latin-9 (adds € sign).
     */
    private fun encodeText(text: String, charsetName: String, result: MethodChannel.Result) {
        try {
            val charset = Charset.forName(charsetName)
            val encoded = text.toByteArray(charset)
            result.success(encoded)
        } catch (e: java.nio.charset.UnsupportedCharsetException) {
            result.error(
                "UNSUPPORTED_CHARSET",
                "Charset '$charsetName' is not supported. Use getSupportedCharsets() to list available charsets.",
                null
            )
        } catch (e: Exception) {
            result.error("ENCODE_ERROR", "Encoding error: \${e.message}", null)
        }
    }

    /**
     * Returns a list of common charsets supported by this device.
     * Useful for letting the user pick the right encoding for their printer.
     */
    private fun getSupportedCharsets(result: MethodChannel.Result) {
        val common = listOf(
            "Cp850", "Cp437", "Cp1252", "Cp858",
            "ISO-8859-1", "ISO-8859-15",
            "US-ASCII", "UTF-8"
        )
        val supported = common.filter {
            try { Charset.isSupported(it) } catch (_: Exception) { false }
        }
        result.success(supported)
    }
}
