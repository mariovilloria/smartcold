import json
import firebase_admin
from firebase_admin import credentials, firestore

DEVICE_ID = "SmartCold-5494"

if not firebase_admin._apps:
    cred = credentials.Certificate("firebase-key.json")
    firebase_admin.initialize_app(cred)

db = firestore.client()

doc_ref = db.collection("device_config").document(DEVICE_ID)
doc = doc_ref.get()

if not doc.exists:
    print(f"❌ No existe device_config/{DEVICE_ID}")
    exit()

data = doc.to_dict()

print(f"\n✅ device_config/{DEVICE_ID}\n")
print(json.dumps(data, indent=2, ensure_ascii=False, default=str))