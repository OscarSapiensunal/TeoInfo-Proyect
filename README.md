# DSP · BT Analyzer — Flutter App
## Teoría de la Información y Sistemas de Comunicación — UNAL

Comunicación **P2P entre dos teléfonos Android** por Bluetooth Clásico
RFCOMM/SPP: captura de voz por micrófono en ráfagas de 2 s (PCM lineal),
transmisión con detección de pérdidas, DSP en el receptor y medición de
latencia por ráfaga. Modo alternativo: transmisión de archivo `.wav`.

**Arquitectura P2P:** el Emisor levanta un servidor SPP nativo
(`MainActivity.kt` — `flutter_bluetooth_serial` solo soporta modo cliente)
y queda esperando; el Receptor escanea, se empareja y conecta como cliente.
El canal es bidireccional: audio Emisor→Receptor, ACKs Receptor→Emisor.

---

## Arquitectura de archivos

```
lib/
├── main.dart                          # Punto de entrada + MaterialApp + Provider
├── models/
│   └── app_models.dart                # WavHeader, ChannelMetrics, paquetes BT
├── bluetooth/
│   ├── bluetooth_manager.dart         # TX ráfagas (servidor) / RX cliente, pérdidas, latencia
│   ├── rfcomm_server.dart             # Wrapper Dart del servidor SPP nativo
│   ├── audio_capture_service.dart     # flutter_sound Recorder → stream PCM del micrófono
│   └── audio_player_service.dart      # flutter_sound PCM stream (FeedFromStream)
├── dsp/
│   └── dsp_processor.dart             # Jitter Buffer, PLC, AWGN, filtros IIR+FIR
├── ui/
│   └── ui_dashboard.dart              # Dashboard: roles, métricas, gráfica fl_chart
└── utils/
    └── app_state.dart                 # ChangeNotifier — estado global + permisos

android/
└── app/src/main/
    ├── AndroidManifest.xml            # Permisos BT + audio para Android 12+
    └── kotlin/.../MainActivity.kt     # Servidor RFCOMM/SPP nativo + RSSI (BluetoothGatt)
```

---

## Dependencias clave

| Paquete | Versión | Función |
|---|---|---|
| `flutter_bluetooth_serial` | ^0.4.0 | Bluetooth Clásico RFCOMM/SPP (NO BLE) |
| `flutter_sound` | ^9.2.13 | Stream PCM crudo → parlantes (feedFromStream) |
| `file_picker` | ^6.1.1 | Selección de archivos .wav |
| `fl_chart` | ^0.68.0 | Gráfica RSSI vs Packet Loss en tiempo real |
| `permission_handler` | ^11.3.0 | Permisos Android 12+ / iOS |
| `provider` | ^6.1.1 | Gestión de estado reactivo |

---

## Protocolo de paquetes BT

```
┌──────────┬──────────┬─────────────┬─────────────┬──────────────────────┐
│ 0xAA (1B)│ 0xBB (1B)│ SEQ_HI (1B) │ SEQ_LO (1B) │ PCM PAYLOAD (1020 B) │
└──────────┴──────────┴─────────────┴─────────────┴──────────────────────┘
  Total: 1024 bytes/paquete | SEQ: uint16 módulo 65536
```

**Tipos especiales:**
- `[0xCC, 0xDD, ...]` — Meta-paquete con parámetros del audio (sampleRate, canales, bits)
- `[0xCC, 0xEE, ID_HI, ID_LO, byteLen(u32), txEpochMs(u64), ...]` — Cabecera de ráfaga
- `[0xCD, 0xEF, ID_HI, ID_LO, txEpochMs(u64), rxEpochMs(u64)]` — ACK de ráfaga (20 B, Receptor→Emisor)
- `[0xFF, 0xFF, 0xEE, 0xDD, ...]` — Fin de stream

**Detección de pérdidas:** salto en `SEQ` → `lost = (SEQ_recibido - SEQ_esperado) mod 65536`

## Ráfagas de voz y latencia (modo micrófono P2P)

- Captura PCM lineal Int16 LE, **16 kHz mono** → ráfagas de **2 s = 64 000 bytes**
  (63 paquetes de 1020 B, el último con relleno).
- Cada ráfaga viaja precedida de su cabecera con `txEpochMs` del emisor.
- **Latencia en el receptor**: `rxEpochMs - txEpochMs` al completar la ráfaga
  (estimación sujeta al desfase de reloj entre teléfonos).
- **Latencia en el emisor (RTT)**: el receptor responde ACK por el mismo socket;
  el emisor mide `ahora - txEpochMs` con su propio reloj (sin problema de
  sincronización). Incluye el tiempo de transmisión del bloque completo.
