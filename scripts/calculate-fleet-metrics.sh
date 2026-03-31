#!/usr/bin/env bash
# calculate-fleet-metrics.sh
# Aggregates fleet-wide maintenance and utilization metrics.
# Reads from all data sources and writes updated data/fleet-health.json.
# Archives previous snapshot to data/history/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

FLEET_HEALTH="$PROJECT_ROOT/data/fleet-health.json"
INSPECTION_STATUS="$PROJECT_ROOT/data/inspection-status.json"
FLIGHT_LOG="$PROJECT_ROOT/data/flight-log.json"
MEL_ITEMS="$PROJECT_ROOT/config/mel-items.yaml"
PARTS_ORDERS="$PROJECT_ROOT/data/parts-orders.json"
HISTORY_DIR="$PROJECT_ROOT/data/history"
FLEET_MANIFEST="$PROJECT_ROOT/config/fleet-manifest.yaml"

TODAY=$(date +%Y-%m-%d)

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "Starting fleet metrics calculation for $TODAY"

# Archive previous fleet health snapshot
mkdir -p "$HISTORY_DIR"
if [[ -f "$FLEET_HEALTH" ]]; then
    PREV_DATE=$(python3 -c "import json; d=json.load(open('$FLEET_HEALTH')); print(d.get('snapshot_date','unknown'))")
    cp "$FLEET_HEALTH" "$HISTORY_DIR/fleet-health-${PREV_DATE}.json"
    log "Archived previous snapshot: fleet-health-${PREV_DATE}.json"
fi

# Calculate metrics using Python
python3 - <<PYEOF
import json, re, os
from datetime import datetime, timedelta
from collections import defaultdict

project_root = "$PROJECT_ROOT"
today = datetime.strptime("$TODAY", "%Y-%m-%d")

# Load all data sources
with open(os.path.join(project_root, "data", "flight-log.json")) as f:
    flight_log = json.load(f)

with open(os.path.join(project_root, "data", "inspection-status.json")) as f:
    inspection_status = json.load(f)

with open(os.path.join(project_root, "data", "parts-orders.json")) as f:
    parts_orders = json.load(f)

# Calculate 7-day utilization
week_ago = today - timedelta(days=7)
weekly_totals = defaultdict(lambda: {"fh": 0.0, "cycles": 0, "flights": 0})
snag_count = 0
total_flights = 0
completed_flights = 0

for day in flight_log:
    day_date = datetime.strptime(day["date"], "%Y-%m-%d")
    if week_ago <= day_date <= today:
        for flight in day["flights"]:
            weekly_totals[flight["tail"]]["fh"] += flight["block_hours"]
            weekly_totals[flight["tail"]]["cycles"] += flight["cycles"]
            weekly_totals[flight["tail"]]["flights"] += 1
            total_flights += 1
            completed_flights += 1
            if flight.get("pilot_remarks"):
                snag_count += 1

# Build per-aircraft utilization
aircraft_util = []
fleet_daily_avg = 0.0
for ac in inspection_status["aircraft"]:
    tail = ac["tail_number"]
    weekly = weekly_totals.get(tail, {"fh": 0.0, "cycles": 0, "flights": 0})
    daily_avg = weekly["fh"] / 7
    fleet_daily_avg += daily_avg
    aircraft_util.append({
        "tail": tail,
        "weekly_fh": round(weekly["fh"], 1),
        "daily_avg": round(daily_avg, 2),
        "cycles": weekly["cycles"],
        "vs_target_pct": round((daily_avg / 8.0) * 100, 1)
    })

fleet_daily_avg = round(fleet_daily_avg / len(inspection_status["aircraft"]), 2)

# Build inspection urgency summary
urgent = []
schedule = []
ok_count = 0

for ac in inspection_status["aircraft"]:
    tail = ac["tail_number"]
    for check_name, check in ac.get("inspections", {}).items():
        remaining_fh = check.get("remaining_hours", 9999)
        remaining_days = check.get("remaining_days", 9999)
        status = check.get("status", "ok")

        if status == "ok":
            ok_count += 1
        elif status == "urgent" or remaining_fh < 50 or remaining_days < 7:
            urgent.append({"tail": tail, "check_type": check_name,
                          "remaining_fh": remaining_fh if remaining_fh < 9999 else None,
                          "remaining_days": remaining_days if remaining_days < 9999 else None,
                          "notes": check.get("notes", "")})
        elif status == "schedule" or remaining_fh < 200 or (0 < remaining_days < 30):
            schedule.append({"tail": tail, "check_type": check_name,
                            "remaining_fh": remaining_fh if remaining_fh < 9999 else None,
                            "remaining_days": remaining_days if remaining_days < 9999 else None,
                            "notes": check.get("notes", "")})
        else:
            ok_count += 1

