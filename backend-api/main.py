from fastapi import FastAPI
from pydantic import BaseModel
from datetime import datetime
from typing import Dict
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
    print("Timestamp:", datetime.now())
    db.collection("device_status").document(data.device_id).set(
        {
            "device_id": data.device_id,
            "temperature": data.temperature,
            "humidity": data.humidity,
            "rssi": data.rssi,
            "online": data.online,
            "updated_at": datetime.now().isoformat(),
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

    return {"success": True, "status": doc.to_dict()}
