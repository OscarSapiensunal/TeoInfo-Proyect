# DSP · BT Analyzer — Transmisión digital de voz sobre un canal Bluetooth ruidoso
## Teoría de la Información y Sistemas de Comunicación — Universidad Nacional de Colombia

App Android (Flutter/Dart + Kotlin) que implementa un **sistema de comunicación
digital completo entre dos teléfonos**: captura de voz → digitalización PCM →
empaquetado con números de secuencia → transmisión por Bluetooth Clásico
(RFCOMM/SPP, un canal inalámbrico real y ruidoso) → detección de pérdidas →
procesamiento digital de señales en recepción (PLC, ruido AWGN, filtros
IIR/FIR, jitter buffer) → reproducción, con medición en vivo de RSSI, tasa de
pérdida de paquetes y latencia por ráfaga.

> Este README sigue la estructura de la plantilla oficial del proyecto del
> curso (secciones 2–12). La portada (sección 1: integrantes, grupo, docente,
> fecha) va en el documento PDF de entrega.

---

## 2. Problema o necesidad

**¿Qué problema se quiere resolver?** Estudiar experimentalmente cómo se
degrada una señal de voz digitalizada al transmitirse por un canal
inalámbrico real de corto alcance (Bluetooth Clásico), y qué técnicas de
procesamiento digital permiten mitigar esa degradación en el receptor.

**¿Por qué es importante?** Los cursos de sistemas de comunicación suelen
estudiar el canal ruidoso de forma simulada (MATLAB/Python sobre datos
sintéticos). Este proyecto usa un **canal físico real** — con desvanecimiento
por distancia, interferencia y pérdida de paquetes genuina — lo que permite
contrastar la teoría (muestreo, PCM, canal ruidoso, filtrado) contra el
comportamiento medible de hardware de consumo. Además, todo el instrumento de
medición es la propia app: un laboratorio de comunicaciones portátil en dos
teléfonos.

---

## 3. Objetivos

**Objetivo general:** Implementar y caracterizar un enlace de comunicación
digital de voz punto a punto sobre Bluetooth Clásico, midiendo la calidad del
canal (RSSI, pérdida de paquetes, latencia) y aplicando técnicas de DSP en
recepción para mitigar la degradación.

**Objetivos específicos:**
1. Digitalizar voz en PCM lineal (16 kHz, 16 bits, mono — cumpliendo el
   teorema de muestreo para voz) y transmitirla en ráfagas empaquetadas con
   números de secuencia sobre sockets RFCOMM.
2. Detectar y cuantificar la pérdida de paquetes del canal real, y ocultarla
   perceptualmente con un algoritmo de PLC (Packet Loss Concealment)
   implementado a mano.
3. Implementar filtros digitales IIR y FIR propios para atenuar el ruido
   agregado cuando la señal del canal se degrada (RSSI bajo), y comparar el
   filtro práctico contra el ideal (script de análisis en Python/SciPy).
4. Medir y graficar en tiempo real las métricas del canal (RSSI vs. pérdida,
   latencia de bloque por RTT) como insumo experimental del informe.

---

## 4. Marco teórico

Conceptos del curso directamente aplicados:

