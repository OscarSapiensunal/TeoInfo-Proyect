// lib/utils/app_state.dart
//
// Estado global de la aplicación (ChangeNotifier).
//
// Flujo P2P simplificado: no hay "rol" que elegir de antemano. Cualquier
// teléfono puede:
//   · esperar()      : queda visible y a la espera de una conexión entrante.
//   · connectToDevice(): busca y se conecta directamente a otro teléfono.
//
// Quien conecte primero define quién "escuchó" (host) y quién "buscó"
// (cliente) solo a nivel de transporte — a efectos de la conversación es
// irrelevante: una vez conectados, AMBOS lados reciben y reproducen audio
// siempre, y ambos capturan/transmiten su propio micrófono si lo tienen
// habilitado (mic vivo, se puede silenciar antes o durante la sesión). El
// modo "archivo WAV" es la única excepción intencional: unidireccional,
// para tener una señal de prueba controlada en el informe.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:logger/logger.dart';
import 'package:permission_handler/permission_handler.dart';

import '../bluetooth/bluetooth_manager.dart';
import '../bluetooth/audio_player_service.dart';
import '../models/app_models.dart';

class AppState extends ChangeNotifier {
  final Logger _log = Logger();

  final BluetoothManager btManager = BluetoothManager();
  final AudioPlayerService audioPlayer = AudioPlayerService();

  /// Si está habilitado, este dispositivo captura y transmite su propio
  /// micrófono. Se puede cambiar antes de conectar o EN VIVO durante una
  /// sesión activa (silenciarse/hablar en cualquier momento).
  bool _micEnabled = true;
  bool get micEnabled => _micEnabled;

  /// Modo laboratorio: si está activo y este dispositivo termina esperando
  /// la conexión (host), transmite el archivo .wav seleccionado en lugar de
  /// su micrófono — señal de prueba controlada y repetible para el informe.
  bool _wavLabMode = false;
  bool get wavLabMode => _wavLabMode;

  String? _wavFilePath;
  WavHeader? _wavHeader;
  String? get wavFilePath => _wavFilePath;
  WavHeader? get wavHeader => _wavHeader;
  String get wavFileName =>
      _wavFilePath?.split(Platform.pathSeparator).last ?? 'Sin archivo';

  // ── Dispositivos BT (emparejados + descubiertos) ─────────────────────────
  final Map<String, BtDeviceInfo> _devices = {};
  List<BtDeviceInfo> get devices {
    final list = _devices.values.toList()
      ..sort((a, b) {
        if (a.bonded != b.bonded) return a.bonded ? -1 : 1;
        return a.name.compareTo(b.name);
      });
    return list;
  }

  bool _isDiscovering = false;
  bool get isDiscovering => _isDiscovering;
  StreamSubscription<BluetoothDiscoveryResult>? _discoverySub;

  bool _isConnected = false;
  bool _isActive    = false;
  String _statusMessage = 'Activa Bluetooth para comenzar';
  bool get isConnected  => _isConnected;
  bool get isActive     => _isActive;
  String get statusMessage => _statusMessage;

  ChannelMetrics _metrics = ChannelMetrics.zero();
  ChannelMetrics get metrics => _metrics;

  // ── Teoría de la Información (capacidad de Shannon, entropía) ────────────
  InfoTheoryMetrics? _infoTheory;
  InfoTheoryMetrics? get infoTheory => _infoTheory;

  // ── Log de actividad de algoritmos DSP (PLC, AWGN, filtro, entropía) ────
  final List<String> _algorithmLog = [];
  List<String> get algorithmLog => List.unmodifiable(_algorithmLog);

  // ── Latencias por ráfaga (insumos para el informe) ───────────────────────
  double? _lastLatencyMs;
  double _latencySumMs = 0;
  int _burstCount = 0;
  final List<String> _latencyLog = [];
  static const int kMaxLogLines = 200;

  double? get lastLatencyMs => _lastLatencyMs;
  double? get avgLatencyMs =>
      _burstCount > 0 ? _latencySumMs / _burstCount : null;
  int get burstCount => _burstCount;
  List<String> get latencyLog => List.unmodifiable(_latencyLog);

