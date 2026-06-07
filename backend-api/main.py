from fastapi import FastAPI
from pydantic import BaseModel
from datetime import datetime, timedelta
from typing import Dict, List, Optional
import firebase_admin
from firebase_admin import credentials, firestore
import os

app = FastAPI(title="SmartCold API")

# =====================================
# FIREBASE
# =====================================

import os

if os.getenv("K_SERVICE"):
    firebase_admin.initialize_app()
else:
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

    temperature: float
    humidity: float
    rssi: int
    online: bool

    device_state: str | None = None
    device_health: str | None = None
    device_health_reason: str | None = None
    compressor_block_reason: str | None = None

    compressor_relay_on: bool | None = None
    compressor_should_be_on: bool | None = None
    compressor_can_turn_on: bool | None = None
    compressor_wait_seconds_remaining: int | None = None
    compressor_runtime_since_defrost_seconds: int | None = None

    defrost_active: bool | None = None
    defrost_elapsed_seconds: int | None = None
    defrost_remaining_seconds: int | None = None
    defrost_next_seconds: int | None = None
    defrost_interval_minutes: int | None = None
    defrost_duration_minutes: int | None = None
    defrost_end_sensor_role: str | None = None
    defrost_end_temperature: float | None = None

    drip_active: bool | None = None
    drip_elapsed_seconds: int | None = None
    drip_remaining_seconds: int | None = None
    drip_time_seconds: int | None = None

    cloud_connected: bool | None = None
    cloud_fail_count: int | None = None
    cloud_status: str | None = None
    last_cloud_ok_ms: int | None = None

    detected_sensors: list[str] = []
    sensor_readings: Dict[str, float] = {}
    sensor_alarms: Dict[str, dict] = {}
    
    hardware_uid: str | None = None
    firmware_version: str | None = None

    configured: bool | None = None
    provisioning_status: str | None = None


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


class OutputConfig(BaseModel):
    enabled: bool = True
    pin: int
    active_level: str = "HIGH"
    name: str


class OutputsConfig(BaseModel):
    compressor: OutputConfig
    defrost: OutputConfig
    fan: OutputConfig
    alarm: OutputConfig


class DefrostConfig(BaseModel):
    enabled: bool = False
    mode: str = "time"
    interval_minutes: int = 360
    duration_minutes: int = 20
    end_sensor_role: str = "evaporator"
    end_temperature: float = 8


class SafetyConfig(BaseModel):
    offline_mode: str = "local_control"
    sensor_error_action: str = "compressor_off"
    max_compressor_runtime_minutes: int = 0


class DeviceConfigUpdate(BaseModel):
    config_version: int = 1
    compressor: CompressorConfig
    sensors: List[SensorConfig]
    outputs: OutputsConfig
    defrost: DefrostConfig
    safety: SafetyConfig