| Concepto (capítulo del curso) | Dónde aparece en el proyecto |
|---|---|
| **Teorema de muestreo** (Cap. III 3.1) | La voz se muestrea a 16 kHz: el ancho de banda útil de la voz (~300–3400 Hz, hasta ~7 kHz en banda ancha) queda por debajo de Nyquist (8 kHz). |
| **PCM — Modulación por codificación de pulsos** (Cap. III 3.2) | Cuantización uniforme a 16 bits por muestra, mono. El flujo se transmite sin compresión precisamente para analizar la señal "pura". |
| **Transmisión digital de señales analógicas** (Cap. III) | Pipeline completo: micrófono (analógico) → ADC → empaquetado → canal → DAC → parlante. |
| **Canal ruidoso** (Cap. IV 4.4) | El canal Bluetooth real presenta pérdida de paquetes y desvanecimiento con la distancia; la app lo cuantifica (loss %) en vez de simularlo. |
| **Filtros ideales vs. prácticos** (Cap. II 2.10) | Filtro paso-bajos de dos etapas hecho a mano: IIR de primer orden (y[n] = α·x[n] + (1−α)·y[n−1]) + FIR de promedio móvil de orden 5. El script `python_dsp/filtro_iir_butterworth.py` analiza la respuesta en frecuencia (Bode) de un Butterworth práctico con SciPy y discute por qué su fase no es lineal. |
| **Transformada de Fourier / respuesta en frecuencia** (Cap. II 2.5–2.11) | El diseño y análisis del filtro (frecuencia de corte, atenuación) se hace en el dominio de la frecuencia con `scipy.signal.freqz` (DFT computacional, Cap. II 2.11). |
| **Ruido AWGN** (Cap. IV) | Cuando el RSSI cae bajo −75 dBm, el receptor inyecta ruido blanco gaussiano (método Box-Muller, implementado a mano) proporcional a la degradación, para hacer audible/medible el efecto del canal sobre la señal. |
| **Medidas del canal físico** | RSSI en dBm (potencia recibida), tasa de pérdida (calidad del canal de datos), latencia por RTT (el emisor mide con su propio reloj, evitando el problema de relojes no sincronizados entre teléfonos). |
| **Filtro adaptativo — cancelación de eco acústico** (Cap. II, filtro con coeficientes variables en el tiempo) | NLMS (Normalized LMS) de 128 taps que estima, muestra a muestra, el eco acústico parlante→micrófono propio y lo resta antes de transmitir (`echo_canceller.dart`); usa la misma ecuación en diferencias que un FIR, pero con `w[k]` adaptándose con `w[k] += (μ·e[n]/‖x‖²)·x[n−k]`. La mitigación PRINCIPAL y garantizada es semi-dúplex (silenciar el micrófono propio mientras el parlante reproduce); el NLMS ataca el eco residual, no reemplaza al semi-dúplex. |
| **Capacidad de canal de Shannon-Hartley** (Cap. IV) | `C = B·log2(1+SNR)` calculada en vivo: `B` = ancho de banda de Nyquist del muestreo, `SNR` estimado como el RSSI actual sobre un piso de ruido asumido de −95 dBm (`information_theory.dart`). Mostrada junto al RSSI para comparar capacidad teórica contra el throughput real observado. |
| **Entropía de la fuente** (Cap. IV 4.2) | `H(X) = −Σp(x)·log2(p(x))` estimada por histograma de 256 bins sobre cada clip de voz reproducido, contrastada contra la entropía máxima log2(256)=8 bits/muestra (ruido blanco uniforme) — la voz real siempre da menos, por sus silencios y su distribución de amplitud concentrada. |
| **Corrección de errores hacia adelante — FEC** (Cap. V) | Código de Hamming (7,4) implementado a mano (`error_correction.dart`): 4 bits de datos → 7 bits con 3 de paridad: `p1=d1⊕d2⊕d4, p2=d1⊕d3⊕d4, p3=d2⊕d3⊕d4`. El síndrome de paridad en el receptor apunta directo a la posición del bit volteado y lo corrige sin pedir reenvío. |
| **ARQ — repetición automática bajo pedido** (Cap. V) | Al detectar un hueco de secuencia, el receptor envía un NACK pidiendo la ráfaga completa; el emisor, si aún la tiene en caché, la reenvía. Complementa al FEC: FEC corrige bits aislados sin esperar; ARQ recupera pérdidas completas al costo de una ida y vuelta. |

**Qué es implementación propia y qué es infraestructura de terceros** (transparencia metodológica):

| Componente | Origen |
|---|---|
| Protocolo de paquetes (framing, magic bytes, SEQ, cabecera de ráfaga, ACK) | **Propio** (`app_models.dart`) |
| Detección de pérdidas por salto de secuencia (aritmética módulo 65536) | **Propio** (`bluetooth_manager.dart`) |
| PLC: repetición con atenuación exponencial −3 dB por bloque | **Propio** (`dsp_processor.dart`) |
| Inyección AWGN (Box-Muller) | **Propio** (`dsp_processor.dart`) |
| Filtros IIR + FIR (ecuaciones en diferencias muestra a muestra) | **Propio** (`dsp_processor.dart`) |
| Jitter buffer circular con política drop-oldest | **Propio** (`dsp_processor.dart`) |
| Medición de latencia por RTT con ACKs | **Propio** (protocolo + `bluetooth_manager.dart`) |
| Servidor RFCOMM (listen/accept nativo Android) | **Propio** (`MainActivity.kt`, Kotlin) |
| Parser de cabecera WAV (RIFF) | **Propio** (`app_models.dart`) |
| Análisis de filtro Butterworth (Bode, filtfilt) | **Propio** sobre SciPy (`python_dsp/`) |
| Cancelador de eco acústico (NLMS + semi-dúplex) | **Propio** (`echo_canceller.dart`, `bluetooth_manager.dart`) |
| Capacidad de Shannon + entropía de la fuente | **Propio** (`information_theory.dart`) |
| Lectura de RSSI real vía GATT sobre BT Clásico (con *fallback* simulado si el teléfono no la soporta) | **Propio** (`MainActivity.kt` + `rssi_channel.dart`) |
| FEC — Hamming (7,4), codificación/decodificación/corrección | **Propio** (`error_correction.dart`) |
| ARQ — protocolo NACK + caché de última ráfaga + reenvío | **Propio** (`app_models.dart` + `bluetooth_manager.dart`) |
| Socket Bluetooth cliente | Librería `flutter_bluetooth_serial` |
| Acceso a micrófono y parlante (drivers de audio) | Librería `flutter_sound` |
| UI y gráficas | Flutter + `fl_chart` |

