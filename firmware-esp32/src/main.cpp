#include <Arduino.h>
#include <WiFi.h>
#include <WiFiManager.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include <OneWire.h>
#include <DallasTemperature.h>

const bool BORRAR_WIFI_AL_INICIAR = false;

const String DEVICE_ID = "SmartCold-5494";
const String API_BASE_URL = "http://192.168.18.8:8000";

const int PIN_ONEWIRE = 4;

OneWire oneWire(PIN_ONEWIRE);
DallasTemperature sensoresDS18B20(&oneWire);

const int MAX_SENSORES_DS18B20 = 8;
String sensoresDetectados[MAX_SENSORES_DS18B20];
int cantidadSensoresDetectados = 0;

const bool MODO_PRUEBA_TEMPERATURA = false;
unsigned long ultimoCambioTemperaturaPrueba = 0;

bool compressorRelayOn = false;
float configSetpoint = 4.0;
float configDifferential = 2.0;
int configMinOffSeconds = 180;
String configUpdatedAt = "";
float temperaturaActual = 7.0;
String sensorCamaraAddress = "285150C0000000AB";

bool compressorShouldBeOn = false;
bool compressorCanTurnOn = true;
int localProtectionWaitSecondsRemaining = 0;

unsigned long compressorLastOffMillis = 0;
bool localProtectionActive = false;
unsigned long localProtectionStartMillis = 0;
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
  doc["temperature"] = temperaturaActual;
  doc["humidity"] = 65;
  doc["rssi"] = WiFi.RSSI();
  doc["online"] = true;
  doc["compressor_relay_on"] = compressorRelayOn;
  doc["compressor_should_be_on"] = compressorShouldBeOn;
  doc["compressor_can_turn_on"] = compressorCanTurnOn;
  doc["compressor_wait_seconds_remaining"] = localProtectionWaitSecondsRemaining;
  JsonArray detectedSensors = doc["detected_sensors"].to<JsonArray>();

  for (int i = 0; i < cantidadSensoresDetectados; i++)
  {
    detectedSensors.add(sensoresDetectados[i]);
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

  float newSetpoint = config["setpoint"] | configSetpoint;
  float newDifferential = config["differential"] | configDifferential;
  int newMinOffSeconds = config["compressor_min_off_seconds"] | configMinOffSeconds;

  String newSensorCamaraAddress = sensorCamaraAddress;

  if (config["sensor_roles"].is<JsonObject>())
  {
    JsonObject sensorRoles = config["sensor_roles"];
    newSensorCamaraAddress = sensorRoles["camara"] | sensorCamaraAddress;
  }

  bool camAddrNoGuardado = !preferences.isKey("cam_addr");

  bool configChanged = (camAddrNoGuardado ||
                        remoteUpdatedAt != configUpdatedAt ||
                        newSetpoint != configSetpoint ||
                        newDifferential != configDifferential ||
                        newMinOffSeconds != configMinOffSeconds ||
                        newSensorCamaraAddress != sensorCamaraAddress);

  if (!configChanged)
  {
    Serial.println("Configuracion sin cambios. No se guarda en memoria.");
    http.end();
    return;
  }

  configSetpoint = newSetpoint;
  configDifferential = newDifferential;
  configMinOffSeconds = newMinOffSeconds;
  configUpdatedAt = remoteUpdatedAt;
  sensorCamaraAddress = newSensorCamaraAddress;

  preferences.putFloat("setpoint", configSetpoint);
  preferences.putFloat("diff", configDifferential);
  preferences.putInt("min_off", configMinOffSeconds);
  preferences.putString("cfg_time", configUpdatedAt);
  preferences.putString("cam_addr", sensorCamaraAddress);

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

  http.end();
}
void calcularControlCompresorLocal()
{
  bool estadoAnterior = compressorRelayOn;

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

  compressorRelayOn = compressorShouldBeOn && compressorCanTurnOn;

  if (estadoAnterior && !compressorRelayOn)
  {
    compressorLastOffMillis = millis();
    localProtectionActive = true;
    localProtectionStartMillis = millis();

    preferences.putBool("prot_active", true);

    compressorCanTurnOn = false;
    localProtectionWaitSecondsRemaining = configMinOffSeconds;

    Serial.println("⚠️ Compresor apagado. Proteccion local iniciada.");
  }

  preferences.putBool("relay_on", compressorRelayOn);

  Serial.println();
  Serial.println("====== CONTROL LOCAL COMPRESOR ======");
  Serial.print("Temperatura actual: ");
  Serial.println(temperaturaActual);

  Serial.print("Setpoint: ");
  Serial.println(configSetpoint);

  Serial.print("Diferencial: ");
  Serial.println(configDifferential);

  Serial.print("Temperatura encendido: ");
  Serial.println(temperaturaEncendido);

  Serial.print("Debe encender: ");
  Serial.println(compressorShouldBeOn ? "SI" : "NO");

  Serial.print("Puede encender: ");
  Serial.println(compressorCanTurnOn ? "SI" : "NO");

  Serial.print("Espera proteccion: ");
  Serial.print(localProtectionWaitSecondsRemaining);
  Serial.println(" segundos");

  Serial.print("Relay compresor: ");
  Serial.println(compressorRelayOn ? "ON" : "OFF");
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

      if (direccionTexto == sensorCamaraAddress && tempC != DEVICE_DISCONNECTED_C)
      {
        temperaturaActual = tempC;

        Serial.print("✅ Temperatura de cámara actualizada: ");
        Serial.print(temperaturaActual);
        Serial.println(" °C");
      }
    }
  }
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

  compressorRelayOn = preferences.getBool("relay_on", false);
  localProtectionActive = true;
  localProtectionStartMillis = millis();
  preferences.putBool("prot_active", true);

  Serial.println("⚠️ Proteccion local iniciada por arranque/reinicio.");

  configSetpoint = preferences.getFloat("setpoint", 4.0);
  configDifferential = preferences.getFloat("diff", 2.0);
  configMinOffSeconds = preferences.getInt("min_off", 180);
  configUpdatedAt = preferences.getString("cfg_time", "");
  sensorCamaraAddress = preferences.getString("cam_addr", sensorCamaraAddress);

  Serial.print("Sensor camara configurado: ");
  Serial.println(sensorCamaraAddress);

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
  leerTemperaturasDS18B20();
  actualizarTemperaturaPrueba();
  calcularControlCompresorLocal();
  enviarTelemetria();

  delay(10000);
}