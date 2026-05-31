#include <Arduino.h>
#include <WiFi.h>
#include <WiFiManager.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include <OneWire.h>
#include <DallasTemperature.h>

const bool BORRAR_WIFI_AL_INICIAR = false;
unsigned long ultimoIntentoConfig = 0;
const unsigned long INTERVALO_CONFIG_MS = 60000;
// const unsigned long INTERVALO_CONFIG_MS = 15UL * 60UL * 1000UL;

unsigned long ultimoIntentoWifi = 0;
const unsigned long INTERVALO_REINTENTO_WIFI_MS = 30000;

const String DEVICE_ID = "SmartCold-5494";
const String API_BASE_URL = "http://192.168.18.8:8000";

const int PIN_ONEWIRE = 4;

OneWire oneWire(PIN_ONEWIRE);
DallasTemperature sensoresDS18B20(&oneWire);

const int MAX_SENSORES_DS18B20 = 8;
String sensoresDetectados[MAX_SENSORES_DS18B20];
int cantidadSensoresDetectados = 0;

const int MAX_SENSORES_CONFIGURADOS = 8;

struct SensorConfigurado
{
  String role;
  String address;
  float temperature;
  bool hasReading;

  bool alarmEnabled;
  float tempMinAlarm;
  float tempMaxAlarm;
  bool inAlarm;
  bool previousAlarmState;
  String alarmReason;
};

SensorConfigurado sensoresConfigurados[MAX_SENSORES_CONFIGURADOS];
int cantidadSensoresConfigurados = 0;

const bool MODO_PRUEBA_TEMPERATURA = false;
unsigned long ultimoCambioTemperaturaPrueba = 0;

bool compressorRelayOn = false;
int compressorOutputPin = 26;
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

unsigned long compressorRuntimeSinceDefrostSeconds = 0;
unsigned long lastCompressorRuntimeUpdateMillis = 0;
String configControlSensorRole = "chamber";
String configUpdatedAt = "";
float temperaturaActual = 7.0;
float temperaturaEvaporador = NAN;
String sensorCamaraAddress = "285150C0000000AB";
String sensorEvaporadorAddress = "";

bool compressorShouldBeOn = false;
bool compressorCanTurnOn = true;
int localProtectionWaitSecondsRemaining = 0;

unsigned long compressorLastOffMillis = 0;
bool localProtectionActive = false;
unsigned long localProtectionStartMillis = 0;
WiFiManager wifiManager;
float obtenerTemperaturaPorRole(String role);
Preferences preferences;

void descargarConfiguracion();

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
  doc["temperature"] = temperaturaActual;
  doc["humidity"] = 65;
  doc["rssi"] = WiFi.RSSI();
  doc["online"] = true;
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
  doc["defrost_interval_minutes"] =
      configDefrostIntervalMinutes;

  doc["defrost_duration_minutes"] =
      configDefrostDurationMinutes;

  doc["defrost_end_temperature"] =
      configDefrostEndTemperature;

  doc["defrost_end_sensor_role"] =
      configDefrostEndSensorRole;

  doc["drip_time_seconds"] =
      configDripTimeSeconds;

  if (defrostActive)
  {
    unsigned long defrostElapsed =
        (millis() - defrostStartMillis) / 1000;

    doc["defrost_elapsed_seconds"] = defrostElapsed;

    unsigned long defrostDurationSeconds =
        (unsigned long)configDefrostDurationMinutes * 60UL;

    unsigned long defrostRemaining = 0;

    if (defrostElapsed < defrostDurationSeconds)
    {
      defrostRemaining =
          defrostDurationSeconds - defrostElapsed;
    }

    doc["defrost_remaining_seconds"] = defrostRemaining;
  }
  else
  {
    doc["defrost_elapsed_seconds"] = 0;
    doc["defrost_remaining_seconds"] = 0;
  }
  doc["drip_active"] = dripActive;

  if (dripActive)
  {
    unsigned long dripElapsed = (millis() - dripStartMillis) / 1000;
    unsigned long dripRemaining = 0;

    if (dripElapsed < (unsigned long)configDripTimeSeconds)
    {
      dripRemaining = (unsigned long)configDripTimeSeconds - dripElapsed;
    }

    doc["drip_elapsed_seconds"] = dripElapsed;
    doc["drip_remaining_seconds"] = dripRemaining;
  }
  else
  {
    doc["drip_elapsed_seconds"] = 0;
    doc["drip_remaining_seconds"] = 0;
  }
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
      sensorReadings[sensoresConfigurados[i].role] = sensoresConfigurados[i].temperature;

      JsonObject alarmData = sensorAlarms[sensoresConfigurados[i].role].to<JsonObject>();
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
        sensoresConfigurados[cantidadSensoresConfigurados].role = role;
        sensoresConfigurados[cantidadSensoresConfigurados].address = address;
        sensoresConfigurados[cantidadSensoresConfigurados].temperature = NAN;
        sensoresConfigurados[cantidadSensoresConfigurados].hasReading = false;

        sensoresConfigurados[cantidadSensoresConfigurados].alarmEnabled = sensor["alarm_enabled"] | false;
        sensoresConfigurados[cantidadSensoresConfigurados].tempMinAlarm = sensor["temp_min_alarm"] | -100.0;
        sensoresConfigurados[cantidadSensoresConfigurados].tempMaxAlarm = sensor["temp_max_alarm"] | 100.0;
        sensoresConfigurados[cantidadSensoresConfigurados].inAlarm = false;
        sensoresConfigurados[cantidadSensoresConfigurados].previousAlarmState = false;
        sensoresConfigurados[cantidadSensoresConfigurados].alarmReason = "";

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

    preferences.putInt("sensor_count", cantidadSensoresConfigurados);

    for (int i = 0; i < cantidadSensoresConfigurados; i++)
    {
      String prefix = "s" + String(i) + "_";

      preferences.putString((prefix + "role").c_str(), sensoresConfigurados[i].role);
      preferences.putString((prefix + "addr").c_str(), sensoresConfigurados[i].address);
      preferences.putBool((prefix + "alm_en").c_str(), sensoresConfigurados[i].alarmEnabled);
      preferences.putFloat((prefix + "min").c_str(), sensoresConfigurados[i].tempMinAlarm);
      preferences.putFloat((prefix + "max").c_str(), sensoresConfigurados[i].tempMaxAlarm);
    }

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

  if (defrostActive || dripActive)
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