Es decir: el **núcleo académico** (protocolo, detección de pérdidas, PLC,
ruido, filtros, buffer, métricas) es código propio; las librerías cubren solo
el acceso al hardware (equivalente a usar `audiorecorder` de MATLAB).

---

## 5. Metodología

**Herramientas:** Flutter 3.x / Dart (app multiplataforma), Kotlin (servidor
RFCOMM nativo Android), `flutter_bluetooth_serial` (cliente SPP),
`flutter_sound` (E/S de audio), `fl_chart` (gráficas en vivo), Python 3 +
NumPy/SciPy/Matplotlib (análisis de filtros), `adb logcat` (depuración sobre
hardware real), Git/GitHub (control de versiones).

**Desarrollo iterativo guiado por experimento:** cada versión se probó en
teléfonos físicos reales (Motorola G86 — MediaTek/Android 15, Motorola G52 —
Qualcomm/Android 12, Huawei Y6s — Android 10). Los fallos se diagnosticaron
con captura de `logcat` en vivo por USB, leyendo los volcados nativos
(tombstones) del sistema — no por ensayo y error a ciegas. La sección 9
documenta ese proceso.

**Flujo del sistema:**

```
  TELÉFONO A (habla)                    CANAL                TELÉFONO B (escucha)
┌───────────────────┐                                      ┌────────────────────┐
│ Micrófono         │                                      │ Parlante           │
│   ↓ ADC           │      Bluetooth Clásico RFCOMM        │   ↑ DAC            │
│ PCM 16kHz/16bit   │   (real: pérdidas, RSSI variable)    │ Clips de ~2 s      │
│   ↓               │                                      │   ↑                │
│ Ráfagas de 2 s    │  ────────  paquetes 1024 B  ───────► │ Jitter buffer      │
│ (64000 B c/u)     │                                      │   ↑                │
│   ↓               │  ◄────────  ACK (20 B)  ───────────  │ DSP: PLC+AWGN+LP   │
│ SEQ + timestamp   │                                      │   ↑                │
└───────────────────┘                                      │ Detección pérdidas │
     (y viceversa: el enlace es full-duplex,               └────────────────────┘
      ambos teléfonos hablan y escuchan)
```

---

## 6. Implementación / Desarrollo

### Arquitectura de archivos

```
lib/
├── main.dart                          # Punto de entrada + Provider + manejo global de errores
├── models/
│   └── app_models.dart                # Protocolo de paquetes, ráfagas, ACK, métricas, WavHeader
├── bluetooth/
│   ├── bluetooth_manager.dart         # Pipeline RX/TX unificado (full-duplex), pérdidas, latencia, AEC
│   ├── rfcomm_server.dart             # Wrapper Dart del servidor SPP nativo
│   ├── rssi_channel.dart              # MethodChannel hacia la lectura de RSSI real (GATT)
│   ├── audio_capture_service.dart     # Micrófono → stream PCM (flutter_sound Recorder)
│   └── audio_player_service.dart      # Reproducción por clips discretos encolados
├── dsp/
│   ├── dsp_processor.dart             # Jitter Buffer, PLC, AWGN, filtros IIR+FIR (todo a mano)
│   ├── echo_canceller.dart            # Cancelador de eco NLMS + semi-dúplex (todo a mano)
│   ├── information_theory.dart        # Capacidad de Shannon + entropía de la fuente (todo a mano)
│   └── error_correction.dart          # FEC Hamming (7,4): codifica/decodifica/corrige (todo a mano)
├── ui/
│   └── ui_dashboard.dart              # Conectar (esperar/buscar), mic, métricas, gráfica
└── utils/
    └── app_state.dart                 # Estado global + permisos + escaneo BT

android/app/src/main/
├── AndroidManifest.xml                # Permisos BT + audio para Android 12+
└── kotlin/.../MainActivity.kt         # Servidor RFCOMM/SPP nativo + RSSI (BluetoothGatt)

python_dsp/
└── filtro_iir_butterworth.py          # Diseño/análisis de filtro IIR (Bode, filtfilt)
```

