import 'dart:convert';
import 'package:http/http.dart' as http;

class BackendService {
  static const String baseUrl =
      'https://smartcold-api-649501100610.us-central1.run.app';

  static Future<Map<String, dynamic>> requestServiceMode({
    required String deviceId,
    required bool serviceMode,
  }) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/api/devices/$deviceId/service-mode'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'service_mode': serviceMode}),
        )
        .timeout(const Duration(seconds: 10));

    final body = jsonDecode(response.body);

    if (response.statusCode != 200 || body['success'] != true) {
      throw Exception(body['message'] ?? 'No se pudo cambiar modo servicio');
    }

    return Map<String, dynamic>.from(body);
  }

  static Future<Map<String, dynamic>> getConfigSummary({
    required String deviceId,
  }) async {
    final response = await http
        .get(Uri.parse('$baseUrl/api/devices/$deviceId/config-summary'))
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }

    final body = jsonDecode(response.body);

    if (body['success'] != true) {
      throw Exception(body['message'] ?? 'No se pudo leer configuración');
    }

    return Map<String, dynamic>.from(body);
  }

  static Future<Map<String, dynamic>> updateCoolingLevel({
    required String deviceId,
    required int coolingLevel,
  }) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/api/devices/$deviceId/cooling-level'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'cooling_level': coolingLevel}),
        )
        .timeout(const Duration(seconds: 10));

    final body = jsonDecode(response.body);

    if (response.statusCode != 200 || body['success'] != true) {
      throw Exception(body['message'] ?? 'No se pudo guardar el ajuste');
    }

    return Map<String, dynamic>.from(body);
  }
}
