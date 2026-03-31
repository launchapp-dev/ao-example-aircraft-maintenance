# Aircraft Maintenance — Agent Context

## What This Project Is

An automated aircraft maintenance pipeline for a small regional airline operating 6 turboprop aircraft (DHC-8-400 / Q400). The system manages four workflows at different cadences: daily flight-hour ingestion and inspection scheduling, on-demand work-order generation when inspections come due, weekly fleet health reporting, and event-driven airworthiness certification after heavy maintenance.

Aviation maintenance is safety-critical and highly regulated (FAA 14 CFR Part 121 / EASA Part-M). Every maintenance action must be traceable, every inspection interval respected, and every aircraft released to service by a qualified certifying authority. This pipeline demonstrates AO handling life-safety workflows with strict regulatory gates.

## Data Model — What's in Each File

| File | What It Contains | Who Reads It | Who Writes It |
|---|---|---|---|
| `config/fleet-manifest.yaml` | Aircraft registry: tail numbers, MSN, type, engine type, delivery date, current hours/cycles | All agents | ingest-flight-hours.sh (updates hours/cycles) |
| `config/inspection-intervals.yaml` | Regulatory inspection schedule: A-check (600 FH), B-check (6 months), C-check (6000 FH), D-check (24000 FH), plus AD compliance intervals | fleet-planner, maintenance-controller | Never modified (static regulatory data) |
| `config/parts-catalog.yaml` | Rotable parts inventory: part numbers, descriptions, serial numbers, time-since-overhaul, life limits, locations (on-wing / warehouse / MRO shop) | parts-manager | parts-manager (updates after procurement/rotation) |
| `config/task-card-templates.yaml` | Standard task cards per check type: task ID, description, zone, estimated hours, skill required, tooling, parts consumed | maintenance-controller | Never modified (static reference) |
| `config/mel-items.yaml` | Minimum Equipment List deferred items: ATA chapter, description, deferral category (A/B/C/D), max deferral period, current deferrals per aircraft | fleet-planner, certifying-engineer | maintenance-controller (updates after rectification) |
| `data/flight-log.json` | Daily flight records: tail number, flight number, origin, destination, block hours, cycles, pilot remarks (snags) | fleet-planner, maintenance-controller | ingest-flight-hours.sh (appends daily) |
| `data/inspection-status.json` | Per-aircraft inspection tracker: last completion date/hours for each check type, next-due date/hours, remaining margin | fleet-planner, maintenance-controller | schedule-inspections phase |
| `data/work-orders/` | Individual work order files (WO-YYYY-NNN.json): aircraft, check type, task list, parts required, labor estimate, assigned bay, status | maintenance-controller, parts-manager, certifying-engineer | generate-work-order phase |
| `data/parts-orders.json` | Parts procurement log: part number, quantity, vendor, PO number, expected delivery, status | parts-manager | procure-parts phase |
| `data/airworthiness-certs/` | Airworthiness release certificates (CRS-YYYY-NNN.json): aircraft, work performed, conformity statement, certifying engineer, date, limitations | certifying-engineer | certify-airworthiness phase |
| `data/fleet-health.json` | Aggregated fleet metrics: utilization rates, upcoming inspection windows, MEL item count, parts availability, reliability dispatch rate | reporter | calculate-fleet-metrics.sh |
| `data/history/` | Archived weekly fleet health snapshots and completed work orders for trend analysis | reporter | calculate-fleet-metrics.sh |
| `reports/` | Weekly fleet health reports and post-maintenance summaries (markdown) | Management reference | reporter |

## Domain Terminology

**Flight Hours (FH)** — Total airframe time in flight. Primary meter for maintenance intervals. A Q400 in regional service accumulates ~2500 FH/year.

**Cycles** — One takeoff-and-landing pair. Regional turboprops accumulate high cycles relative to hours (short sectors). Critical for fatigue-life items like landing gear and pressurized fuselage.

**A-Check** — Light maintenance inspection every ~600 FH. Takes 1-2 days. Performed in-house at the operator's hangar. Covers general visual inspection, lubrication, minor component replacement.

**B-Check** — Intermediate inspection approximately every 6 months. Takes 2-3 days. Covers more detailed systems checks, filter replacements, and operational tests.

**C-Check** — Heavy maintenance every ~6000 FH (roughly every 2 years). Takes 2-3 weeks. Aircraft is out of service. Structural inspections, component overhauls, major systems testing. Often contracted to an MRO facility.

