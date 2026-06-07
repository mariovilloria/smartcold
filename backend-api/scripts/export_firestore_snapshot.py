import json
from google.oauth2 import service_account
from datetime import datetime, timezone
from pathlib import Path

from google.cloud import firestore


COLLECTIONS = [
    "clients",
    "stores",
    "users",
    "devices",
    "device_config",
    "device_status",
    "device_registry",
    "installations",
]


def serialize_value(value):
    if isinstance(value, datetime):
        return value.isoformat()
    return value


def serialize_document(data):
    return {key: serialize_value(value) for key, value in data.items()}


def main():
    from google.oauth2 import service_account

    credentials = service_account.Credentials.from_service_account_file(
        "firebase-key.json"
    )

    db = firestore.Client(
        project=credentials.project_id,
        credentials=credentials,
    )

    snapshot = {
        "exported_at": datetime.now(timezone.utc).isoformat(),
        "collections": {},
    }

    for collection_name in COLLECTIONS:
        docs = db.collection(collection_name).stream()

        snapshot["collections"][collection_name] = {}

        for doc in docs:
            snapshot["collections"][collection_name][doc.id] = serialize_document(
                doc.to_dict()
            )

    output_dir = Path("exports")
    output_dir.mkdir(exist_ok=True)

    output_file = output_dir / "firestore_snapshot.json"

    with output_file.open("w", encoding="utf-8") as file:
        json.dump(snapshot, file, ensure_ascii=False, indent=2)

    print(f"✅ Exportado correctamente: {output_file}")


if __name__ == "__main__":
    main()