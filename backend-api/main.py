from fastapi import FastAPI
from pydantic import BaseModel
from datetime import datetime, timedelta
from typing import Dict, List, Optional
import firebase_admin
from firebase_admin import credentials, firestore

app = FastAPI(title="SmartCold API")

# =====================================
# FIREBASE
# =====================================

cred = credentials.Certificate("firebase-key.json")
firebase_admin.initialize_app(cred)

db = firestore.client()

# =====================================
# CONFIGURACION ONLINE/OFFLINE
# =====================================

OFFLINE_WARNING_SECONDS = 120
OFFLINE_REAL_SECONDS = 300
HISTORY_INTERVAL_SECONDS = 300

# =====================================
# BASE TEMPORAL EN MEMORIA
# =====================================

devices_db: Dict[str, dict] = {}

# =====================================
# MODELO TELEMETRIA
# =====================================


class TelemetryData(BaseModel):
    device_id: str
    compressor_relay_on: bool | None = None
    temperature: float
    humidity: float
    rssi: int
    online: bool


# =====================================
# MODELO DEVICE
# =====================================


class DeviceRegister(BaseModel):
    device_id: str
    client_name: str
    store_name: str
    equipment_name: str


# =====================================
# MODELO CLIENTE
# =====================================


class ClientCreate(BaseModel):
    name: str
    cedula_ruc: str
    phone: str | None = None
    email: str | None = None


# =====================================
# MODELO TIENDA
# =====================================


class StoreCreate(BaseModel):
    client_id: str
    name: str
    address: str | None = None


# =====================================
# MODELO DISPOSITIVO
# =====================================


class DeviceCreate(BaseModel):
    device_id: str
    client_id: str
    store_id: str
    name: str
    type: str


# =====================================
# MODELO CONFIGURACION DISPOSITIVO
# =====================================


class SensorConfig(BaseModel):
    id: str
    role: str
    name: str
    type: str
    bus: str
    pin: Optional[int] = None
    address: Optional[str] = None
    enabled: bool = True
    offset: float = 0
    alarm_enabled: bool = True
    temp_min_alarm: Optional[float] = None
    temp_max_alarm: Optional[float] = None
    can_stop_compressor: bool = False


class CompressorConfig(BaseModel):
    enabled: bool = True
    control_sensor_role: str = "chamber"
    setpoint: float = 4
    differential: float = 2
    min_off_seconds: int = 180


class DeviceConfigUpdate(BaseModel):
    compressor: CompressorConfig
    sensors: List[SensorConfig]


# =====================================
# RUTAS BASICAS
# =====================================


@app.get("/")
def home():
    return {"app": "SmartCold API", "status": "ok"}


@app.get("/health")
def health():
    return {"status": "healthy"}


# =====================================
# TELEMETRIA
# =====================================