void consultarControlCompresor()
{
  if (WiFi.status() != WL_CONNECTED)
  {
    Serial.println("❌ WIFI NO CONECTADO");
    return;
  }

  HTTPClient http;
  String url = API_BASE_URL + "/api/devices/" + DEVICE_ID + "/control";

  http.begin(url);

  Serial.println();
  Serial.println("🧠 CONSULTANDO CONTROL COMPRESOR...");
  Serial.println(url);

  int httpCode = http.GET();

  if (httpCode <= 0)
  {
    Serial.print("ERROR HTTP CONTROL: ");
    Serial.println(http.errorToString(httpCode));
    http.end();
    return;
  }

  Serial.print("HTTP CONTROL CODE: ");
  Serial.println(httpCode);

  String response = http.getString();

  Serial.println("RESPUESTA CONTROL:");
  Serial.println(response);

  JsonDocument doc;
  DeserializationError error = deserializeJson(doc, response);

  if (error)
  {
    Serial.print("❌ ERROR JSON CONTROL: ");
    Serial.println(error.c_str());
    http.end();
    return;
  }

  bool compressorShouldBeOn = doc["compressor_should_be_on"] | false;
  bool compressorCanTurnOn = doc["compressor_can_turn_on"] | false;
  int waitSecondsRemaining = doc["compressor_wait_seconds_remaining"] | 0;
  compressorRelayOn = compressorShouldBeOn && compressorCanTurnOn;
  preferences.putBool("relay_on", compressorRelayOn);
  Serial.println();
  Serial.println("====== ESTADO CONTROL ======");
  Serial.print("Compresor debe encender: ");
  Serial.println(compressorShouldBeOn ? "SI" : "NO");

  Serial.print("Puede encender ahora: ");
  Serial.println(compressorCanTurnOn ? "SI" : "NO");

  Serial.print("Espera restante: ");
  Serial.print(waitSecondsRemaining);
  Serial.println(" segundos");
  Serial.println("============================");

  Serial.print("Relay compresor: ");
  Serial.println(compressorRelayOn ? "ON" : "OFF");

  http.end();
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
  sensoresDS18B20.requestTemperatures();

  int cantidadSensores = sensoresDS18B20.getDeviceCount();
  cantidadSensoresDetectados = 0;

  Serial.println();
  Serial.println("🌡️ LECTURA TEMPERATURAS DS18B20");

  DeviceAddress direccion;

  for (int i = 0; i < cantidadSensores; i++)
  {
    if (sensoresDS18B20.getAddress(direccion, i))
    {
      float tempC = sensoresDS18B20.getTempC(direccion);

      Serial.print("Sensor ");
      Serial.print(i + 1);
      Serial.print(" ");
      imprimirDireccionSensor(direccion);
      Serial.print(" = ");
      Serial.print(tempC);
      Serial.println(" °C");

      String direccionTexto = direccionSensorToString(direccion);

      if (cantidadSensoresDetectados < MAX_SENSORES_DS18B20)
      {
        sensoresDetectados[cantidadSensoresDetectados] = direccionTexto;
        cantidadSensoresDetectados++;
      }

      for (int j = 0; j < cantidadSensoresConfigurados; j++)
      {
        if (direccionTexto == sensoresConfigurados[j].address && tempC != DEVICE_DISCONNECTED_C)
        {
          sensoresConfigurados[j].temperature = tempC;
          sensoresConfigurados[j].hasReading = true;

          Serial.print("✅ Sensor por rol actualizado: ");
          Serial.print(sensoresConfigurados[j].role);
          Serial.print(" = ");
          Serial.print(tempC);
          Serial.println(" °C");
        }
      }
    }
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

    role.toLowerCase();
    address.toUpperCase();

    if (role.length() == 0 || address.length() == 0)
    {
      continue;
    }

    sensoresConfigurados[cantidadSensoresConfigurados].role = role;
    sensoresConfigurados[cantidadSensoresConfigurados].address = address;
    sensoresConfigurados[cantidadSensoresConfigurados].temperature = NAN;
    sensoresConfigurados[cantidadSensoresConfigurados].hasReading = false;

    sensoresConfigurados[cantidadSensoresConfigurados].alarmEnabled = preferences.getBool((prefix + "alm_en").c_str(), false);
    sensoresConfigurados[cantidadSensoresConfigurados].tempMinAlarm = preferences.getFloat((prefix + "min").c_str(), -100.0);
    sensoresConfigurados[cantidadSensoresConfigurados].tempMaxAlarm = preferences.getFloat((prefix + "max").c_str(), 100.0);
    sensoresConfigurados[cantidadSensoresConfigurados].inAlarm = false;
    sensoresConfigurados[cantidadSensoresConfigurados].previousAlarmState = false;
    sensoresConfigurados[cantidadSensoresConfigurados].alarmReason = "";

    cantidadSensoresConfigurados++;
  }

  Serial.print("Sensores configurados cargados desde memoria: ");
  Serial.println(cantidadSensoresConfigurados);
}