### Protocolo de paquetes (diseño propio)

```
┌──────────┬──────────┬─────────────┬─────────────┬──────────────────────┐
│ 0xAA (1B)│ 0xBB (1B)│ SEQ_HI (1B) │ SEQ_LO (1B) │ PCM PAYLOAD (1020 B) │
└──────────┴──────────┴─────────────┴─────────────┴──────────────────────┘
  Total: 1024 bytes/paquete | SEQ: uint16 módulo 65536
```

**Tipos especiales:**
- `[0xCC, 0xDD, ...]` — Meta-paquete con parámetros del audio (sampleRate, canales, bits)
- `[0xCC, 0xEE, ID_HI, ID_LO, byteLen(u32), txEpochMs(u64), ...]` — Cabecera de ráfaga
- `[0xCD, 0xEF, ID_HI, ID_LO, txEpochMs(u64), rxEpochMs(u64)]` — ACK de ráfaga (20 B — más corto
  que los demás; el framing de recepción calcula el tamaño esperado según los 2 bytes de magic)
- `[0xCD, 0xF0, ID_HI, ID_LO]` — NACK: solicitud de reenvío de la ráfaga `ID` (4 B, ARQ — ver
  sección "Optimizar señal")
- `[0xFF, 0xFF, 0xEE, 0xDD, ...]` — Fin de stream

**Detección de pérdidas:** salto en `SEQ` → `perdidos = (SEQ_recibido − SEQ_esperado) mod 65536`.
Cada lado cuenta las pérdidas de SU PROPIO enlace de recepción.

### Arquitectura P2P sin roles

La app no pregunta "quién habla y quién escucha" — ambos hacen ambas cosas.
Solo se decide CÓMO se establece el enlace: un teléfono toca **"Esperar
conexión"** (levanta un servidor SPP nativo — `flutter_bluetooth_serial` solo
soporta modo cliente, por eso `MainActivity.kt` implementa `listen`+`accept()`
en Kotlin) y el otro toca **"Buscar dispositivo"** y lo selecciona. El socket
RFCOMM resultante es full-duplex: ambos lados ejecutan el mismo pipeline de
envío/recepción. El micrófono de cada teléfono se silencia/activa en vivo.

### Cancelación de eco acústico (AEC)

Sin auriculares, el micrófono de cada teléfono capta lo que su propio
parlante está reproduciendo — el interlocutor escucha su propia voz de
regreso, con retardo. Se mitiga en dos capas:

1. **Semi-dúplex (garantizado):** mientras el parlante propio está
   reproduciendo un clip, la captura de micrófono se descarta por completo
   (no se acumula ni se envía nada) — `isSpeakerActive` en
   `bluetooth_manager.dart`, alimentado desde `AudioPlayerService.isPlaying`.
   Esta es la mitigación que realmente garantiza que no haya un bucle de
   realimentación acústica.
2. **NLMS residual (best-effort):** el filtro adaptativo de
   `echo_canceller.dart` mantiene un buffer del audio recién reproducido
   (referencia "far-end") y estima/resta la porción que se filtró de vuelta
   al micrófono en los bordes de la ventana semi-dúplex (colas de
   reverberación). Es una implementación de curso, sin estimación de retardo
   ni detección de doble-habla — no es un AEC de grado profesional, y se
   documenta así honestamente.

Cada transición de estado (silenciado/reactivado) y cada corrección del PLC
se emiten como eventos legibles al panel **"Log de algoritmos en vivo"** de
la UI, para poder ver — no solo inferir — qué algoritmo actuó y cuándo.

### RSSI real vs. simulado

El RSSI se intenta leer del hardware Bluetooth real vía una conexión GATT
híbrida (`BluetoothGatt.readRemoteRssi`, expuesta por `MainActivity.kt` y
consumida desde `rssi_channel.dart`). No todos los chipsets/Android exponen
esta lectura de forma confiable sobre un enlace Bluetooth Clásico; cuando
falla, la app recurre a una caminata aleatoria acotada (±1 dB, clamped a
[−95, −40] dBm) como *placeholder* visual — y la UI **marca explícitamente**
cuál de los dos modos está activo (`ChannelMetrics.rssiIsReal`), en vez de
presentar un dato simulado como si fuera real.

### Panel "Optimizar señal" — de crudo a optimizado, sintiendo la diferencia

Analizar el canal no es lo mismo que mejorarlo. Cada sesión arranca **cruda**
(`SignalOptimizationSettings.raw`: las 5 mitigaciones apagadas) para poder
escuchar primero el canal tal como llega, y el panel "Optimizar señal" del
dashboard deja activarlas en vivo — el cambio se siente de inmediato, sin
reconectar, porque `BluetoothManager.signalSettings` se relee en cada
paquete/chunk:

