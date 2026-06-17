#include <Arduino.h>
#include <WiFi.h>
#include <WiFiManager.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include <OneWire.h>
#include <DallasTemperature.h>
#include <WebServer.h>
#include "nvs_flash.h"

bool tieneConfiguracionOperativa();
const bool BORRAR_WIFI_AL_INICIAR = false;
const bool BORRAR_CONFIG_SMARTCOLD_AL_INICIAR = false;
const String FIRMWARE_VERSION = "0.2.0-provisioning";
unsigned long ultimoIntentoConfig = 0;
const unsigned long INTERVALO_CONFIG_MS = 60000;
String configOperationMode = "";
int configCoolingLevel = 4;
// const unsigned long INTERVALO_CONFIG_MS = 15UL * 60UL * 1000UL;

unsigned long ultimoIntentoWifi = 0;
const unsigned long INTERVALO_REINTENTO_WIFI_MS = 30000;

String DEVICE_ID = "";
String obtenerHardwareUid()
{
  uint64_t chipid = ESP.getEfuseMac();
  char uid[13];
  snprintf(uid, sizeof(uid), "%04X%08X", (uint16_t)(chipid >> 32), (uint32_t)chipid);
  return String(uid);
}

String obtenerDeviceIdUnico()
{
  String uid = obtenerHardwareUid();

  if (uid.length() == 0)
  {
    return "SmartCold-SINUID";
  }

  return "SmartCold-" + uid;
}

String HARDWARE_UID = "";
const String API_BASE_URL = "https://smartcold-api-649501100610.us-central1.run.app";

const int PIN_ONEWIRE = 4;

// Hardware SmartCold V1
const int PIN_RELAY_COMPRESSOR = 26;
const int PIN_RELAY_DEFROST = 27;
const int PIN_RELAY_FAN = 14;
const int PIN_DOOR_INPUT = 25;
const int PIN_EXTERNAL_INPUT = 33;

OneWire oneWire(PIN_ONEWIRE);
DallasTemperature sensoresDS18B20(&oneWire);

const int MAX_SENSORES_DS18B20 = 8;
String sensoresDetectados[MAX_SENSORES_DS18B20];
int cantidadSensoresDetectados = 0;

const int MAX_SENSORES_CONFIGURADOS = 8;

struct SensorConfigurado
{
  String id;
  String role;
  String name;
  String type;

  String address;

  bool enabled;
  float offset;

  bool alarmEnabled;
  float tempMinAlarm;
  float tempMaxAlarm;
  bool canStopCompressor;

  float temperature;
  bool hasReading;

  bool inAlarm;
  bool previousAlarmState;
  String alarmReason;
};

SensorConfigurado sensoresConfigurados[MAX_SENSORES_CONFIGURADOS];
int cantidadSensoresConfigurados = 0;

const bool MODO_PRUEBA_TEMPERATURA = false;
unsigned long ultimoCambioTemperaturaPrueba = 0;

bool compressorRelayOn = false;
int compressorOutputPin = PIN_RELAY_COMPRESSOR;
float configSetpoint = 4.0;
float configDifferential = 2.0;
int configMinOffSeconds = 180;
bool configDefrostEnabled = false;
int configDefrostIntervalMinutes = 360;
int configDefrostDurationMinutes = 20;
String configDefrostEndSensorRole = "evaporator";
float configDefrostEndTemperature = 8.0;
bool defrostActive = false;
unsigned long defrostStartMillis = 0;
unsigned long lastDefrostMillis = 0;

bool dripActive = false;
unsigned long dripStartMillis = 0;
int configDripTimeSeconds = 120;

bool configFanEnabled = true;
bool configDoorInputEnabled = false;
bool configDoorNormallyClosed = true;
bool configExternalInputEnabled = false;
bool configExternalInputNormallyClosed = true;
bool configExternalInputCanStopCompressor = false;
String configExternalInputRole = "external_alarm";
String configExternalInputName = "Entrada externa";

unsigned long compressorRuntimeSinceDefrostSeconds = 0;
unsigned long lastCompressorRuntimeUpdateMillis = 0;
String configControlSensorRole = "chamber";
String configUpdatedAt = "";
float temperaturaActual = 7.0;
float temperaturaEvaporador = NAN;
String sensorCamaraAddress = "";
String sensorEvaporadorAddress = "";

bool compressorShouldBeOn = false;
bool compressorCanTurnOn = true;
int localProtectionWaitSecondsRemaining = 0;

unsigned long compressorLastOffMillis = 0;
bool localProtectionActive = false;
unsigned long localProtectionStartMillis = 0;
WiFiManager wifiManager;
WebServer servidorInstalacion(80);
bool modoInstalacionLocalActivo = false;
float obtenerTemperaturaPorRole(String role);

Preferences preferences;
String wifiPendienteSsid = "";
String wifiPendientePassword = "";
bool wifiConfiguracionPendiente = false;
String wifiEstadoSsid = "";
String wifiEstado = "idle";
String wifiUltimoError = "";
bool wifiBackendVerificado = false;
unsigned long wifiProcesarDespuesDeMs = 0;
//====================================================
// ESTADO DE INSTALACION
//====================================================

bool installationCompleted = false;

String installationStatus = "NEW";
// NEW
// INSTALLING
// COMMISSIONED

String installationSessionId = "";

String installationPhase = "pending_device";

String installerUid = "";

bool installationWifiConfigured = false;
bool installationConnectionVerified = false;
bool installationSensorsDetected = false;
bool installationSensorsAssigned = false;

String installationWifiSsid = "";

void guardarEstadoInstalacionLocal()
{
  preferences.putBool("inst_done", installationCompleted);

  preferences.putString("inst_status", installationStatus);

  preferences.putString("inst_session", installationSessionId);

  preferences.putString("installer_uid", installerUid);

  preferences.putString("inst_phase", installationPhase);

  preferences.putBool("inst_wifi_ok", installationWifiConfigured);

  preferences.putBool("inst_cloud_ok", installationConnectionVerified);

  preferences.putString("inst_ssid", installationWifiSsid);

  preferences.putBool("inst_sens_det", installationSensorsDetected);

  preferences.putBool("inst_sens_asg", installationSensorsAssigned);
}

void cargarEstadoInstalacionLocal()
{
  installationCompleted =
      preferences.getBool("inst_done", false);

  installationStatus =
      preferences.getString("inst_status", "NEW");

  installationSessionId =
      preferences.getString("inst_session", "");

  installerUid =
      preferences.getString("installer_uid", "");

  installationPhase =
      preferences.getString("inst_phase", "pending_device");

  installationWifiConfigured =
      preferences.getBool("inst_wifi_ok", false);

  installationConnectionVerified =
      preferences.getBool("inst_cloud_ok", false);

  installationWifiSsid =
      preferences.getString("inst_ssid", "");

  installationSensorsDetected =
      preferences.getBool("inst_sens_det", false);

  installationSensorsAssigned =
      preferences.getBool("inst_sens_asg", false);
}
void descargarConfiguracion();
String nombreSensorPorRole(String role);
void actualizarSensoresDetectados();
int buscarSensorConfiguradoPorAddress(String address);

String obtenerEstadoOperativo()
{
  if (defrostActive)
    return "DEFROST";

  if (dripActive)
    return "DRIP";

  if (localProtectionActive)
    return "PROTECTION";

  if (compressorRelayOn)
    return "COOLING";

  return "IDLE";
}

String obtenerMotivoBloqueoCompresor()
{
  if (compressorRelayOn)
    return "NONE";

  if (defrostActive)
    return "DEFROST";

  if (dripActive)
    return "DRIP";

  for (int i = 0; i < cantidadSensoresConfigurados; i++)
  {
    if (sensoresConfigurados[i].enabled &&
        sensoresConfigurados[i].canStopCompressor &&
        sensoresConfigurados[i].inAlarm)
    {
      return "SENSOR_PROTECTION";
    }
  }

  if (localProtectionActive)
    return "PROTECTION";

  if (!compressorShouldBeOn)
    return "TEMP_OK";

  if (!compressorCanTurnOn)
    return "BLOCKED";

  return "NONE";
}

String obtenerSaludDispositivo()
{
  bool sensorControlSinLectura =
      isnan(obtenerTemperaturaPorRole(configControlSensorRole));

  bool evaporadorSinLectura =
      isnan(obtenerTemperaturaPorRole("evaporator"));

  if (sensorControlSinLectura)
    return "CRITICAL";

  if (evaporadorSinLectura)
    return "WARNING";

  for (int i = 0; i < cantidadSensoresConfigurados; i++)
  {
    if (sensoresConfigurados[i].inAlarm)
      return "WARNING";
  }

  return "HEALTHY";
}

String obtenerMotivoSaludDispositivo()
{
  bool sensorControlSinLectura =
      isnan(obtenerTemperaturaPorRole(configControlSensorRole));

  bool evaporadorSinLectura =
      isnan(obtenerTemperaturaPorRole("evaporator"));

  if (sensorControlSinLectura)
    return "CONTROL_SENSOR_MISSING";

  if (evaporadorSinLectura)
    return "EVAPORATOR_SENSOR_MISSING";

  for (int i = 0; i < cantidadSensoresConfigurados; i++)
  {
    if (sensoresConfigurados[i].inAlarm)
    {
      return sensoresConfigurados[i].alarmReason;
    }
  }

  return "NORMAL";
}