**D-Check** — Structural overhaul every ~24000 FH (roughly every 8 years). Takes 1-2 months. Complete strip-down and rebuild. Almost always at a specialized MRO.

**AD (Airworthiness Directive)** — Mandatory safety modification or inspection issued by the aviation authority. Must be completed within prescribed intervals or the aircraft is grounded.

**MEL (Minimum Equipment List)** — List of equipment that may be inoperative while still allowing dispatch. Each item has a deferral category (A: per flight manual, B: 3 days, C: 10 days, D: 120 days). Deferred items must be tracked and rectified within limits.

**Rotable** — A component that is repaired/overhauled and returned to service rather than discarded. Tracked by serial number with time-since-overhaul (TSO) limits.

**CRS (Certificate of Release to Service)** — The formal document that certifies maintenance has been performed correctly and the aircraft is airworthy. Must be signed by an authorized certifying engineer.

**Task Card** — A specific maintenance instruction: what to inspect/replace/test, where on the aircraft (zone), tools needed, parts consumed, estimated labor hours.

**MRO** — Maintenance, Repair, and Overhaul facility. External shops that perform heavy maintenance.

## Key Invariants Agents Must Respect

1. **Inspection intervals are hard limits**: An aircraft MUST NOT fly past its next-due inspection. If remaining margin < 50 FH or 7 days, the aircraft must be flagged for immediate scheduling.

2. **MEL deferral limits are absolute**: A Category B deferral expires after 3 calendar days. If not rectified, the aircraft is grounded. Never extend a deferral beyond its category limit.

3. **Work orders require parts availability**: Never generate a work order and schedule it unless all required parts are either in stock or have confirmed delivery before the planned induction date.

4. **CRS traceability**: Every airworthiness certificate must reference specific work order numbers, task card IDs completed, and conformity statements. No aircraft may return to service without a valid CRS.

5. **Fleet utilization balance**: When scheduling maintenance, consider fleet-wide impact. Never schedule more than 2 aircraft for simultaneous heavy maintenance (C/D checks) — the airline needs minimum 4 aircraft available for daily operations.

6. **Pilot snags require assessment**: Any pilot-reported defect in the flight log must be triaged within 24 hours. Safety-critical snags (engine, flight controls, landing gear) ground the aircraft until assessed.

7. **Parts life limits are non-negotiable**: A rotable part that has reached its life limit (TSO or total time) must be removed regardless of apparent condition. No extensions.

## Agents

| Agent | Model | Role |
|---|---|---|
| **fleet-planner** | claude-opus-4-6 | Strategic brain — analyzes inspection schedules, prioritizes maintenance windows, balances fleet availability. Uses sequential-thinking for complex scheduling decisions. |
| **maintenance-controller** | claude-sonnet-4-6 | Operational manager — generates work orders, assigns task cards, coordinates with parts availability, manages MEL items. |
| **parts-manager** | claude-haiku-4-5 | Logistics — checks parts inventory, identifies shortages, generates procurement orders, tracks rotable component life. |
| **certifying-engineer** | claude-sonnet-4-6 | Quality gate — reviews completed work orders, verifies conformity, issues airworthiness certificates. Safety-critical decision maker. |
| **reporter** | claude-haiku-4-5 | Analytics — compiles fleet health metrics, generates weekly status reports, tracks reliability trends. |

## Workflows

### 1. `daily-ops` (scheduled: daily at 06:00)
Ingest yesterday's flight data, update aircraft hours/cycles, check inspection intervals, flag upcoming maintenance, triage pilot snags.

**Phases:**
1. `ingest-flight-hours` (command) — Parse flight log CSV, update fleet manifest hours/cycles, append to flight-log.json
2. `triage-snags` (agent: maintenance-controller) — Review pilot remarks from yesterday's flights. Safety-critical snags → ground aircraft. Minor snags → add to MEL or schedule rectification.
3. `schedule-inspections` (agent: fleet-planner) — Calculate remaining margin for all inspection types across fleet. Flag aircraft approaching limits. Produce scheduling recommendations.
4. `review-schedule` (agent: fleet-planner, decision) — Review the scheduling recommendations. Verdict: `clear` (no action needed), `schedule` (inspections need work orders), `urgent` (aircraft must be grounded or immediately inducted).

### 2. `generate-work-order` (on-demand, triggered when daily-ops verdict = schedule/urgent)
Create detailed work orders for upcoming maintenance events.