class CoolingLevelUpdate(BaseModel):
    cooling_level: int


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
    print("Temp:", data.temperature)
    print("Humidity:", data.humidity)
    print("RSSI:", data.rssi)
    print("Online:", data.online)
    print("Compressor relay on:", data.compressor_relay_on)
    print("Compressor should be on:", data.compressor_should_be_on)
    print("Compressor can turn on:", data.compressor_can_turn_on)
    print("Wait seconds:", data.compressor_wait_seconds_remaining)
    print("Detected sensors:", data.detected_sensors)
    print("Sensor readings:", data.sensor_readings)
    print("Sensor alarms:", data.sensor_alarms)
    print("Timestamp:", datetime.now())

    now = datetime.now()
    now_iso = now.isoformat()
    connection_status = "online"
    seconds_since_last_seen = 0

    status_doc = db.collection("device_status").document(data.device_id).get()
    current_status = status_doc.to_dict() if status_doc.exists else {}
    device_ref = db.collection("devices").document(data.device_id)
    device_doc = device_ref.get()

    if not device_doc.exists:
        unregistered_status = {
            "device_id": data.device_id,
            "hardware_uid": data.hardware_uid,
            "firmware_version": data.firmware_version,
            "online": True,
            "configured": False,
            "provisioning_status": "device_not_registered",
            "device_state": "SETUP",
            "device_health": "SETUP",
            "device_health_reason": "DEVICE_NOT_REGISTERED",
            "compressor_block_reason": "DEVICE_NOT_REGISTERED",
            "detected_sensors": data.detected_sensors,
            "sensor_readings": data.sensor_readings,
            "rssi": data.rssi,
            "last_seen_at": now_iso,
            "updated_at": now_iso,
        }

        db.collection("device_status").document(data.device_id).set(
            unregistered_status,
            merge=True,
        )

        return {
            "success": False,
            "message": "DEVICE_NOT_REGISTERED",
            "config_pending": False,
        }

    device_data = device_doc.to_dict() or {}
    saved_hardware_uid = device_data.get("hardware_uid")

    if (
        saved_hardware_uid
        and data.hardware_uid
        and saved_hardware_uid != data.hardware_uid
    ):
        print("🚨 CONFLICTO CRITICO DE HARDWARE UID")
        print("Device ID:", data.device_id)
        print("Firestore hardware_uid:", saved_hardware_uid)
        print("Incoming hardware_uid:", data.hardware_uid)

        return {
            "success": False,
            "message": "HARDWARE_UID_CONFLICT",
            "config_pending": False,
        }

    device_ref.set(
        {
            "hardware_uid": data.hardware_uid or saved_hardware_uid,
            "firmware_version": data.firmware_version,
            "updated_at": now_iso,
            "last_seen_at": now_iso,
        },
        merge=True,
    )

    alarm = False
    alarm_reason = None

    should_save_history = False
    last_history_at = current_status.get("last_history_at")

    if not last_history_at:
        should_save_history = True
    else:
        last_history_dt = datetime.fromisoformat(last_history_at)
        seconds_since_last_history = int((now - last_history_dt).total_seconds())

        if seconds_since_last_history >= HISTORY_INTERVAL_SECONDS:
            should_save_history = True

    telemetry_data = {
        "device_id": data.device_id,
        "temperature": data.temperature,
        "humidity": data.humidity,
        "rssi": data.rssi,
        "online": True,
        "hardware_uid": data.hardware_uid,
        "firmware_version": data.firmware_version,

        "configured": data.configured,
        "provisioning_status": data.provisioning_status,
        "connection_status": connection_status,
        "seconds_since_last_seen": seconds_since_last_seen,
        "last_seen_at": now_iso,
        "cloud_connected": data.cloud_connected,
        "cloud_fail_count": data.cloud_fail_count,
        "cloud_status": data.cloud_status,
        "last_cloud_ok_ms": data.last_cloud_ok_ms,
        "alarm": alarm,
        "alarm_reason": alarm_reason,
        "device_state": data.device_state,
        "device_health": data.device_health,
        "device_health_reason": data.device_health_reason,
        "compressor_block_reason": data.compressor_block_reason,
        "compressor_relay_on": data.compressor_relay_on,
        "compressor_should_be_on": data.compressor_should_be_on,
        "compressor_can_turn_on": data.compressor_can_turn_on,
        "compressor_wait_seconds_remaining": data.compressor_wait_seconds_remaining,
        "compressor_runtime_since_defrost_seconds": data.compressor_runtime_since_defrost_seconds,
        "defrost_active": data.defrost_active,
        "defrost_elapsed_seconds": data.defrost_elapsed_seconds,
        "defrost_remaining_seconds": data.defrost_remaining_seconds,
        "defrost_next_seconds": data.defrost_next_seconds,
        "defrost_interval_minutes": data.defrost_interval_minutes,
        "defrost_duration_minutes": data.defrost_duration_minutes,
        "defrost_end_sensor_role": data.defrost_end_sensor_role,
        "defrost_end_temperature": data.defrost_end_temperature,
        "drip_active": data.drip_active,
        "drip_elapsed_seconds": data.drip_elapsed_seconds,
        "drip_remaining_seconds": data.drip_remaining_seconds,
        "drip_time_seconds": data.drip_time_seconds,
        "detected_sensors": data.detected_sensors,
        "sensor_readings": data.sensor_readings,
        "sensor_alarms": data.sensor_alarms,
        "timestamp": now_iso,
    }

    if should_save_history:
        db.collection("device_telemetry").add(telemetry_data)

    status_data = {
        **telemetry_data,
        "last_seen_at": now_iso,
        "updated_at": now_iso,
        "connection_status": connection_status,
        "seconds_since_last_seen": seconds_since_last_seen,
        "last_history_at": (
            now_iso if should_save_history else current_status.get("last_history_at")
        ),
    }

    db.collection("device_status").document(data.device_id).set(
        status_data,
        merge=True,
    )

    config_doc = db.collection("device_config").document(data.device_id).get()
    config_data = config_doc.to_dict() if config_doc.exists else {}
    config_pending = bool(config_data.get("config_pending", False))

    return {
        "success": True,
        "message": "Telemetry received",
        "config_pending": config_pending,
    }


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
    config_data["config_pending"] = True

    db.collection("device_config").document(device_id).set(config_data, merge=True)

    print("\n==============================")
    print("CONFIGURACION ACTUALIZADA")
    print("==============================")
    print(config_data)

    return {"success": True, "config": config_data}


