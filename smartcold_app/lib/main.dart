import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

import 'firebase_options.dart';

enum CoolingMode { refrigerate, freeze }

class CoolingProfile {
  const CoolingProfile({
    required this.mode,
    required this.level,
    required this.targetTemperature,
  });

  final CoolingMode mode;
  final int level;
  final double targetTemperature;
}

CoolingProfile getCoolingProfile({
  required CoolingMode mode,
  required int level,
}) {
  final safeLevel = level.clamp(1, 7);

  if (mode == CoolingMode.freeze) {
    const values = {
      1: -12.0,
      2: -14.0,
      3: -16.0,
      4: -18.0,
      5: -20.0,
      6: -22.0,
      7: -24.0,
    };

    return CoolingProfile(
      mode: mode,
      level: safeLevel,
      targetTemperature: values[safeLevel]!,
    );
  }

  const values = {1: 7.0, 2: 6.0, 3: 5.0, 4: 4.0, 5: 3.0, 6: 2.0, 7: 1.0};

  return CoolingProfile(
    mode: mode,
    level: safeLevel,
    targetTemperature: values[safeLevel]!,
  );
}

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

class DeviceStatusPage extends StatefulWidget {
  const DeviceStatusPage({super.key, required this.deviceId});

  final String deviceId;

  @override
  State<DeviceStatusPage> createState() => _DeviceStatusPageState();
}

class _DeviceStatusPageState extends State<DeviceStatusPage> {
  Timer? _timer;
  int? _selectedCoolingLevel;
  int? _configCoolingLevel;
  bool _dialUnlocked = false;
  int? _levelBeforeEdit;
  CoolingMode _configOperationMode = CoolingMode.refrigerate;
  String? _lastConfigAckSeen;