void enviarTelemetria()
{
  if (!installationCompleted)
  {
    Serial.println("⚙️ Equipo no comisionado. Telemetria deshabilitada.");
    return;
  }

  if (WiFi.status() != WL_CONNECTED)
  {
    Serial.println("❌ WIFI NO CONECTADO");
    return;
  }

  HTTPClient http;
  String url = API_BASE_URL + "/api/telemetry";

  http.begin(url);
  http.addHeader("Content-Type", "application/json");

  JsonDocument doc;

  doc["device_id"] = DEVICE_ID;
  doc["hardware_uid"] = HARDWARE_UID;
  doc["firmware_version"] = FIRMWARE_VERSION;
  doc["rssi"] = WiFi.RSSI();
  doc["online"] = true;
  doc["configured"] = true;
  doc["provisioning_status"] = "commissioned";

  doc["temperature"] = temperaturaActual;
  doc["humidity"] = 65;

  doc["device_state"] = obtenerEstadoOperativo();
  doc["device_health"] = obtenerSaludDispositivo();
  doc["device_health_reason"] = obtenerMotivoSaludDispositivo();
  doc["compressor_block_reason"] = obtenerMotivoBloqueoCompresor();

  doc["compressor_relay_on"] = compressorRelayOn;
  doc["compressor_should_be_on"] = compressorShouldBeOn;
  doc["compressor_can_turn_on"] = compressorCanTurnOn;
  doc["compressor_wait_seconds_remaining"] = localProtectionWaitSecondsRemaining;
  doc["compressor_runtime_since_defrost_seconds"] =
      compressorRuntimeSinceDefrostSeconds;

  doc["defrost_active"] = defrostActive;
  doc["defrost_interval_minutes"] = configDefrostIntervalMinutes;
  doc["defrost_duration_minutes"] = configDefrostDurationMinutes;
  doc["defrost_end_temperature"] = configDefrostEndTemperature;
  doc["defrost_end_sensor_role"] = configDefrostEndSensorRole;
  doc["drip_time_seconds"] = configDripTimeSeconds;

  JsonArray detectedSensors = doc["detected_sensors"].to<JsonArray>();

  for (int i = 0; i < cantidadSensoresDetectados; i++)
  {
    detectedSensors.add(sensoresDetectados[i]);
  }

  JsonObject sensorReadings = doc["sensor_readings"].to<JsonObject>();
  JsonObject sensorAlarms = doc["sensor_alarms"].to<JsonObject>();

  for (int i = 0; i < cantidadSensoresConfigurados; i++)
  {
    if (sensoresConfigurados[i].hasReading)
    {
      sensorReadings[sensoresConfigurados[i].role] =
          sensoresConfigurados[i].temperature;

      JsonObject alarmData =
          sensorAlarms[sensoresConfigurados[i].role].to<JsonObject>();

      alarmData["in_alarm"] = sensoresConfigurados[i].inAlarm;
      alarmData["reason"] = sensoresConfigurados[i].alarmReason;
    }
  }

  String body;
  serializeJson(doc, body);

  Serial.println();
  Serial.println("📡 ENVIANDO TELEMETRIA...");
  Serial.println(body);

  int httpCode = http.POST(body);

  if (httpCode <= 0)
  {
    Serial.print("ERROR HTTP: ");
    Serial.println(http.errorToString(httpCode));
    http.end();
    return;
  }

  Serial.print("HTTP CODE: ");
  Serial.println(httpCode);

  String response = http.getString();

  Serial.println("RESPUESTA TELEMETRIA:");
  Serial.println(response);

  JsonDocument responseDoc;
  DeserializationError error = deserializeJson(responseDoc, response);

  if (!error)
  {
    bool configPending = responseDoc["config_pending"] | false;

    if (configPending)
    {
      Serial.println("⚙️ Configuracion pendiente detectada desde telemetria.");
      descargarConfiguracion();
    }
  }
  else
  {
    Serial.print("⚠️ No se pudo leer respuesta JSON de telemetria: ");
    Serial.println(error.c_str());
  }

  http.end();
}
bool tieneConfiguracionOperativa()
{
  return configUpdatedAt.length() > 0 &&
         cantidadSensoresConfigurados > 0 &&
         sensorCamaraAddress.length() > 0;
}

bool respuestaTieneConfiguracionOperativa(JsonObject config)
{
  if (config.isNull())
  {
    return false;
  }

  if (!config.containsKey("compressor"))
  {
    return false;
  }

  if (!config.containsKey("sensors"))
  {
    return false;
  }

  JsonArray sensors = config["sensors"].as<JsonArray>();

  if (sensors.isNull() || sensors.size() == 0)
  {
    return false;
  }

  return true;
}

void borrarConfiguracionOperativaGuardada()
{
  preferences.remove("setpoint");
  preferences.remove("diff");
  preferences.remove("min_off");
  preferences.remove("cfg_time");
  preferences.remove("ctrl_role");
  preferences.remove("cam_addr");
  preferences.remove("evap_addr");
  preferences.remove("def_en");
  preferences.remove("def_int");
  preferences.remove("def_dur");
  preferences.remove("def_role");
  preferences.remove("def_temp");
  preferences.remove("drip_sec");

  configUpdatedAt = "";
  cantidadSensoresConfigurados = 0;
  sensorCamaraAddress = "";
  sensorEvaporadorAddress = "";
  installationCompleted = false;
  installationStatus = "INSTALLING";
  installationSessionId = "";
  installerUid = "";

  installationPhase = "pending_device";

  installationWifiConfigured = false;
  installationConnectionVerified = false;
  installationWifiSsid = "";

  installationSensorsDetected = false;
  installationSensorsAssigned = false;

  guardarEstadoInstalacionLocal();
  Serial.println("🧹 Configuracion operativa local eliminada.");
}
void confirmarConfiguracionDescargada()
{
  if (WiFi.status() != WL_CONNECTED)
  {
    Serial.println("❌ WIFI NO CONECTADO - NO SE PUEDE CONFIRMAR CONFIG");
    return;
  }

  HTTPClient http;
  String url = API_BASE_URL + "/api/devices/" + DEVICE_ID + "/config/ack";

  http.begin(url);
  http.addHeader("Content-Type", "application/json");

  Serial.println();
  Serial.println("✅ CONFIRMANDO CONFIGURACION DESCARGADA...");
  Serial.println(url);

  int httpCode = http.POST("{}");

  if (httpCode <= 0)
  {
    Serial.print("ERROR HTTP ACK CONFIG: ");
    Serial.println(http.errorToString(httpCode));
    http.end();
    return;
  }

  Serial.print("HTTP ACK CONFIG CODE: ");
  Serial.println(httpCode);

  String response = http.getString();

  Serial.println("RESPUESTA ACK CONFIG:");
  Serial.println(response);

  http.end();
}
void limpiarSensorConfigurado(SensorConfigurado &sensor);
String idSensorPorRole(String role);
void guardarSensoresConfiguradosEnMemoria();
void descargarConfiguracion()
{
  if (WiFi.status() != WL_CONNECTED)
  {
    Serial.println("❌ WIFI NO CONECTADO - NO SE PUEDE DESCARGAR CONFIG");
    return;
  }

  HTTPClient http;
  String url = API_BASE_URL + "/api/devices/" + DEVICE_ID + "/config";

  http.begin(url);

  Serial.println();
  Serial.println("⚙️ DESCARGANDO CONFIGURACION...");
  Serial.println(url);

  int httpCode = http.GET();

  if (httpCode <= 0)
  {
    Serial.print("ERROR HTTP CONFIG: ");
    Serial.println(http.errorToString(httpCode));
    http.end();
    return;
  }

  Serial.print("HTTP CONFIG CODE: ");
  Serial.println(httpCode);

  String response = http.getString();

  Serial.println("RESPUESTA CONFIG:");
  Serial.println(response);

  JsonDocument doc;
  DeserializationError error = deserializeJson(doc, response);

  if (error)
  {
    Serial.print("❌ ERROR JSON CONFIG: ");
    Serial.println(error.c_str());
    http.end();
    return;
  }

  JsonObject config = doc["config"];
  bool configPending = config["config_pending"] | false;

  if (!respuestaTieneConfiguracionOperativa(config))
  {
    Serial.println("⚙️ Backend no entrego configuracion operativa completa.");
    Serial.println("Equipo permanece en modo instalacion. No se guardan parametros locales.");

    borrarConfiguracionOperativaGuardada();

    http.end();

    if (configPending)
    {
      Serial.println("⚠️ Config pendiente invalida. No se confirma ACK.");
    }

    return;
  }

  String remoteUpdatedAt = config["updated_at"] | "";

  float newSetpoint = configSetpoint;
  float newDifferential = configDifferential;
  int newMinOffSeconds = configMinOffSeconds;
  String newControlSensorRole = configControlSensorRole;
  String newSensorCamaraAddress = sensorCamaraAddress;
  String newSensorEvaporadorAddress = sensorEvaporadorAddress;

  bool newDefrostEnabled = configDefrostEnabled;
  int newDefrostIntervalMinutes = configDefrostIntervalMinutes;
  int newDefrostDurationMinutes = configDefrostDurationMinutes;
  String newDefrostEndSensorRole = configDefrostEndSensorRole;
  float newDefrostEndTemperature = configDefrostEndTemperature;
  int newDripTimeSeconds = configDripTimeSeconds;

  if (config["compressor"].is<JsonObject>())
  {
    JsonObject compressor = config["compressor"];

    newSetpoint = compressor["setpoint"] | configSetpoint;
    newDifferential = compressor["differential"] | configDifferential;
    newMinOffSeconds = compressor["min_off_seconds"] | configMinOffSeconds;
    newControlSensorRole = compressor["control_sensor_role"] | configControlSensorRole;
    newControlSensorRole.toLowerCase();
  }
  else
  {
    newSetpoint = config["setpoint"] | configSetpoint;
    newDifferential = config["differential"] | configDifferential;
    newMinOffSeconds = config["compressor_min_off_seconds"] | configMinOffSeconds;
  }

  if (config["defrost"].is<JsonObject>())
  {
    JsonObject defrost = config["defrost"];

    newDefrostEnabled = defrost["enabled"] | configDefrostEnabled;
    newDefrostIntervalMinutes = defrost["interval_minutes"] | configDefrostIntervalMinutes;
    newDefrostDurationMinutes = defrost["duration_minutes"] | configDefrostDurationMinutes;
    newDefrostEndSensorRole = String(defrost["end_sensor_role"] | configDefrostEndSensorRole);
    newDefrostEndSensorRole.toLowerCase();
    newDefrostEndTemperature = defrost["end_temperature"] | configDefrostEndTemperature;
    newDripTimeSeconds = defrost["drip_time_seconds"] | configDripTimeSeconds;
  }

  if (config["sensors"].is<JsonArray>())
  {
    JsonArray sensors = config["sensors"];
    cantidadSensoresConfigurados = 0;

    for (JsonObject sensor : sensors)
    {
      String role = sensor["role"] | "";
      String address = sensor["address"] | "";
      bool enabled = sensor["enabled"] | true;

      role.toLowerCase();
      address.toUpperCase();

      if (enabled && role.length() > 0 && address.length() > 0 && cantidadSensoresConfigurados < MAX_SENSORES_CONFIGURADOS)
      {
        limpiarSensorConfigurado(sensoresConfigurados[cantidadSensoresConfigurados]);

        sensoresConfigurados[cantidadSensoresConfigurados].id =
            String(sensor["id"] | idSensorPorRole(role));
        sensoresConfigurados[cantidadSensoresConfigurados].role = role;
        sensoresConfigurados[cantidadSensoresConfigurados].name =
            String(sensor["name"] | nombreSensorPorRole(role));
        sensoresConfigurados[cantidadSensoresConfigurados].type =
            String(sensor["type"] | "ds18b20");
        sensoresConfigurados[cantidadSensoresConfigurados].address = address;
        sensoresConfigurados[cantidadSensoresConfigurados].enabled = enabled;
        sensoresConfigurados[cantidadSensoresConfigurados].offset = sensor["offset"] | 0.0;

        sensoresConfigurados[cantidadSensoresConfigurados].alarmEnabled = sensor["alarm_enabled"] | false;
        sensoresConfigurados[cantidadSensoresConfigurados].tempMinAlarm = sensor["temp_min_alarm"] | -100.0;
        sensoresConfigurados[cantidadSensoresConfigurados].tempMaxAlarm = sensor["temp_max_alarm"] | 100.0;
        sensoresConfigurados[cantidadSensoresConfigurados].canStopCompressor = sensor["can_stop_compressor"] | false;

        cantidadSensoresConfigurados++;
      }

      if (enabled && address.length() > 0 && (role == "chamber" || role == "camara"))
      {
        newSensorCamaraAddress = address;
      }

      if (enabled && address.length() > 0 && (role == "evaporator" || role == "evaporador"))
      {
        newSensorEvaporadorAddress = address;
      }
    }

    guardarSensoresConfiguradosEnMemoria();

    Serial.print("Sensores configurados cargados: ");
    Serial.println(cantidadSensoresConfigurados);

    for (int i = 0; i < cantidadSensoresConfigurados; i++)
    {
      Serial.print("Role: ");
      Serial.print(sensoresConfigurados[i].role);
      Serial.print(" | Address: ");
      Serial.println(sensoresConfigurados[i].address);
    }
  }
  else if (config["sensor_roles"].is<JsonObject>())
  {
    JsonObject sensorRoles = config["sensor_roles"];
    newSensorCamaraAddress = sensorRoles["camara"] | sensorCamaraAddress;
    newSensorCamaraAddress.toUpperCase();
  }

  bool camAddrNoGuardado = !preferences.isKey("cam_addr");

  bool configChanged = (camAddrNoGuardado ||
                        remoteUpdatedAt != configUpdatedAt ||
                        newSetpoint != configSetpoint ||
                        newControlSensorRole != configControlSensorRole ||
                        newDifferential != configDifferential ||
                        newMinOffSeconds != configMinOffSeconds ||
                        newSensorCamaraAddress != sensorCamaraAddress ||
                        newSensorEvaporadorAddress != sensorEvaporadorAddress ||
                        newDefrostEnabled != configDefrostEnabled ||
                        newDefrostIntervalMinutes != configDefrostIntervalMinutes ||
                        newDefrostDurationMinutes != configDefrostDurationMinutes ||
                        newDefrostEndSensorRole != configDefrostEndSensorRole ||
                        newDefrostEndTemperature != configDefrostEndTemperature ||
                        newDripTimeSeconds != configDripTimeSeconds);

  if (!configChanged)
  {
    Serial.println("Configuracion sin cambios. No se guarda en memoria.");
    http.end();
    confirmarConfiguracionDescargada();
    return;
  }

  configSetpoint = newSetpoint;
  configDifferential = newDifferential;
  configMinOffSeconds = newMinOffSeconds;
  configControlSensorRole = newControlSensorRole;
  configUpdatedAt = remoteUpdatedAt;
  sensorCamaraAddress = newSensorCamaraAddress;
  sensorEvaporadorAddress = newSensorEvaporadorAddress;

  configDefrostEnabled = newDefrostEnabled;
  configDefrostIntervalMinutes = newDefrostIntervalMinutes;
  configDefrostDurationMinutes = newDefrostDurationMinutes;
  configDefrostEndSensorRole = newDefrostEndSensorRole;
  configDefrostEndTemperature = newDefrostEndTemperature;
  configDripTimeSeconds = newDripTimeSeconds;

  preferences.putFloat("setpoint", configSetpoint);
  preferences.putFloat("diff", configDifferential);
  preferences.putInt("min_off", configMinOffSeconds);
  preferences.putString("ctrl_role", configControlSensorRole);
  preferences.putString("cfg_time", configUpdatedAt);
  preferences.putString("cam_addr", sensorCamaraAddress);
  preferences.putString("evap_addr", sensorEvaporadorAddress);

  preferences.putBool("def_en", configDefrostEnabled);
  preferences.putInt("def_int", configDefrostIntervalMinutes);
  preferences.putInt("def_dur", configDefrostDurationMinutes);
  preferences.putString("def_role", configDefrostEndSensorRole);
  preferences.putFloat("def_temp", configDefrostEndTemperature);
  preferences.putInt("drip_sec", configDripTimeSeconds);

  Serial.println("✅ Configuracion guardada en memoria local:");
  Serial.print("Setpoint: ");
  Serial.println(configSetpoint);
  Serial.print("Diferencial: ");
  Serial.println(configDifferential);
  Serial.print("Min off seconds: ");
  Serial.println(configMinOffSeconds);
  Serial.print("Sensor camara: ");
  Serial.println(sensorCamaraAddress);
  Serial.print("Updated at: ");
  Serial.println(configUpdatedAt);

  Serial.println("Defrost configurado:");
  Serial.print("Enabled: ");
  Serial.println(configDefrostEnabled ? "SI" : "NO");
  Serial.print("Interval minutes: ");
  Serial.println(configDefrostIntervalMinutes);
  Serial.print("Duration minutes: ");
  Serial.println(configDefrostDurationMinutes);
  Serial.print("End sensor role: ");
  Serial.println(configDefrostEndSensorRole);
  Serial.print("End temperature: ");
  Serial.println(configDefrostEndTemperature);
  Serial.print("Drip time seconds: ");
  Serial.println(configDripTimeSeconds);

  http.end();
  confirmarConfiguracionDescargada();
}