@app.post("/api/telemetry")
def receive_telemetry(data: TelemetryData):

    print("\n==============================")
    print("NUEVA TELEMETRIA")
    print("==============================")
    print("Device:", data.device_id)
    print("Compressor relay on:", data.compressor_relay_on)
    print("Temp:", data.temperature)
    print("Humidity:", data.humidity)
    print("RSSI:", data.rssi)
    print("Online:", data.online)
    print("Timestamp:", datetime.now())

    now = datetime.now()
    now_iso = now.isoformat()

    config_doc = db.collection("device_config").document(data.device_id).get()
    config = config_doc.to_dict() if config_doc.exists else {}

    status_doc = db.collection("device_status").document(data.device_id).get()
    current_status = status_doc.to_dict() if status_doc.exists else {}

    alarm = False
    alarm_reason = None

    if config.get("alarm_enabled", False):
        temp_min = config.get("temp_min_alarm")
        temp_max = config.get("temp_max_alarm")

        if temp_min is not None and data.temperature < temp_min:
            alarm = True
            alarm_reason = "TEMP_LOW"

        if temp_max is not None and data.temperature > temp_max:
            alarm = True
            alarm_reason = "TEMP_HIGH"

    previous_compressor_state = current_status.get("compressor_should_be_on", False)

    compressor_should_be_on = previous_compressor_state
    compressor_last_off_at = current_status.get("compressor_last_off_at")
    compressor_can_turn_on = True
    compressor_wait_seconds_remaining = 0

    if compressor_last_off_at:
        last_off_dt = datetime.fromisoformat(compressor_last_off_at)
        seconds_since_last_off = int((now - last_off_dt).total_seconds())

        min_off_seconds = config.get("compressor_min_off_seconds", 180)

        if seconds_since_last_off < min_off_seconds:
            compressor_can_turn_on = False
            compressor_wait_seconds_remaining = min_off_seconds - seconds_since_last_off

    if config.get("compressor_control_enabled", False):
        setpoint = config.get("setpoint")
        differential = config.get("differential")

        if setpoint is not None and differential is not None:
            turn_on_temp = setpoint + differential

            if data.temperature >= turn_on_temp:
                compressor_should_be_on = True

            elif data.temperature <= setpoint:
                compressor_should_be_on = False
    else:
        compressor_should_be_on = False

    compressor_turned_off_now = (
        previous_compressor_state is True and compressor_should_be_on is False
    )

    if compressor_turned_off_now:
        compressor_last_off_at = now_iso

    should_save_history = False

    last_history_at = current_status.get("last_history_at")

    if not last_history_at:
        should_save_history = True
    else:
        last_history_dt = datetime.fromisoformat(last_history_at)
        seconds_since_last_history = int((now - last_history_dt).total_seconds())

        if seconds_since_last_history >= HISTORY_INTERVAL_SECONDS:
            should_save_history = True

    if should_save_history:
        history_data = {
            "device_id": data.device_id,
            "temperature": data.temperature,
            "humidity": data.humidity,
            "rssi": data.rssi,
            "alarm": alarm,
            "alarm_reason": alarm_reason,
            "compressor_should_be_on": compressor_should_be_on,
            "compressor_relay_on": data.compressor_relay_on,
            "timestamp": now_iso,
        }

        db.collection("device_telemetry").add(history_data)

    db.collection("device_status").document(data.device_id).set(
        {
            "device_id": data.device_id,
            "temperature": data.temperature,
            "humidity": data.humidity,
            "rssi": data.rssi,
            "online": True,
            "last_seen_at": now_iso,
            "updated_at": now_iso,
            "alarm": alarm,
            "alarm_reason": alarm_reason,
            "compressor_should_be_on": compressor_should_be_on,
            "compressor_relay_on": data.compressor_relay_on,
            "compressor_last_off_at": compressor_last_off_at,
            "compressor_can_turn_on": compressor_can_turn_on,
            "compressor_wait_seconds_remaining": compressor_wait_seconds_remaining,
            "last_history_at": (
                now_iso
                if should_save_history
                else current_status.get("last_history_at")
            ),
        },
        merge=True,
    )

    return {"success": True, "message": "Telemetry received"}


# =====================================
# REGISTRO DE DISPOSITIVOS
# =====================================


@app.post("/api/devices/register")
def register_device(device: DeviceRegister):

    devices_db[device.device_id] = {
        "device_id": device.device_id,
        "client_name": device.client_name,
        "store_name": device.store_name,
        "equipment_name": device.equipment_name,
        "created_at": datetime.now().isoformat(),
        "active": True,
    }

    print("\n==============================")
    print("DEVICE REGISTRADO")
    print("==============================")
    print(devices_db[device.device_id])

    return {"success": True, "device": devices_db[device.device_id]}


# =====================================
# CLIENTES
# =====================================