void setup()
{
  Serial.begin(115200);
  delay(1000);

  Serial.println();
  Serial.println("==========================");
  Serial.println("SMARTCOLD INICIANDO");
  Serial.println("==========================");
  detectarSensoresDS18B20();

  preferences.begin("smartcold", false);
  pinMode(compressorOutputPin, OUTPUT);
  digitalWrite(compressorOutputPin, LOW);

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
  configControlSensorRole = preferences.getString("ctrl_role", configControlSensorRole);
  sensorCamaraAddress = preferences.getString("cam_addr", sensorCamaraAddress);
  sensorEvaporadorAddress = preferences.getString("evap_addr", sensorEvaporadorAddress);

  configDefrostEnabled = preferences.getBool("def_en", configDefrostEnabled);
  configDefrostIntervalMinutes = preferences.getInt("def_int", configDefrostIntervalMinutes);
  configDefrostDurationMinutes = preferences.getInt("def_dur", configDefrostDurationMinutes);
  configDefrostEndSensorRole = preferences.getString("def_role", configDefrostEndSensorRole);
  configDefrostEndTemperature = preferences.getFloat("def_temp", configDefrostEndTemperature);
  configDripTimeSeconds = preferences.getInt("drip_sec", configDripTimeSeconds);

  Serial.print("Sensor camara configurado: ");
  Serial.println(sensorCamaraAddress);
  Serial.print("Sensor evaporador configurado: ");
  Serial.println(sensorEvaporadorAddress);
  cargarSensoresConfiguradosDesdeMemoria();
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

  String nombreAP = "SmartCold-" + String((uint32_t)ESP.getEfuseMac(), HEX);
  nombreAP = nombreAP.substring(nombreAP.length() - 4);
  nombreAP = "SmartCold-" + nombreAP;

  Serial.println("Iniciando portal WiFiManager...");
  Serial.print("Red configuracion: ");
  Serial.println(nombreAP);

  wifiManager.setConnectTimeout(30);
  wifiManager.setConfigPortalTimeout(180);

  bool conectado = wifiManager.autoConnect(nombreAP.c_str());

  if (!conectado)
  {
    Serial.println("❌ No se pudo conectar. Reiniciando...");
    delay(3000);
    ESP.restart();
  }

  Serial.println("✅ WIFI CONECTADO");
  Serial.print("SSID: ");
  Serial.println(WiFi.SSID());
  Serial.print("IP: ");
  Serial.println(WiFi.localIP());
  Serial.print("RSSI: ");
  Serial.println(WiFi.RSSI());
  descargarConfiguracion();

  leerTemperaturasDS18B20();
  evaluarAlarmasSensores();
  calcularControlCompresorLocal();
  enviarTelemetria();
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