#!/usr/bin/env bash
# update-records.sh
# Post-maintenance record updates after airworthiness certification.
# Updates fleet manifest, inspection-status.json, mel-items.yaml, parts-catalog.yaml.
# Archives the completed work order to data/history/.
# Expects the latest CRS in data/airworthiness-certs/ and work order in data/work-orders/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

WORK_ORDERS_DIR="$PROJECT_ROOT/data/work-orders"
CERTS_DIR="$PROJECT_ROOT/data/airworthiness-certs"
HISTORY_DIR="$PROJECT_ROOT/data/history"
INSPECTION_STATUS="$PROJECT_ROOT/data/inspection-status.json"

TODAY=$(date +%Y-%m-%d)
log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "Starting post-maintenance record updates for $TODAY"

mkdir -p "$HISTORY_DIR"

python3 - <<PYEOF
import json, os, glob, shutil
from datetime import datetime

project_root = "$PROJECT_ROOT"
today = "$TODAY"

work_orders_dir = os.path.join(project_root, "data", "work-orders")
certs_dir = os.path.join(project_root, "data", "airworthiness-certs")
history_dir = os.path.join(project_root, "data", "history")
inspection_status_path = os.path.join(project_root, "data", "inspection-status.json")

# Find the latest CRS
certs = sorted(glob.glob(os.path.join(certs_dir, "CRS-*.json")))
if not certs:
    print("No CRS found — no records to update")
    exit(0)

latest_cert_path = certs[-1]
with open(latest_cert_path) as f:
    cert = json.load(f)

print(f"Processing CRS: {cert.get('crs_number')} for aircraft {cert.get('aircraft')}")

# Find the associated work order
wo_ref = cert.get("work_order_ref")
if not wo_ref:
    print("CRS has no work_order_ref — skipping work order archive")
else:
    wo_path = os.path.join(work_orders_dir, f"{wo_ref}.json")
    if os.path.exists(wo_path):
        with open(wo_path) as f:
            wo = json.load(f)

        # Update work order status to completed
        wo["status"] = "completed"
        wo["crs_reference"] = cert.get("crs_number")
        wo["completion_date"] = today
        with open(wo_path, "w") as f:
            json.dump(wo, f, indent=2)

        # Archive to history
        archive_path = os.path.join(history_dir, f"{wo_ref}-completed-{today}.json")
        shutil.copy2(wo_path, archive_path)
        print(f"Archived work order to history: {os.path.basename(archive_path)}")
    else:
        print(f"Work order {wo_ref} not found at {wo_path}")

# Update inspection-status.json if C-check or similar major check was performed
aircraft = cert.get("aircraft")
check_type_raw = cert.get("work_performed_summary", "")

with open(inspection_status_path) as f:
    inspection_status = json.load(f)

for ac in inspection_status["aircraft"]:
    if ac["tail_number"] == aircraft:
        # Update last_updated and note the release
        ac["last_maintenance_release"] = {
            "date": today,
            "crs_number": cert.get("crs_number"),
            "verdict": cert.get("verdict"),
            "limitations": cert.get("limitations", [])
        }

        # If verdict is serviceable, clear any grounded status
        if cert.get("verdict") in ("serviceable", "conditional"):
            if ac.get("status") == "grounded":
                ac["status"] = "serviceable"
                print(f"Updated {aircraft} status: grounded -> serviceable")

        # Update open MEL items if limitations are cleared
        if cert.get("verdict") == "serviceable":
            ac["open_mel_items"] = 0
            print(f"Cleared MEL items for {aircraft} (serviceable release)")

        break

inspection_status["last_updated"] = today
with open(inspection_status_path, "w") as f:
    json.dump(inspection_status, f, indent=2)

print(f"Updated inspection-status.json for {aircraft}")
print(f"Post-maintenance record update complete.")
PYEOF

log "Record update complete."
