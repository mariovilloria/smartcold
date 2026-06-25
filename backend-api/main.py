from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from datetime import datetime, timedelta
from typing import Dict, List, Optional, Any
import firebase_admin
import uuid
from firebase_admin import credentials, firestore, auth
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

    temperature: Optional[float] = None
    humidity: Optional[float] = None
    rssi: int
    online: bool

    device_mode: str | None = None
    service_mode: bool | None = None
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

    drip_active: bool | None = None
    drip_elapsed_seconds: int | None = None
    drip_remaining_seconds: int | None = None

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

class ServiceModeUpdate(BaseModel):
    service_mode: bool

class ServiceAccessAck(BaseModel):
    active: bool

# =====================================
# MODELO CLIENTE
# =====================================


class ClientCreate(BaseModel):
    name: str
    cedula_ruc: str
    phone: str | None = None
    email: str | None = None
    
class DeviceAssignRequest(BaseModel):
    client_id: str
    store_id: str
    device_name: str
    equipment_type: str | None = None
    assigned_by: str | None = None
    reason: str | None = None
    
# =====================================
# MODELO TIENDA
# =====================================


class StoreCreate(BaseModel):
    client_id: str
    name: str
    address: str | None = None
    phone: str | None = None


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

class OperationModeUpdate(BaseModel):
    operation_mode: str
   
 
# =====================================================
# SmartCold Contract v1.0
# =====================================================

class SmartColdCompressorContract(BaseModel):
    enabled: bool = True
    control_sensor_role: str = "chamber"
    setpoint: float
    differential: float
    min_off_seconds: int = 180
    force_off_on_sensor_error: bool = True


class SmartColdDefrostContract(BaseModel):
    enabled: bool = False
    mode: str = "time_temperature"
    interval_minutes: int = 360
    duration_minutes: int = 20
    end_sensor_role: str = "evaporator"
    end_temperature: float = 8.0
    drip_time_seconds: int = 120


class SmartColdSensorContract(BaseModel):
    id: str
    role: str
    name: str
    type: str = "ds18b20"
    bus: str = "onewire"
    pin: int = 4
    address: str
    enabled: bool = True
    offset: float = 0.0
    alarm_enabled: bool = False
    temp_min_alarm: float = -100.0
    temp_max_alarm: float = 100.0
    can_stop_compressor: bool = False


class SmartColdOutputItemContract(BaseModel):
    enabled: bool = False
    pin: Optional[int] = None
    active_level: str = "HIGH"
    name: str


class SmartColdOutputsContract(BaseModel):
    compressor: SmartColdOutputItemContract = SmartColdOutputItemContract(
        enabled=True,
        pin=26,
        active_level="HIGH",
        name="Salida compresor",
    )
    defrost: SmartColdOutputItemContract = SmartColdOutputItemContract(
        enabled=True,
        pin=27,
        active_level="HIGH",
        name="Salida defrost",
    )
    fan: SmartColdOutputItemContract = SmartColdOutputItemContract(
        enabled=True,
        pin=14,
        active_level="HIGH",
        name="Salida ventilador",
    )
    alarm: SmartColdOutputItemContract = SmartColdOutputItemContract(
        enabled=False,
        pin=None,
        active_level="HIGH",
        name="Salida alarma",
    )


class SmartColdInputItemContract(BaseModel):
    enabled: bool = False
    pin: Optional[int] = None
    normally_closed: bool = True
    name: str


class SmartColdExternalInputContract(SmartColdInputItemContract):
    can_stop_compressor: bool = False
    role: str = "external_alarm"


class SmartColdInputsContract(BaseModel):
    door: SmartColdInputItemContract = SmartColdInputItemContract(
        enabled=False,
        pin=25,
        normally_closed=True,
        name="Entrada puerta",
    )
    external: SmartColdExternalInputContract = SmartColdExternalInputContract(
        enabled=False,
        pin=33,
        normally_closed=True,
        name="Entrada externa",
        can_stop_compressor=False,
        role="external_alarm",
    )