float obtenerTemperaturaPorRole(String role)
{
  role.toLowerCase();

  for (int i = 0; i < cantidadSensoresConfigurados; i++)
  {
    if (sensoresConfigurados[i].role == role &&
        sensoresConfigurados[i].hasReading)
    {
      return sensoresConfigurados[i].temperature;
    }
  }

  return NAN;
}

void evaluarAlarmasSensores()
{
  for (int i = 0; i < cantidadSensoresConfigurados; i++)
  {
    SensorConfigurado &sensor = sensoresConfigurados[i];

    bool estadoAnterior = sensor.previousAlarmState;

    sensor.inAlarm = false;
    sensor.alarmReason = "";

    if (!sensor.alarmEnabled)
      continue;

    if (!sensor.hasReading)
      continue;

    if (sensor.temperature < sensor.tempMinAlarm)
    {
      sensor.inAlarm = true;
      sensor.alarmReason = "LOW_TEMP";
    }
    else if (sensor.temperature > sensor.tempMaxAlarm)
    {
      sensor.inAlarm = true;
      sensor.alarmReason = "HIGH_TEMP";
    }

    if (!estadoAnterior && sensor.inAlarm)
    {
      Serial.print("🚨 ALARMA ACTIVADA: ");
      Serial.print(sensor.role);
      Serial.print(" (");
      Serial.print(sensor.alarmReason);
      Serial.println(")");
    }

    if (estadoAnterior && !sensor.inAlarm)
    {
      Serial.print("✅ ALARMA RESTABLECIDA: ");
      Serial.println(sensor.role);
    }

    sensor.previousAlarmState = sensor.inAlarm;
  }
}

bool existeSensorBloqueandoCompresor()
{
  for (int i = 0; i < cantidadSensoresConfigurados; i++)
  {
    SensorConfigurado &sensor = sensoresConfigurados[i];

    if (!sensor.enabled)
      continue;

    if (!sensor.canStopCompressor)
      continue;

    if (!sensor.inAlarm)
      continue;

    Serial.print("🛑 Compresor bloqueado por sensor: ");
    Serial.print(sensor.role);
    Serial.print(" | ");
    Serial.println(sensor.alarmReason);

    return true;
  }

  return false;
}

void aplicarSalidaCompresor()
{
  digitalWrite(compressorOutputPin, compressorRelayOn ? HIGH : LOW);

  Serial.print("Salida fisica compresor GPIO ");
  Serial.print(compressorOutputPin);
  Serial.print(": ");
  Serial.println(compressorRelayOn ? "ON" : "OFF");
}

void actualizarTiempoCompresorParaDefrost()
{
  unsigned long ahora = millis();

  if (lastCompressorRuntimeUpdateMillis == 0)
  {
    lastCompressorRuntimeUpdateMillis = ahora;
    return;
  }

  unsigned long deltaMs = ahora - lastCompressorRuntimeUpdateMillis;
  lastCompressorRuntimeUpdateMillis = ahora;

  if (compressorRelayOn && !defrostActive)
  {
    compressorRuntimeSinceDefrostSeconds += deltaMs / 1000;
  }
}

void verificarInicioDefrost()
{
  if (!configDefrostEnabled)
    return;

  if (defrostActive)
    return;

  unsigned long intervaloMs =
      (unsigned long)configDefrostIntervalMinutes * 60UL * 1000UL;

  if (millis() - lastDefrostMillis >= intervaloMs)
  {
    Serial.println();
    Serial.println("❄️ INICIO DE DEFROST PROGRAMADO");

    defrostActive = true;
    defrostStartMillis = millis();
  }
}

void verificarFinDefrost()
{
  if (!defrostActive)
    return;

  unsigned long duracionMaximaMs =
      (unsigned long)configDefrostDurationMinutes * 60UL * 1000UL;

  unsigned long tiempoDefrostMs = millis() - defrostStartMillis;

  float temperaturaFin = obtenerTemperaturaPorRole(configDefrostEndSensorRole);

  if (!isnan(temperaturaFin) && temperaturaFin >= configDefrostEndTemperature)
  {
    Serial.println();
    Serial.println("✅ DEFROST FINALIZADO POR TEMPERATURA");
    Serial.print("Sensor fin: ");
    Serial.println(configDefrostEndSensorRole);
    Serial.print("Temperatura: ");
    Serial.println(temperaturaFin);

    defrostActive = false;

    dripActive = true;
    dripStartMillis = millis();

    lastDefrostMillis = millis();
    compressorRuntimeSinceDefrostSeconds = 0;

    Serial.println("💧 INICIANDO TIEMPO DE GOTEO");

    return;
  }

  if (tiempoDefrostMs >= duracionMaximaMs)
  {
    Serial.println();
    Serial.println("⚠️ DEFROST FINALIZADO POR TIEMPO MAXIMO");
    Serial.print("Duracion configurada: ");
    Serial.print(configDefrostDurationMinutes);
    Serial.println(" minutos");

    defrostActive = false;

    dripActive = true;
    dripStartMillis = millis();

    lastDefrostMillis = millis();
    compressorRuntimeSinceDefrostSeconds = 0;

    Serial.println("💧 INICIANDO TIEMPO DE GOTEO");

    return;
  }
}

void verificarFinGoteo()
{
  if (!dripActive)
    return;

  unsigned long tiempoGoteoMs =
      (unsigned long)configDripTimeSeconds * 1000UL;

  if (millis() - dripStartMillis >= tiempoGoteoMs)
  {
    dripActive = false;

    Serial.println();
    Serial.println("✅ TIEMPO DE GOTEO FINALIZADO");
  }
}

