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
installation_doc = installation_ref.get()

if not installation_doc.exists:
    raise Exception(f"No existe la instalación {installation_id}")

installation = installation_doc.to_dict() or {}

phase = (
    installation.get("phase")
    or installation.get("installation_phase")
    or "pending_sensor_roles"
)

device_ref.update({
    "status": "assigned",
    "installation_status": firestore.DELETE_FIELD,
    "installation_phase": firestore.DELETE_FIELD,
    "updated_at": now_iso,
})

installation_ref.update({
    "status": "in_progress",
    "phase": phase,
    "installation_phase": firestore.DELETE_FIELD,
    "updated_at": now_iso,
})

print("Normalización completada")
print("device_id:", DEVICE_ID)
print("device.status: assigned")
print("installation_id:", installation_id)
print("installation.status: in_progress")
print("installation.phase:", phase)