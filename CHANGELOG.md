## 1.0.0

* 🎉 Initial release
* Device discovery via Android USB Host API
* Connect/disconnect with automatic permission handling (30s timeout)
* Raw byte printing with chunked 16KB transfers and speed metrics
* Hardware status via ESC/POS DLE EOT commands (n=2, 3, 4):
  - Paper status (OK, near end, empty)
  - Cover status (open/closed)
  - Error status (cutter, unrecoverable, auto-recoverable)
* Auto-reconnect by VID/PID
* Print queue with 3 retries
* Paper warning stream (global alerts)
* Structured logging (circular buffer, persisted to disk)
* USB event stream (attach, detach, connection_lost)
* Connection state stream
* Real connection verification via bulk transfer test