- Ambas se muestran en el panel "Latencia de transmisión por ráfaga" de la UI
  y se imprimen en logcat (`adb logcat`) — insumos para la Sección 8 del informe.

---

## Pipeline DSP (receptor)

```
Socket RFCOMM
     │
     ▼
┌─────────────────────┐
│  Reensamblado de    │  (buffer de bytes, sincronización por magic bytes)
│  paquetes           │
└────────┬────────────┘
         │ payload (1020 bytes PCM Int16)
         ▼
┌─────────────────────┐
│  Detección de       │  SEQ_esperado vs SEQ_recibido
│  pérdida            │
└────────┬────────────┘
         │ isLost = true/false
         ▼
┌─────────────────────────────────────────────────────────┐
│                    DspProcessor                          │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────┐ │
│  │     PLC     │→ │ Inyección    │→ │  Filtro LP     │ │
│  │ (atenuación │  │ AWGN         │  │  IIR + FIR     │ │
│  │  3dB/rep)   │  │ (RSSI < -75) │  │  (RSSI < -75)  │ │
│  └─────────────┘  └──────────────┘  └────────────────┘ │
└────────┬────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────┐
│   Jitter Buffer     │  Circular, 16 slots × 1020 bytes
│   (circular)        │  Política: drop-oldest si lleno
└────────┬────────────┘
         │
         ▼
┌─────────────────────┐
│  flutter_sound      │  feedFromStream() → PCM directo a DAC
│  PCM Stream         │
└─────────────────────┘
```

---

## Parámetros DSP configurables (dsp_processor.dart)

| Constante | Valor | Descripción |
|---|---|---|
| `kJitterBufferCapacity` | 16 | Slots del buffer circular |
| `kRssiWeakThreshold` | -75 dBm | Umbral para activar PLC + ruido |
| `kRssiCriticalThreshold` | -88 dBm | Umbral señal crítica |
| `kPlcAttenuationFactor` | 0.707 | Atenuación por repetición PLC (-3 dB) |
| `kIirAlpha` | 0.15 | Coef. filtro IIR paso-bajos |
| `kMovingAvgOrder` | 5 | Orden del filtro FIR promedio móvil |

---

## Setup en Android

### Prerrequisitos
1. Flutter ≥ 3.10 con Android SDK 33+
2. Dos teléfonos Android emparejados vía Bluetooth Clásico

### Build
```bash
flutter pub get
flutter run --release   # conectado al transmisor
# En el segundo teléfono:
flutter run --release   # conectado al receptor
```

### Notas de permisos Android 12+
El `AndroidManifest.xml` ya incluye todos los permisos necesarios.
En tiempo de ejecución, `AppState.requestAllPermissions()` solicita:
- `BLUETOOTH_SCAN`
- `BLUETOOTH_CONNECT`  
- `BLUETOOTH_ADVERTISE`
- `ACCESS_FINE_LOCATION`
- `RECORD_AUDIO`

---

## Experimento de laboratorio

**Procedimiento (voz P2P, mismo APK en ambos teléfonos):**
1. Teléfono A (Emisor): rol *Emisor* → fuente *Micrófono (2 s)* → **Activar BT** →
   **Visible** → **Iniciar sesión** (queda esperando conexión).
2. Teléfono B (Receptor): rol *Receptor* → **Activar BT** → **Escanear** →
   tocar el emisor en la lista (se empareja si hace falta) → **Iniciar sesión**.
3. Hablar cerca del micrófono de A: la voz se reproduce en B en bloques de 2 s.
4. Emisor adentro de la casa; alejar el receptor progresivamente.
5. Observar RSSI (azul) decrecer y pérdida de paquetes (rojo) aumentar en la gráfica,
   y las latencias por ráfaga en el panel correspondiente (capturas para el informe).
6. El PLC y el filtro LP mantienen la reproducción continua incluso con RSSI < -75 dBm.

**Métricas registradas:**
- RSSI en dBm (señal del canal físico)
- Packet Loss Rate % (calidad del canal de datos)
- Jitter Buffer fill ratio (estabilidad del buffer de reproducción)
- Tiempo de sesión (eje X de la gráfica)

---

## Notas de implementación

- **Hilo UI vs DSP**: el procesamiento de bytes ocurre en callbacks `async` de Dart,
  que son cooperative multitasking sobre el event loop. Para cargas muy pesadas,
  considera mover `DspProcessor.processBlock()` a un `Isolate` con `compute()`.
- **RSSI real**: requiere la implementación nativa en `MainActivity.kt` (incluida).
  Fallback: variación aleatoria de ±0.5 dBm para demostración.
- **flutter_bluetooth_serial**: la versión ^0.4.0 requiere `minSdkVersion 19`.
  Asegúrate de configurarlo en `android/app/build.gradle`.
