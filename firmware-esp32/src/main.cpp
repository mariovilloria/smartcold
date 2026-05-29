#include <Arduino.h>
#include <WiFi.h>
#include <WiFiManager.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <Preferences.h>

const bool BORRAR_WIFI_AL_INICIAR = false;

const String DEVICE_ID = "SmartCold-5494";
const String API_BASE_URL = "http://192.168.18.8:8000";

bool compressorRelayOn = false;
float configSetpoint = 4.0;
float configDifferential = 2.0;
int configMinOffSeconds = 180;
String configUpdatedAt = "";

WiFiManager wifiManager;
Preferences preferences;

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
  doc["temperature"] = 3;
  doc["humidity"] = 65;
  doc["rssi"] = WiFi.RSSI();
  doc["online"] = true;
  doc["compressor_relay_on"] = compressorRelayOn;

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

  if (remoteUpdatedAt == configUpdatedAt)
  {
    Serial.println("Configuracion sin cambios. No se guarda en memoria.");
    http.end();
    return;
  }

  float newSetpoint = config["setpoint"] | configSetpoint;
  float newDifferential = config["differential"] | configDifferential;
  int newMinOffSeconds = config["compressor_min_off_seconds"] | configMinOffSeconds;

  configSetpoint = newSetpoint;
  configDifferential = newDifferential;
  configMinOffSeconds = newMinOffSeconds;
  configUpdatedAt = remoteUpdatedAt;

  preferences.putFloat("setpoint", configSetpoint);
  preferences.putFloat("diff", configDifferential);
  preferences.putInt("min_off", configMinOffSeconds);
  preferences.putString("cfg_time", configUpdatedAt);

  Serial.println("✅ Configuracion guardada en memoria local:");
  Serial.print("Setpoint: ");
  Serial.println(configSetpoint);
  Serial.print("Diferencial: ");
  Serial.println(configDifferential);
  Serial.print("Min off seconds: ");
  Serial.println(configMinOffSeconds);
  Serial.print("Updated at: ");
  Serial.println(configUpdatedAt);

  http.end();
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

void setup()
{
  Serial.begin(115200);
  delay(1000);

  Serial.println();
  Serial.println("==========================");
  Serial.println("SMARTCOLD INICIANDO");
  Serial.println("==========================");
  preferences.begin("smartcold", false);

  compressorRelayOn = preferences.getBool("relay_on", false);

  configSetpoint = preferences.getFloat("setpoint", 4.0);
  configDifferential = preferences.getFloat("diff", 2.0);
  configMinOffSeconds = preferences.getInt("min_off", 180);
  configUpdatedAt = preferences.getString("cfg_time", "");

  Serial.println("Configuracion local cargada:");
  Serial.print("Setpoint: ");
  Serial.println(configSetpoint);
  Serial.print("Diferencial: ");
  Serial.println(configDifferential);
  Serial.print("Min off seconds: ");
  Serial.println(configMinOffSeconds);
  Serial.print("Updated at: ");
  Serial.println(configUpdatedAt);
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
  enviarTelemetria();
}

void loop()
{
  enviarTelemetria();

  delay(10000);
}