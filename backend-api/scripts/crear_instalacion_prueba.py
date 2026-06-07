import firebase_admin
from firebase_admin import credentials, firestore
from datetime import datetime
import uuid

DEVICE_ID = "SmartCold-5494"

if not firebase_admin._apps:
    cred = credentials.Certificate("firebase-key.json")
    firebase_admin.initialize_app(cred)

db = firestore.client()

now_iso = datetime.now().isoformat()

device_ref = db.collection("devices").document(DEVICE_ID)
device_doc = device_ref.get()

if not device_doc.exists:
    raise Exception(f"No existe el dispositivo {DEVICE_ID}")

device = device_doc.to_dict() or {}

installation_id = f"INS-{uuid.uuid4().hex[:8].upper()}"

installation_data = {
    "installation_id": installation_id,
    "device_id": DEVICE_ID,
    "client_id": device.get("client_id"),
    "store_id": device.get("store_id"),
    "equipment_name_at_installation": device.get("name"),
    "technician_id": None,
    "technician_name": None,
    "status": "pending_sensors",
    "wifi_configured": True,
    "sensors_detected": True,
    "sensors_assigned": False,
    "parameters_configured": False,
    "tests_completed": False,
    "detected_sensors": [],
    "started_at": now_iso,
    "completed_at": None,
    "cancelled_at": None,
    "created_at": now_iso,
    "updated_at": now_iso,
}

db.collection("installations").document(installation_id).set(installation_data)

device_ref.set(
    {
        "current_installation_id": installation_id,
        "installation_status": "pending_sensors",
        "updated_at": now_iso,
    },
    merge=True,
)

print("Instalación creada correctamente")
print("installation_id:", installation_id)
print("device_id:", DEVICE_ID)
