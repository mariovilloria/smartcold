import 'local_esp_service.dart';

class SmartColdConnectionManager {
  static Future<Map<String, dynamic>?> readLocalDeviceInfo() async {
    return LocalEspService.getDeviceInfo();
  }

  static Future<bool> isLocalEspAvailable() async {
    final info = await LocalEspService.getDeviceInfo();
    return info != null;
  }

  static Future<bool> isLocalServiceModeActive() async {
    final info = await LocalEspService.getDeviceInfo();

    if (info == null) return false;

    final serviceMode = info['service_mode'] == true;
    final deviceMode = info['device_mode']?.toString();

    return serviceMode || deviceMode == 'SERVICE';
  }
}
