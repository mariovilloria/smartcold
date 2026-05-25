#include <Arduino.h>

void setup()
{
  Serial.begin(115200);

  Serial.println();
  Serial.println("================================");
  Serial.println("SmartCold iniciado correctamente");
  Serial.println("ESP32 online");
  Serial.println("================================");
}

void loop()
{
  Serial.println("SmartCold ejecutandose...");
  delay(2000);
}