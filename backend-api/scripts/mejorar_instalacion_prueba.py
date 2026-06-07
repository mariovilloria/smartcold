import firebase_admin
from firebase_admin import credentials, firestore
from datetime import datetime

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
installation_id = device.get("current_installation_id")

if not installation_id:
    raise Exception("El dispositivo no tiene current_installation_id")

installation_ref = db.collection("installations").document(installation_id)

installation_ref.set(
    {
        "installation_phase": "pending_sensor_roles",
        "technicians": [],
        "updated_at": now_iso,
    },
    merge=True,
)

device_ref.set(
    {
        "installation_phase": "pending_sensor_roles",
        "updated_at": now_iso,
    },
    merge=True,
)

print("Instalación mejorada correctamente")
print("installation_id:", installation_id)
print("installation_phase: pending_sensor_roles")