void calcularControlCompresorLocal()
{
  bool estadoAnterior = compressorRelayOn;

  float temperaturaControl = obtenerTemperaturaPorRole(configControlSensorRole);

  if (isnan(temperaturaControl))
  {
    Serial.println("❌ No hay lectura valida del sensor de control. Compresor apagado por seguridad.");

    compressorShouldBeOn = false;
    compressorRelayOn = false;
    compressorCanTurnOn = false;
    localProtectionWaitSecondsRemaining = 0;

    preferences.putBool("relay_on", false);
    aplicarSalidaCompresor();
    return;
  }

  temperaturaActual = temperaturaControl;

  float temperaturaEncendido = configSetpoint + configDifferential;

  if (temperaturaActual >= temperaturaEncendido)
  {
    compressorShouldBeOn = true;
  }
  else if (temperaturaActual <= configSetpoint)
  {
    compressorShouldBeOn = false;
  }

  compressorCanTurnOn = true;
  localProtectionWaitSecondsRemaining = 0;
  bool sensorProtectionActive = existeSensorBloqueandoCompresor();

  if (sensorProtectionActive)
  {
    compressorCanTurnOn = false;
  }
  if (localProtectionActive)
  {
    unsigned long tiempoApagado = millis() - localProtectionStartMillis;
    unsigned long tiempoProteccion = (unsigned long)configMinOffSeconds * 1000;

    if (tiempoApagado < tiempoProteccion)
    {
      compressorCanTurnOn = false;

      unsigned long restanteMs = tiempoProteccion - tiempoApagado;
      localProtectionWaitSecondsRemaining = (restanteMs + 999) / 1000;
    }
    else
    {
      localProtectionActive = false;
      localProtectionWaitSecondsRemaining = 0;
      preferences.putBool("prot_active", false);

      Serial.println("✅ Proteccion local finalizada.");
    }
  }

  if (defrostActive || dripActive || sensorProtectionActive)
  {
    compressorCanTurnOn = false;
    compressorRelayOn = false;
  }
  else
  {
    compressorRelayOn = compressorShouldBeOn && compressorCanTurnOn;
  }

  if (estadoAnterior && !compressorRelayOn)
  {
    compressorLastOffMillis = millis();
    localProtectionActive = true;
    localProtectionStartMillis = millis();

    preferences.putBool("prot_active", true);

    compressorCanTurnOn = false;
    localProtectionWaitSecondsRemaining = configMinOffSeconds;

    if (defrostActive)
    {
      Serial.println("❄️ Compresor apagado por defrost.");
    }
    else
    {
      Serial.println("⚠️ Compresor apagado. Proteccion local iniciada.");
    }
  }

  preferences.putBool("relay_on", compressorRelayOn);
  aplicarSalidaCompresor();

  Serial.println();
  Serial.println("====== ESTADO GENERAL ======");

  if (defrostActive)
  {
    Serial.println("Estado: DEFROST");
  }
  else if (dripActive)
  {
    Serial.println("Estado: GOTEO");
  }
  else if (localProtectionActive)
  {
    Serial.println("Estado: PROTECCION");
  }
  else if (compressorRelayOn)
  {
    Serial.println("Estado: ENFRIANDO");
  }
  else
  {
    Serial.println("Estado: ESPERA");
  }

  Serial.println();
  Serial.println("====== CONTROL LOCAL COMPRESOR ======");
  Serial.print("Sensor control: ");
  Serial.println(configControlSensorRole);

  Serial.print("Temperatura control: ");
  Serial.println(temperaturaControl);

  float temperaturaEvaporadorStatus = obtenerTemperaturaPorRole("evaporator");

  Serial.print("Temperatura evaporador: ");
  if (isnan(temperaturaEvaporadorStatus))
  {
    Serial.println("SIN LECTURA");
  }
  else
  {
    Serial.println(temperaturaEvaporadorStatus);
  }

  Serial.print("Setpoint: ");
  Serial.println(configSetpoint);

  Serial.print("Diferencial: ");
  Serial.println(configDifferential);

  Serial.print("Temperatura encendido: ");
  Serial.println(temperaturaEncendido);

  Serial.print("Defrost activo: ");
  Serial.println(defrostActive ? "SI" : "NO");
  Serial.print("Sensor fin defrost: ");
  Serial.println(configDefrostEndSensorRole);

  Serial.print("Temperatura fin defrost: ");
  Serial.println(configDefrostEndTemperature);

  Serial.print("Duracion maxima defrost: ");
  Serial.print(configDefrostDurationMinutes);
  Serial.println(" minutos");

  Serial.print("Tiempo goteo: ");
  Serial.print(configDripTimeSeconds);
  Serial.println(" segundos");

  Serial.print("Debe encender: ");
  Serial.println(compressorShouldBeOn ? "SI" : "NO");

  Serial.print("Puede encender: ");
  Serial.println(compressorCanTurnOn ? "SI" : "NO");

  Serial.print("Espera proteccion: ");
  Serial.print(localProtectionWaitSecondsRemaining);
  Serial.println(" segundos");

  Serial.print("Relay compresor: ");
  Serial.println(compressorRelayOn ? "ON" : "OFF");

  Serial.print("Tiempo compresor desde ultimo defrost: ");
  Serial.print(compressorRuntimeSinceDefrostSeconds);
  Serial.println(" segundos");
  if (defrostActive)
  {
    Serial.print("Defrost transcurrido: ");
    Serial.print((millis() - defrostStartMillis) / 1000);
    Serial.println(" segundos");
  }
  if (dripActive)
  {
    unsigned long dripElapsed = (millis() - dripStartMillis) / 1000;
    unsigned long dripRemaining = 0;

    if (dripElapsed < (unsigned long)configDripTimeSeconds)
    {
      dripRemaining = (unsigned long)configDripTimeSeconds - dripElapsed;
    }

    Serial.print("Goteo transcurrido: ");
    Serial.print(dripElapsed);
    Serial.println(" segundos");

    Serial.print("Goteo restante: ");
    Serial.print(dripRemaining);
    Serial.println(" segundos");
  }
  unsigned long intervaloDefrostSeg =
      (unsigned long)configDefrostIntervalMinutes * 60UL;

  unsigned long tiempoDesdeUltimoDefrostSeg =
      (millis() - lastDefrostMillis) / 1000;

  if (!defrostActive)
  {
    unsigned long restante = 0;

    if (tiempoDesdeUltimoDefrostSeg < intervaloDefrostSeg)
    {
      restante = intervaloDefrostSeg - tiempoDesdeUltimoDefrostSeg;
    }

    Serial.print("Proximo defrost en: ");
    Serial.print(restante);
    Serial.println(" segundos");
  }
  Serial.println("=====================================");
}

void actualizarTemperaturaPrueba()
{
  if (!MODO_PRUEBA_TEMPERATURA)
  {
    return;
  }

  if (millis() - ultimoCambioTemperaturaPrueba >= 30000)
  {
    ultimoCambioTemperaturaPrueba = millis();

    if (temperaturaActual >= 6.0)
    {
      temperaturaActual = 3.0;
    }
    else
    {
      temperaturaActual = 7.0;
    }

    Serial.println();
    Serial.println("🧪 MODO PRUEBA TEMPERATURA");
    Serial.print("Nueva temperatura simulada: ");
    Serial.println(temperaturaActual);
  }
}

void imprimirDireccionSensor(DeviceAddress direccion)
{
  for (uint8_t i = 0; i < 8; i++)
  {
    if (direccion[i] < 16)
    {
      Serial.print("0");
    }

    Serial.print(direccion[i], HEX);
  }
}

void detectarSensoresDS18B20()
{
  sensoresDS18B20.begin();

  int cantidadSensores = sensoresDS18B20.getDeviceCount();

  Serial.println();
  Serial.println("🌡️ DETECTANDO SENSORES DS18B20...");
  Serial.print("Sensores encontrados: ");
  Serial.println(cantidadSensores);

  DeviceAddress direccion;

  for (int i = 0; i < cantidadSensores; i++)
  {
    if (sensoresDS18B20.getAddress(direccion, i))
    {
      Serial.print("Sensor ");
      Serial.print(i + 1);
      Serial.print(" direccion: ");
      imprimirDireccionSensor(direccion);
      Serial.println();
    }
    else
    {
      Serial.print("No se pudo leer direccion del sensor ");
      Serial.println(i + 1);
    }
  }
}

String direccionSensorToString(DeviceAddress direccion)
{
  String resultado = "";

  for (uint8_t i = 0; i < 8; i++)
  {
    if (direccion[i] < 16)
    {
      resultado += "0";
    }

    resultado += String(direccion[i], HEX);
  }

  resultado.toUpperCase();
  return resultado;
}

void leerTemperaturasDS18B20()
{
  actualizarSensoresDetectados();

  Serial.println();
  Serial.println("🌡️ LECTURA TEMPERATURAS DS18B20");
  Serial.print("Sensores detectados guardados: ");
  Serial.println(cantidadSensoresDetectados);

  for (int i = 0; i < cantidadSensoresDetectados; i++)
  {
    String direccionTexto = sensoresDetectados[i];

    Serial.print("Sensor ");
    Serial.print(i + 1);
    Serial.print(" ");
    Serial.print(direccionTexto);

    int configuredIndex = buscarSensorConfiguradoPorAddress(direccionTexto);

    if (configuredIndex >= 0 && sensoresConfigurados[configuredIndex].hasReading)
    {
      Serial.print(" = ");
      Serial.print(sensoresConfigurados[configuredIndex].temperature);
      Serial.println(" °C");

      Serial.print("✅ Sensor por rol actualizado: ");
      Serial.print(sensoresConfigurados[configuredIndex].role);
      Serial.print(" = ");
      Serial.print(sensoresConfigurados[configuredIndex].temperature);
      Serial.println(" °C");
    }
    else
    {
      Serial.println(" detectado sin rol configurado o sin lectura valida.");
    }
  }
}

void limpiarSensorConfigurado(SensorConfigurado &sensor)
{
  sensor.id = "";
  sensor.role = "";
  sensor.name = "";
  sensor.type = "ds18b20";
  sensor.address = "";
  sensor.enabled = true;
  sensor.offset = 0.0;
  sensor.alarmEnabled = false;
  sensor.tempMinAlarm = -100.0;
  sensor.tempMaxAlarm = 100.0;
  sensor.canStopCompressor = false;
  sensor.temperature = NAN;
  sensor.hasReading = false;
  sensor.inAlarm = false;
  sensor.previousAlarmState = false;
  sensor.alarmReason = "";
}

bool roleSensorValido(String role)
{
  role.toLowerCase();

  return role == "chamber" ||
         role == "evaporator" ||
         role == "condenser" ||
         role == "compressor" ||
         role == "ambient" ||
         role == "aux1" ||
         role == "aux2" ||
         role == "aux3";
}

bool roleSensorDebeSerUnico(String role)
{
  role.toLowerCase();

  return role == "chamber" ||
         role == "evaporator" ||
         role == "condenser" ||
         role == "compressor" ||
         role == "ambient";
}

bool existeRoleConfigurado(String role)
{
  role.toLowerCase();

  for (int i = 0; i < cantidadSensoresConfigurados; i++)
  {
    String roleActual = sensoresConfigurados[i].role;
    roleActual.toLowerCase();

    if (roleActual == role)
    {
      return true;
    }
  }

  return false;
}

bool sensorEstaDetectado(String address)
{
  address.toUpperCase();

  for (int i = 0; i < cantidadSensoresDetectados; i++)
  {
    String detectado = sensoresDetectados[i];
    detectado.toUpperCase();

    if (detectado == address)
    {
      return true;
    }
  }

  return false;
}

void guardarSensoresConfiguradosEnMemoria()
{
  preferences.putInt("sensor_count", cantidadSensoresConfigurados);

  for (int i = 0; i < cantidadSensoresConfigurados; i++)
  {
    String prefix = "s" + String(i) + "_";

    preferences.putString((prefix + "id").c_str(), sensoresConfigurados[i].id);
    preferences.putString((prefix + "role").c_str(), sensoresConfigurados[i].role);
    preferences.putString((prefix + "name").c_str(), sensoresConfigurados[i].name);
    preferences.putString((prefix + "type").c_str(), sensoresConfigurados[i].type);
    preferences.putString((prefix + "addr").c_str(), sensoresConfigurados[i].address);

    preferences.putBool((prefix + "en").c_str(), sensoresConfigurados[i].enabled);
    preferences.putFloat((prefix + "offset").c_str(), sensoresConfigurados[i].offset);

    preferences.putBool((prefix + "alm_en").c_str(), sensoresConfigurados[i].alarmEnabled);
    preferences.putFloat((prefix + "min").c_str(), sensoresConfigurados[i].tempMinAlarm);
    preferences.putFloat((prefix + "max").c_str(), sensoresConfigurados[i].tempMaxAlarm);
    preferences.putBool((prefix + "stop").c_str(), sensoresConfigurados[i].canStopCompressor);
  }
}