**Phases:**
1. `check-parts` (agent: parts-manager) — For the planned maintenance, check parts catalog for availability of all required items. Identify shortages.
2. `procure-parts` (agent: parts-manager, decision) — If shortages exist, generate procurement orders. Verdict: `ready` (all parts available), `ordered` (parts ordered, delivery confirmed before induction), `blocked` (critical parts unavailable, cannot schedule).
3. `create-work-order` (agent: maintenance-controller) — Generate the complete work order: task card assignments, labor estimates, bay allocation, induction date, parts reservation.
4. `validate-work-order` (agent: certifying-engineer, decision) — Review work order for completeness and regulatory compliance. Verdict: `approve` (ready to execute), `rework` (missing items or non-compliant), `reject` (fundamental issues).

### 3. `certify-release` (on-demand, triggered after maintenance completion)
Post-maintenance airworthiness certification.

**Phases:**
1. `review-completion` (agent: certifying-engineer) — Review completed work order: all task cards signed off, all replaced parts documented with serial numbers, all AD compliance noted.
2. `assess-airworthiness` (agent: certifying-engineer, decision) — Make the airworthiness determination. Verdict: `serviceable` (aircraft cleared for return to service), `conditional` (cleared with limitations/MEL items), `grounded` (safety findings require further work).
3. `issue-certificate` (agent: certifying-engineer) — Generate the formal CRS document with conformity statements, references, and limitations (if conditional).
4. `update-records` (command) — Update fleet manifest, inspection status, MEL items, and parts catalog to reflect completed maintenance.

### 4. `weekly-fleet-review` (scheduled: every Monday at 07:00)
Fleet-wide health assessment and management reporting.

**Phases:**
1. `calculate-fleet-metrics` (command) — Aggregate utilization rates, inspection margins, MEL counts, parts availability, dispatch reliability across all aircraft.
2. `analyze-fleet-health` (agent: fleet-planner) — Assess fleet health trends. Identify aircraft with deteriorating reliability, upcoming heavy-maintenance windows, parts supply risks.
3. `compile-fleet-report` (agent: reporter) — Generate the weekly fleet health report: utilization dashboard, maintenance forecast, risk items, procurement status.

## Phase Routing Summary

```
daily-ops:
  ingest-flight-hours → triage-snags → schedule-inspections → review-schedule
    review-schedule verdicts:
      clear → done
      schedule → (triggers generate-work-order)
      urgent → (triggers generate-work-order with priority flag)

generate-work-order:
  check-parts → procure-parts → create-work-order → validate-work-order
    procure-parts verdicts:
      ready → create-work-order
      ordered → create-work-order
      blocked → done (cannot proceed, flag for manual intervention)
    validate-work-order verdicts:
      approve → done (work order ready for execution)
      rework → create-work-order (fix and resubmit)
      reject → done (fundamental issue, flag for manual review)

certify-release:
  review-completion → assess-airworthiness → issue-certificate → update-records
    assess-airworthiness verdicts:
      serviceable → issue-certificate
      conditional → issue-certificate (with limitations)
      grounded → done (aircraft remains AOG, requires further maintenance)

weekly-fleet-review:
  calculate-fleet-metrics → analyze-fleet-health → compile-fleet-report
```

## Supporting Files to Create

### Config files:
- `config/fleet-manifest.yaml` — 6 Q400 aircraft with realistic tail numbers, hours, cycles
- `config/inspection-intervals.yaml` — A/B/C/D check intervals plus sample ADs
- `config/parts-catalog.yaml` — ~30 rotable parts with life-limit tracking
- `config/task-card-templates.yaml` — Standard task cards per check type
- `config/mel-items.yaml` — Sample MEL with current deferrals

### Scripts:
- `scripts/ingest-flight-hours.sh` — Python-via-bash script to parse flight data and update manifest
- `scripts/calculate-fleet-metrics.sh` — Aggregate fleet health metrics
- `scripts/update-records.sh` — Post-maintenance record updates

### Sample data:
- `data/flight-log.json` — 2 weeks of sample flight data for 6 aircraft
- `data/inspection-status.json` — Current inspection status per aircraft
- `data/fleet-health.json` — Initial fleet health snapshot
- `data/parts-orders.json` — Empty initial state

### Directories:
- `data/work-orders/` — Will contain generated work orders
- `data/airworthiness-certs/` — Will contain CRS documents
- `data/history/` — Will contain archived snapshots
- `reports/` — Will contain generated reports

## MCP Servers Used

| Server | Purpose |
|---|---|
| `filesystem` | Read/write all config, data, and report files |
| `sequential-thinking` | Complex scheduling decisions (fleet-planner), airworthiness assessments (certifying-engineer) |
