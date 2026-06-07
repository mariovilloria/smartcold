import firebase_admin
from firebase_admin import credentials, firestore
from datetime import datetime

OLD_DEVICE_ID = "SmartCold-5494"
NEW_DEVICE_ID = "SmartCold-2CBB74C55494"
NEW_HARDWARE_UID = "2CBB74C55494"

if not firebase_admin._apps:
    cred = credentials.Certificate("firebase-key.json")
    firebase_admin.initialize_app(cred)

db = firestore.client()
now_iso = datetime.now().isoformat()

old_config_ref = db.collection("device_config").document(OLD_DEVICE_ID)
old_config_doc = old_config_ref.get()

if not old_config_doc.exists:
    raise Exception(f"No existe device_config/{OLD_DEVICE_ID}")

config_data = old_config_doc.to_dict() or {}

config_data["device_id"] = NEW_DEVICE_ID
config_data["config_pending"] = True
config_data["updated_at"] = now_iso

# Limpiar colección device_config
for doc in db.collection("device_config").stream():
    doc.reference.delete()
    print("Eliminado:", doc.id)

# Crear solo la config del ESP viejo con su ID real
db.collection("device_config").document(NEW_DEVICE_ID).set(config_data)

# Crear/actualizar devices del ESP viejo como instalado
db.collection("devices").document(NEW_DEVICE_ID).set(
    {
        "device_id": NEW_DEVICE_ID,
        "hardware_uid": NEW_HARDWARE_UID,
        "status": "installed",
        "active": True,
        "configured": True,
        "provisioning_status": "configured",
        "name": "Congelador Coca Cola",
        "type": "congelador",
        "client_id": "client_1300000000",
        "store_id": "store_queseria_del_centro",
        "current_client_id": "client_1300000000",
        "current_store_id": "store_queseria_del_centro",
        "current_installation_id": "INS-14B798D7",
        "updated_at": now_iso,
    },
    merge=True,
)

print("\n✅ Listo")
print(f"device_config limpio y creado: {NEW_DEVICE_ID}")
print(f"devices actualizado: {NEW_DEVICE_ID}")