  @override
  void initState() {
    super.initState();
    _loadConfigSummary();

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadConfigSummary() async {
    try {
      final response = await http.get(
        Uri.parse(
          'https://smartcold-api-649501100610.us-central1.run.app/api/devices/${widget.deviceId}/config-summary',
        ),
      );

      if (response.statusCode != 200) return;

      final body = jsonDecode(response.body);

      if (body['success'] != true) return;

      if (!mounted) return;

      setState(() {
        _configCoolingLevel =
            _intFromDynamic(body['cooling_level']) ?? _configCoolingLevel;
        _configOperationMode = _coolingModeFromString(body['operation_mode']);
      });
    } catch (_) {
      // Sin bloqueo visual si la API no responde.
    }
  }

  @override
  Widget build(BuildContext context) {
    final statusRef = FirebaseFirestore.instance
        .collection('device_status')
        .doc(widget.deviceId);

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
            stream: statusRef.snapshots(),
            builder: (context, statusSnapshot) {
              if (statusSnapshot.hasError) {
                return const Center(
                  child: Text('Error leyendo estado del equipo'),
                );
              }

              if (!statusSnapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final data = statusSnapshot.data!.data();

              if (data == null) {
                return Center(
                  child: Text('No existe estado para ${widget.deviceId}'),
                );
              }

              final lastConfigAckAt = data['last_config_ack_at']?.toString();

              if (lastConfigAckAt != null &&
                  lastConfigAckAt != _lastConfigAckSeen &&
                  !_dialUnlocked) {
                _lastConfigAckSeen = lastConfigAckAt;

                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && !_dialUnlocked) {
                    _loadConfigSummary();
                  }
                });
              }

              final savedCoolingLevel = _configCoolingLevel ?? 4;

              final visibleCoolingLevel =
                  _selectedCoolingLevel ?? savedCoolingLevel;

              final operationMode = _configOperationMode;

              final coolingProfile = getCoolingProfile(
                mode: operationMode,
                level: visibleCoolingLevel,
              );

              final setpoint = coolingProfile.targetTemperature;
              const differential = 2.0;
              final turnOnTemp = setpoint + differential;
              final turnOffTemp = setpoint;

              final secondsSinceLastSeen = _secondsSinceLastSeen(
                data['last_seen_at'],
              );

              final connectionStatus = _connectionStatus(secondsSinceLastSeen);

              final lastUpdateText = _lastUpdateText(secondsSinceLastSeen);

              final chamberTemp = _sensorValue(data, 'chamber');
              final evaporatorTemp = _sensorValue(data, 'evaporator');

              return Column(
                children: [
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
                      children: [
                        _TopBar(
                          connectionStatus: connectionStatus,
                          rssi: data['rssi'],
                        ),
                        const SizedBox(height: 14),

                        _HeroPanel(
                          deviceName:
                              data['device_name'] ??
                              data['name'] ??
                              widget.deviceId,
                          health: data['device_health'],
                          healthReason: data['device_health_reason'],
                          state: data['device_state'],
                          online: connectionStatus != 'offline',
                          rssi: data['rssi'],
                          compressorOn: data['compressor_relay_on'],
                          blockReason: data['compressor_block_reason'],
                        ),

                        const SizedBox(height: 8),

                        _CoolingLevelDial(
                          level: visibleCoolingLevel,
                          setpoint: setpoint,
                          turnOnTemp: turnOnTemp,
                          turnOffTemp: turnOffTemp,
                          unlocked: _dialUnlocked,
                          onUnlockChanged: (value) {
                            setState(() {
                              if (value) {
                                _levelBeforeEdit = visibleCoolingLevel;
                                _dialUnlocked = true;
                                return;
                              }

                              _selectedCoolingLevel = null;
                              _levelBeforeEdit = null;
                              _dialUnlocked = false;
                            });
                          },
                          onLevelChanged: (newLevel) {
                            if (!_dialUnlocked) return;

                            setState(() {
                              _selectedCoolingLevel = newLevel;
                            });
                          },
                        ),

                        if (_dialUnlocked &&
                            _selectedCoolingLevel != null &&
                            _levelBeforeEdit != null &&
                            _selectedCoolingLevel != _levelBeforeEdit) ...[
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: () async {
                                final levelToSave = _selectedCoolingLevel;

                                if (levelToSave == null) return;

                                try {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Guardando ajuste...'),
                                      duration: Duration(seconds: 1),
                                    ),
                                  );

                                  final response = await http.post(
                                    Uri.parse(
                                      'https://smartcold-api-649501100610.us-central1.run.app/api/devices/${widget.deviceId}/cooling-level',
                                    ),
                                    headers: {
                                      'Content-Type': 'application/json',
                                    },
                                    body: jsonEncode({
                                      'cooling_level': levelToSave,
                                    }),
                                  );

                                  final body = jsonDecode(response.body);

                                  if (response.statusCode != 200 ||
                                      body['success'] != true) {
                                    throw Exception(
                                      body['message'] ??
                                          'No se pudo guardar el ajuste',
                                    );
                                  }

                                  if (!context.mounted) return;

                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Nivel $levelToSave guardado',
                                      ),
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                                  setState(() {
                                    _configCoolingLevel = levelToSave;
                                    _selectedCoolingLevel = null;
                                    _levelBeforeEdit = null;
                                    _dialUnlocked = false;
                                  });
                                } catch (e) {
                                  if (!context.mounted) return;

                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('Error guardando: $e'),
                                      duration: const Duration(seconds: 4),
                                    ),
                                  );
                                }
                              },
                              icon: const Icon(Icons.save_rounded),
                              label: const Text('Guardar ajuste'),
                            ),
                          ),
                        ],

                        const SizedBox(height: 18),

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
                                  badgeText: _sensorAlarmText(
                                    data,
                                    'evaporator',
                                  ),
                                  accent: const Color(0xFF21B9FF),
                                ),
                                _MiniCompressorKpi(
                                  relayOn: data['compressor_relay_on'],
                                  shouldBeOn: data['compressor_should_be_on'],
                                  protectionSeconds:
                                      data['compressor_wait_seconds_remaining'],
                                  connectionStatus: connectionStatus,
                                  secondsSinceLastSeen: secondsSinceLastSeen,
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
                              remainingSeconds:
                                  data['defrost_remaining_seconds'],
                              nextSeconds: data['defrost_next_seconds'],
                              durationMinutes: data['defrost_duration_minutes'],
                              intervalMinutes: data['defrost_interval_minutes'],
                              connectionStatus: connectionStatus,
                              secondsSinceLastSeen: secondsSinceLastSeen,
                            );

                            final dripCard = _DripCard(
                              active: data['drip_active'],
                              configuredSeconds: data['drip_time_seconds'],
                              remainingSeconds: data['drip_remaining_seconds'],
                              connectionStatus: connectionStatus,
                              secondsSinceLastSeen: secondsSinceLastSeen,
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
                    ),
                  ),

                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      lastUpdateText,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFF9DB0C1),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  static int? _secondsSinceLastSeen(dynamic value) {
    if (value == null) return null;

    DateTime? lastSeenUtc;

    if (value is Timestamp) {
      lastSeenUtc = value.toDate().toUtc();
    } else if (value is String) {
      final parsed = DateTime.tryParse(value);

      if (parsed != null) {
        lastSeenUtc = DateTime.utc(
          parsed.year,
          parsed.month,
          parsed.day,
          parsed.hour,
          parsed.minute,
          parsed.second,
          parsed.millisecond,
          parsed.microsecond,
        );
      }
    }

    if (lastSeenUtc == null) return null;

    final seconds = DateTime.now().toUtc().difference(lastSeenUtc).inSeconds;

    if (seconds < 0) return 0;

    return seconds;
  }

  static String _connectionStatus(int? seconds) {
    if (seconds == null) return 'offline';
    if (seconds <= 30) return 'online';
    if (seconds <= 90) return 'warning';
    return 'offline';
  }

  static String _lastUpdateText(int? seconds) {
    if (seconds == null) return 'Sin información de actualización';

    if (seconds < 10) return 'Actualizado';

    if (seconds < 60) {
      final roundedSeconds = (seconds ~/ 10) * 10;
      return 'Actualizado hace $roundedSeconds seg';
    }

    final minutes = seconds ~/ 60;

    if (minutes == 1) return 'Actualizado hace 1 min';
    if (minutes < 60) return 'Actualizado hace $minutes min';

    final hours = minutes ~/ 60;

    if (hours == 1) return 'Actualizado hace 1 h';

    return 'Actualizado hace $hours h';
  }

  static int? _intFromDynamic(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is double) return value.round();
    return int.tryParse(value.toString());
  }

  static CoolingMode _coolingModeFromString(dynamic value) {
    if (value?.toString() == 'freeze') {
      return CoolingMode.freeze;
    }

    return CoolingMode.refrigerate;
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
  const _TopBar({required this.connectionStatus, required this.rssi});

  final String connectionStatus;
  final dynamic rssi;

  @override
  Widget build(BuildContext context) {
    final isOnline = connectionStatus == 'online';
    final isWarning = connectionStatus == 'warning';

    final color = isOnline
        ? const Color(0xFF20D76D)
        : isWarning
        ? Colors.orangeAccent
        : Colors.redAccent;

    final label = isOnline
        ? 'ONLINE'
        : isWarning
        ? 'SIN ACTUALIZAR'
        : 'OFFLINE';

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
                Icon(Icons.circle, color: color, size: 10),
                const SizedBox(width: 5),
                Text(
                  label,
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
      margin: EdgeInsets.zero,
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
            child: Stack(
              alignment: Alignment.center,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
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
                ),

                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 56),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'ESTADO DEL EQUIPO',
                        textAlign: TextAlign.center,
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
                        textAlign: TextAlign.center,
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

class _CoolingLevelDial extends StatefulWidget {
  const _CoolingLevelDial({
    required this.level,
    required this.setpoint,
    required this.turnOnTemp,
    required this.turnOffTemp,
    required this.unlocked,
    required this.onUnlockChanged,
    required this.onLevelChanged,
  });

  final int level;
  final double setpoint;
  final double turnOnTemp;
  final double turnOffTemp;
  final bool unlocked;
  final ValueChanged<bool> onUnlockChanged;
  final ValueChanged<int> onLevelChanged;

  @override
  State<_CoolingLevelDial> createState() => _CoolingLevelDialState();
}

class _CoolingLevelDialState extends State<_CoolingLevelDial> {
  late final PageController _controller;

  @override
  void initState() {
    super.initState();
    _controller = PageController(
      initialPage: widget.level - 1,
      viewportFraction: 0.16,
    );
  }

  @override
  void didUpdateWidget(covariant _CoolingLevelDial oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.level != widget.level && _controller.hasClients) {
      _controller.animateToPage(
        widget.level - 1,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF00A8FF);

    return SizedBox(
      height: 104,
      width: double.infinity,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            top: 20,
            child: CustomPaint(painter: _EmbeddedDialPainter()),
          ),

          const Positioned(
            top: 0,
            child: Text(
              'NIVEL DE FRÍO',
              style: TextStyle(
                color: Color(0xFF9DB0C1),
                fontSize: 9,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.4,
              ),
            ),
          ),

          Positioned(
            top: 0,
            right: 0,
            child: GestureDetector(
              onTap: () {
                widget.onUnlockChanged(!widget.unlocked);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                decoration: BoxDecoration(
                  color: widget.unlocked
                      ? accent.withValues(alpha: 0.18)
                      : Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: widget.unlocked
                        ? accent.withValues(alpha: 0.45)
                        : Colors.white.withValues(alpha: 0.12),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      widget.unlocked
                          ? Icons.lock_open_rounded
                          : Icons.lock_rounded,
                      color: widget.unlocked ? accent : const Color(0xFF9DB0C1),
                      size: 11,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      widget.unlocked ? 'CANCELAR' : 'DESBLOQ',
                      style: TextStyle(
                        color: widget.unlocked
                            ? accent
                            : const Color(0xFF9DB0C1),
                        fontSize: 8,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          Positioned(
            top: 24,
            left: 0,
            right: 0,
            height: 62,
            child: PageView.builder(
              controller: _controller,
              physics: widget.unlocked
                  ? const PageScrollPhysics()
                  : const NeverScrollableScrollPhysics(),
              itemCount: 7,
              onPageChanged: (index) {
                widget.onLevelChanged(index + 1);
              },
              itemBuilder: (context, index) {
                final number = index + 1;

                return AnimatedBuilder(
                  animation: _controller,
                  builder: (context, child) {
                    double page = widget.level - 1;

                    if (_controller.hasClients &&
                        _controller.position.haveDimensions) {
                      page = _controller.page ?? page;
                    }

                    final distance = (page - index).abs().clamp(0.0, 3.0);
                    final selected = distance < 0.35;
                    final scale = selected ? 1.65 : 1.0 - (distance * 0.12);
                    final opacity = selected ? 1.0 : (0.72 - distance * 0.16);

                    return Center(
                      child: Transform.scale(
                        scale: scale.clamp(0.68, 1.65),
                        child: Text(
                          '$number',
                          style: TextStyle(
                            color: selected
                                ? Colors.white
                                : Colors.white.withValues(
                                    alpha: opacity.clamp(0.22, 0.72),
                                  ),
                            fontSize: selected ? 31 : 21,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),

          Positioned(
            top: 20,
            child: IgnorePointer(
              child: Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: accent, width: 1.35),
                  gradient: RadialGradient(
                    colors: [
                      accent.withValues(alpha: 0.16),
                      const Color(0xFF020B14).withValues(alpha: 0.18),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.28),
                      blurRadius: 18,
                    ),
                  ],
                ),
              ),
            ),
          ),

          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Row(
              children: [
                Expanded(
                  child: _InlineDialInfo(
                    label: 'ENCIENDE',
                    value: widget.turnOnTemp,
                    color: accent,
                  ),
                ),
                Expanded(
                  child: _InlineDialInfo(
                    label: 'SETPOINT',
                    value: widget.setpoint,
                    color: Colors.white,
                  ),
                ),
                Expanded(
                  child: _InlineDialInfo(
                    label: 'APAGA',
                    value: widget.turnOffTemp,
                    color: accent,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineDialInfo extends StatelessWidget {
  const _InlineDialInfo({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      textAlign: TextAlign.center,
      TextSpan(
        children: [
          TextSpan(
            text: '$label ',
            style: const TextStyle(
              color: Color(0xFF8DA1B2),
              fontSize: 7.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.3,
            ),
          ),
          TextSpan(
            text: '${value.toStringAsFixed(1)}°',
            style: TextStyle(
              color: color,
              fontSize: 10.5,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmbeddedDialPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height * 0.55;

    final glowLinePaint = Paint()
      ..color = const Color(0xFF00A8FF).withValues(alpha: 0.16)
      ..strokeWidth = 1.2;

    final softLinePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.13)
      ..strokeWidth = 1;

    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.22)
      ..style = PaintingStyle.fill;

    final topRect = Rect.fromLTWH(0, centerY - 30, size.width, 62);
    final rrect = RRect.fromRectAndRadius(topRect, const Radius.circular(60));
    canvas.drawRRect(rrect, shadowPaint);

    canvas.drawLine(
      Offset(0, centerY),
      Offset(size.width, centerY),
      glowLinePaint,
    );

    for (int i = 0; i <= 42; i++) {
      final x = size.width * i / 42;
      final major = i % 7 == 0;
      final h = major ? 24.0 : 10.0;

      canvas.drawLine(
        Offset(x, centerY - h / 2),
        Offset(x, centerY + h / 2),
        softLinePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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
    final cardAccent = inAlarm ? Colors.redAccent : accent;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 115;

        return Container(
          padding: EdgeInsets.all(compact ? 7 : 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              colors: inAlarm
                  ? const [Color(0xFF3A0710), Color(0xFF5A0B18)]
                  : const [Color(0xFF062033), Color(0xFF082B49)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            border: Border.all(color: cardAccent.withValues(alpha: 0.85)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: cardAccent, size: compact ? 15 : 17),
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
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 38,
                              fontWeight: FontWeight.w900,
                              height: 0.9,
                            ),
                          ),
                          TextSpan(
                            text: ' $suffix',
                            style: TextStyle(
                              color: cardAccent,
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
                  color: inAlarm ? Colors.redAccent : const Color(0xFF20D76D),
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
    required this.connectionStatus,
    required this.secondsSinceLastSeen,
  });

  final dynamic active;
  final dynamic evaporatorTemp;
  final dynamic chamberTemp;
  final dynamic endTemperature;
  final dynamic remainingSeconds;
  final dynamic nextSeconds;
  final dynamic durationMinutes;
  final dynamic intervalMinutes;
  final String connectionStatus;
  final int? secondsSinceLastSeen;

  @override
  Widget build(BuildContext context) {
    final isActive = active == true;

    final baseSeconds = isActive
        ? _toInt(remainingSeconds)
        : _toInt(nextSeconds);

    final elapsed = connectionStatus == 'online'
        ? (secondsSinceLastSeen ?? 0)
        : 0;

    final displaySeconds = baseSeconds == null
        ? null
        : (baseSeconds - elapsed).clamp(0, 999999);

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
                  value: displaySeconds,
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

  static int? _toInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is double) return value.round();
    return int.tryParse(value.toString());
  }
}

class _DripCard extends StatelessWidget {
  const _DripCard({
    required this.active,
    required this.configuredSeconds,
    required this.remainingSeconds,
    required this.connectionStatus,
    required this.secondsSinceLastSeen,
  });

  final dynamic active;
  final dynamic configuredSeconds;
  final dynamic remainingSeconds;
  final String connectionStatus;
  final int? secondsSinceLastSeen;

  @override
  Widget build(BuildContext context) {
    final isActive = active == true;

    final baseSeconds = isActive
        ? _toInt(remainingSeconds)
        : _toInt(configuredSeconds);

    final elapsed = connectionStatus == 'online'
        ? (secondsSinceLastSeen ?? 0)
        : 0;

    final displaySeconds = isActive
        ? (baseSeconds == null
              ? null
              : (baseSeconds - elapsed).clamp(0, 999999))
        : baseSeconds;

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
              value: displaySeconds,
              suffix: 's',
              color: const Color(0xFF22D3EE),
              icon: Icons.timer_rounded,
            ),
          ),
        ],
      ),
    );
  }

  static int? _toInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is double) return value.round();
    return int.tryParse(value.toString());
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
    required this.connectionStatus,
    required this.secondsSinceLastSeen,
  });

  final dynamic relayOn;
  final dynamic shouldBeOn;
  final dynamic protectionSeconds;
  final String connectionStatus;
  final int? secondsSinceLastSeen;

  @override
  Widget build(BuildContext context) {
    final isOn = relayOn == true;
    const accent = Color(0xFF20D76D);

    final baseSeconds = _toInt(protectionSeconds) ?? 0;

    final elapsed = connectionStatus == 'online'
        ? (secondsSinceLastSeen ?? 0)
        : 0;

    final displaySeconds = (baseSeconds - elapsed).clamp(0, 999999);

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
              text: 'PROT. ${displaySeconds}s',
              color: accent,
            ),
          ),
        ],
      ),
    );
  }

  static int? _toInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is double) return value.round();
    return int.tryParse(value.toString());
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