void cargarSensoresConfiguradosDesdeMemoria()
{
  cantidadSensoresConfigurados = 0;

  int sensorCount = preferences.getInt("sensor_count", 0);

  for (int i = 0; i < sensorCount && i < MAX_SENSORES_CONFIGURADOS; i++)
  {
    String prefix = "s" + String(i) + "_";

    String role = preferences.getString((prefix + "role").c_str(), "");
    String address = preferences.getString((prefix + "addr").c_str(), "");
    String type = preferences.getString((prefix + "type").c_str(), "ds18b20");
    String name = preferences.getString((prefix + "name").c_str(), "");

    role.toLowerCase();
    address.toUpperCase();
    type.toLowerCase();

    if (role.length() == 0 || address.length() == 0)
    {
      continue;
    }

    limpiarSensorConfigurado(sensoresConfigurados[cantidadSensoresConfigurados]);

    sensoresConfigurados[cantidadSensoresConfigurados].id =
        preferences.getString((prefix + "id").c_str(), idSensorPorRole(role));

    sensoresConfigurados[cantidadSensoresConfigurados].role = role;
    sensoresConfigurados[cantidadSensoresConfigurados].name =
        name.length() > 0 ? name : nombreSensorPorRole(role);
    sensoresConfigurados[cantidadSensoresConfigurados].type = type;
    sensoresConfigurados[cantidadSensoresConfigurados].address = address;

    sensoresConfigurados[cantidadSensoresConfigurados].enabled =
        preferences.getBool((prefix + "en").c_str(), true);

    sensoresConfigurados[cantidadSensoresConfigurados].offset =
        preferences.getFloat((prefix + "offset").c_str(), 0.0);

    sensoresConfigurados[cantidadSensoresConfigurados].alarmEnabled =
        preferences.getBool((prefix + "alm_en").c_str(), false);

    sensoresConfigurados[cantidadSensoresConfigurados].tempMinAlarm =
        preferences.getFloat((prefix + "min").c_str(), -100.0);

    sensoresConfigurados[cantidadSensoresConfigurados].tempMaxAlarm =
        preferences.getFloat((prefix + "max").c_str(), 100.0);

    sensoresConfigurados[cantidadSensoresConfigurados].canStopCompressor =
        preferences.getBool((prefix + "stop").c_str(), false);

    cantidadSensoresConfigurados++;
  }

  Serial.print("Sensores configurados cargados desde memoria: ");
  Serial.println(cantidadSensoresConfigurados);
}

String nombreSensorPorRole(String role)
{
  role.toLowerCase();

  if (role == "chamber")
    return "Cámara";

  if (role == "evaporator")
    return "Evaporador";

  if (role == "condenser")
    return "Condensador";

  if (role == "compressor")
    return "Compresor";

  if (role == "ambient")
    return "Ambiente";

  if (role == "aux1")
    return "Auxiliar 1";

  if (role == "aux2")
    return "Auxiliar 2";

  if (role == "aux3")
    return "Auxiliar 3";

  return role;
}
String idSensorPorRole(String role)
{
  if (role == "chamber")
    return "chamber_1";
  if (role == "evaporator")
    return "evaporator_1";
  if (role == "condenser")
    return "condenser_1";
  if (role == "compressor")
    return "compressor_1";
  if (role == "ambient")
    return "ambient_1";
  if (role == "aux1")
    return "aux1";
  if (role == "aux2")
    return "aux2";
  if (role == "aux3")
    return "aux3";

  return "sensor_unknown";
}
int buscarSensorConfiguradoPorAddress(String address)
{
  address.toUpperCase();

  for (int i = 0; i < cantidadSensoresConfigurados; i++)
  {
    String configuredAddress = sensoresConfigurados[i].address;
    configuredAddress.toUpperCase();

    if (configuredAddress == address)
    {
      return i;
    }
  }

  return -1;
}

void actualizarSensoresDetectados()
{
  cantidadSensoresDetectados = 0;

  for (int i = 0; i < cantidadSensoresConfigurados; i++)
  {
    sensoresConfigurados[i].temperature = NAN;
    sensoresConfigurados[i].hasReading = false;
  }

  sensoresDS18B20.begin();
  sensoresDS18B20.requestTemperatures();

  int cantidadFisica = sensoresDS18B20.getDeviceCount();

  DeviceAddress direccion;

  for (int i = 0; i < cantidadFisica && cantidadSensoresDetectados < MAX_SENSORES_DS18B20; i++)
  {
    if (!sensoresDS18B20.getAddress(direccion, i))
    {
      continue;
    }

    String address = direccionSensorToString(direccion);
    float tempC = sensoresDS18B20.getTempC(direccion);
    bool hasReading = tempC != DEVICE_DISCONNECTED_C;

    sensoresDetectados[cantidadSensoresDetectados] = address;
    cantidadSensoresDetectados++;

    int configuredIndex = buscarSensorConfiguradoPorAddress(address);

    if (configuredIndex >= 0)
    {
      sensoresConfigurados[configuredIndex].temperature =
          hasReading ? tempC + sensoresConfigurados[configuredIndex].offset : NAN;

      sensoresConfigurados[configuredIndex].hasReading = hasReading;
    }
  }
}

void responderInstallSensors()
{
  actualizarSensoresDetectados();

  JsonDocument doc;

  doc["success"] = true;
  doc["device_id"] = DEVICE_ID;
  doc["hardware_uid"] = HARDWARE_UID;
  doc["firmware_version"] = FIRMWARE_VERSION;
  doc["installation_phase"] = installationPhase;
  doc["installation_completed"] = installationCompleted;
  doc["installation_status"] = installationStatus;
  doc["max_ds18b20_sensors"] = MAX_SENSORES_DS18B20;
  doc["configured_count"] = cantidadSensoresConfigurados;

  JsonArray sensores = doc["sensors"].to<JsonArray>();

  for (int i = 0; i < cantidadSensoresDetectados; i++)
  {
    String address = sensoresDetectados[i];

    int configuredIndex = buscarSensorConfiguradoPorAddress(address);
    bool configured = configuredIndex >= 0;

    JsonObject sensor = sensores.add<JsonObject>();
    sensor["index"] = i + 1;
    sensor["type"] = "ds18b20";
    sensor["address"] = address;
    sensor["configured"] = configured;

    if (configured)
    {
      sensor["temperature"] = sensoresConfigurados[configuredIndex].hasReading
                                  ? sensoresConfigurados[configuredIndex].temperature
                                  : 0;

      sensor["has_reading"] = sensoresConfigurados[configuredIndex].hasReading;
      sensor["id"] = sensoresConfigurados[configuredIndex].id;
      sensor["role"] = sensoresConfigurados[configuredIndex].role;
      sensor["name"] = sensoresConfigurados[configuredIndex].name;
      sensor["enabled"] = sensoresConfigurados[configuredIndex].enabled;
      sensor["offset"] = sensoresConfigurados[configuredIndex].offset;
      sensor["alarm_enabled"] = sensoresConfigurados[configuredIndex].alarmEnabled;
      sensor["temp_min_alarm"] = sensoresConfigurados[configuredIndex].tempMinAlarm;
      sensor["temp_max_alarm"] = sensoresConfigurados[configuredIndex].tempMaxAlarm;
      sensor["can_stop_compressor"] = sensoresConfigurados[configuredIndex].canStopCompressor;
    }
    else
    {
      sensor["temperature"] = 0;
      sensor["has_reading"] = true;
      sensor["id"] = "";
      sensor["role"] = "";
      sensor["name"] = "Sin asignar";
      sensor["enabled"] = false;
      sensor["offset"] = 0;
      sensor["alarm_enabled"] = false;
      sensor["temp_min_alarm"] = 0;
      sensor["temp_max_alarm"] = 0;
      sensor["can_stop_compressor"] = false;
    }
  }

  installationSensorsDetected = cantidadSensoresDetectados > 0;

  if (installationSensorsDetected &&
      (installationPhase == "pending_sensor_detection" || installationPhase == "wifi_setup"))
  {
    installationPhase = "sensors_setup";
  }

  guardarEstadoInstalacionLocal();

  doc["detected_count"] = cantidadSensoresDetectados;
  doc["sensors_detected"] = installationSensorsDetected;
  doc["sensors_assigned"] = installationSensorsAssigned;

  String respuesta;
  serializeJson(doc, respuesta);

  servidorInstalacion.send(200, "application/json", respuesta);
}