- **Switch maestro:** todo crudo ↔ todo optimizado, para la demo rápida.
- **"Personalizar" (colapsado por defecto):** 5 switches individuales — PLC,
  Filtro IIR/FIR, AEC, FEC y ARQ — para poder medir en el informe cuánto
  aporta CADA técnica por separado, sin abrumar al usuario promedio con 5
  controles a la vista todo el tiempo.

| Mitigación | Con el switch apagado se oye/pasa… | Encendido… |
|---|---|---|
| PLC | Silencio/gap crudo en cada paquete perdido | Repetición atenuada (−3 dB/repetición) |
| Filtro IIR/FIR | El ruido AWGN inyectado (RSSI débil) sin limpiar | Ruido filtrado (~40 dB/octava) |
| AEC | Full-dúplex sin cancelar — eco propio audible sin auriculares | Semi-dúplex + NLMS residual |
| FEC (Hamming 7,4) | Bits corrompidos simulados tal cual (clics/pops) | Bits corregidos automáticamente |
| ARQ | El hueco de pérdida se queda como tal (más allá de lo que PLC repuso) | Ráfaga completa reenviada a pedido |

**Nota importante de honestidad metodológica:** el ruido AWGN y los
bit-errores que corrige el FEC **siempre** se inyectan cuando el RSSI cae
bajo el umbral débil — representan al CANAL degradado, no a una
optimización. Lo que cada switch enciende/apaga es si esa degradación se
**limpia/corrige** o se deja pasar tal cual. Esto es deliberado: Bluetooth
Clásico (RFCOMM sobre L2CAP) ya protege el enlace contra corrupción de bits
a nivel físico, así que en la práctica casi nunca llega un bit volteado
hasta la capa de aplicación — sin esta simulación, el FEC no tendría nada
que corregir y el switch no se sentiría. La pérdida de paquetes real, en
cambio, sí ocurre de forma genuina (desbordamiento del Jitter Buffer,
interrupciones del enlace), así que el ARQ actúa sobre pérdidas reales, no
simuladas.

**Cómo funciona el ARQ sin arriesgar el Jitter Buffer ya probado:** en vez de
reinsertar el paquete recuperado en su posición exacta dentro del buffer
circular (que ya jugó su parte con PLC para ese hueco), el paquete
retransmitido se reproduce como un clip corto adicional, apenas llega —
simple y no toca la lógica de temporización del Jitter Buffer que costó
varias iteraciones dejar estable (ver Dificultades §4-5). El costo real: el
audio recuperado puede sonar un poco fuera de orden/con retraso — un
trade-off genuino de ARQ sobre un canal con latencia, no una simplificación
que se esconda.

### Ráfagas de voz y latencia

- Captura PCM Int16 LE, **16 kHz mono** → ráfagas de **2 s = 64 000 bytes**
  (63 paquetes de 1020 B, el último con relleno).
- Cada ráfaga viaja precedida de su cabecera con `txEpochMs` del emisor.
- **Latencia en el receptor:** `rxEpochMs − txEpochMs` al completar la ráfaga
  (estimación sujeta al desfase de reloj entre teléfonos).
- **Latencia en el emisor (RTT):** el receptor responde ACK por el mismo
  socket; el emisor mide `ahora − txEpochMs` con su propio reloj (sin
  problema de sincronización). Incluye el tiempo de transmisión del bloque.
- Ambas se muestran en el panel de latencias de la UI y se imprimen en
  `logcat` — insumos de la sección 8.

### Pipeline DSP (receptor)

```
Socket RFCOMM
     │
     ▼
┌─────────────────────┐
│  Reensamblado de    │  (buffer de bytes, sincronización por magic bytes,
│  paquetes           │   framing de longitud variable según tipo)
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
│   Jitter Buffer     │  Circular, 80 slots × 1020 bytes (≈ 1 ráfaga completa)
│   (circular)        │  Política: drop-oldest si lleno
└────────┬────────────┘
         │  Se agrupa en clips de ~2 s (una ráfaga completa, o lo acumulado
         │  si el flujo se detiene) — BluetoothManager._drainToPlaybackQueue
         ▼
┌─────────────────────┐
│  flutter_sound      │  Clips discretos encolados vía startPlayer
│  startPlayer()      │  (fromDataBuffer:) — NO streaming en tiempo real,
│  (fromDataBuffer)   │  ver sección 9 (Dificultades).
└─────────────────────┘
```

### Parámetros DSP configurables (`dsp_processor.dart`)