@app.get("/api/devices/{device_id}/config")
def get_device_config(device_id: str):

    device_doc = db.collection("devices").document(device_id).get()

    if not device_doc.exists:
        return {
            "success": False,
            "error": "DEVICE_NOT_REGISTERED",
            "config": {
                "configured": False,
                "provisioning_status": "device_not_registered",
                "config_pending": False,
            },
        }

    device_data = device_doc.to_dict() or {}
    device_status = device_data.get("status")

    if device_status != "installed":
        return {
            "success": True,
            "config": {
                "device_id": device_id,
                "configured": False,
                "provisioning_status": "pending_installation",
                "device_status": device_status,
                "config_pending": False,
                "last_config_ack_at": device_data.get("last_config_ack_at"),
            },
        }

    config_doc = db.collection("device_config").document(device_id).get()

    if not config_doc.exists:
        return {
            "success": False,
            "error": "CONFIG_NOT_FOUND",
            "config": {
                "device_id": device_id,
                "configured": False,
                "provisioning_status": "config_missing",
                "config_pending": False,
            },
        }

    config_data = config_doc.to_dict() or {}
    config_data["configured"] = True
    config_data["provisioning_status"] = "configured"

    return {
        "success": True,
        "config": config_data,
    }


@app.get("/api/devices/{device_id}/config-summary")
def get_device_config_summary(device_id: str):

    doc = db.collection("device_config").document(device_id).get()

    if not doc.exists:
        return {
            "success": False,
            "message": "Device config not found",
        }

    config = doc.to_dict() or {}

    compressor = config.get("compressor", {})
    sensors = config.get("sensors", [])

    chamber_sensor = next(
        (s for s in sensors if s.get("role") == "chamber"),
        {},
    )
    setpoint = compressor.get("setpoint", 4)
    differential = compressor.get("differential", 2)
    turn_on_temperature = setpoint + differential
    turn_off_temperature = setpoint
    return {
        "success": True,
        "device_id": device_id,
        "operation_mode": config.get("operation_mode", "refrigerate"),
        "cooling_level": config.get("cooling_level", 4),
        "setpoint": setpoint,
        "differential": differential,
        "turn_on_temperature": turn_on_temperature,
        "turn_off_temperature": turn_off_temperature,
        "temp_max_alarm": chamber_sensor.get("temp_max_alarm"),
        "temp_min_alarm": chamber_sensor.get("temp_min_alarm"),
        "config_pending": config.get("config_pending", False),
        "updated_at": config.get("updated_at"),
    }