void responderGuardarInstallSensors()
{
  if (servidorInstalacion.method() != HTTP_POST)
  {
    servidorInstalacion.send(405, "application/json", "{\"success\":false,\"error\":\"METHOD_NOT_ALLOWED\"}");
    return;
  }
  // Refresca la lista física antes de validar direcciones.
  actualizarSensoresDetectados();
  JsonDocument doc;
  DeserializationError error = deserializeJson(doc, servidorInstalacion.arg("plain"));

  if (error)
  {
    servidorInstalacion.send(400, "application/json", "{\"success\":false,\"error\":\"INVALID_JSON\"}");
    return;
  }

  if (!doc["sensors"].is<JsonArray>())
  {
    servidorInstalacion.send(400, "application/json", "{\"success\":false,\"error\":\"SENSORS_ARRAY_REQUIRED\"}");
    return;
  }

  JsonArray sensors = doc["sensors"].as<JsonArray>();

  if (sensors.size() == 0)
  {
    servidorInstalacion.send(400, "application/json", "{\"success\":false,\"error\":\"AT_LEAST_ONE_SENSOR_REQUIRED\"}");
    return;
  }

  cantidadSensoresConfigurados = 0;
  sensorCamaraAddress = "";
  sensorEvaporadorAddress = "";

  for (JsonObject sensor : sensors)
  {
    if (cantidadSensoresConfigurados >= MAX_SENSORES_CONFIGURADOS)
    {
      servidorInstalacion.send(400, "application/json", "{\"success\":false,\"error\":\"MAX_SENSORS_EXCEEDED\"}");
      return;
    }

    String type = sensor["type"] | "ds18b20";
    String role = sensor["role"] | "";
    String name = sensor["name"] | "";
    String address = sensor["address"] | "";

    type.toLowerCase();
    role.toLowerCase();
    address.toUpperCase();
    name.trim();

    bool enabled = sensor["enabled"] | true;

    if (!enabled)
    {
      continue;
    }

    if (type != "ds18b20")
    {
      servidorInstalacion.send(400, "application/json", "{\"success\":false,\"error\":\"ONLY_DS18B20_SUPPORTED_IN_THIS_STEP\"}");
      return;
    }

    if (!roleSensorValido(role))
    {
      servidorInstalacion.send(400, "application/json", "{\"success\":false,\"error\":\"INVALID_SENSOR_ROLE\"}");
      return;
    }

    if (address.length() == 0)
    {
      servidorInstalacion.send(400, "application/json", "{\"success\":false,\"error\":\"ADDRESS_REQUIRED\"}");
      return;
    }

    if (!sensorEstaDetectado(address))
    {
      servidorInstalacion.send(400, "application/json", "{\"success\":false,\"error\":\"SENSOR_NOT_DETECTED\"}");
      return;
    }

    if (buscarSensorConfiguradoPorAddress(address) >= 0)
    {
      servidorInstalacion.send(400, "application/json", "{\"success\":false,\"error\":\"DUPLICATED_SENSOR_ADDRESS\"}");
      return;
    }

    if (roleSensorDebeSerUnico(role) && existeRoleConfigurado(role))
    {
      servidorInstalacion.send(400, "application/json", "{\"success\":false,\"error\":\"DUPLICATED_SENSOR_ROLE\"}");
      return;
    }

    limpiarSensorConfigurado(sensoresConfigurados[cantidadSensoresConfigurados]);

    sensoresConfigurados[cantidadSensoresConfigurados].id =
        String(sensor["id"] | idSensorPorRole(role));

    sensoresConfigurados[cantidadSensoresConfigurados].role = role;
    sensoresConfigurados[cantidadSensoresConfigurados].name =
        name.length() > 0 ? name : nombreSensorPorRole(role);
    sensoresConfigurados[cantidadSensoresConfigurados].type = type;
    sensoresConfigurados[cantidadSensoresConfigurados].address = address;

    sensoresConfigurados[cantidadSensoresConfigurados].enabled = true;
    sensoresConfigurados[cantidadSensoresConfigurados].offset = sensor["offset"] | 0.0;

    sensoresConfigurados[cantidadSensoresConfigurados].alarmEnabled =
        sensor["alarm_enabled"] | false;

    sensoresConfigurados[cantidadSensoresConfigurados].tempMinAlarm =
        sensor["temp_min_alarm"] | -100.0;

    sensoresConfigurados[cantidadSensoresConfigurados].tempMaxAlarm =
        sensor["temp_max_alarm"] | 100.0;

    sensoresConfigurados[cantidadSensoresConfigurados].canStopCompressor =
        sensor["can_stop_compressor"] | false;

    if (role == "chamber")
    {
      sensorCamaraAddress = address;
    }

    if (role == "evaporator")
    {
      sensorEvaporadorAddress = address;
    }

    cantidadSensoresConfigurados++;
  }

  if (cantidadSensoresConfigurados == 0)
  {
    servidorInstalacion.send(400, "application/json", "{\"success\":false,\"error\":\"NO_ENABLED_SENSORS\"}");
    return;
  }

  if (sensorCamaraAddress.length() == 0)
  {
    servidorInstalacion.send(400, "application/json", "{\"success\":false,\"error\":\"CHAMBER_SENSOR_REQUIRED\"}");
    return;
  }

  guardarSensoresConfiguradosEnMemoria();
  preferences.putString("cam_addr", sensorCamaraAddress);
  preferences.putString("evap_addr", sensorEvaporadorAddress);

  installationSensorsDetected = cantidadSensoresDetectados > 0;
  installationSensorsAssigned = true;
  installationPhase = "pending_initial_configuration";
  guardarEstadoInstalacionLocal();

  JsonDocument respuestaDoc;
  respuestaDoc["success"] = true;
  respuestaDoc["device_id"] = DEVICE_ID;
  respuestaDoc["installation_phase"] = installationPhase;
  respuestaDoc["installation_completed"] = installationCompleted;
  respuestaDoc["installation_status"] = installationStatus;
  respuestaDoc["configured_count"] = cantidadSensoresConfigurados;
  respuestaDoc["sensors_assigned"] = installationSensorsAssigned;

  JsonArray assigned = respuestaDoc["sensors"].to<JsonArray>();

  for (int i = 0; i < cantidadSensoresConfigurados; i++)
  {
    JsonObject item = assigned.add<JsonObject>();
    item["id"] = sensoresConfigurados[i].id;
    item["type"] = sensoresConfigurados[i].type;
    item["role"] = sensoresConfigurados[i].role;
    item["name"] = sensoresConfigurados[i].name;
    item["address"] = sensoresConfigurados[i].address;
    item["enabled"] = sensoresConfigurados[i].enabled;
    item["offset"] = sensoresConfigurados[i].offset;
    item["alarm_enabled"] = sensoresConfigurados[i].alarmEnabled;
    item["temp_min_alarm"] = sensoresConfigurados[i].tempMinAlarm;
    item["temp_max_alarm"] = sensoresConfigurados[i].tempMaxAlarm;
    item["can_stop_compressor"] = sensoresConfigurados[i].canStopCompressor;
  }

  String respuesta;
  serializeJson(respuestaDoc, respuesta);

  servidorInstalacion.send(200, "application/json", respuesta);
}

void responderDeviceInfo()
{
  leerTemperaturasDS18B20();

  JsonDocument doc;

  doc["device_id"] = DEVICE_ID;
  doc["hardware_uid"] = HARDWARE_UID;
  doc["firmware_version"] = FIRMWARE_VERSION;
  doc["installation_completed"] = installationCompleted;
  doc["installation_status"] = installationStatus;
  doc["installation_session_id"] = installationSessionId;
  doc["installer_uid"] = installerUid;
  doc["configured"] = installationCompleted;
  doc["provisioning_status"] = installationCompleted ? "configured" : "pending_installation";

  doc["installation_phase"] = installationPhase;
  doc["wifi_configured"] = installationWifiConfigured;
  doc["connection_verified"] = installationConnectionVerified;
  doc["configured_wifi_ssid"] = installationWifiSsid;
  doc["sensors_detected"] = installationSensorsDetected;
  doc["sensors_assigned"] = installationSensorsAssigned;
  doc["operation_mode"] = configOperationMode;
  doc["cooling_level"] = configCoolingLevel;
  bool parametersConfigured =
      installationPhase == "pending_finish" ||
      installationPhase == "completed" ||
      installationCompleted;

  doc["parameters_configured"] = parametersConfigured;
  doc["setpoint"] = configSetpoint;
  doc["differential"] = configDifferential;
  doc["min_off_seconds"] = configMinOffSeconds;
  doc["control_sensor_role"] = configControlSensorRole;
  doc["defrost_enabled"] = configDefrostEnabled;
  doc["defrost_active"] = defrostActive;
  doc["defrost_interval_minutes"] = configDefrostIntervalMinutes;
  doc["defrost_duration_minutes"] = configDefrostDurationMinutes;
  doc["defrost_end_sensor_role"] = configDefrostEndSensorRole;
  doc["defrost_end_temperature"] = configDefrostEndTemperature;
  doc["defrost_remaining_seconds"] = 0;
  doc["defrost_next_seconds"] = 0;

  doc["drip_active"] = dripActive;
  doc["drip_time_seconds"] = configDripTimeSeconds;
  doc["drip_remaining_seconds"] = 0;
  doc["local_installation_mode"] = modoInstalacionLocalActivo;
  doc["wifi_status"] = wifiEstado;
  doc["wifi_error"] = wifiUltimoError;
  doc["wifi_backend_verified"] = wifiBackendVerificado;
  doc["sta_ip"] = WiFi.status() == WL_CONNECTED ? WiFi.localIP().toString() : "";
  doc["ap_ip"] = WiFi.softAPIP().toString();
  doc["wifi_ssid"] = WiFi.status() == WL_CONNECTED ? WiFi.SSID() : "";

  JsonArray detectedSensors = doc["detected_sensors"].to<JsonArray>();

  for (int i = 0; i < cantidadSensoresDetectados; i++)
  {
    detectedSensors.add(sensoresDetectados[i]);
  }

  JsonArray configuredSensors = doc["configured_sensors"].to<JsonArray>();

  for (int i = 0; i < cantidadSensoresConfigurados; i++)
  {
    JsonObject sensor = configuredSensors.add<JsonObject>();

    sensor["role"] = sensoresConfigurados[i].role;
    sensor["name"] = sensoresConfigurados[i].name;
    sensor["address"] = sensoresConfigurados[i].address;
    sensor["enabled"] = sensoresConfigurados[i].enabled;
    sensor["temperature"] = sensoresConfigurados[i].temperature;
    sensor["has_reading"] = sensoresConfigurados[i].hasReading;
    sensor["alarm_enabled"] = sensoresConfigurados[i].alarmEnabled;
    sensor["temp_min_alarm"] = sensoresConfigurados[i].tempMinAlarm;
    sensor["temp_max_alarm"] = sensoresConfigurados[i].tempMaxAlarm;
    sensor["can_stop_compressor"] = sensoresConfigurados[i].canStopCompressor;
  }
  String respuesta;
  serializeJson(doc, respuesta);

  servidorInstalacion.send(200, "application/json", respuesta);
}

void restaurarModoInstalacionLocal()
{
  Serial.println("🔁 Restaurando modo instalacion local...");

  WiFi.disconnect(false);
  delay(300);

  WiFi.mode(WIFI_AP);
  delay(300);

  IPAddress localIp(192, 168, 4, 1);
  IPAddress gateway(192, 168, 4, 1);
  IPAddress subnet(255, 255, 255, 0);

  WiFi.softAPConfig(localIp, gateway, subnet);

  bool apOk = WiFi.softAP(DEVICE_ID.c_str(), nullptr, 6, false, 4);

  if (apOk)
  {
    Serial.print("✅ AP restaurado: ");
    Serial.println(WiFi.softAPSSID());
    Serial.print("IP AP: ");
    Serial.println(WiFi.softAPIP());
  }
  else
  {
    Serial.println("❌ No se pudo restaurar AP SmartCold.");
  }
}

void responderWifiScan()
{
  Serial.println("📡 Escaneando redes WiFi desde ESP...");

  WiFi.mode(WIFI_AP_STA);
  delay(300);

  int redes = WiFi.scanNetworks(false, true);

  JsonDocument doc;
  JsonArray lista = doc["networks"].to<JsonArray>();

  for (int i = 0; i < redes; i++)
  {
    String ssid = WiFi.SSID(i);

    if (ssid.length() == 0)
    {
      continue;
    }

    JsonObject red = lista.add<JsonObject>();
    red["ssid"] = ssid;
    red["rssi"] = WiFi.RSSI(i);
    red["secure"] = WiFi.encryptionType(i) != WIFI_AUTH_OPEN;
  }

  WiFi.scanDelete();

  String respuesta;
  serializeJson(doc, respuesta);

  servidorInstalacion.send(200, "application/json", respuesta);
}

void responderWifiConfigure()
{
  if (servidorInstalacion.method() != HTTP_POST)
  {
    servidorInstalacion.send(405, "application/json", "{\"success\":false,\"error\":\"METHOD_NOT_ALLOWED\"}");
    return;
  }

  JsonDocument doc;
  DeserializationError error = deserializeJson(doc, servidorInstalacion.arg("plain"));

  if (error)
  {
    servidorInstalacion.send(400, "application/json", "{\"success\":false,\"error\":\"INVALID_JSON\"}");
    return;
  }

  String ssid = doc["ssid"] | "";
  String password = doc["password"] | "";

  ssid.trim();
  password.trim();

  if (ssid.length() == 0)
  {
    servidorInstalacion.send(400, "application/json", "{\"success\":false,\"error\":\"SSID_REQUIRED\"}");
    return;
  }

  wifiPendienteSsid = ssid;
  wifiPendientePassword = password;
  wifiConfiguracionPendiente = true;
  wifiProcesarDespuesDeMs = millis() + 2000;

  wifiEstadoSsid = ssid;
  wifiEstado = "received";
  wifiUltimoError = "";
  wifiBackendVerificado = false;

  Serial.println("📶 WiFi recibido desde app SmartCold.");
  Serial.print("SSID pendiente: ");
  Serial.println(wifiPendienteSsid);

  servidorInstalacion.send(200, "application/json", "{\"success\":true,\"status\":\"wifi_received\"}");
}

