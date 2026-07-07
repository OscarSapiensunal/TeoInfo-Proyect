// android/app/src/main/kotlin/com/example/dsp_bt_analyzer/MainActivity.kt
//
// Actividad principal de Android. Expone dos canales a Flutter:
//
//  1. "com.dsp_bt_analyzer/rssi" — lectura de RSSI del enlace BT (GATT).
//
//  2. "com.dsp_bt_analyzer/spp_server" (+ EventChannel "…/spp_server_events")
//     — Servidor RFCOMM/SPP nativo. flutter_bluetooth_serial solo soporta
//     conexiones salientes (cliente); para P2P real entre dos teléfonos el
//     emisor debe ESCUCHAR conexiones entrantes. Este canal implementa:
//       · start        → listenUsingRfcommWithServiceRecord + accept()
//       · write(bytes) → escritura al socket del cliente conectado
//       · stop         → cierre de sockets
//     Eventos hacia Dart: waiting, connected, data, disconnected, error.
// ─────────────────────────────────────────────────────────────────────────────

package com.example.dsp_bt_analyzer

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "DspBtAnalyzer"
        private const val RSSI_CHANNEL = "com.dsp_bt_analyzer/rssi"
        private const val SERVER_CHANNEL = "com.dsp_bt_analyzer/spp_server"
        private const val SERVER_EVENTS_CHANNEL = "com.dsp_bt_analyzer/spp_server_events"
        private const val SPP_SERVICE_NAME = "DSP_BT_ANALYZER"
        private val SPP_UUID: UUID =
            UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    }

    // RSSI leído por callback (thread-safe con AtomicInteger)
    private val latestRssi = AtomicInteger(-60)
    private var gattForRssi: BluetoothGatt? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // ── Estado del servidor SPP ───────────────────────────────────────────
    private var serverSocket: BluetoothServerSocket? = null
    private var clientSocket: BluetoothSocket? = null
    private var clientOut: OutputStream? = null
    private var serverEventSink: EventChannel.EventSink? = null
    @Volatile private var serverRunning = false
    private val writeExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            RSSI_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getRssi" -> {
                    val address = call.argument<String>("address")
                    if (address == null) {
                        result.error("INVALID_ARG", "address es null", null)
                        return@setMethodCallHandler
                    }
                    readRssi(address, result)
                }
                "startRssiPolling" -> {
                    val address = call.argument<String>("address")
                    if (address != null) startRssiPolling(address)
                    result.success(null)
                }
                "stopRssiPolling" -> {
                    stopRssiPolling()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SERVER_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    startSppServer()
                    result.success(null)
                }
                "write" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    if (bytes == null) {
                        result.error("INVALID_ARG", "bytes es null", null)
                        return@setMethodCallHandler
                    }
                    // Escritura en hilo dedicado: el socket BT bloquea y no debe
                    // congelar el hilo principal. Se responde al completar la
                    // escritura para dar backpressure natural al emisor Dart.
                    writeExecutor.execute {
                        try {
                            val out = clientOut
                                ?: throw IllegalStateException("Sin cliente conectado")
                            out.write(bytes)
                            out.flush()
                            mainHandler.post { result.success(null) }
                        } catch (e: Exception) {
                            mainHandler.post {
                                result.error("WRITE_ERROR", e.message, null)
                            }
                        }
                    }
                }
                "stop" -> {
                    stopSppServer()
                    result.success(null)
                }
                "isConnected" -> result.success(clientSocket?.isConnected == true)
                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SERVER_EVENTS_CHANNEL
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                serverEventSink = events
            }

            override fun onCancel(arguments: Any?) {
                serverEventSink = null
            }
        })
    }

    // ──────────────────────────────────────────────────────────────────────
    // SERVIDOR RFCOMM / SPP
    // ──────────────────────────────────────────────────────────────────────

    private fun emitServerEvent(event: Map<String, Any?>) {
        mainHandler.post { serverEventSink?.success(event) }
    }

    private fun startSppServer() {
        stopSppServer()
        serverRunning = true

        Thread {
            try {
                val btManager =
                    getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
                val adapter: BluetoothAdapter = btManager.adapter

                serverSocket = adapter.listenUsingRfcommWithServiceRecord(
                    SPP_SERVICE_NAME, SPP_UUID
                )
                Log.i(TAG, "Servidor SPP escuchando en $SPP_UUID")
                emitServerEvent(mapOf("event" to "waiting"))

                val socket = serverSocket!!.accept() // bloquea hasta conexión entrante
                clientSocket = socket
                clientOut = socket.outputStream

                // Un solo cliente: dejar de aceptar nuevas conexiones
                try { serverSocket?.close() } catch (_: Exception) {}
                serverSocket = null

                val device = socket.remoteDevice
                Log.i(TAG, "Cliente SPP conectado: ${device.address}")
                emitServerEvent(
                    mapOf(
                        "event" to "connected",
                        "name" to (device.name ?: "Desconocido"),
                        "address" to device.address
                    )
                )

                // Bucle de lectura (ACKs del receptor → emisor)
                val input = socket.inputStream
                val buffer = ByteArray(4096)
                while (serverRunning) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    if (n > 0) {
                        emitServerEvent(
                            mapOf("event" to "data", "bytes" to buffer.copyOf(n))
                        )
                    }
                }
                emitServerEvent(mapOf("event" to "disconnected"))
            } catch (e: Exception) {
                if (serverRunning) {
                    Log.w(TAG, "Error en servidor SPP: ${e.message}")
                    emitServerEvent(
                        mapOf("event" to "error", "message" to (e.message ?: "desconocido"))
                    )
                }
            }
        }.start()
    }

    private fun stopSppServer() {
        serverRunning = false
        try { serverSocket?.close() } catch (_: Exception) {}
        try { clientSocket?.close() } catch (_: Exception) {}
        serverSocket = null
        clientSocket = null
        clientOut = null
    }

    // ──────────────────────────────────────────────────────────────────────
    // RSSI (GATT híbrido, solo telemetría)
    // ──────────────────────────────────────────────────────────────────────

    private fun readRssi(address: String, result: MethodChannel.Result) {
        val btManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val adapter: BluetoothAdapter = btManager.adapter

        val device: BluetoothDevice? = try {
            adapter.getRemoteDevice(address)
        } catch (e: Exception) {
            null
        }

        if (device == null) {
            result.error("DEVICE_NOT_FOUND", "Dispositivo $address no encontrado", null)
            return
        }

        val callback = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    gatt.readRemoteRssi()
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    gatt.close()
                }
            }

            override fun onReadRemoteRssi(gatt: BluetoothGatt, rssi: Int, status: Int) {
                latestRssi.set(rssi)
                mainHandler.post {
                    result.success(rssi.toDouble())
                }
                gatt.disconnect()
                gatt.close()
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            device.connectGatt(this, false, callback, BluetoothDevice.TRANSPORT_BREDR)
        } else {
            device.connectGatt(this, false, callback)
        }
    }

    // ── Polling periódico de RSSI (reutiliza gatt) ───────────────────────
    private var rssiRunnable: Runnable? = null

    private fun startRssiPolling(address: String) {
        stopRssiPolling()
        rssiRunnable = object : Runnable {
            override fun run() {
                gattForRssi?.readRemoteRssi()
                mainHandler.postDelayed(this, 1000L)
            }
        }

        val btManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val adapter   = btManager.adapter
        val device    = adapter.getRemoteDevice(address)

        val callback = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    gattForRssi = gatt
                    mainHandler.post(rssiRunnable!!)
                }
            }
            override fun onReadRemoteRssi(gatt: BluetoothGatt, rssi: Int, status: Int) {
                latestRssi.set(rssi)
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            device.connectGatt(this, false, callback, BluetoothDevice.TRANSPORT_BREDR)
        } else {
            device.connectGatt(this, false, callback)
        }
    }

    private fun stopRssiPolling() {
        rssiRunnable?.let { mainHandler.removeCallbacks(it) }
        rssiRunnable = null
        gattForRssi?.disconnect()
        gattForRssi?.close()
        gattForRssi = null
    }

    override fun onDestroy() {
        stopSppServer()
        writeExecutor.shutdown()
        stopRssiPolling()
        super.onDestroy()
    }
}
