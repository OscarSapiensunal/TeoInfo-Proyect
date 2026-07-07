// lib/utils/app_state.dart
//
// Estado global de la aplicación (ChangeNotifier).
//
// Flujo P2P:
//   · Emisor  : activar BT → hacerse visible → iniciar sesión (queda en
//               espera como servidor SPP) → al conectar el receptor captura
//               micrófono en ráfagas de 2 s (o transmite un WAV).
//   · Receptor: activar BT → escanear → seleccionar/emparejar emisor →
//               iniciar sesión (conecta como cliente y reproduce).
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

  DeviceRole _role = DeviceRole.none;
  DeviceRole get role => _role;

  AudioTxSource _txSource = AudioTxSource.microphone;
  AudioTxSource get txSource => _txSource;

  String? _wavFilePath;
  WavHeader? _wavHeader;
  String? get wavFilePath => _wavFilePath;
  WavHeader? get wavHeader => _wavHeader;
  String get wavFileName =>
      _wavFilePath?.split(Platform.pathSeparator).last ?? 'Sin archivo';

  // ── Dispositivos BT (emparejados + descubiertos) ─────────────────────────
  final Map<String, BtDeviceInfo> _devices = {};
  BtDeviceInfo? _selectedDevice;
  List<BtDeviceInfo> get devices {
    final list = _devices.values.toList()
      ..sort((a, b) {
        if (a.bonded != b.bonded) return a.bonded ? -1 : 1;
        return a.name.compareTo(b.name);
      });
    return list;
  }

  BtDeviceInfo? get selectedDevice => _selectedDevice;

  bool _isDiscovering = false;
  bool get isDiscovering => _isDiscovering;
  StreamSubscription<BluetoothDiscoveryResult>? _discoverySub;

  bool _isConnected = false;
  bool _isActive    = false;
  String _statusMessage = 'Selecciona un rol para comenzar';
  bool get isConnected  => _isConnected;
  bool get isActive     => _isActive;
  String get statusMessage => _statusMessage;

  ChannelMetrics _metrics = ChannelMetrics.zero();
  ChannelMetrics get metrics => _metrics;

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

  StreamSubscription<ChannelMetrics>? _metricsSub;
  StreamSubscription<Uint8List>?      _audioChunkSub;
  StreamSubscription<String>?         _statusSub;
  StreamSubscription<LatencyMetric>?  _latencySub;

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

  // ── Rol y fuente ──────────────────────────────────────────────────────────
  void setRole(DeviceRole role) {
    _role = role;
    _statusMessage = role == DeviceRole.transmitter
        ? 'Modo Emisor. Activa BT, hazte visible e inicia sesión.'
        : 'Modo Receptor. Escanea y selecciona el emisor.';
    notifyListeners();
    _refreshPairedDevices();
  }

  void setTxSource(AudioTxSource source) {
    _txSource = source;
    notifyListeners();
  }

  // ── WAV ───────────────────────────────────────────────────────────────────
  Future<void> pickWavFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['wav'],
    );
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
    _statusMessage = 'Dispositivo visible por 120 s';
    notifyListeners();
  }

  Future<void> startScan() async {
    final granted = await requestAllPermissions();
    if (!granted) return;
    await stopScan();

    // Conservar emparejados; limpiar descubiertos previos
    _devices.removeWhere((_, d) => !d.bonded);
    _isDiscovering = true;
    _statusMessage = 'Escaneando dispositivos cercanos…';
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
            'Escaneo finalizado: ${_devices.length} dispositivo(s)';
        notifyListeners();
      },
      onError: (Object e) {
        _isDiscovering = false;
        _statusMessage = 'Error de escaneo: $e';
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

  /// Selecciona un dispositivo; si no está emparejado, envía la solicitud
  /// de emparejamiento primero (aparece el diálogo del sistema en ambos).
  Future<void> selectDevice(BtDeviceInfo device) async {
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
      _statusMessage = 'Emparejado con ${device.name}';
    }
    _selectedDevice = _devices[device.address] ?? device;
    notifyListeners();
  }

  // ── Sesión ────────────────────────────────────────────────────────────────
  Future<void> startSession() async {
    if (_role == DeviceRole.receiver && _selectedDevice == null) {
      _statusMessage = 'Selecciona el dispositivo emisor primero';
      notifyListeners();
      return;
    }
    await stopScan();
    _sessionStart = DateTime.now();
    _chartHistory.clear();
    _latencyLog.clear();
    _lastLatencyMs = null;
    _latencySumMs = 0;
    _burstCount = 0;
    _isActive = true;
    notifyListeners();
    _listenToStreams();
    if (_role == DeviceRole.transmitter) {
      await _startTransmission();
    } else {
      await _startReception();
    }
  }

  Future<void> _startTransmission() async {
    if (_txSource == AudioTxSource.microphone) {
      await btManager.startMicBurstTransmitter();
      return;
    }
    if (_wavFilePath == null || _wavHeader == null) {
      _statusMessage = 'Selecciona un archivo .wav primero';
      notifyListeners();
      return;
    }
    await btManager.startWavServerTransmitter(
      wavFilePath: _wavFilePath!,
      wavHeader:   _wavHeader!,
    );
  }

  Future<void> _startReception() async {
    await audioPlayer.init();
    await btManager.connectAndReceive(
      address: _selectedDevice!.address,
      name:    _selectedDevice!.name,
      onWavInfo: (int sr, int nc, int bps) async {
        await audioPlayer.startStreaming(
          sampleRate: sr, numChannels: nc, bitsPerSample: bps,
        );
        _log.i('Motor de audio: ${sr}Hz ${nc}ch ${bps}bit');
      },
    );
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
    _audioChunkSub = btManager.audioChunkStream.listen((chunk) async {
      await audioPlayer.feedChunk(chunk);
    });
    _statusSub = btManager.statusStream.listen((msg) {
      _statusMessage = msg;
      _isConnected   = btManager.isConnected;
      notifyListeners();
    });
    _latencySub = btManager.latencyStream.listen(_onLatencyMetric);
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
    _metricsSub = null; _audioChunkSub = null;
    _statusSub = null;  _latencySub = null;
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