void ejecutarFactoryResetCompleto()
{
  Serial.println("🧨 FACTORY RESET SMARTCOLD INICIADO");

  WiFi.disconnect(true, true);
  delay(300);

  wifiManager.resetSettings();
  delay(300);

  esp_err_t eraseResult = nvs_flash_erase();

  if (eraseResult == ESP_OK)
  {
    Serial.println("🧹 NVS borrada correctamente.");
  }
  else
  {
    Serial.print("⚠️ Error borrando NVS: ");
    Serial.println(eraseResult);
  }

  nvs_flash_init();

  Serial.println("✅ Factory reset completo. Reiniciando ESP...");
  delay(1000);

  ESP.restart();
}

void responderFactoryReset()
{
  servidorInstalacion.send(
      200,
      "application/json",
      "{\"success\":true,\"message\":\"factory_reset_started\"}");

  delay(1000);
  ejecutarFactoryResetCompleto();
}

void responderWifiStatus()
{
  JsonDocument doc;

  doc["success"] = true;
  doc["ssid"] = wifiEstadoSsid;
  doc["status"] = wifiEstado;
  doc["connected"] = WiFi.status() == WL_CONNECTED;
  doc["backend_verified"] = wifiBackendVerificado;
  doc["error"] = wifiUltimoError;
  doc["ip"] = WiFi.status() == WL_CONNECTED ? WiFi.localIP().toString() : "";
  doc["sta_ip"] = WiFi.status() == WL_CONNECTED ? WiFi.localIP().toString() : "";
  doc["ap_ip"] = WiFi.softAPIP().toString();
  doc["wifi_ssid"] = WiFi.status() == WL_CONNECTED ? WiFi.SSID() : "";
  doc["device_id"] = DEVICE_ID;
  doc["installation_completed"] = installationCompleted;
  doc["installation_status"] = installationStatus;
  doc["installation_phase"] = installationPhase;
  doc["rssi"] = WiFi.status() == WL_CONNECTED ? WiFi.RSSI() : 0;

  String respuesta;
  serializeJson(doc, respuesta);

  servidorInstalacion.send(200, "application/json", respuesta);
}

void responderGuardarOperationMode()
{
  if (servidorInstalacion.method() != HTTP_POST)
  {
    servidorInstalacion.send(405, "application/json", "{\"success\":false,\"error\":\"METHOD_NOT_ALLOWED\"}");
    return;
  }

  JsonDocument doc;
  DeserializationError error = deserializeJson(doc, servidorInstalacion.arg("plain"));

  if (error)
  {
    servidorInstalacion.send(400, "application/json", "{\"success\":false,\"error\":\"INVALID_JSON\"}");
    return;
  }

  String operationMode = doc["operation_mode"] | "";
  operationMode.toLowerCase();

  if (operationMode != "refrigerate" && operationMode != "freeze")
  {
    servidorInstalacion.send(400, "application/json", "{\"success\":false,\"error\":\"INVALID_OPERATION_MODE\"}");
    return;
  }

  configOperationMode = operationMode;
  configCoolingLevel = 4;

  if (operationMode == "freeze")
  {
    configSetpoint = -18.0;
    configDifferential = 3.0;
  }
  else
  {
    configSetpoint = 4.0;
    configDifferential = 2.0;
  }

  preferences.putString("op_mode", configOperationMode);
  preferences.putInt("cool_lvl", configCoolingLevel);
  preferences.putFloat("setpoint", configSetpoint);
  preferences.putFloat("diff", configDifferential);
  preferences.putInt("min_off", configMinOffSeconds);

  installationStatus = "INSTALLING";
  installationPhase = "pending_sensor_detection";
  guardarEstadoInstalacionLocal();

  JsonDocument respuesta;
  respuesta["success"] = true;
  respuesta["device_id"] = DEVICE_ID;
  respuesta["operation_mode"] = configOperationMode;
  respuesta["cooling_level"] = configCoolingLevel;
  respuesta["setpoint"] = configSetpoint;
  respuesta["differential"] = configDifferential;
  respuesta["installation_status"] = installationStatus;
  respuesta["installation_phase"] = installationPhase;
  respuesta["installation_completed"] = installationCompleted;

  String body;
  serializeJson(respuesta, body);

  servidorInstalacion.send(200, "application/json", body);
}

void responderGuardarInitialConfig()
{
  Serial.println();
  Serial.println("⚙️ RECIBIENDO CONFIGURACION INICIAL...");
  Serial.println(servidorInstalacion.arg("plain"));
  if (servidorInstalacion.method() != HTTP_POST)
  {
    servidorInstalacion.send(405, "application/json", "{\"success\":false,\"error\":\"METHOD_NOT_ALLOWED\"}");
    return;
  }

  JsonDocument doc;
  DeserializationError error = deserializeJson(doc, servidorInstalacion.arg("plain"));

  if (error)
  {
    servidorInstalacion.send(400, "application/json", "{\"success\":false,\"error\":\"INVALID_JSON\"}");
    return;
  }

  String operationMode = doc["operation_mode"] | configOperationMode;
  operationMode.toLowerCase();

  if (operationMode != "refrigerate" && operationMode != "freeze")
  {
    servidorInstalacion.send(400, "application/json", "{\"success\":false,\"error\":\"INVALID_OPERATION_MODE\"}");
    return;
  }

  int coolingLevel = doc["cooling_level"] | configCoolingLevel;

  if (coolingLevel < 1 || coolingLevel > 7)
  {
    servidorInstalacion.send(400, "application/json", "{\"success\":false,\"error\":\"INVALID_COOLING_LEVEL\"}");
    return;
  }

  float setpoint = doc["setpoint"] | configSetpoint;
  float differential = doc["differential"] | configDifferential;
  int minOffSeconds = doc["min_off_seconds"] | configMinOffSeconds;

  float tempMinAlarm = doc["temp_min_alarm"] | -100.0;
  float tempMaxAlarm = doc["temp_max_alarm"] | 100.0;

  configOperationMode = operationMode;
  configCoolingLevel = coolingLevel;
  configSetpoint = setpoint;
  configDifferential = differential;
  configMinOffSeconds = minOffSeconds;
  configControlSensorRole = "chamber";

  preferences.putString("op_mode", configOperationMode);
  preferences.putInt("cool_lvl", configCoolingLevel);
  preferences.putFloat("setpoint", configSetpoint);
  preferences.putFloat("diff", configDifferential);
  preferences.putInt("min_off", configMinOffSeconds);
  preferences.putString("ctrl_role", configControlSensorRole);

  for (int i = 0; i < cantidadSensoresConfigurados; i++)
  {
    if (sensoresConfigurados[i].role == "chamber")
    {
      sensoresConfigurados[i].alarmEnabled = true;
      sensoresConfigurados[i].tempMinAlarm = tempMinAlarm;
      sensoresConfigurados[i].tempMaxAlarm = tempMaxAlarm;
      sensoresConfigurados[i].canStopCompressor = true;
    }
  }

  guardarSensoresConfiguradosEnMemoria();

  installationPhase = "pending_finish";
  guardarEstadoInstalacionLocal();
  Serial.println("✅ CONFIGURACION INICIAL GUARDADA.");
  Serial.print("Operation mode: ");
  Serial.println(configOperationMode);
  Serial.print("Cooling level: ");
  Serial.println(configCoolingLevel);
  Serial.print("Setpoint: ");
  Serial.println(configSetpoint);
  Serial.print("Differential: ");
  Serial.println(configDifferential);
  Serial.print("Installation phase: ");
  Serial.println(installationPhase);
  JsonDocument respuesta;
  respuesta["success"] = true;
  respuesta["device_id"] = DEVICE_ID;
  respuesta["operation_mode"] = configOperationMode;
  respuesta["cooling_level"] = configCoolingLevel;
  respuesta["setpoint"] = configSetpoint;
  respuesta["differential"] = configDifferential;
  respuesta["min_off_seconds"] = configMinOffSeconds;
  respuesta["control_sensor_role"] = configControlSensorRole;
  respuesta["temp_min_alarm"] = tempMinAlarm;
  respuesta["temp_max_alarm"] = tempMaxAlarm;
  respuesta["installation_phase"] = installationPhase;
  respuesta["parameters_configured"] = true;

  String body;
  serializeJson(respuesta, body);

  servidorInstalacion.send(200, "application/json", body);
}

void iniciarModoInstalacionLocal()
{
  String nombreAP = DEVICE_ID;

  Serial.println("📡 Iniciando modo instalacion local SmartCold...");
  Serial.print("AP: ");
  Serial.println(nombreAP);

  WiFi.disconnect(false, false);
  delay(500);

  WiFi.mode(WIFI_AP);
  delay(500);

  IPAddress localIp(192, 168, 4, 1);
  IPAddress gateway(192, 168, 4, 1);
  IPAddress subnet(255, 255, 255, 0);

  WiFi.softAPConfig(localIp, gateway, subnet);

  bool apOk = WiFi.softAP(
      nombreAP.c_str(),
      nullptr,
      6,
      false,
      4);

  if (!apOk)
  {
    Serial.println("❌ ERROR iniciando AP SmartCold");
    return;
  }

  Serial.print("✅ AP iniciado correctamente: ");
  Serial.println(WiFi.softAPSSID());

  Serial.print("IP AP: ");
  Serial.println(WiFi.softAPIP());

  servidorInstalacion.on("/api/device-info", HTTP_GET, responderDeviceInfo);
  servidorInstalacion.on("/api/wifi/scan", HTTP_GET, responderWifiScan);
  servidorInstalacion.on("/api/wifi/configure", HTTP_POST, responderWifiConfigure);
  servidorInstalacion.on("/api/wifi/status", HTTP_GET, responderWifiStatus);
  servidorInstalacion.on("/api/install/sensors", HTTP_GET, responderInstallSensors);
  servidorInstalacion.on("/api/install/sensors", HTTP_POST, responderGuardarInstallSensors);
  servidorInstalacion.on("/api/install/operation-mode", HTTP_POST, responderGuardarOperationMode);
  servidorInstalacion.on("/api/install/initial-config", HTTP_POST, responderGuardarInitialConfig);
  servidorInstalacion.on("/api/factory-reset", HTTP_POST, responderFactoryReset);

  servidorInstalacion.begin();

  modoInstalacionLocalActivo = true;

  Serial.println("✅ API local de instalacion activa");
}

void iniciarModoInstalacionLocalConWifiCliente()
{
  String nombreAP = DEVICE_ID;

  Serial.println("📡 Iniciando AP local SmartCold sin desconectar WiFi cliente...");
  Serial.print("AP: ");
  Serial.println(nombreAP);

  WiFi.mode(WIFI_AP_STA);
  delay(500);

  IPAddress localIp(192, 168, 4, 1);
  IPAddress gateway(192, 168, 4, 1);
  IPAddress subnet(255, 255, 255, 0);

  WiFi.softAPConfig(localIp, gateway, subnet);

  bool apOk = WiFi.softAP(
      nombreAP.c_str(),
      nullptr,
      6,
      false,
      4);

  if (!apOk)
  {
    Serial.println("❌ ERROR iniciando AP SmartCold");
    return;
  }

  Serial.print("✅ AP iniciado correctamente: ");
  Serial.println(WiFi.softAPSSID());

  Serial.print("IP AP: ");
  Serial.println(WiFi.softAPIP());

  servidorInstalacion.on("/api/device-info", HTTP_GET, responderDeviceInfo);
  servidorInstalacion.on("/api/wifi/scan", HTTP_GET, responderWifiScan);
  servidorInstalacion.on("/api/wifi/configure", HTTP_POST, responderWifiConfigure);
  servidorInstalacion.on("/api/wifi/status", HTTP_GET, responderWifiStatus);
  servidorInstalacion.on("/api/install/sensors", HTTP_GET, responderInstallSensors);
  servidorInstalacion.on("/api/install/sensors", HTTP_POST, responderGuardarInstallSensors);
  servidorInstalacion.on("/api/install/operation-mode", HTTP_POST, responderGuardarOperationMode);
  servidorInstalacion.on("/api/install/initial-config", HTTP_POST, responderGuardarInitialConfig);
  servidorInstalacion.on("/api/factory-reset", HTTP_POST, responderFactoryReset);

  servidorInstalacion.begin();

  modoInstalacionLocalActivo = true;

  Serial.println("✅ API local de instalacion activa con WiFi cliente conectado");
}