# MEL status
open_mel = [ac for ac in inspection_status["aircraft"] if ac.get("open_mel_items", 0) > 0]
mel_expiring = []
for ac in open_mel:
    if "mel_notes" in ac:
        mel_expiring.append({"tail": ac["tail_number"], "notes": ac["mel_notes"]})

# Parts orders
open_orders = [o for o in parts_orders if o.get("status") not in ("delivered", "cancelled")]

# Reliability metrics
dispatch_rel = round((completed_flights / total_flights * 100) if total_flights > 0 else 100.0, 1)
total_fh = sum(v["fh"] for v in weekly_totals.values())
snag_rate = round((snag_count / total_fh * 100) if total_fh > 0 else 0.0, 2)

# Build risk items
risk_items = []
for item in urgent:
    risk_items.append({
        "severity": "high",
        "aircraft": item["tail"],
        "description": f"{item['check_type']} approaching hard limit. {item.get('notes', '')}",
        "action_required": True
    })
for item in mel_expiring:
    risk_items.append({
        "severity": "medium",
        "aircraft": item["tail"],
        "description": item["notes"],
        "action_required": True
    })
for item in schedule:
    risk_items.append({
        "severity": "low",
        "aircraft": item["tail"],
        "description": f"{item['check_type']} in planning window. {item.get('notes', '')}",
        "action_required": False
    })

# Write updated fleet health
fleet_health = {
    "snapshot_date": "$TODAY",
    "fleet_size": len(inspection_status["aircraft"]),
    "aircraft_serviceable": sum(1 for ac in inspection_status["aircraft"] if ac.get("status", "serviceable") == "serviceable"),
    "aircraft_grounded": sum(1 for ac in inspection_status["aircraft"] if ac.get("status") == "grounded"),
    "fleet_availability_pct": round(sum(1 for ac in inspection_status["aircraft"] if ac.get("status", "serviceable") == "serviceable") / len(inspection_status["aircraft"]) * 100, 1),
    "utilization": {
        "period_start": (today - timedelta(days=7)).strftime("%Y-%m-%d"),
        "period_end": "$TODAY",
        "target_daily_fh_per_aircraft": 8.0,
        "fleet_totals": {
            "block_hours": round(sum(v["fh"] for v in weekly_totals.values()), 1),
            "cycles": sum(v["cycles"] for v in weekly_totals.values()),
            "days_in_period": 7
        },
        "per_aircraft": aircraft_util,
        "fleet_daily_avg_fh": fleet_daily_avg,
        "fleet_utilization_pct": round((fleet_daily_avg / 8.0) * 100, 1)
    },
    "inspection_summary": {
        "urgent": urgent,
        "schedule": schedule,
        "ok_count": ok_count
    },
    "mel_status": {
        "total_open_items": sum(ac.get("open_mel_items", 0) for ac in inspection_status["aircraft"]),
        "expiring_within_7_days": mel_expiring,
        "by_aircraft": [{"tail": ac["tail_number"], "open": ac.get("open_mel_items", 0)} for ac in inspection_status["aircraft"]]
    },
    "parts_procurement": {
        "open_orders": len(open_orders),
        "critical_shortages": [],
        "open_order_details": open_orders
    },
    "reliability": {
        "period": f"{(today - timedelta(days=29)).strftime('%Y-%m-%d')} to $TODAY",
        "flights_planned": total_flights,
        "flights_completed": completed_flights,
        "dispatch_reliability_pct": dispatch_rel,
        "snag_rate_per_100fh": snag_rate
    },
    "risk_items": risk_items
}

output_path = os.path.join(project_root, "data", "fleet-health.json")
with open(output_path, "w") as f:
    json.dump(fleet_health, f, indent=2)

print(f"Fleet health snapshot written to data/fleet-health.json")
print(f"Fleet availability: {fleet_health['fleet_availability_pct']}%")
print(f"Urgent items: {len(urgent)}, Schedule items: {len(schedule)}")
print(f"Dispatch reliability: {dispatch_rel}%, Snag rate: {snag_rate}/100FH")
PYEOF

log "Fleet metrics calculation complete."
