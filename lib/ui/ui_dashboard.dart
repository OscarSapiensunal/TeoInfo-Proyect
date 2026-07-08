// lib/ui/ui_dashboard.dart
//
// Pantalla principal — Dashboard de análisis DSP/BT en tiempo real.
//
// Secciones:
//   1. Header.
//   2. Mi micrófono (siempre visible, silenciable en cualquier momento).
//   3. Conectar: "Esperar conexión" / "Buscar dispositivo" + lista + modo
//      laboratorio opcional (archivo .wav). Se oculta una vez conectado.
//   4. Panel de latencias y métricas en tiempo real (RSSI, Packet Loss, Buffer).
//   5. Gráfica dinámica RSSI vs Packet Loss (fl_chart LineChart).
//   6. Botón de finalizar sesión (solo mientras está activa).
// ─────────────────────────────────────────────────────────────────────────────

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_models.dart';
import '../utils/app_state.dart';

// ─────────────────────────────────────────────────────────────────────────────
// PALETA DE COLORES
// ─────────────────────────────────────────────────────────────────────────────

class _C {
  static const bg         = Color(0xFF0D1117);
  static const surface    = Color(0xFF161B22);
  static const surfaceAlt = Color(0xFF21262D);
  static const accent     = Color(0xFF58A6FF);
  static const accentGreen= Color(0xFF3FB950);
  static const accentRed  = Color(0xFFF85149);
  static const accentAmber= Color(0xFFD29922);
  static const textPrimary= Color(0xFFE6EDF3);
  static const textMuted  = Color(0xFF8B949E);
  static const border     = Color(0xFF30363D);
  static const rssiLine   = Color(0xFF58A6FF);
  static const lossLine   = Color(0xFFF85149);
}

// ─────────────────────────────────────────────────────────────────────────────
// WIDGET RAÍZ DEL DASHBOARD
// ─────────────────────────────────────────────────────────────────────────────

