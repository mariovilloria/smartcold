#include <Arduino.h>
#include <WiFi.h>
#include <WiFiManager.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>

const bool BORRAR_WIFI_AL_INICIAR = false;

WiFiManager wifiManager;
void enviarTelemetria()
{

  if (WiFi.status() != WL_CONNECTED)
  {
    Serial.println("❌ WIFI NO CONECTADO");
    return;
  }

  HTTPClient http;

  String url = "http://192.168.18.8:8000/api/telemetry";

  http.begin(url);

  http.addHeader("Content-Type", "application/json");

  JsonDocument doc;

  doc["device_id"] = "SmartCold-5494";
  doc["temperature"] = 7;
  doc["humidity"] = 65;
  doc["rssi"] = WiFi.RSSI();
  doc["online"] = true;

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
  }
  Serial.print("HTTP CODE: ");
  Serial.println(httpCode);

  String response = http.getString();

  Serial.println("RESPUESTA:");
  Serial.println(response);

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
  enviarTelemetria();
}

void loop()
{
  delay(1000);
}