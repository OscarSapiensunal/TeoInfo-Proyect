# DSP · BT Analyzer — Flutter App
## Teoría de la Información y Sistemas de Comunicación — UNAL

Comunicación **P2P bidireccional entre dos teléfonos Android** por Bluetooth
Clásico RFCOMM/SPP — conversación tipo radio de dos vías: ambos lados
capturan voz por micrófono en ráfagas de 2 s (PCM lineal), transmiten con
detección de pérdidas, aplican DSP y reproducen lo que reciben, con medición
de latencia por ráfaga. Modo alternativo unidireccional: transmisión de un
archivo `.wav` de prueba controlada (solo el anfitrión transmite).

**Arquitectura P2P:** el Anfitrión levanta un servidor SPP nativo
(`MainActivity.kt` — `flutter_bluetooth_serial` solo soporta modo cliente)
y queda esperando; el Participante escanea, se empareja y conecta como
cliente. El socket RFCOMM es full-duplex (como un socket TCP): ambos lados
ejecutan el MISMO pipeline de envío/recepción por el mismo canal, así que
cualquiera con el micrófono habilitado habla y cualquiera escucha lo que
llega — de ahí la conversación de dos vías.

**Limitación conocida:** sin cancelación de eco acústico (AEC), si ambos
micrófono y parlante están activos en el mismo teléfono sin auriculares,
el micrófono puede captar el propio parlante (retroalimentación). Se
recomienda usar auriculares/manos libres durante las pruebas, o silenciar
el micrófono del lado que solo escucha (toggle "Mi micrófono" en la UI).

---

## Arquitectura de archivos

```
lib/
├── main.dart                          # Punto de entrada + MaterialApp + Provider
├── models/
│   └── app_models.dart                # WavHeader, ChannelMetrics, paquetes BT
├── bluetooth/
│   ├── bluetooth_manager.dart         # Pipeline RX/TX unificado (full-duplex), pérdidas, latencia
│   ├── rfcomm_server.dart             # Wrapper Dart del servidor SPP nativo
│   ├── audio_capture_service.dart     # flutter_sound Recorder → stream PCM del micrófono
│   └── audio_player_service.dart      # flutter_sound PCM stream (FeedFromStream)
├── dsp/
│   └── dsp_processor.dart             # Jitter Buffer (drenado externo), PLC, AWGN, filtros IIR+FIR
├── ui/
│   └── ui_dashboard.dart              # Dashboard: roles, modo de sesión, mic, métricas, gráfica
└── utils/
    └── app_state.dart                 # ChangeNotifier — estado global + permisos + escaneo

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
- `[0xCD, 0xEF, ID_HI, ID_LO, txEpochMs(u64), rxEpochMs(u64)]` — ACK de ráfaga (20 B — nótese que
  es más corto que los demás tipos; el framing de recepción calcula el tamaño esperado según los
  2 bytes de magic antes de extraer el paquete, no asume una longitud fija para todo el stream)
- `[0xFF, 0xFF, 0xEE, 0xDD, ...]` — Fin de stream

**Detección de pérdidas:** salto en `SEQ` → `lost = (SEQ_recibido - SEQ_esperado) mod 65536`.
Cada lado cuenta las pérdidas de SU PROPIO enlace de recepción (contador independiente).

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
         │  Timer periódico (BluetoothManager._startPlaybackDrain), NO cada
         │  paquete: desacopla la llegada a ráfagas del BT del ritmo real
         │  de reproducción, para que fillRatio refleje el estado real.
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
flutter run --release   # instalar en el teléfono anfitrión
# En el segundo teléfono:
flutter run --release   # instalar en el teléfono participante
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

**Procedimiento (conversación bidireccional, mismo APK en ambos teléfonos):**
1. Teléfono A: rol *Anfitrión* → modo *Conversación* → **Activar BT** →
   **Visible** → **Iniciar sesión** (queda esperando conexión).
2. Teléfono B: rol *Participante* → **Activar BT** → **Escanear** →
   tocar al anfitrión en la lista (se empareja si hace falta) → **Iniciar sesión**.
3. Con el toggle "Mi micrófono" activo en ambos (por defecto lo está), cualquiera
   de los dos puede hablar y el otro lo escucha en bloques de 2 s — como una
   radio de dos vías. Usar auriculares para evitar eco (ver limitación conocida).
4. Anfitrión adentro de la casa; alejar al participante progresivamente.
5. Observar RSSI (azul) decrecer y pérdida de paquetes (rojo) aumentar en la
   gráfica de CADA teléfono (cada uno mide su propio enlace de recepción), y
   las latencias por ráfaga en el panel correspondiente (capturas para el informe).
6. El PLC y el filtro LP mantienen la reproducción continua incluso con RSSI < -75 dBm.

**Modo alternativo (prueba unidireccional con señal controlada):** rol
*Anfitrión* → modo *Archivo WAV* → seleccionar el `.wav` → el participante
solo escucha (sin su propio micrófono), útil para repetir el experimento
con una señal de referencia idéntica en cada corrida.

**Métricas registradas (en cada teléfono, sobre su propio enlace de RX):**
- RSSI en dBm (señal del canal físico)
- Packet Loss Rate % (calidad del canal de datos)
- Jitter Buffer fill ratio (estabilidad del buffer de reproducción)
- Latencia por ráfaga: tránsito estimado en el receptor y RTT medido en el emisor
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