@app.post("/api/clients")
def create_client(client: ClientCreate):

    client_id = f"client_{client.cedula_ruc}"

    client_data = {
        "client_id": client_id,
        "name": client.name,
        "cedula_ruc": client.cedula_ruc,
        "phone": client.phone,
        "email": client.email,
        "active": True,
        "created_at": datetime.now().isoformat(),
    }

    db.collection("clients").document(client_id).set(client_data)

    print("\n==============================")
    print("CLIENTE CREADO")
    print("==============================")
    print(client_data)

    return {"success": True, "client": client_data}


# =====================================
# TIENDAS
# =====================================


@app.post("/api/stores")
def create_store(store: StoreCreate):

    store_id = "store_" + store.name.lower().replace(" ", "_").replace("-", "_")

    store_data = {
        "store_id": store_id,
        "client_id": store.client_id,
        "name": store.name,
        "address": store.address,
        "active": True,
        "created_at": datetime.now().isoformat(),
    }

    db.collection("stores").document(store_id).set(store_data)

    print("\n==============================")
    print("TIENDA CREADA")
    print("==============================")
    print(store_data)

    return {"success": True, "store": store_data}


# =====================================
# DISPOSITIVOS
# =====================================


@app.post("/api/devices")
def create_device(device: DeviceCreate):

    device_data = {
        "device_id": device.device_id,
        "client_id": device.client_id,
        "store_id": device.store_id,
        "name": device.name,
        "type": device.type,
        "active": True,
        "created_at": datetime.now().isoformat(),
    }

    db.collection("devices").document(device.device_id).set(device_data)

    print("\n==============================")
    print("DISPOSITIVO CREADO")
    print("==============================")
    print(device_data)

    return {"success": True, "device": device_data}


# =====================================
# CONSULTAS
# =====================================


@app.get("/api/clients/{client_id}/stores")
def get_client_stores(client_id: str):

    docs = (
        db.collection("stores")
        .where("client_id", "==", client_id)
        .where("active", "==", True)
        .stream()
    )

    stores = []

    for doc in docs:
        stores.append(doc.to_dict())

    return {"success": True, "stores": stores}


@app.get("/api/stores/{store_id}/devices")
def get_store_devices(store_id: str):

    docs = (
        db.collection("devices")
        .where("store_id", "==", store_id)
        .where("active", "==", True)
        .stream()
    )

    devices = []

    for doc in docs:
        devices.append(doc.to_dict())

    return {"success": True, "devices": devices}


@app.get("/api/devices/{device_id}/status")
def get_device_status(device_id: str):

    doc = db.collection("device_status").document(device_id).get()

    if not doc.exists:
        return {"success": False, "message": "Device status not found"}

    status = doc.to_dict()

    connection_state = "unknown"
    seconds_since_last_seen = None

    last_seen_at = status.get("last_seen_at")

    if last_seen_at:
        last_seen_dt = datetime.fromisoformat(last_seen_at)
        seconds_since_last_seen = int((datetime.now() - last_seen_dt).total_seconds())

        if seconds_since_last_seen <= OFFLINE_WARNING_SECONDS:
            connection_state = "online"
        elif seconds_since_last_seen <= OFFLINE_REAL_SECONDS:
            connection_state = "unstable"
        else:
            connection_state = "offline"

    status["connection_state"] = connection_state
    status["seconds_since_last_seen"] = seconds_since_last_seen
    status["online"] = connection_state == "online"

    return {"success": True, "status": status}


# =====================================
# CONFIGURACION DISPOSITIVO
# =====================================


@app.post("/api/devices/{device_id}/config")
def update_device_config(device_id: str, config: DeviceConfigUpdate):

    config_data = config.model_dump()
    config_data["device_id"] = device_id
    config_data["updated_at"] = datetime.now().isoformat()

    db.collection("device_config").document(device_id).set(config_data, merge=True)

    print("\n==============================")
    print("CONFIGURACION ACTUALIZADA")
    print("==============================")
    print(config_data)

    return {"success": True, "config": config_data}