class UiDashboard extends StatelessWidget {
  const UiDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _C.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: const [
              _HeaderSection(),
              SizedBox(height: 16),
              _MicToggleCard(),
              SizedBox(height: 12),
              _ConnectCard(),
              SizedBox(height: 12),
              _LatencyCard(),
              SizedBox(height: 12),
              _MetricsPanelCard(),
              SizedBox(height: 12),
              _RealtimeChartCard(),
              SizedBox(height: 16),
              _StopSessionButton(),
              SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// HEADER
// ─────────────────────────────────────────────────────────────────────────────

class _HeaderSection extends StatelessWidget {
  const _HeaderSection();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 32,
              decoration: BoxDecoration(
                color: _C.accent,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              'DSP · BT Analyzer',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: _C.textPrimary,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Padding(
          padding: EdgeInsets.only(left: 18),
          child: Text(
            'Teoría de la Información y Sistemas de Comunicación',
            style: TextStyle(
              fontSize: 11,
              color: _C.textMuted,
              letterSpacing: 0.4,
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CARD BASE
// ─────────────────────────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  final String title;
  final Widget child;
  final IconData? icon;

  const _Card({required this.title, required this.child, this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _C.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _C.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 14, color: _C.accent),
                  const SizedBox(width: 6),
                ],
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: _C.textMuted,
                    letterSpacing: 1.1,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TOGGLE DE MICRÓFONO PROPIO — siempre visible, silenciable en cualquier
// momento (antes de conectar o en plena conversación).
// ─────────────────────────────────────────────────────────────────────────────

class _MicToggleCard extends StatelessWidget {
  const _MicToggleCard();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return _Card(
      title: 'MI MICRÓFONO',
      icon: Icons.mic_rounded,
      child: Row(
        children: [
          Expanded(
            child: Text(
              state.micEnabled
                  ? 'Activo: hablas en ráfagas de ${kBurstDurationMs ~/ 1000} s.'
                  : 'Silenciado: solo escuchas.',
              style: const TextStyle(color: _C.textMuted, fontSize: 12),
            ),
          ),
          Switch(
            value: state.micEnabled,
            activeThumbColor: _C.accentGreen,
            onChanged: (v) => state.setMicEnabled(v),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CONECTAR — un único flujo, sin elegir "quién habla y quién escucha"
// (ambos hacen ambas cosas). Solo define cómo se establece el enlace:
// esperar a que alguien se conecte, o buscar y conectarse a alguien.
// ─────────────────────────────────────────────────────────────────────────────

class _ConnectCard extends StatelessWidget {
  const _ConnectCard();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.isActive) return const SizedBox.shrink();

    return _Card(
      title: 'CONECTAR',
      icon: Icons.bluetooth_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => state.setWavLabMode(!state.wavLabMode),
            child: Row(
              children: [
                Icon(
                  state.wavLabMode
                      ? Icons.check_box_rounded
                      : Icons.check_box_outline_blank_rounded,
                  size: 18,
                  color: state.wavLabMode ? _C.accent : _C.textMuted,
                ),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    'Modo laboratorio: transmitir un archivo .wav en vez de mi voz '
                    '(solo aplica si espero la conexión)',
                    style: TextStyle(color: _C.textMuted, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
          if (state.wavLabMode) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: _C.surfaceAlt,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _C.border),
                    ),
                    child: Text(
                      state.wavFileName,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: _C.textPrimary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _ActionButton(
                  label: 'Seleccionar',
                  icon: Icons.folder_open_rounded,
                  onTap: state.pickWavFile,
                ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              _RoleButton(
                label: 'Esperar conexión',
                icon: Icons.wifi_tethering_rounded,
                selected: false,
                onTap: () async {
                  await state.makeDiscoverable();
                  await state.waitForConnection();
                },
              ),
              const SizedBox(width: 10),
              _RoleButton(
                label: state.isDiscovering ? 'Buscando…' : 'Buscar dispositivo',
                icon: state.isDiscovering
                    ? Icons.radar_rounded
                    : Icons.search_rounded,
                selected: state.isDiscovering,
                onTap: state.isDiscovering ? state.stopScan : state.startScan,
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (state.isDiscovering)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: LinearProgressIndicator(
                backgroundColor: _C.surfaceAlt,
                valueColor: AlwaysStoppedAnimation<Color>(_C.accent),
                minHeight: 3,
              ),
            ),
          if (state.devices.isNotEmpty)
            ...state.devices.map(
              (device) => _DeviceTile(
                device: device,
                onTap: () => state.connectToDevice(device),
              ),
            )
          else if (state.isDiscovering)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Buscando cerca… asegúrate de que el otro teléfono esté '
                'esperando conexión.',
                style: TextStyle(color: _C.textMuted, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
          const SizedBox(height: 8),
          _StatusBadge(message: state.statusMessage),
        ],
      ),
    );
  }
}

class _RoleButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _RoleButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: selected ? _C.accent.withOpacity(0.15) : _C.surfaceAlt,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? _C.accent : _C.border,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            children: [
              Icon(icon, color: selected ? _C.accent : _C.textMuted, size: 22),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: selected ? _C.accent : _C.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final BtDeviceInfo device;
  final VoidCallback onTap;

  const _DeviceTile({
    required this.device,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: _C.surfaceAlt,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _C.border),
        ),
        child: Row(
          children: [
            Icon(
              device.bonded
                  ? Icons.bluetooth_connected_rounded
                  : Icons.bluetooth_searching_rounded,
              size: 16,
              color: _C.textMuted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    device.name,
                    style: const TextStyle(
                      fontSize: 13,
                      color: _C.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    device.rssi != null
                        ? '${device.address}  ·  ${device.rssi} dBm'
                        : device.address,
                    style: const TextStyle(
                      fontSize: 11,
                      color: _C.textMuted,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
            if (!device.bonded)
              const Padding(
                padding: EdgeInsets.only(right: 6),
                child: Text(
                  'emparejar',
                  style: TextStyle(fontSize: 10, color: _C.accentAmber),
                ),
              ),
            const Icon(Icons.chevron_right_rounded, size: 18, color: _C.textMuted),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PANEL DE LATENCIAS POR RÁFAGA (insumo Sección 8 — Resultados)
// ─────────────────────────────────────────────────────────────────────────────

class _LatencyCard extends StatelessWidget {
  const _LatencyCard();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.isActive) return const SizedBox.shrink();

    return _Card(
      title: 'LATENCIA DE TRANSMISIÓN POR RÁFAGA',
      icon: Icons.timer_outlined,
      child: Column(
        children: [
          Row(
            children: [
              _MetricTile(
                label: 'ÚLT. LATENCIA',
                value: state.lastLatencyMs != null
                    ? '${state.lastLatencyMs!.toStringAsFixed(0)} ms'
                    : '—',
                icon: Icons.speed_rounded,
                color: _C.accent,
              ),
              const SizedBox(width: 10),
              _MetricTile(
                label: 'PROMEDIO',
                value: state.avgLatencyMs != null
                    ? '${state.avgLatencyMs!.toStringAsFixed(0)} ms'
                    : '—',
                icon: Icons.functions_rounded,
                color: _C.accentAmber,
              ),
              const SizedBox(width: 10),
              _MetricTile(
                label: 'RÁFAGAS',
                value: '${state.burstCount}',
                icon: Icons.stacked_bar_chart_rounded,
                color: _C.accentGreen,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            height: 140,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _C.bg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _C.border),
            ),
            child: state.latencyLog.isEmpty
                ? const Center(
                    child: Text(
                      'Sin ráfagas registradas aún…',
                      style: TextStyle(color: _C.textMuted, fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    itemCount: state.latencyLog.length,
                    itemBuilder: (_, i) => Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        state.latencyLog[i],
                        style: const TextStyle(
                          fontSize: 10,
                          color: _C.textPrimary,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PANEL DE MÉTRICAS
// ─────────────────────────────────────────────────────────────────────────────

class _MetricsPanelCard extends StatelessWidget {
  const _MetricsPanelCard();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    // Ambos lados reciben y reproducen audio (bidireccional), así que ambos
    // ven las métricas de SU PROPIO enlace de recepción.
    if (!state.isActive) return const SizedBox.shrink();

    final m = state.metrics;

    return _Card(
      title: 'MÉTRICAS EN TIEMPO REAL',
      icon: Icons.analytics_rounded,
      child: Column(
        children: [
          Row(
            children: [
              _MetricTile(
                label: 'RSSI',
                value: '${m.rssiDbm.toStringAsFixed(1)} dBm',
                icon: Icons.signal_cellular_alt_rounded,
                color: _rssiColor(m.rssiDbm),
              ),
              const SizedBox(width: 10),
              _MetricTile(
                label: 'PACKET LOSS',
                value: '${m.packetLossPercent.toStringAsFixed(1)}%',
                icon: Icons.warning_amber_rounded,
                color: _lossColor(m.packetLossPercent),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _MetricTile(
                label: 'BUFFER',
                value: '${(m.bufferFillRatio * 100).toStringAsFixed(0)}%',
                icon: Icons.memory_rounded,
                color: _C.accentAmber,
              ),
              const SizedBox(width: 10),
              _MetricTile(
                label: 'PKT RECIBIDOS',
                value: '${m.packetsReceived}',
                icon: Icons.check_circle_outline_rounded,
                color: _C.accentGreen,
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Barra de progreso del buffer
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Jitter Buffer', style: TextStyle(fontSize: 11, color: _C.textMuted)),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: m.bufferFillRatio,
                  backgroundColor: _C.surfaceAlt,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    m.bufferFillRatio > 0.8 ? _C.accentRed :
                    m.bufferFillRatio > 0.5 ? _C.accentAmber : _C.accentGreen,
                  ),
                  minHeight: 6,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static Color _rssiColor(double rssi) {
    if (rssi > -65) return _C.accentGreen;
    if (rssi > -75) return _C.accentAmber;
    return _C.accentRed;
  }

  static Color _lossColor(double loss) {
    if (loss < 2)  return _C.accentGreen;
    if (loss < 10) return _C.accentAmber;
    return _C.accentRed;
  }
}

class _MetricTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _MetricTile({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 12, color: color),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 9,
                    color: color,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: color,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// GRÁFICA EN TIEMPO REAL — RSSI vs PACKET LOSS
// ─────────────────────────────────────────────────────────────────────────────

class _RealtimeChartCard extends StatelessWidget {
  const _RealtimeChartCard();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.isActive) return const SizedBox.shrink();

    final history = state.chartHistory;

    return _Card(
      title: 'RSSI vs PÉRDIDA DE PAQUETES',
      icon: Icons.show_chart_rounded,
      child: SizedBox(
        height: 200,
        child: history.length < 2
            ? const Center(
                child: Text(
                  'Esperando datos…',
                  style: TextStyle(color: _C.textMuted, fontSize: 13),
                ),
              )
            : LineChart(
                _buildChartData(history),
                duration: const Duration(milliseconds: 150),
              ),
      ),
    );
  }

  LineChartData _buildChartData(List<ChartDataPoint> history) {
    // ── Series de RSSI (eje Y izquierdo: -100 a -30 dBm) ─────────────────
    final rssiSpots = history
        .map((p) => FlSpot(p.timeSeconds, p.rssiDbm))
        .toList();

    // ── Series de Packet Loss (eje Y derecho: 0–100%) ─────────────────────
    // Normalizamos packet loss al rango -100…-30 para superponerlo visualmente
    // en el mismo eje (escala secundaria visual).
    // Fórmula: rssiRange = 70 dBm → loss% → dBm equivalente
    final lossSpots = history.map((p) {
      // Mapear 0–100% → -100…-30 dBm para comparación visual en misma escala
      final mapped = -100.0 + (p.packetLossPercent / 100.0) * 70.0;
      return FlSpot(p.timeSeconds, mapped);
    }).toList();

    final minX = history.first.timeSeconds;
    final maxX = history.last.timeSeconds;
    final xRange = (maxX - minX).clamp(10.0, double.infinity);

    return LineChartData(
      clipData: const FlClipData.all(),
      gridData: FlGridData(
        show: true,
        drawHorizontalLine: true,
        drawVerticalLine: false,
        getDrawingHorizontalLine: (_) => FlLine(
          color: _C.border,
          strokeWidth: 1,
          dashArray: [4, 4],
        ),
      ),
      borderData: FlBorderData(
        show: true,
        border: Border.all(color: _C.border),
      ),
      titlesData: FlTitlesData(
        leftTitles: AxisTitles(
          axisNameWidget: const Text('dBm', style: TextStyle(color: _C.textMuted, fontSize: 9)),
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 36,
            interval: 14,
            getTitlesWidget: (value, _) => Text(
              value.toInt().toString(),
              style: const TextStyle(color: _C.textMuted, fontSize: 9, fontFamily: 'monospace'),
            ),
          ),
        ),
        rightTitles: AxisTitles(
          axisNameWidget: const Text('Loss%', style: TextStyle(color: _C.accentRed, fontSize: 9)),
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 36,
            interval: 14,
            getTitlesWidget: (value, _) {
              // Invertir mapeo: dBm → %
              final pct = ((value + 100.0) / 70.0 * 100.0).clamp(0.0, 100.0);
              return Text(
                '${pct.toInt()}%',
                style: const TextStyle(color: _C.accentRed, fontSize: 9, fontFamily: 'monospace'),
              );
            },
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 22,
            interval: (xRange / 4).ceilToDouble(),
            getTitlesWidget: (value, _) => Text(
              '${value.toInt()}s',
              style: const TextStyle(color: _C.textMuted, fontSize: 9, fontFamily: 'monospace'),
            ),
          ),
        ),
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      minX: minX,
      maxX: maxX,
      minY: -100,
      maxY: -30,
      lineBarsData: [
        // ── Línea RSSI ───────────────────────────────────────────────────
        LineChartBarData(
          spots: rssiSpots,
          isCurved: true,
          curveSmoothness: 0.3,
          color: _C.rssiLine,
          barWidth: 2,
          isStrokeCapRound: true,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(
            show: true,
            color: _C.rssiLine.withOpacity(0.08),
          ),
        ),
        // ── Línea Packet Loss (normalizada) ──────────────────────────────
        LineChartBarData(
          spots: lossSpots,
          isCurved: true,
          curveSmoothness: 0.3,
          color: _C.lossLine,
          barWidth: 2,
          isStrokeCapRound: true,
          dotData: const FlDotData(show: false),
          dashArray: [6, 3],
          belowBarData: BarAreaData(
            show: true,
            color: _C.lossLine.withOpacity(0.05),
          ),
        ),
      ],
      lineTouchData: LineTouchData(
        touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => _C.surfaceAlt,
          getTooltipItems: (touchedSpots) {
            return touchedSpots.map((spot) {
              final isRssi = spot.barIndex == 0;
              return LineTooltipItem(
                isRssi
                    ? '${spot.y.toStringAsFixed(1)} dBm'
                    : '${((spot.y + 100.0) / 70.0 * 100.0).toStringAsFixed(1)}%',
                TextStyle(
                  color: isRssi ? _C.rssiLine : _C.lossLine,
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              );
            }).toList();
          },
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BOTÓN DE FINALIZAR SESIÓN
// ─────────────────────────────────────────────────────────────────────────────

class _StopSessionButton extends StatelessWidget {
  const _StopSessionButton();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.isActive) return const SizedBox.shrink();

    return GestureDetector(
      onTap: state.stopSession,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 52,
        decoration: BoxDecoration(
          color: _C.accentRed.withOpacity(0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _C.accentRed, width: 1.5),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.stop_circle_rounded, color: _C.accentRed, size: 22),
            SizedBox(width: 8),
            Text(
              'Finalizar sesión',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: _C.accentRed,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// UTILIDADES MENORES
// ─────────────────────────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final String message;
  const _StatusBadge({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _C.surfaceAlt,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: _C.border),
      ),
      child: Text(
        message,
        style: const TextStyle(
          fontSize: 11,
          color: _C.textMuted,
          fontFamily: 'monospace',
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: _C.accent.withOpacity(0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _C.accent.withOpacity(0.4)),
        ),
        child: Row(
          children: [
            Icon(icon, color: _C.accent, size: 15),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(color: _C.accent, fontSize: 12, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