  final List<ChartDataPoint> _chartHistory = [];
  List<ChartDataPoint> get chartHistory => List.unmodifiable(_chartHistory);
  DateTime? _sessionStart;
  static const int kMaxChartPoints = 60;

  StreamSubscription<ChannelMetrics>?    _metricsSub;
  StreamSubscription<Uint8List>?         _audioChunkSub;
  StreamSubscription<String>?            _statusSub;
  StreamSubscription<LatencyMetric>?     _latencySub;
  StreamSubscription<InfoTheoryMetrics>? _infoTheorySub;
  StreamSubscription<String>?            _algorithmLogSub;

  // ── Permisos ─────────────────────────────────────────────────────────────
  Future<bool> requestAllPermissions() async {
    final permissions = <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
      Permission.locationWhenInUse,
      Permission.microphone,
    ];
    final statuses = await permissions.request();
    bool allGranted = true;
    statuses.forEach((p, s) {
      if (!s.isGranted) {
        _log.w('Permiso denegado: $p');
        allGranted = false;
      }
    });
    if (!allGranted) {
      _statusMessage = 'Faltan permisos. Verifica la configuración de la app.';
      notifyListeners();
    }
    return allGranted;
  }

  // ── Micrófono y modo laboratorio ──────────────────────────────────────────

  /// Habilita/deshabilita el micrófono propio. Funciona antes de conectar
  /// (decide si se arranca la captura) y también EN VIVO durante una sesión
  /// activa (silencia/reactiva sin necesidad de reconectar).
  Future<void> setMicEnabled(bool enabled) async {
    _micEnabled = enabled;
    notifyListeners();
    if (_isActive) {
      await btManager.setMicEnabled(enabled);
    }
  }

  void setWavLabMode(bool enabled) {
    _wavLabMode = enabled;
    notifyListeners();
  }

  // ── WAV ───────────────────────────────────────────────────────────────────
  //
  // NOTA: `FileType.custom` + `allowedExtensions: ['wav']` es un problema
  // documentado de file_picker — depende de que el proveedor de archivos
  // del sistema (galería/gestor de archivos del fabricante) tenga bien
  // mapeado el MIME type de .wav; en muchos dispositivos (confirmado en un
  // Motorola) esto deja TODOS los archivos en gris, sin poder seleccionar
  // ninguno. Se usa `FileType.any` (sin filtro) y se valida el contenido
  // después con WavHeader.parse, que ya rechaza con un mensaje claro
  // cualquier archivo que no sea un WAV válido.
  Future<void> pickWavFile() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    if (result == null || result.files.single.path == null) return;
    final path = result.files.single.path!;
    try {
      final file = File(path);
      final raf  = await file.open();
      final headerBytes = Uint8List(512);
      await raf.readInto(headerBytes);
      await raf.close();
      final header = WavHeader.parse(headerBytes);
      _wavFilePath = path;
      _wavHeader   = header;
      _statusMessage = 'Archivo: ${result.files.single.name}\n${header.toString()}';
      _log.i('WAV: $header');
    } catch (e) {
      _statusMessage = 'Error al leer el archivo WAV: $e';
      _log.e('Error parseando WAV: $e');
    }
    notifyListeners();
  }

  // ── Gestión Bluetooth: activar / visible / escanear / emparejar ──────────
  Future<void> enableBluetooth() async {
    final granted = await requestAllPermissions();
    if (!granted) return;
    final enabled = await btManager.requestEnable();
    _statusMessage = enabled
        ? 'Bluetooth activado'
        : 'No se pudo activar el Bluetooth';
    notifyListeners();
    if (enabled) await _refreshPairedDevices();
  }

  Future<void> makeDiscoverable() async {
    final granted = await requestAllPermissions();
    if (!granted) return;
    await btManager.requestDiscoverable();
  }

  Future<void> startScan() async {
    final granted = await requestAllPermissions();
    if (!granted) return;
    await stopScan();

    // Conservar emparejados; limpiar descubiertos previos
    _devices.removeWhere((_, d) => !d.bonded);
    _isDiscovering = true;
    _statusMessage = 'Buscando dispositivos cercanos…';
    notifyListeners();

    _discoverySub = btManager.startDiscovery().listen(
      (BluetoothDiscoveryResult r) {
        final existing = _devices[r.device.address];
        _devices[r.device.address] = BtDeviceInfo(
          name: r.device.name ?? existing?.name ?? 'Desconocido',
          address: r.device.address,
          bonded: r.device.isBonded || (existing?.bonded ?? false),
          rssi: r.rssi,
        );
        notifyListeners();
      },
      onDone: () {
        _isDiscovering = false;
        _statusMessage =
            'Búsqueda finalizada: ${_devices.length} dispositivo(s)';
        notifyListeners();
      },
      onError: (Object e) {
        _isDiscovering = false;
        _statusMessage = 'Error de búsqueda: $e';
        _log.e('Error en discovery: $e');
        notifyListeners();
      },
    );
  }

  Future<void> stopScan() async {
    await _discoverySub?.cancel();
    _discoverySub = null;
    if (_isDiscovering) {
      await btManager.cancelDiscovery();
      _isDiscovering = false;
      notifyListeners();
    }
  }

  Future<void> _refreshPairedDevices() async {
    final paired = await btManager.getPairedDevices();
    for (final d in paired) {
      _devices[d.address] = BtDeviceInfo(
        name: d.name ?? 'Desconocido',
        address: d.address,
        bonded: true,
        rssi: _devices[d.address]?.rssi,
      );
    }
    notifyListeners();
  }

  // ── Sesión ────────────────────────────────────────────────────────────────

  /// Queda a la espera de una conexión entrante (se hace visible y arranca
  /// el servidor). Si [wavLabMode] está activo, transmitirá el archivo .wav
  /// seleccionado en cuanto alguien se conecte; en caso contrario, habla por
  /// su propio micrófono (si [micEnabled]) y escucha lo que le llegue.
  Future<void> waitForConnection() async {
    if (_wavLabMode && (_wavFilePath == null || _wavHeader == null)) {
      _statusMessage = 'Selecciona un archivo .wav primero';
      notifyListeners();
      return;
    }
    final granted = await requestAllPermissions();
    if (!granted) return;

    await stopScan();
    await btManager.requestEnable();
    await btManager.requestDiscoverable();
    await _beginActiveSession();

    await btManager.startAsHost(
      onWavInfo: _onWavInfo,
      micEnabled: !_wavLabMode && _micEnabled,
      wavFilePath: _wavLabMode ? _wavFilePath : null,
      wavHeader: _wavLabMode ? _wavHeader : null,
    );
  }

  /// Se conecta directamente al dispositivo [device] (emparejando primero
  /// si hace falta) y comienza la sesión de inmediato.
  Future<void> connectToDevice(BtDeviceInfo device) async {
    final granted = await requestAllPermissions();
    if (!granted) return;
    await stopScan();

    if (!device.bonded) {
      _statusMessage = 'Emparejando con ${device.name}…';
      notifyListeners();
      final ok = await btManager.bondDevice(device.address);
      if (!ok) {
        _statusMessage = 'Emparejamiento con ${device.name} rechazado o fallido';
        notifyListeners();
        return;
      }
      _devices[device.address] = device.copyWith(bonded: true);
    }

    await _beginActiveSession();
    try {
      await btManager.joinAsClient(
        address: device.address,
        name: device.name,
        onWavInfo: _onWavInfo,
        micEnabled: _micEnabled,
      );
    } catch (e) {
      _isActive = false;
      _statusMessage = 'No se pudo conectar a ${device.name}: $e';
      notifyListeners();
    }
  }

  Future<void> _beginActiveSession() async {
    _sessionStart = DateTime.now();
    _chartHistory.clear();
    _latencyLog.clear();
    _lastLatencyMs = null;
    _latencySumMs = 0;
    _burstCount = 0;
    _algorithmLog.clear();
    _infoTheory = null;
    _isActive = true;
    notifyListeners();
    _listenToStreams();
    btManager.isSpeakerActive = () => audioPlayer.isPlaying;
    await audioPlayer.init();
  }

  /// Solo fija el formato — ya no arranca ningún reproductor persistente
  /// (ver AudioPlayerService: se reproduce por clips discretos encolados,
  /// no streaming en tiempo real), así que no hay nada que pueda fallar
  /// aquí ni ningún estado que reiniciar.
  void _onWavInfo(int sampleRate, int numChannels, int bitsPerSample) {
    audioPlayer.configure(sampleRate: sampleRate, numChannels: numChannels);
    _log.i('Formato de audio: ${sampleRate}Hz ${numChannels}ch');
  }

  void _listenToStreams() {
    _metricsSub = btManager.metricsStream.listen((m) {
      _metrics = m;
      final elapsed = _sessionStart != null
          ? DateTime.now().difference(_sessionStart!).inMilliseconds / 1000.0
          : 0.0;
      _chartHistory.add(ChartDataPoint(
        timeSeconds: elapsed,
        rssiDbm: m.rssiDbm,
        packetLossPercent: m.packetLossPercent,
      ));
      if (_chartHistory.length > kMaxChartPoints) _chartHistory.removeAt(0);
      notifyListeners();
    });
    _audioChunkSub = btManager.audioChunkStream.listen((chunk) {
      audioPlayer.enqueueChunk(chunk);
    });
    _statusSub = btManager.statusStream.listen((msg) {
      _statusMessage = msg;
      _isConnected   = btManager.isConnected;
      notifyListeners();
    });
    _latencySub = btManager.latencyStream.listen(_onLatencyMetric);
    _infoTheorySub = btManager.infoTheoryStream.listen((m) {
      _infoTheory = m;
      notifyListeners();
    });
    _algorithmLogSub = btManager.algorithmLogStream.listen((msg) {
      final t = DateTime.now();
      final hh = t.hour.toString().padLeft(2, '0');
      final mm = t.minute.toString().padLeft(2, '0');
      final ss = t.second.toString().padLeft(2, '0');
      _algorithmLog.insert(0, '[$hh:$mm:$ss] $msg');
      if (_algorithmLog.length > kMaxLogLines) _algorithmLog.removeLast();
      _log.i(msg);
      notifyListeners();
    });
  }

  void _onLatencyMetric(LatencyMetric m) {
    _lastLatencyMs = m.latencyMs;
    _latencySumMs += m.latencyMs;
    _burstCount++;

    final t = m.timestamp;
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final ss = t.second.toString().padLeft(2, '0');
    final line = m.isRoundTrip
        ? '[$hh:$mm:$ss] TX ráfaga #${m.burstId} → RTT ${m.latencyMs.toStringAsFixed(0)} ms'
        : '[$hh:$mm:$ss] RX ráfaga #${m.burstId} → tránsito ${m.latencyMs.toStringAsFixed(0)} ms';
    _latencyLog.insert(0, line);
    if (_latencyLog.length > kMaxLogLines) _latencyLog.removeLast();

    // También al log de Android (adb logcat) para el informe
    _log.i(line);
    notifyListeners();
  }

  Future<void> stopSession() async {
    _isActive = false; _isConnected = false;
    await _metricsSub?.cancel();
    await _audioChunkSub?.cancel();
    await _statusSub?.cancel();
    await _latencySub?.cancel();
    await _infoTheorySub?.cancel();
    await _algorithmLogSub?.cancel();
    _metricsSub = null; _audioChunkSub = null;
    _statusSub = null;  _latencySub = null;
    _infoTheorySub = null; _algorithmLogSub = null;
    await btManager.disconnect();
    await audioPlayer.stopStreaming();
    _statusMessage = 'Sesión finalizada';
    notifyListeners();
  }

  @override
  void dispose() {
    stopScan();
    stopSession();
    btManager.dispose();
    audioPlayer.dispose();
    super.dispose();
  }
}