@app.get("/api/devices/{device_id}/config")
def get_device_config(device_id: str):

    doc = db.collection("device_config").document(device_id).get()

    if not doc.exists:
        default_config = {
            "device_id": device_id,
            "compressor": {
                "enabled": True,
                "control_sensor_role": "chamber",
                "setpoint": 4,
                "differential": 2,
                "min_off_seconds": 180,
                "force_off_on_sensor_error": True,
            },
            "sensors": [
                {
                    "id": "chamber_1",
                    "role": "chamber",
                    "name": "Sonda cámara",
                    "type": "ds18b20",
                    "bus": "onewire",
                    "pin": 4,
                    "address": "",
                    "enabled": True,
                    "offset": 0,
                    "alarm_enabled": True,
                    "temp_min_alarm": 0,
                    "temp_max_alarm": 8,
                    "can_stop_compressor": True,
                }
            ],
            "outputs": {
                "compressor": {
                    "enabled": True,
                    "pin": 26,
                    "active_level": "HIGH",
                    "name": "Salida compresor",
                },
                "defrost": {
                    "enabled": False,
                    "pin": 27,
                    "active_level": "HIGH",
                    "name": "Salida defrost",
                },
                "fan": {
                    "enabled": False,
                    "pin": 25,
                    "active_level": "HIGH",
                    "name": "Salida ventilador",
                },
                "alarm": {
                    "enabled": False,
                    "pin": 14,
                    "active_level": "HIGH",
                    "name": "Salida alarma",
                },
            },
            "defrost": {
                "enabled": False,
                "mode": "time",
                "interval_minutes": 360,
                "duration_minutes": 20,
                "end_sensor_role": "evaporator",
                "end_temperature": 8,
            },
            "safety": {
                "offline_mode": "local_control",
                "sensor_error_action": "compressor_off",
                "max_compressor_runtime_minutes": 0,
            },
            "updated_at": datetime.now().isoformat(),
        }

        return {"success": True, "config": default_config}

    return {"success": True, "config": doc.to_dict()}


@app.get("/api/devices/{device_id}/dashboard")
def get_device_dashboard(device_id: str):

    device_doc = db.collection("devices").document(device_id).get()
    status_doc = db.collection("device_status").document(device_id).get()
    config_doc = db.collection("device_config").document(device_id).get()

    if not device_doc.exists:
        return {"success": False, "message": "Device not found"}

    device = device_doc.to_dict()
    status = status_doc.to_dict() if status_doc.exists else {}
    config = config_doc.to_dict() if config_doc.exists else {}

    readings_docs = (
        db.collection("device_telemetry")
        .where("device_id", "==", device_id)
        .order_by("timestamp", direction=firestore.Query.DESCENDING)
        .limit(20)
        .stream()
    )

    recent_readings = []

    for doc in readings_docs:
        recent_readings.append(doc.to_dict())

    return {
        "success": True,
        "device": device,
        "status": status,
        "config": config,
        "recent_readings": recent_readings,
    }


@app.get("/api/devices/{device_id}/telemetry")
def get_device_telemetry(device_id: str, limit: int = 50):

    docs = (
        db.collection("device_telemetry")
        .where("device_id", "==", device_id)
        .order_by("timestamp", direction=firestore.Query.DESCENDING)
        .limit(limit)
        .stream()
    )

    readings = []

    for doc in docs:
        readings.append(doc.to_dict())

    return {"success": True, "readings": readings}


@app.get("/api/devices/{device_id}/control")
def get_device_control(device_id: str):

    status_doc = db.collection("device_status").document(device_id).get()

    if not status_doc.exists:
        return {"success": False, "message": "Device status not found"}

    status = status_doc.to_dict()

    return {
        "success": True,
        "device_id": device_id,
        "compressor_should_be_on": status.get("compressor_should_be_on", False),
        "compressor_can_turn_on": status.get("compressor_can_turn_on", True),
        "compressor_wait_seconds_remaining": status.get(
            "compressor_wait_seconds_remaining", 0
        ),
        "alarm": status.get("alarm", False),
        "alarm_reason": status.get("alarm_reason"),
    }