class SmartColdSimulationContract(BaseModel):
    enabled: bool = False
    scenario: str = "OFF"
    source: str = "none"


class SmartColdSafetyContract(BaseModel):
    offline_mode: str = "local_control"
    sensor_error_action: str = "compressor_off"
    max_compressor_runtime_minutes: int = 0


class SmartColdCommissionRequest(BaseModel):
    device_id: str
    hardware_uid: str
    firmware_version: str

    operation_mode: str
    cooling_level: int = 4

    compressor: SmartColdCompressorContract
    defrost: SmartColdDefrostContract = SmartColdDefrostContract()
    sensors: List[SmartColdSensorContract]

    outputs: SmartColdOutputsContract = SmartColdOutputsContract()
    inputs: SmartColdInputsContract = SmartColdInputsContract()
    simulation: SmartColdSimulationContract = SmartColdSimulationContract()
    safety: SmartColdSafetyContract = SmartColdSafetyContract()

    installer_uid: Optional[str] = None
    configured_wifi_ssid: Optional[str] = None   
   
   
def build_commissioned_device_documents(payload: SmartColdCommissionRequest) -> dict:
    now = datetime.utcnow().isoformat()

    device_doc = {
        "device_id": payload.device_id,
        "hardware_uid": payload.hardware_uid,
        "name": "Pendiente de asignar",
        "type": "refrigeration_controller",
        "active": True,
        "configured": True,
        "status": "installed",
        "provisioning_status": "commissioned",
        "simulation_enabled": payload.simulation.enabled,
        "simulation_scenario": payload.simulation.scenario,
        "current_client_id": None,
        "current_store_id": None,
        "current_installation_id": payload.device_id,
        "firmware_version": payload.firmware_version,
        "created_at": now,
        "updated_at": now,
        "commissioned_at": now,
        "last_seen_at": now,
    }

    config_doc = {
        "device_id": payload.device_id,
        "operation_mode": payload.operation_mode,
        "cooling_level": payload.cooling_level,
        "compressor": payload.compressor.dict(),
        "defrost": payload.defrost.dict(),
        "sensors": [sensor.dict() for sensor in payload.sensors],
        "outputs": payload.outputs.dict(),
        "inputs": payload.inputs.dict(),
        "simulation": payload.simulation.dict(),
        "safety": payload.safety.dict(),
        "config_version": 1,
        "config_source": "commissioning",
        "config_pending": False,
        "updated_at": now,
        "last_config_ack_at": None,
    }

    status_doc = {
        "device_id": payload.device_id,
        "hardware_uid": payload.hardware_uid,
        "online": False,
        "connection_status": "offline",
        "configured": True,
        "provisioning_status": "commissioned",
        "device_mode": "OPERATION",
        "service_mode": False,
        "simulation_enabled": payload.simulation.enabled,
        "simulation_scenario": payload.simulation.scenario,
        "device_state": "UNKNOWN",
        "device_health": "HEALTHY",
        "device_health_reason": "",
        "alarm": False,
        "alarm_reason": "",
        "temperature": None,
        "humidity": None,
        "sensor_readings": {},
        "sensor_alarms": {},
        "compressor_relay_on": False,
        "compressor_should_be_on": False,
        "compressor_can_turn_on": False,
        "compressor_block_reason": "NONE",
        "compressor_block_reasons": [],
        "compressor_wait_seconds_remaining": 0,
        "compressor_runtime_since_defrost_seconds": 0,
        "defrost_active": False,
        "defrost_elapsed_seconds": 0,
        "defrost_remaining_seconds": 0,
        "defrost_next_seconds": 0,
        "drip_active": False,
        "drip_elapsed_seconds": 0,
        "drip_remaining_seconds": 0,
        "detected_sensors": [],
        "firmware_version": payload.firmware_version,
        "rssi": None,
        "timestamp": now,
        "last_seen_at": now,
        "updated_at": now,
        "seconds_since_last_seen": 0,
    }

    installation_doc = {
        "installation_id": payload.device_id,
        "device_id": payload.device_id,
        "hardware_uid": payload.hardware_uid,
        "status": "completed",
        "phase": "completed",
        "completed": True,
        "installer_uid": payload.installer_uid,
        "wifi_configured": True,
        "connection_verified": True,
        "configured_wifi_ssid": payload.configured_wifi_ssid,
        "sensors_detected": len(payload.sensors) > 0,
        "sensors_assigned": len(payload.sensors) > 0,
        "detected_sensors": [sensor.address for sensor in payload.sensors],
        "parameters_configured": True,
        "tests_completed": True,
        "device_mode_after_finish": "OPERATION",
        "service_mode": False,
        "created_at": now,
        "updated_at": now,
        "completed_at": now,
    }

    return {
        "device": device_doc,
        "device_config": config_doc,
        "device_status": status_doc,
        "installation": installation_doc,
    }   
    