| Constante | Valor | Descripción |
|---|---|---|
| `kJitterBufferCapacity` | 80 | Slots del buffer circular (≥ 1 ráfaga de 63 bloques) |
| `kRssiWeakThreshold` | −75 dBm | Umbral para activar PLC + ruido |
| `kRssiCriticalThreshold` | −88 dBm | Umbral de señal crítica |
| `kPlcAttenuationFactor` | 0.707 | Atenuación por repetición PLC (−3 dB) |
| `kIirAlpha` | 0.15 | Coeficiente del filtro IIR paso-bajos |
| `kMovingAvgOrder` | 5 | Orden del filtro FIR de promedio móvil |

---

## 7. Demostración

**Procedimiento (conversación bidireccional, mismo APK en ambos teléfonos):**
1. Teléfono A: tocar **"Esperar conexión"** (queda visible y a la espera).
2. Teléfono B: tocar **"Buscar dispositivo"** → tocar a A en la lista
   (se empareja si hace falta) → conecta de inmediato.
3. Con "Mi micrófono" activo en ambos (por defecto lo está), cualquiera puede
   hablar y el otro lo escucha en bloques de ~2 s — como una radio de dos
   vías. Usar auriculares para evitar eco; silenciar el micrófono propio con
   el toggle si solo se quiere escuchar.
4. Teléfono A adentro de un edificio; alejar el teléfono B progresivamente.
5. Observar en CADA teléfono (cada uno mide su propio enlace de recepción):
   RSSI (azul) decrecer, pérdida de paquetes (rojo) aumentar, y las latencias
   por ráfaga en el panel correspondiente — capturas de pantalla para el
   informe.

**Modo laboratorio (señal de prueba controlada):** en el teléfono que va a
"Esperar conexión", marcar **"Modo laboratorio"** y seleccionar un `.wav`
antes de conectar — transmite ese archivo en vez del micrófono, útil para
repetir el experimento con una señal de referencia idéntica en cada corrida.
Se recomienda un WAV de 16 kHz mono 16 bits (el throughput de RFCOMM,
~90 KB/s, no alcanza para 44.1 kHz estéreo en tiempo real: 176 KB/s).

**Evidencias sugeridas:** capturas del dashboard en 3 distancias (cerca /
media / límite de cobertura), foto del montaje, video corto de la
conversación, y el log de latencias (se imprime también en `adb logcat`).

---

## 8. Resultados / análisis (métricas que produce la app)

En cada teléfono, sobre su propio enlace de recepción:
- **RSSI [dBm]** — potencia de señal del canal físico (gráfica en vivo), con
  indicador explícito de si el dato es real (GATT) o simulado (ver sección 6).
- **Packet Loss Rate [%]** — calidad del canal de datos, medida por saltos de
  secuencia (no simulada).
- **Jitter Buffer fill ratio [%]** — estabilidad del buffer de reproducción.
- **Latencia por ráfaga [ms]** — tránsito estimado (receptor) y RTT medido
  (emisor); última, promedio y conteo, con log con marca de tiempo.
- **Paquetes recibidos/perdidos** — contadores absolutos.
- **Capacidad de canal C [kbps]** y **entropía de la fuente H(X) [bits/muestra]**
  — recalculadas tras cada clip reproducido (panel "Teoría de la Información").
- **Paquetes recuperados por ARQ** — cuántos de los detectados como perdidos
  se recuperaron por retransmisión (subconjunto de `packetsLost`).
- **Log de algoritmos en vivo** — traza con marca de tiempo de cada evento de
  PLC (paquetes repuestos), AEC (silenciado/reactivado del micrófono), FEC
  (bits corregidos por Hamming), ARQ (solicitudes/reenvíos) y AWGN+filtro
  (activados cuando el RSSI cae bajo el umbral débil).

Análisis esperado para el informe: correlación RSSI ↓ ⇒ pérdida ↑ al aumentar
la distancia/obstáculos; efectividad del PLC (continuidad perceptual pese a
pérdidas); RTT ≈ tiempo de transmisión del bloque + latencia del canal;
contraste entre la capacidad teórica de Shannon y el throughput real de
RFCOMM (~90 KB/s) — la brecha entre ambos es, en sí misma, una medida de
cuánto overhead de protocolo/reintentos consume el canal real frente al
límite teórico.

---

## 9. Dificultades encontradas (y cómo se resolvieron)

Documentadas con detalle porque son la parte más formativa del proyecto:

1. **`flutter_bluetooth_serial` no soporta modo servidor.** Para P2P real un
   lado debe escuchar conexiones entrantes. Solución: servidor RFCOMM nativo
   en Kotlin (`MainActivity.kt`, `listenUsingRfcommWithServiceRecord` +
   `accept()`), expuesto a Dart vía MethodChannel/EventChannel.
