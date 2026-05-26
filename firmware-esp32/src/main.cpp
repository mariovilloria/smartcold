#include <Arduino.h>
#include <WiFi.h>
#include <WiFiManager.h>

const bool BORRAR_WIFI_AL_INICIAR = false;

WiFiManager wifiManager;

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
}

void loop()
{
  delay(1000);
}