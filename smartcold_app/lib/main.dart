import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  static const String deviceId = 'SmartCold-5494';

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SmartCold',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        fontFamily: 'Roboto',
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00A8FF),
          brightness: Brightness.dark,
        ),
      ),
      home: const DeviceStatusPage(deviceId: deviceId),
    );
  }
}

class DeviceStatusPage extends StatelessWidget {
  const DeviceStatusPage({super.key, required this.deviceId});

  final String deviceId;

  @override
  Widget build(BuildContext context) {
    final docRef = FirebaseFirestore.instance
        .collection('device_status')
        .doc(deviceId);

    return Scaffold(
      backgroundColor: const Color(0xFF020B14),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color(0xFF020B14),
              Color(0xFF03192B),
              Color(0xFF061E32),
              Color(0xFF020B14),
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: docRef.snapshots(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const Center(
                  child: Text('Error leyendo estado del equipo'),
                );
              }

              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final data = snapshot.data!.data();

              if (data == null) {
                return Center(child: Text('No existe estado para $deviceId'));
              }

              final chamberTemp = _sensorValue(data, 'chamber');
              final evaporatorTemp = _sensorValue(data, 'evaporator');

              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
                children: [
                  _TopBar(online: data['online'], rssi: data['rssi']),
                  const SizedBox(height: 14),

                  _HeroPanel(
                    deviceName: data['device_name'] ?? data['name'] ?? deviceId,
                    health: data['device_health'],
                    healthReason: data['device_health_reason'],
                    state: data['device_state'],
                    online: data['online'],
                    rssi: data['rssi'],
                    compressorOn: data['compressor_relay_on'],
                    blockReason: data['compressor_block_reason'],
                  ),

                  LayoutBuilder(
                    builder: (context, constraints) {
                      return GridView.count(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        crossAxisCount: 3,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                        childAspectRatio: constraints.maxWidth < 430
                            ? 0.95
                            : 1.25,
                        children: [
                          _KpiCard(
                            title: 'Cámara',
                            value: chamberTemp,
                            suffix: '°C',
                            icon: Icons.thermostat_rounded,
                            badgeText: _sensorAlarmText(data, 'chamber'),
                            accent: const Color(0xFF1EA7FF),
                          ),
                          _KpiCard(
                            title: 'Evaporador',
                            value: evaporatorTemp,
                            suffix: '°C',
                            icon: Icons.ac_unit_rounded,
                            badgeText: _sensorAlarmText(data, 'evaporator'),
                            accent: const Color(0xFF21B9FF),
                          ),
                          _MiniCompressorKpi(
                            relayOn: data['compressor_relay_on'],
                            shouldBeOn: data['compressor_should_be_on'],
                            protectionSeconds:
                                data['compressor_wait_seconds_remaining'],
                          ),
                        ],
                      );
                    },
                  ),

                  const SizedBox(height: 12),

                  LayoutBuilder(
                    builder: (context, constraints) {
                      final defrostCard = _DefrostCard(
                        active: data['defrost_active'],
                        evaporatorTemp: evaporatorTemp,
                        chamberTemp: chamberTemp,
                        endTemperature: data['defrost_end_temperature'],
                        remainingSeconds: data['defrost_remaining_seconds'],
                        nextSeconds: data['defrost_next_seconds'],
                        durationMinutes: data['defrost_duration_minutes'],
                        intervalMinutes: data['defrost_interval_minutes'],
                      );

                      final dripCard = _DripCard(
                        active: data['drip_active'],
                        configuredSeconds: data['drip_time_seconds'],
                        remainingSeconds: data['drip_remaining_seconds'],
                      );

                      return IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: defrostCard),
                            const SizedBox(width: 8),
                            Expanded(child: dripCard),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  static dynamic _sensorValue(Map<String, dynamic> data, String role) {
    final readings = data['sensor_readings'];
    if (readings is Map && readings.containsKey(role)) {
      return readings[role];
    }
    return null;
  }

  static String _sensorAlarmText(Map<String, dynamic> data, String role) {
    final alarms = data['sensor_alarms'];
    if (alarms is Map && alarms[role] is Map) {
      final alarm = alarms[role] as Map;
      final inAlarm = alarm['in_alarm'] == true;
      final reason = alarm['reason']?.toString();
      if (inAlarm && reason != null && reason.isNotEmpty) {
        if (reason == 'HIGH_TEMP') return 'ALTA';
        if (reason == 'LOW_TEMP') return 'BAJA';
        return reason.replaceAll('_', ' ');
      }
    }
    return 'NORMAL';
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.online, required this.rssi});

  final dynamic online;
  final dynamic rssi;

  @override
  Widget build(BuildContext context) {
    final isOnline = online == true;

    return Row(
      children: [
        const Icon(Icons.menu_rounded, color: Colors.white, size: 32),
        const SizedBox(width: 14),

        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF00A8FF), width: 2),
          ),
          child: const Icon(Icons.ac_unit_rounded, color: Color(0xFF00A8FF)),
        ),

        const SizedBox(width: 10),

        const Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: 'SMART',
                  style: TextStyle(color: Colors.white),
                ),
                TextSpan(
                  text: 'COLD',
                  style: TextStyle(color: Color(0xFF00A8FF)),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.2,
            ),
          ),
        ),

        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.circle,
                  color: isOnline ? const Color(0xFF20D76D) : Colors.redAccent,
                  size: 10,
                ),
                const SizedBox(width: 5),
                Text(
                  isOnline ? 'ONLINE' : 'OFFLINE',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 2),

            Text(
              '${rssi ?? "--"} dBm',
              style: const TextStyle(
                color: Color(0xFF9DB0C1),
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _HeroPanel extends StatelessWidget {
  const _HeroPanel({
    required this.deviceName,
    required this.health,
    required this.healthReason,
    required this.state,
    required this.online,
    required this.rssi,
    required this.compressorOn,
    required this.blockReason,
  });

  final dynamic deviceName;
  final dynamic health;
  final dynamic healthReason;
  final dynamic state;
  final dynamic online;
  final dynamic rssi;
  final dynamic compressorOn;
  final dynamic blockReason;

  @override
  Widget build(BuildContext context) {
    final nameText = deviceName?.toString() ?? 'Equipo sin nombre';
    final rawState = state?.toString();
    final stateText = _estadoEquipo(rawState);
    final stateColor = _stateColor(rawState);
    final stateIcon = _stateIcon(rawState);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: const LinearGradient(
          colors: [Color(0xFF071421), Color(0xFF082846), Color(0xFF071421)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: stateColor.withValues(alpha: 0.55), width: 1),
        boxShadow: [
          BoxShadow(
            color: stateColor.withValues(alpha: 0.16),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        children: [
          Text(
            nameText.toUpperCase(),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 19,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 12),

          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: LinearGradient(
                colors: [
                  stateColor.withValues(alpha: 0.18),
                  Colors.white.withValues(alpha: 0.04),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              border: Border.all(color: stateColor.withValues(alpha: 0.32)),
            ),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: stateColor.withValues(alpha: 0.18),
                    boxShadow: [
                      BoxShadow(
                        color: stateColor.withValues(alpha: 0.2),
                        blurRadius: 18,
                      ),
                    ],
                  ),
                  child: Icon(stateIcon, color: stateColor, size: 28),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'ESTADO DEL EQUIPO',
                        style: TextStyle(
                          color: Color(0xFFB6C7D6),
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        stateText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: stateColor,
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.4,
                        ),
                      ),
                      const SizedBox(height: 3),
                      if (_stateSubtitle(rawState, blockReason).isNotEmpty)
                        Text(
                          _stateSubtitle(rawState, blockReason),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFFD2DEE8),
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _estadoEquipo(dynamic state) {
    final text = state?.toString() ?? '—';

    if (text == 'DRIP') return 'GOTEO';
    if (text == 'DEFROST') return 'DEFROST';
    if (text == 'PROTECTION') return 'PROTECCIÓN';
    if (text == 'COOLING') return 'ENFRIANDO';
    if (text == 'IDLE') return 'ESPERA';

    return text;
  }

  IconData _stateIcon(String? state) {
    if (state == 'DRIP') return Icons.water_drop_rounded;
    if (state == 'DEFROST') return Icons.ac_unit_rounded;
    if (state == 'PROTECTION') return Icons.shield_rounded;
    if (state == 'COOLING') return Icons.severe_cold_rounded;
    if (state == 'IDLE') return Icons.pause_circle_filled_rounded;
    return Icons.info_rounded;
  }

  Color _stateColor(String? state) {
    if (state == 'DRIP') return const Color(0xFF22D3EE);
    if (state == 'DEFROST') return const Color(0xFFA855F7);
    if (state == 'PROTECTION') return const Color(0xFFFFC928);
    if (state == 'COOLING') return const Color(0xFF20D76D);
    if (state == 'IDLE') return const Color(0xFF1EA7FF);
    return const Color(0xFFB6C7D6);
  }

  String _stateSubtitle(String? state, dynamic reason) {
    if (state == 'IDLE') {
      return 'Aún no se alcanza la temperatura de encendido';
    }

    return '';
  }
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({
    required this.title,
    required this.icon,
    required this.value,
    required this.suffix,
    required this.badgeText,
    required this.accent,
  });

  final String title;
  final IconData icon;
  final dynamic value;
  final String suffix;
  final String badgeText;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final textValue = _formatNumber(value);
    final inAlarm = badgeText != 'NORMAL';

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 115;

        return Container(
          padding: EdgeInsets.all(compact ? 7 : 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: const LinearGradient(
              colors: [Color(0xFF062033), Color(0xFF082B49)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            border: Border.all(color: accent.withValues(alpha: 0.65)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: accent, size: compact ? 15 : 17),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      title.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: compact ? 10 : 12,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.center,
                    child: Text.rich(
                      textAlign: TextAlign.center,
                      TextSpan(
                        children: [
                          TextSpan(
                            text: textValue,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: compact ? 32 : 38,
                              fontWeight: FontWeight.w900,
                              height: 0.9,
                            ),
                          ),
                          TextSpan(
                            text: ' $suffix',
                            style: TextStyle(
                              color: accent,
                              fontSize: compact ? 12 : 14,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 5),
              Center(
                child: _TinyPill(
                  icon: Icons.thermostat_rounded,
                  text: inAlarm ? badgeText : 'NORMAL',
                  color: inAlarm
                      ? const Color(0xFF1EA7FF)
                      : const Color(0xFF20D76D),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DefrostCard extends StatelessWidget {
  const _DefrostCard({
    required this.active,
    required this.evaporatorTemp,
    required this.chamberTemp,
    required this.endTemperature,
    required this.remainingSeconds,
    required this.nextSeconds,
    required this.durationMinutes,
    required this.intervalMinutes,
  });

  final dynamic active;
  final dynamic evaporatorTemp;
  final dynamic chamberTemp;
  final dynamic endTemperature;
  final dynamic remainingSeconds;
  final dynamic nextSeconds;
  final dynamic durationMinutes;
  final dynamic intervalMinutes;

  @override
  Widget build(BuildContext context) {
    final isActive = active == true;

    return _GlassCard(
      borderColor: const Color(0xFFA855F7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(
            icon: Icons.ac_unit_rounded,
            title: 'DEFROST',
            badge: isActive ? 'ACTIVO' : 'INACTIVO',
            color: const Color(0xFFA855F7),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _MiniMetric(
                  label: 'Temp. fin',
                  value: endTemperature,
                  suffix: '°C',
                  color: const Color(0xFFC084FC),
                  icon: Icons.thermostat_rounded,
                ),
              ),
              _VerticalDivider(),
              Expanded(
                child: _MiniMetric(
                  label: isActive ? 'Restante' : 'Próximo',
                  value: isActive ? remainingSeconds : nextSeconds,
                  suffix: 's',
                  color: const Color(0xFFC084FC),
                  icon: Icons.timer_rounded,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DripCard extends StatelessWidget {
  const _DripCard({
    required this.active,
    required this.configuredSeconds,
    required this.remainingSeconds,
  });

  final dynamic active;
  final dynamic configuredSeconds;
  final dynamic remainingSeconds;

  @override
  Widget build(BuildContext context) {
    final isActive = active == true;

    return _GlassCard(
      borderColor: const Color(0xFF00D5D5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(
            icon: Icons.water_drop_rounded,
            title: 'GOTEO',
            badge: isActive ? 'ACTIVO' : 'INACTIVO',
            color: const Color(0xFF00D5D5),
          ),
          const SizedBox(height: 8),
          Center(
            child: _MiniMetric(
              label: isActive ? 'Restante' : 'Configurado',
              value: isActive ? remainingSeconds : configuredSeconds,
              suffix: 's',
              color: const Color(0xFF22D3EE),
              icon: Icons.timer_rounded,
            ),
          ),
        ],
      ),
    );
  }
}

class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.child, required this.borderColor});

  final Widget child;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
          colors: [
            const Color(0xFF061A2E).withValues(alpha: 0.96),
            const Color(0xFF08263F).withValues(alpha: 0.96),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: borderColor.withValues(alpha: 0.65)),
        boxShadow: [
          BoxShadow(
            color: borderColor.withValues(alpha: 0.12),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.badge,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String badge;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: color, size: 13),
        const SizedBox(width: 3),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        const SizedBox(width: 3),
        Flexible(
          child: Align(
            alignment: Alignment.centerRight,
            child: _GlowBadge(text: badge, color: color),
          ),
        ),
      ],
    );
  }
}

class _GlowBadge extends StatelessWidget {
  const _GlowBadge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: 8,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _MiniMetric extends StatelessWidget {
  const _MiniMetric({
    required this.label,
    required this.value,
    required this.suffix,
    required this.color,
    this.icon,
  });

  final String label;
  final dynamic value;
  final String suffix;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final formatted = _formatNumber(value);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFFD2DEE8),
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              if (icon != null) ...[
                Icon(icon, color: color, size: 25),
                const SizedBox(width: 6),
              ],
              Text(
                formatted,
                style: TextStyle(
                  color: color,
                  fontSize: 28,
                  height: 0.95,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                suffix,
                style: TextStyle(
                  color: color,
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _VerticalDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 62,
      margin: const EdgeInsets.symmetric(horizontal: 14),
      color: Colors.white.withValues(alpha: 0.16),
    );
  }
}

String _formatNumber(dynamic value) {
  if (value == null) return '—';

  if (value is int) {
    return value.toString();
  }

  if (value is double) {
    return value.toStringAsFixed(2);
  }

  if (value is num) {
    return value.toStringAsFixed(2);
  }

  return value.toString();
}

class _MiniCompressorKpi extends StatelessWidget {
  const _MiniCompressorKpi({
    required this.relayOn,
    required this.shouldBeOn,
    required this.protectionSeconds,
  });

  final dynamic relayOn;
  final dynamic shouldBeOn;
  final dynamic protectionSeconds;

  @override
  Widget build(BuildContext context) {
    final isOn = relayOn == true;
    const accent = Color(0xFF20D76D);

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          colors: [Color(0xFF042619), Color(0xFF063D2B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: accent.withValues(alpha: 0.65)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.settings_input_component_rounded,
                color: accent,
                size: 15,
              ),
              SizedBox(width: 4),
              Expanded(
                child: Text(
                  'COMPRESOR',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 9.8,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          Expanded(
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  isOn ? 'ON' : 'OFF',
                  style: const TextStyle(
                    color: accent,
                    fontSize: 34,
                    fontWeight: FontWeight.w900,
                    height: 0.9,
                  ),
                ),
              ),
            ),
          ),
          Center(
            child: _TinyPill(
              icon: Icons.timer_rounded,
              text: 'PROT. ${protectionSeconds ?? 0}s',
              color: accent,
            ),
          ),
        ],
      ),
    );
  }
}

class _TinyPill extends StatelessWidget {
  const _TinyPill({
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 11),
          const SizedBox(width: 3),
          Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 8.5,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}