2. **Crashes nativos del proceso (SIGSEGV/SIGABRT) sin excepción Dart
   visible.** Se diagnosticaron conectando los teléfonos por USB y capturando
   `adb logcat` en vivo: el tombstone nativo mostró el fallo dentro de
   `AudioTrack::write`/`releaseBuffer`, en el hilo de escritura de
   `flutter_sound`, reproducible en 3 teléfonos (MediaTek, Qualcomm, Kirin).
   Coincide con el issue sin resolver
   [flutter_sound#508](https://github.com/Canardoux/flutter_sound/issues/508).
   Lección: ante un crash sin stack trace de Dart, el logcat nativo da la
   causa exacta en minutos.
3. **El streaming de audio en tiempo real del plugin es inestable.** Tras
   agotar mitigaciones (serializar escrituras, secuenciar arranques, agrandar
   el buffer nativo 2048→8192), se cambió el mecanismo: el audio recibido se
   agrupa en clips de ~2 s (una ráfaga) y se reproduce con
   `startPlayer(fromDataBuffer:)`, la API estable "de archivo" del plugin.
   Costo: ~0.2 s de pausa entre clips (efecto walkie-talkie), aceptable
   frente a un crash de proceso.
4. **Clips de 500 ms sonaban entrecortados.** Cada `startPlayer()` añade
   ~100–300 ms de silencio; con clips de 0.5 s la voz se troceaba. Solución:
   acumular la ráfaga completa (~2 s) antes de emitir el clip, con vaciado
   del residuo cuando el flujo se detiene.
5. **El Jitter Buffer (16 slots) descartaba el 75 % de cada ráfaga.** Los 63
   paquetes de una ráfaga llegan casi de golpe; con capacidad 16 se
   descartaban por drop-oldest antes de reproducirse (métricas bien, audio
   mudo). Se dimensionó a 80 slots ≥ 1 ráfaga.
6. **El selector de archivos no dejaba elegir ningún archivo** (Motorola):
   `FileType.custom` + `allowedExtensions` depende del mapeo MIME del
   proveedor de archivos del fabricante. Solución: `FileType.any` + validación
   del contenido con el parser RIFF propio.
7. **Compilación bloqueada en la máquina de desarrollo** ("Unable to
   establish loopback connection"): el antivirus corporativo bloquea sockets
   AF_UNIX que JDK ≥16 usa en `Selector.open()`. Workaround:
   `JAVA_TOOL_OPTIONS=-Djdk.net.unixdomain.tmpdir=Z:\no_existe` fuerza el
   fallback a loopback TCP.
8. **Relojes no sincronizados entre teléfonos** impiden medir la latencia de
   ida con exactitud. Solución: protocolo de ACK — el emisor mide RTT con su
   propio reloj (metrológicamente honesto); el tránsito del receptor se
   reporta con su salvedad.
9. **¿Cómo demostrar FEC si Bluetooth Clásico ya casi no deja pasar bits
   corruptos?** RFCOMM/L2CAP protege el enlace a nivel físico, así que un
   Hamming(7,4) real casi nunca tendría algo que corregir en la práctica —
   el switch se sentiría "muerto". Solución: simular una tasa de bit-error
   propia (igual patrón que el AWGN ya existente), proporcional a la
   degradación de RSSI, documentado explícitamente como una simulación
   pedagógica y no una medición del canal físico real.
10. **El RSSI mostrado SIEMPRE bajaba, nunca subía.** La simulación de
   respaldo tenía un sesgo: `_currentRssi += (_currentRssi > -90 ? -0.5 : 0.5)`
   restaba en casi cualquier valor razonable (la condición era casi siempre
   cierta), así que el valor solo podía caer hasta el piso. Además el lado
   que actuaba como host nunca sondeaba el RSSI real (solo lo hacía quien se
   conectaba como cliente). Solución: caminata aleatoria acotada y simétrica
   (±1 dB, clamped) para el modo simulado, más sondeo de RSSI real en AMBOS
   roles (host y cliente), con un indicador en la UI de cuál de los dos modos
   está activo en cada momento.

---

## 10. Conclusiones (síntesis sugerida para el informe)

1. Se implementó un sistema de comunicación digital de voz funcional de
   extremo a extremo sobre un canal inalámbrico real, cumpliendo el objetivo
   general: el enlace transmite, mide y mitiga.
2. Las métricas confirman experimentalmente la teoría: la pérdida de paquetes
   crece al degradarse el RSSI, y el PLC + filtrado mantienen la
   inteligibilidad ante pérdidas moderadas.
3. El canal real impone restricciones que la simulación oculta: throughput
   limitado de RFCOMM (~90 KB/s), jitter de entrega, y fallos del stack de
   audio del sistema operativo — gestionarlos fue la mayor parte del esfuerzo
   de ingeniería.
4. La medición de latencia por RTT demuestra la importancia de definir QUÉ se
   mide y CON QUÉ reloj: la única métrica sin sesgo de sincronización es la
   que usa un solo reloj.
5. La capacidad de canal de Shannon (C = B·log₂(1+SNR)) y la entropía de la
   fuente de voz (Cap. IV 4.2) se implementaron y se muestran en vivo junto al
   throughput medido, cerrando la brecha entre "usar el canal" y "caracterizar
   el canal en los términos del curso".
6. La cancelación de eco (semi-dúplex + NLMS residual) mostró que un filtro
   FIR con coeficientes fijos no basta cuando la "respuesta al impulso" del
   acoplamiento acústico cambia con la posición del teléfono — de ahí la
   necesidad de un filtro ADAPTATIVO, el mismo principio de Cap. II llevado a
   coeficientes variables en el tiempo.
7. El código detector/corrector (Hamming 7,4, Cap. V) y el ARQ por NACK se
   implementaron y son ACTIVABLES en vivo desde el panel "Optimizar señal",
   junto a PLC/Filtro/AEC — el proyecto pasó de solo MEDIR la degradación del
   canal a también poder MITIGARLA a demanda, comparando "antes" y "después"
   sin reconectar.

---

## 11. Bibliografía (IEEE)

[1] B. P. Lathi and Z. Ding, *Modern Digital and Analog Communication
Systems*, 4th ed. New York: Oxford University Press, 2009.
[2] L. W. Couch, *Digital and Analog Communication Systems*, 8th ed. Boston:
Pearson, 2013.
[3] C. E. Shannon and W. Weaver, *The Mathematical Theory of Communication*.
Urbana: University of Illinois Press, 1949.
[4] J. G. Proakis and M. Salehi, *Fundamentals of Communication Systems*,
2nd ed. Boston: Pearson, 2013.
[5] Bluetooth SIG, "Serial Port Profile (SPP) Specification," Bluetooth
Special Interest Group. [En línea]. Disponible:
https://www.bluetooth.com/specifications/specs/serial-port-profile-1-2/
[6] Android Developers, "AudioTrack | Android media APIs." [En línea].
Disponible: https://developer.android.com/reference/android/media/AudioTrack
[7] The SciPy community, "scipy.signal — Signal processing." [En línea].
Disponible: https://docs.scipy.org/doc/scipy/reference/signal.html
[8] Canardoux, "flutter_sound issue #508: Program crashes with simultaneous
mic/speaker streams," GitHub, 2020. [En línea]. Disponible:
https://github.com/Canardoux/flutter_sound/issues/508

---

## 12. Anexos

- **Código completo:** este repositorio
  (https://github.com/OscarSapiensunal/TeoInfo-Proyect).
- **Script de análisis de filtros:** `python_dsp/filtro_iir_butterworth.py`
  (diseño Butterworth con SciPy, diagrama de Bode, filtrado fase-cero con
  `filtfilt`, y nota sobre fase no lineal de filtros IIR prácticos).
- **Tests unitarios del protocolo y del jitter buffer:** `test/widget_test.dart`
  (`flutter test`).
- **Manual de uso:** sección 7 (Demostración) de este documento.
- **Historial de depuración:** los mensajes de commit de este repositorio
  documentan cada fallo encontrado y su diagnóstico con logcat.

### Compilación (manual técnico)

Prerrequisitos: Flutter ≥ 3.10, Android SDK 34+, dos o más teléfonos Android
(API ≥ 29 probado).

```bash
flutter pub get
flutter build apk --release
# APK resultante: build/app/outputs/flutter-apk/app-release.apk
# Instalar el MISMO APK en todos los teléfonos:
adb -s <serial> install -r build/app/outputs/flutter-apk/app-release.apk
```

Permisos solicitados en tiempo de ejecución (Android 12+): `BLUETOOTH_SCAN`,
`BLUETOOTH_CONNECT`, `BLUETOOTH_ADVERTISE`, `ACCESS_FINE_LOCATION`,
`RECORD_AUDIO`.

Nota (máquina de desarrollo con antivirus corporativo): si el build falla con
"Unable to establish loopback connection", definir antes
`JAVA_TOOL_OPTIONS=-Djdk.net.unixdomain.tmpdir=Z:\no_existe` (ver
`android/gradle.properties`).
