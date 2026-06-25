import 'dart:convert';
import 'package:http/http.dart' as http;

class LocalEspService {
  static const String baseUrl = 'http://192.168.4.1';

  static Future<bool> finishServiceMode() async {
    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl/api/service/finish'),
            headers: {'Content-Type': 'application/json'},
          )
          .timeout(const Duration(seconds: 4));

      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, dynamic>?> getDeviceInfo() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/api/device-info'))
          .timeout(const Duration(milliseconds: 1500));

      if (response.statusCode != 200) {
        return null;
      }

      final body = jsonDecode(response.body);

      if (body is Map) {
        return Map<String, dynamic>.from(body);
      }

      return null;
    } catch (_) {
      return null;
    }
  }
}