void setup()
{
  Serial.begin(115200);
  delay(1000);

  Serial.println();
  Serial.println("==========================");
  Serial.println("SMARTCOLD INICIANDO");
  Serial.println("==========================");
  HARDWARE_UID = obtenerHardwareUid();
  DEVICE_ID = obtenerDeviceIdUnico();

  Serial.print("Hardware UID: ");
  Serial.println(HARDWARE_UID);

  Serial.print("Device ID unico: ");
  Serial.println(DEVICE_ID);
  detectarSensoresDS18B20();

  preferences.begin("smartcold", false);
  cargarEstadoInstalacionLocal();
  Serial.println();
  Serial.println("===== ESTADO INSTALACION =====");

  Serial.print("Status: ");
  Serial.println(installationStatus);

  Serial.print("Session: ");
  Serial.println(installationSessionId);

  Serial.print("Installer: ");
  Serial.println(installerUid);

  Serial.print("Phase: ");
  Serial.println(installationPhase);

  Serial.print("Completed: ");
  Serial.println(installationCompleted ? "SI" : "NO");

  Serial.println("==============================");
  Serial.println();
  pinMode(compressorOutputPin, OUTPUT);
  pinMode(PIN_RELAY_DEFROST, OUTPUT);
  pinMode(PIN_RELAY_FAN, OUTPUT);
  pinMode(PIN_DOOR_INPUT, INPUT_PULLUP);
  pinMode(PIN_EXTERNAL_INPUT, INPUT_PULLUP);

  digitalWrite(compressorOutputPin, LOW);
  digitalWrite(PIN_RELAY_DEFROST, LOW);
  digitalWrite(PIN_RELAY_FAN, LOW);

  compressorRelayOn = false;
  compressorShouldBeOn = false;
  compressorCanTurnOn = false;

  localProtectionActive = true;
  localProtectionStartMillis = millis();
  localProtectionWaitSecondsRemaining = configMinOffSeconds;

  lastDefrostMillis = millis();

  preferences.putBool("relay_on", false);
  preferences.putBool("prot_active", true);

  Serial.println("⚠️ Proteccion local iniciada por arranque/reinicio.");

  configSetpoint = preferences.getFloat("setpoint", 4.0);
  configDifferential = preferences.getFloat("diff", 2.0);
  configMinOffSeconds = preferences.getInt("min_off", 180);
  configUpdatedAt = preferences.getString("cfg_time", "");
  configOperationMode = preferences.getString("op_mode", "");
  configCoolingLevel = preferences.getInt("cool_lvl", 4);
  configControlSensorRole = preferences.getString("ctrl_role", configControlSensorRole);
  sensorCamaraAddress = preferences.getString("cam_addr", sensorCamaraAddress);
  sensorEvaporadorAddress = preferences.getString("evap_addr", sensorEvaporadorAddress);

  configDefrostEnabled = preferences.getBool("def_en", configDefrostEnabled);
  configDefrostIntervalMinutes = preferences.getInt("def_int", configDefrostIntervalMinutes);
  configDefrostDurationMinutes = preferences.getInt("def_dur", configDefrostDurationMinutes);
  configDefrostEndSensorRole = preferences.getString("def_role", configDefrostEndSensorRole);
  configDefrostEndTemperature = preferences.getFloat("def_temp", configDefrostEndTemperature);
  configDripTimeSeconds = preferences.getInt("drip_sec", configDripTimeSeconds);

  cargarSensoresConfiguradosDesdeMemoria();

  if (installationCompleted && !tieneConfiguracionOperativa())
  {
    Serial.println("⚠️ Equipo marcado como comisionado, pero sin configuracion operativa valida.");
    Serial.println("⚠️ Se desactiva comisionamiento y vuelve a modo instalacion.");

    installationCompleted = false;
    installationStatus = "NEW";
    installationPhase = "pending_device";
    guardarEstadoInstalacionLocal();
  }

  Serial.print("Sensor camara configurado: ");
  Serial.println(sensorCamaraAddress);
  Serial.print("Sensor evaporador configurado: ");
  Serial.println(sensorEvaporadorAddress);

  Serial.println("Configuracion local cargada:");
  Serial.print("Setpoint: ");
  Serial.println(configSetpoint);
  Serial.print("Diferencial: ");
  Serial.println(configDifferential);
  Serial.print("Min off seconds: ");
  Serial.println(configMinOffSeconds);
  Serial.print("Updated at: ");
  Serial.println(configUpdatedAt);

  Serial.println("Configuracion defrost local:");
  Serial.print("Enabled: ");
  Serial.println(configDefrostEnabled ? "SI" : "NO");

  Serial.print("Interval minutes: ");
  Serial.println(configDefrostIntervalMinutes);

  Serial.print("Duration minutes: ");
  Serial.println(configDefrostDurationMinutes);

  Serial.print("End sensor role: ");
  Serial.println(configDefrostEndSensorRole);

  Serial.print("End temperature: ");
  Serial.println(configDefrostEndTemperature);

  Serial.print("Drip time seconds: ");
  Serial.println(configDripTimeSeconds);

  Serial.print("Estado relay guardado: ");
  Serial.println(compressorRelayOn ? "ON" : "OFF");

  if (BORRAR_WIFI_AL_INICIAR)
  {
    Serial.println("🧹 BORRANDO WIFI GUARDADO");
    wifiManager.resetSettings();
  }

  Serial.println("📶 Intentando conectar con WiFi guardado...");

  WiFi.mode(WIFI_STA);
  WiFi.begin();

  unsigned long inicioWifi = millis();

  while (WiFi.status() != WL_CONNECTED && millis() - inicioWifi < 8000)
  {
    delay(500);
    Serial.print(".");
  }

  Serial.println();

  if (WiFi.status() == WL_CONNECTED)
  {
    Serial.println();
    Serial.println("✅ WIFI CONECTADO");
    Serial.print("SSID: ");
    Serial.println(WiFi.SSID());
    Serial.print("IP: ");
    Serial.println(WiFi.localIP());
    Serial.print("RSSI: ");
    Serial.println(WiFi.RSSI());

    if (installationCompleted)
    {
      descargarConfiguracion();
    }
    else
    {
      Serial.println("⚙️ Instalación pendiente.");
      Serial.println("⚙️ No se descarga configuración del backend.");
      iniciarModoInstalacionLocalConWifiCliente();
    }
  }
  else
  {
    Serial.println();
    Serial.println("⚙️ Sin WiFi guardado. Entrando en modo instalacion local.");
    iniciarModoInstalacionLocal();
  }

  if (installationCompleted)
  {
    leerTemperaturasDS18B20();
    evaluarAlarmasSensores();
    calcularControlCompresorLocal();
    enviarTelemetria();
  }
  else
  {
    aplicarSalidaCompresor();
    Serial.println("⚙️ Equipo en proceso de instalación.");
  }
}

void verificarConexionWifi()
{
  if (WiFi.status() == WL_CONNECTED)
    return;

  unsigned long ahora = millis();

  if (ahora - ultimoIntentoWifi < INTERVALO_REINTENTO_WIFI_MS)
    return;

  ultimoIntentoWifi = ahora;

  Serial.println("📶 WIFI DESCONECTADO - INTENTANDO RECONECTAR...");
  WiFi.disconnect();
  WiFi.reconnect();
}

void loop()
{
  if (modoInstalacionLocalActivo)
  {
    servidorInstalacion.handleClient();

    static unsigned long ultimaLecturaInstalacion = 0;

    if (wifiConfiguracionPendiente && millis() >= wifiProcesarDespuesDeMs)
    {
      wifiConfiguracionPendiente = false;
      wifiEstado = "connecting";
      wifiUltimoError = "";
      wifiBackendVerificado = false;

      Serial.println("📶 Procesando WiFi pendiente...");
      Serial.print("SSID: ");
      Serial.println(wifiPendienteSsid);

      WiFi.mode(WIFI_AP_STA);
      delay(500);

      WiFi.disconnect(true, false);
      delay(1000);

      WiFi.mode(WIFI_AP_STA);
      delay(500);

      WiFi.persistent(true);
      WiFi.begin(wifiPendienteSsid.c_str(), wifiPendientePassword.c_str());

      unsigned long inicioWifi = millis();

      while (WiFi.status() != WL_CONNECTED && millis() - inicioWifi < 20000)
      {
        servidorInstalacion.handleClient();
        delay(250);
        Serial.print(".");
      }

      Serial.println();

      if (WiFi.status() == WL_CONNECTED)
      {
        wifiEstado = "backend_verified";
        wifiUltimoError = "";
        wifiBackendVerificado = true;

        Serial.println("✅ WIFI CONFIGURADO DESDE APP");
        Serial.print("IP STA: ");
        Serial.println(WiFi.localIP());

        installationStatus = "INSTALLING";
        installationWifiConfigured = true;
        installationConnectionVerified = true;
        installationWifiSsid = WiFi.SSID();
        installationPhase = "pending_sensor_detection";

        guardarEstadoInstalacionLocal();
      }
      else
      {
        Serial.println("❌ No se pudo conectar al WiFi recibido desde app.");

        wifiEstado = "error";
        wifiUltimoError = "WIFI_CONNECTION_FAILED";
        wifiBackendVerificado = false;

        restaurarModoInstalacionLocal();
      }
    }

    if (millis() - ultimaLecturaInstalacion >= 30000)
    {
      ultimaLecturaInstalacion = millis();
      Serial.println("⚙️ Modo instalacion local activo. AP/API esperando app.");
    }

    delay(10);
    return;
  }

  if (!installationCompleted)
  {
    compressorRelayOn = false;
    compressorShouldBeOn = false;
    compressorCanTurnOn = false;
    defrostActive = false;
    dripActive = false;
    localProtectionActive = false;
    localProtectionWaitSecondsRemaining = 0;

    aplicarSalidaCompresor();

    Serial.println("⚙️ Instalacion pendiente. Control, telemetria y backend deshabilitados.");

    delay(10000);
    return;
  }

  leerTemperaturasDS18B20();
  evaluarAlarmasSensores();

  verificarInicioDefrost();
  verificarFinDefrost();
  verificarFinGoteo();

  actualizarTemperaturaPrueba();
  calcularControlCompresorLocal();
  actualizarTiempoCompresorParaDefrost();

  verificarConexionWifi();

  enviarTelemetria();

  if (millis() - ultimoIntentoConfig >= INTERVALO_CONFIG_MS)
  {
    ultimoIntentoConfig = millis();
    descargarConfiguracion();
  }

  delay(10000);
}