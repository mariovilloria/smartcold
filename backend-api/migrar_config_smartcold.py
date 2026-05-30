from datetime import datetime
import firebase_admin
from firebase_admin import credentials, firestore

cred = credentials.Certificate("firebase-key.json")
firebase_admin.initialize_app(cred)

db = firestore.client()

DEVICE_ID = "SmartCold-5494"

config = {
    "device_id": DEVICE_ID,
    "config_version": 1,
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
            "address": "285150C0000000AB",
            "enabled": True,
            "offset": 0,
            "alarm_enabled": True,
            "temp_min_alarm": 0,
            "temp_max_alarm": 8,
            "can_stop_compressor": True,
        },
        {
            "id": "evaporator_1",
            "role": "evaporator",
            "name": "Sonda evaporador",
            "type": "ds18b20",
            "bus": "onewire",
            "pin": 4,
            "address": "28F15CC0000000D6",
            "enabled": True,
            "offset": 0,
            "alarm_enabled": True,
            "temp_min_alarm": -20,
            "temp_max_alarm": 15,
            "can_stop_compressor": False,
        },
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

db.collection("device_config").document(DEVICE_ID).set(config)

print("✅ Configuración migrada correctamente")