# =====================================
# RUTAS BASICAS
# =====================================


@app.get("/")
def home():
    return {"app": "SmartCold API", "status": "ok"}


@app.get("/health")
def health():
    return {"status": "healthy"}



@app.post("/api/devices/{device_id}/assign")
def assign_device_to_client(device_id: str, payload: DeviceAssignRequest):
    client_id = payload.client_id.strip()
    store_id = payload.store_id.strip()
    
    device_name = payload.device_name.strip()
    assigned_by = payload.assigned_by.strip() if payload.assigned_by else ""

    if not client_id:
        return {"success": False, "message": "client_id requerido"}

    if not store_id:
        return {"success": False, "message": "store_id requerido"}

    if not device_name:
        return {"success": False, "message": "Nombre del equipo requerido"}

    device_ref = db.collection("devices").document(device_id)
    device_doc = device_ref.get()

    if not device_doc.exists:
        return {"success": False, "message": "Dispositivo no existe"}

    client_doc = db.collection("clients").document(client_id).get()
    if not client_doc.exists:
        return {"success": False, "message": "Cliente no existe"}

    store_doc = db.collection("stores").document(store_id).get()
    if not store_doc.exists:
        return {"success": False, "message": "Local no existe"}
    
    client_data = client_doc.to_dict() or {}
    store_data = store_doc.to_dict() or {}

    client_name = client_data.get("name", "")
    store_name = store_data.get("name", "")  

    if store_data.get("client_id") != client_id:
        return {
            "success": False,
            "message": "El local no pertenece al cliente seleccionado",
        }

    now_iso = datetime.now().isoformat()
    installation_id = f"installation_{device_id}_{uuid.uuid4().hex[:12]}"
    device_data = device_doc.to_dict() or {}

    previous_installation_id = device_data.get("current_installation_id")
    previous_client_id = device_data.get("current_client_id")
    previous_store_id = device_data.get("current_store_id")
    previous_name = device_data.get("name")

    is_reassignment = bool(previous_client_id or previous_store_id or previous_installation_id)

    equipment_type = payload.equipment_type or device_data.get("equipment_type") or "refrigerator"
    reason = payload.reason.strip() if payload.reason else ""
    if previous_installation_id:
        db.collection("installations").document(previous_installation_id).set(
        {
            "status": "MOVED" if is_reassignment else "REPLACED",
            "ended_at": now_iso,
            "ended_reason": reason or "REASSIGNED",
            "updated_at": now_iso,
        },
        merge=True,
    )
    installation_data = {
        "installation_id": installation_id,
        "installer_uid": device_doc.to_dict().get("installer_uid", ""),
        "commissioned_at": device_doc.to_dict().get("commissioned_at", ""),
        "device_id": device_id,
        "client_id": client_id,
        "store_id": store_id,
        "client_name": client_name,
        "store_name": store_name,
        "device_name": device_name,
        "status": "ACTIVE",
        "phase": "assigned",
        "completed": True,
        "assigned_by": assigned_by,
        "assigned_at": now_iso,
        "created_at": now_iso,
        "updated_at": now_iso,
        "equipment_type": equipment_type,
        "started_at": now_iso,
        "previous_installation_id": previous_installation_id,
        "previous_client_id": previous_client_id,
        "previous_store_id": previous_store_id,
        "previous_device_name": previous_name,
        "reason": reason,
    }

    device_update = {
        "name": device_name,
        "current_client_id": client_id,
        "current_store_id": store_id,
        "current_installation_id": installation_id,
        "current_client_name": client_name,
        "current_store_name": store_name,
        "assigned_at": now_iso,
        "updated_at": now_iso,
        "equipment_type": equipment_type,
        "status": "installed",
    }

    db.collection("installations").document(installation_id).set(
        installation_data,
        merge=True,
    )

    device_ref.set(device_update, merge=True)

    return {
        "success": True,
        "device_id": device_id,
        "installation_id": installation_id,
        "device": device_update,
        "installation": installation_data,
    }


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
    if (
        data.configured is False
        and data.provisioning_status == "pending_installation"
        and data.temperature is None
        and data.humidity is None
    ):
        print("⚙️ Telemetría SETUP recibida. No se crean documentos todavía.")

        return {
            "success": True,
            "message": "Setup telemetry ignored until installation has real data",
            "config_pending": False,
        }

    if data.temperature is None or data.humidity is None:
        return {
            "success": False,
            "message": "temperature and humidity are required for operational telemetry",
            "config_pending": False,
        }
    status_doc = db.collection("device_status").document(data.device_id).get()
    current_status = status_doc.to_dict() if status_doc.exists else {}
    device_ref = db.collection("devices").document(data.device_id)
    device_doc = device_ref.get()

    if not device_doc.exists:
        print("🆕 DISPOSITIVO NUEVO DETECTADO - CREANDO REGISTRO INICIAL")

        device_ref.set(
            {
                "device_id": data.device_id,
                "hardware_uid": data.hardware_uid,
                "firmware_version": data.firmware_version,
                "status": "installation_in_progress",
                "active": True,
                "current_installation_id": data.device_id,
                "created_at": now_iso,
                "updated_at": now_iso,
                "last_seen_at": now_iso,
            },
            merge=True,
        )

        db.collection("installations").document(data.device_id).set(
            {
                "installation_id": data.device_id,
                "device_id": data.device_id,
                "hardware_uid": data.hardware_uid,
                "firmware_version": data.firmware_version,
                "status": "in_progress",
                "phase": "pending_sensor_detection",
                "wifi_configured": True,
                "connection_verified": True,
                "configured_wifi_ssid": None,
                "sensors_detected": bool(data.detected_sensors),
                "detected_sensors": data.detected_sensors,
                "sensors_assigned": False,
                "parameters_configured": False,
                "tests_completed": False,
                "created_at": now_iso,
                "updated_at": now_iso,
            },
            merge=True,
        )

        db.collection("device_config").document(data.device_id).set(
            {
                "device_id": data.device_id,
                "config_version": 1,
                "operation_mode": None,
                "cooling_level": None,
                "config_source": "installation_created",
                "config_pending": False,
                "updated_at": now_iso,
                "last_config_ack_at": None,
                "compressor": {
                "enabled": False,
                "setpoint": None,
                "differential": None,
                    "min_off_seconds": 180,
                    "control_sensor_role": "chamber",
                    "force_off_on_sensor_error": True,
                },
                "sensors": [],
                "defrost": {
                    "enabled": False,
                    "mode": "time",
                    "interval_minutes": 360,
                    "duration_minutes": 20,
                    "end_sensor_role": "evaporator",
                    "end_temperature": 8.0,
                    "drip_time_seconds": 120,
                },
                "outputs": {
                    "compressor": {
                        "enabled": True,
                        "pin": 26,
                    },
                    "fan": {
                        "enabled": True,
                        "pin": 14,
                    },
                    "defrost": {
                        "enabled": True,
                        "pin": 27,
                    },
                    "alarm": {
                        "enabled": False,
                        "pin": None,
                    },
                },
                "safety": {
                    "offline_mode": "local_control",
                    "sensor_error_action": "compressor_off",
                    "max_compressor_runtime_minutes": 0,
                },
                "created_at": now_iso,
            },
            merge=True,
        )

        device_doc = device_ref.get()

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
        "device_mode": data.device_mode,
        "service_mode": data.service_mode,
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
        "drip_active": data.drip_active,
        "drip_elapsed_seconds": data.drip_elapsed_seconds,
        "drip_remaining_seconds": data.drip_remaining_seconds,
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

    service_access_requested = bool(
        config_data.get("service_access_requested", False)
    )

    service_exit_requested = bool(
        config_data.get("service_exit_requested", False)
    )

    return {
        "success": True,
        "message": "Telemetry received",
        "config_pending": config_pending,
        "service_access_requested": service_access_requested,
        "service_exit_requested": service_exit_requested,
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

    name = client.name.strip()
    cedula_ruc = client.cedula_ruc.strip()
    email = client.email.strip().lower()
    phone = client.phone.strip() if client.phone else ""

    if not name:
        return {"success": False, "message": "Nombre del cliente requerido"}

    if not cedula_ruc:
        return {"success": False, "message": "Cédula/RUC requerido"}

    if not email:
        return {"success": False, "message": "Correo requerido"}

    client_id = f"client_{cedula_ruc}"

    existing_client = db.collection("clients").document(client_id).get()
    if existing_client.exists:
        return {
            "success": False,
            "message": "Ya existe un cliente con esa cédula/RUC",
        }

    try:
        existing_user = auth.get_user_by_email(email)
        return {
            "success": False,
            "message": f"Ya existe un usuario con ese correo: {existing_user.uid}",
        }
    except auth.UserNotFoundError:
        pass

    now_iso = datetime.now().isoformat()

    try:
        user_record = auth.create_user(
            email=email,
            password=cedula_ruc,
            display_name=name,
        )
    except Exception as e:
        return {
            "success": False,
            "message": f"No se pudo crear usuario Auth: {str(e)}",
        }

    client_data = {
        "client_id": client_id,
        "name": name,
        "cedula_ruc": cedula_ruc,
        "phone": phone,
        "email": email,
        "active": True,
        "created_at": now_iso,
        "updated_at": now_iso,
    }

    user_data = {
        "email": email,
        "name": name,
        "role": "client",
        "client_id": client_id,
        "active": True,
        "must_change_password": True,
        "temporary_password_used": True,
        "password_changed_at": None,
        "created_at": now_iso,
        "updated_at": now_iso,
    }

    db.collection("clients").document(client_id).set(client_data)
    db.collection("users").document(user_record.uid).set(user_data)

    print("\n==============================")
    print("CLIENTE Y USUARIO CREADOS")
    print("==============================")
    print(client_data)
    print(user_data)

    return {
        "success": True,
        "client": client_data,
        "user_uid": user_record.uid,
        "temporary_password": cedula_ruc,
    }


# =====================================
# TIENDAS
# =====================================


@app.post("/api/stores")
def create_store(store: StoreCreate):

    client_id = store.client_id.strip()
    name = store.name.strip()
    address = store.address.strip() if store.address else ""
    phone = store.phone.strip() if store.phone else ""

    if not client_id:
        return {"success": False, "message": "client_id requerido"}

    if not name:
        return {"success": False, "message": "Nombre del local requerido"}

    client_doc = db.collection("clients").document(client_id).get()

    if not client_doc.exists:
        return {"success": False, "message": "Cliente no existe"}

    now_iso = datetime.now().isoformat()

    store_id = "store_" + client_id.replace("client_", "") + "_" + name.lower().replace(" ", "_").replace("-", "_")

    existing_store = db.collection("stores").document(store_id).get()

    if existing_store.exists:
        return {
            "success": False,
            "message": "Ya existe un local con ese nombre para este cliente",
        }

    store_data = {
        "store_id": store_id,
        "client_id": client_id,
        "name": name,
        "address": address,
        "phone": phone,
        "active": True,
        "created_at": now_iso,
        "updated_at": now_iso,
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


@app.post("/api/devices/{device_id}/operation-mode")
def update_device_operation_mode(device_id: str, data: OperationModeUpdate):

    if data.operation_mode not in ["refrigerate", "freeze"]:
        return {
            "success": False,
            "message": "operation_mode must be refrigerate or freeze",
        }

    config_ref = db.collection("device_config").document(device_id)
    config_doc = config_ref.get()

    config = config_doc.to_dict() if config_doc.exists else {}

    cooling_level = 4

    if data.operation_mode == "freeze":
        setpoint = -18.0
        differential = 3.0
        temp_min_alarm = -22.0
        temp_max_alarm = -13.0
    else:
        setpoint = 4.0
        differential = 2.0
        temp_min_alarm = 0.0
        temp_max_alarm = 8.0

    now_iso = datetime.now().isoformat()

    compressor = config.get("compressor", {})
    compressor["enabled"] = False
    compressor["setpoint"] = setpoint
    compressor["differential"] = differential
    compressor["min_off_seconds"] = compressor.get("min_off_seconds", 180)
    compressor["control_sensor_role"] = None
    compressor["force_off_on_sensor_error"] = compressor.get(
        "force_off_on_sensor_error", True
    )

    sensors = config.get("sensors", [])

    for sensor in sensors:
        if sensor.get("role") == "chamber":
            sensor["alarm_enabled"] = True
            sensor["temp_min_alarm"] = temp_min_alarm
            sensor["temp_max_alarm"] = temp_max_alarm

    update_data = {
        "device_id": device_id,
        "config_version": config.get("config_version", 1),
        "operation_mode": data.operation_mode,
        "cooling_level": cooling_level,
        "config_source": "installation_step_3",
        "config_pending": False,
        "updated_at": now_iso,
        "last_config_ack_at": config.get("last_config_ack_at"),
        "compressor": compressor,
        "sensors": sensors,
    }

    if not config_doc.exists:
        update_data["created_at"] = now_iso

    config_ref.set(update_data, merge=True)

    return {
        "success": True,
        "device_id": device_id,
        "operation_mode": data.operation_mode,
        "cooling_level": cooling_level,
        "setpoint": setpoint,
        "differential": differential,
        "temp_min_alarm": temp_min_alarm,
        "temp_max_alarm": temp_max_alarm,
        "config_pending": False,
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
        "device_id": device_id,
        "config_version": config.get("config_version", 1),
        "operation_mode": operation_mode,
        "cooling_level": data.cooling_level,
        "config_source": "dashboard_cooling_level",
        "config_pending": True,
        "updated_at": now_iso,
        "last_config_ack_at": config.get("last_config_ack_at"),
        "compressor": compressor,
        "sensors": sensors,
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

@app.post("/api/devices/{device_id}/service-mode")
def update_device_service_mode(device_id: str, data: ServiceModeUpdate):
    config_ref = db.collection("device_config").document(device_id)
    config_doc = config_ref.get()

    if not config_doc.exists:
        return {
            "success": False,
            "message": "Device config not found",
        }

    config_data = config_doc.to_dict() or {}
    current_status = config_data.get("service_access_status", "inactive")
    service_access_requested = config_data.get("service_access_requested", False)
    service_exit_requested = config_data.get("service_exit_requested", False)

    now_iso = datetime.now().isoformat()

    # Solicitud de entrada a modo servicio.
    if data.service_mode:
        # Ya está activo: no volver a requested.
        if current_status == "active":
            return {
                "success": True,
                "device_id": device_id,
                "service_access_requested": False,
                "service_exit_requested": False,
                "service_access_status": "active",
                "message": "Service already active",
            }

        # Ya está solicitado: no reescribir timestamps ni ensuciar estado.
        if current_status == "requested" and service_access_requested:
            return {
                "success": True,
                "device_id": device_id,
                "service_access_requested": True,
                "service_exit_requested": False,
                "service_access_status": "requested",
                "message": "Service access already requested",
            }

        config_ref.set(
            {
                "service_access_requested": True,
                "service_access_status": "requested",
                "service_access_requested_at": now_iso,
                "service_access_request_expires_seconds": 300,
                "service_exit_requested": False,
                "requested_service_mode": firestore.DELETE_FIELD,
                "config_source": "dashboard_service_access_request",
                "updated_at": now_iso,
            },
            merge=True,
        )

        return {
            "success": True,
            "device_id": device_id,
            "service_access_requested": True,
            "service_exit_requested": False,
            "service_access_status": "requested",
            "message": "Service access request saved",
        }

    # Solicitud de salida de modo servicio.
    if current_status == "inactive" and not service_exit_requested:
        return {
            "success": True,
            "device_id": device_id,
            "service_access_requested": False,
            "service_exit_requested": False,
            "service_access_status": "inactive",
            "message": "Service already inactive",
        }

    if current_status == "exit_requested" and service_exit_requested:
        return {
            "success": True,
            "device_id": device_id,
            "service_access_requested": False,
            "service_exit_requested": True,
            "service_access_status": "exit_requested",
            "message": "Service exit already requested",
        }

    config_ref.set(
        {
            "service_access_requested": False,
            "service_access_status": "exit_requested",
            "service_exit_requested": True,
            "service_exit_requested_at": now_iso,
            "requested_service_mode": firestore.DELETE_FIELD,
            "config_source": "dashboard_service_exit_request",
            "updated_at": now_iso,
        },
        merge=True,
    )

    return {
        "success": True,
        "device_id": device_id,
        "service_access_requested": False,
        "service_exit_requested": True,
        "service_access_status": "exit_requested",
        "message": "Service exit request saved",
    }
    
   
@app.post("/api/devices/{device_id}/service-access/ack")
def acknowledge_service_access(device_id: str, data: ServiceAccessAck):

    config_ref = db.collection("device_config").document(device_id)

    if not config_ref.get().exists:
        return {
            "success": False,
            "message": "Device config not found",
        }

    now_iso = datetime.now().isoformat()

    if data.active:

        config_ref.set(
            {
                "service_access_requested": False,
                "service_exit_requested": False,
                "service_access_status": "active",
                "requested_service_mode": firestore.DELETE_FIELD,
                "service_access_started_at": now_iso,
                "updated_at": now_iso,
            },
            merge=True,
        )

    else:

        config_ref.set(
            {
                "service_access_requested": False,
                "service_exit_requested": False,
                "service_access_status": "inactive",
                "requested_service_mode": firestore.DELETE_FIELD,
                "service_access_finished_at": now_iso,
                "updated_at": now_iso,
            },
            merge=True,
        )

    return {
        "success": True,
        "device_id": device_id,
        "service_access_status": "active" if data.active else "inactive",
    }   
    
@app.post("/api/devices/{device_id}/commission")
def commission_device(device_id: str, payload: SmartColdCommissionRequest):
    if device_id != payload.device_id:
        raise HTTPException(
            status_code=400,
            detail="DEVICE_ID_MISMATCH",
        )

    docs = build_commissioned_device_documents(payload)

    db.collection("devices").document(device_id).set(docs["device"], merge=True)
    db.collection("device_config").document(device_id).set(docs["device_config"], merge=True)
    db.collection("device_status").document(device_id).set(docs["device_status"], merge=True)
    ##db.collection("installations").document(device_id).set(docs["installation"], merge=True)

    return {
        "success": True,
        "device_id": device_id,
        "message": "Device commissioned successfully",
    }