@app.post("/api/devices/{device_id}/config/ack")
def ack_device_config(device_id: str):

    now_iso = datetime.now().isoformat()

    db.collection("device_config").document(device_id).set(
        {
            "config_pending": False,
            "last_config_ack_at": now_iso,
        },
        merge=True,
    )

    db.collection("device_status").document(device_id).set(
        {
            "last_config_ack_at": now_iso,
            "config_pending": False,
        },
        merge=True,
    )

    print("\n==============================")
    print("CONFIGURACION CONFIRMADA POR ESP")
    print("==============================")
    print("Device:", device_id)
    print("Ack at:", now_iso)

    return {
        "success": True,
        "message": "Config acknowledged",
        "config_pending": False,
    }


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

    now = datetime.now()
    last_seen_at = status.get("last_seen_at")

    seconds_since_last_seen = None
    connection_status = "offline"
    online = False

    if last_seen_at:
        try:
            last_seen_dt = datetime.fromisoformat(last_seen_at)
            seconds_since_last_seen = int((now - last_seen_dt).total_seconds())

            if seconds_since_last_seen <= OFFLINE_WARNING_SECONDS:
                connection_status = "online"
                online = True
            elif seconds_since_last_seen <= OFFLINE_REAL_SECONDS:
                connection_status = "warning"
                online = True
            else:
                connection_status = "offline"
                online = False

        except Exception:
            seconds_since_last_seen = None
            connection_status = "offline"
            online = False

    status["online"] = online
    status["connection_status"] = connection_status
    status["seconds_since_last_seen"] = seconds_since_last_seen

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


@app.post("/api/devices/{device_id}/cooling-level")
def update_device_cooling_level(device_id: str, data: CoolingLevelUpdate):

    if data.cooling_level < 1 or data.cooling_level > 7:
        return {
            "success": False,
            "message": "Cooling level must be between 1 and 7",
        }

    config_ref = db.collection("device_config").document(device_id)
    config_doc = config_ref.get()

    if not config_doc.exists:
        return {
            "success": False,
            "message": "Device config not found",
        }

    config = config_doc.to_dict() or {}

    operation_mode = config.get("operation_mode", "refrigerate")

    if operation_mode == "freeze":
        level_map = {
            1: -12.0,
            2: -14.0,
            3: -16.0,
            4: -18.0,
            5: -20.0,
            6: -22.0,
            7: -24.0,
        }
    else:
        level_map = {
            1: 7.0,
            2: 6.0,
            3: 5.0,
            4: 4.0,
            5: 3.0,
            6: 2.0,
            7: 1.0,
        }

    setpoint = level_map[data.cooling_level]
    differential = 2.0
    turn_on_temperature = setpoint + differential

    temp_max_alarm = turn_on_temperature + 2.0

    if operation_mode == "freeze":
        temp_min_alarm = setpoint - 4.0
    else:
        temp_min_alarm = max(setpoint - 2.0, 0.0)

    compressor = config.get("compressor", {})
    compressor["setpoint"] = setpoint
    compressor["differential"] = differential

    sensors = config.get("sensors", [])

    for sensor in sensors:
        if sensor.get("role") == "chamber":
            sensor["temp_max_alarm"] = temp_max_alarm
            sensor["temp_min_alarm"] = temp_min_alarm

    now_iso = datetime.now().isoformat()

    update_data = {
        "operation_mode": operation_mode,
        "cooling_level": data.cooling_level,
        "config_source": "client_profile",
        "compressor": compressor,
        "sensors": sensors,
        "config_pending": True,
        "updated_at": now_iso,
    }

    config_ref.set(update_data, merge=True)

    return {
        "success": True,
        "device_id": device_id,
        "operation_mode": operation_mode,
        "cooling_level": data.cooling_level,
        "setpoint": setpoint,
        "differential": differential,
        "turn_on_temperature": turn_on_temperature,
        "turn_off_temperature": setpoint,
        "temp_max_alarm": temp_max_alarm,
        "temp_min_alarm": temp_min_alarm,
        "config_pending": True,
    }
