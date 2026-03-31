# aircraft-maintenance

Automated aircraft maintenance pipeline for a regional airline — tracks flight hours, schedules inspections, generates work orders, manages parts procurement, and issues airworthiness certificates for a 6-aircraft DHC-8-400 (Q400) fleet.

## Workflow Diagram

```
daily-ops (06:00 daily)
═══════════════════════
  ingest-flight-hours [cmd]
        │
  triage-snags [maintenance-controller]
        │
  schedule-inspections [fleet-planner]
        │
  review-schedule [fleet-planner] ◄─decision─►
        │ clear ──────────────────────────────► (done)
        │ schedule / urgent
        ▼

generate-work-order (on-demand)
═══════════════════════════════
  check-parts [parts-manager]
        │
  procure-parts [parts-manager] ◄─decision─►
        │ blocked ────────────────────────────► (done, flag for manual)
        │ ready / ordered
        ▼
  create-work-order [maintenance-controller]
        │
  validate-work-order [certifying-engineer] ◄─decision─►
        │ rework ─────────────────────────────► create-work-order (max 2x)
        │ approve
        ▼ (done, work order ready for execution)

certify-release (on-demand, after maintenance completion)
══════════════════════════════════════════════════════════
  review-completion [certifying-engineer]
        │
  assess-airworthiness [certifying-engineer] ◄─decision─►
        │ grounded ───────────────────────────► (done, aircraft AOG)
        │ serviceable / conditional
        ▼
  issue-certificate [certifying-engineer]
        │
  update-records [cmd]
        ▼ (done, aircraft returned to service)

weekly-fleet-review (07:00 Monday)
═══════════════════════════════════
  calculate-fleet-metrics [cmd]
        │
  analyze-fleet-health [fleet-planner]
        │
  compile-fleet-report [reporter]
        ▼ reports/weekly-fleet-YYYY-WNN.md
```

## Quick Start

```bash
cd examples/aircraft-maintenance
ao daemon start

# Run daily ops manually
ao workflow run daily-ops

# Trigger work order generation (after daily-ops flags schedule/urgent)
ao workflow run generate-work-order

# Certify an aircraft after maintenance is complete
ao workflow run certify-release

# Generate weekly fleet report
ao workflow run weekly-fleet-review
```

## Agents

| Agent | Model | Role |
|---|---|---|
| **fleet-planner** | claude-opus-4-6 | Strategic scheduler — balances fleet availability, prioritizes inspection windows, prevents simultaneous heavy maintenance |
| **maintenance-controller** | claude-sonnet-4-6 | Operations — triages pilot snags, generates work orders from task card templates, manages MEL deferred items |
| **parts-manager** | claude-haiku-4-5 | Logistics — checks rotable inventory, tracks component life limits, generates procurement orders |
| **certifying-engineer** | claude-sonnet-4-6 | Safety gate — validates work orders, reviews completed maintenance, issues Certificates of Release to Service |
| **reporter** | claude-haiku-4-5 | Analytics — aggregates fleet metrics, produces weekly management reports with trend analysis |

## AO Features Demonstrated

- **Scheduled workflows** — `daily-ops` at 06:00 daily, `weekly-fleet-review` Monday 07:00
- **Decision routing** — `review-schedule` branches to different downstream workflows based on urgency
- **Rework loops** — `validate-work-order` sends work orders back to `create-work-order` up to 2 times
- **Command phases** — shell scripts for data ingestion, metrics aggregation, record updates
- **Agent phases** — specialized agents with domain-specific system prompts
- **Manual safety gate** — `assess-airworthiness` uses sequential-thinking for life-safety decisions
- **Multi-model** — Opus for complex scheduling, Sonnet for operational control and QA, Haiku for logistics and reporting
- **Post-success merge** — approved work orders and CRS documents auto-merge to main via PR

## Requirements

### API Keys
None required — all processing is local file-based.

### Tools
- `npx` (Node.js / npm) — for MCP servers
- `python3` — for data processing scripts
- `jq` — for JSON manipulation in scripts
- `ao` daemon

### MCP Servers (auto-installed via npx)
- `@modelcontextprotocol/server-filesystem` — read/write config, data, reports
- `@modelcontextprotocol/server-sequential-thinking` — structured reasoning for scheduling and airworthiness decisions

## File Structure

```
aircraft-maintenance/
├── .ao/workflows/
│   ├── agents.yaml               # 5 agents: fleet-planner, maintenance-controller, parts-manager,
│   │                             #           certifying-engineer, reporter
│   ├── phases.yaml               # 13 phases across 4 workflows
│   ├── workflows.yaml            # 4 workflows: daily-ops, generate-work-order,
│   │                             #              certify-release, weekly-fleet-review
│   ├── mcp-servers.yaml          # filesystem + sequential-thinking
│   └── schedules.yaml            # daily 06:00 + weekly Monday 07:00
├── config/
│   ├── fleet-manifest.yaml       # 6 Q400 aircraft with hours/cycles (mutable)
│   ├── inspection-intervals.yaml # Regulatory A/B/C/D check intervals + ADs (static)
│   ├── parts-catalog.yaml        # ~30 rotable parts with life-limit tracking (mutable)
│   ├── task-card-templates.yaml  # Standard task cards per check type (static)
│   └── mel-items.yaml            # MEL deferred items with categories (mutable)
├── data/
│   ├── flight-log.json           # Appended daily by ingest script
│   ├── inspection-status.json    # Per-aircraft inspection tracker
│   ├── fleet-health.json         # Aggregated fleet metrics
│   ├── parts-orders.json         # Procurement log
│   ├── work-orders/              # Generated work orders (WO-YYYY-NNN.json)
│   ├── airworthiness-certs/      # CRS documents (CRS-YYYY-NNN.json)
│   └── history/                  # Archived snapshots
├── scripts/
│   ├── ingest-flight-hours.sh    # Parse flight CSV → update manifest + flight-log.json
│   ├── calculate-fleet-metrics.sh# Aggregate fleet health data
│   └── update-records.sh         # Post-maintenance record updates
└── reports/                      # Weekly fleet health reports (markdown)
```

## Aviation Domain Notes

- **A-check**: Light inspection every ~600 FH, 1-2 days in-house
- **B-check**: Intermediate check every ~6 months, 2-3 days in-house
- **C-check**: Heavy check every ~6000 FH, 2-3 weeks at MRO
- **D-check**: Structural overhaul every ~24000 FH, 1-2 months at MRO
- **AD**: Airworthiness Directive — mandatory compliance, no extensions
- **MEL**: Minimum Equipment List — categories A (per flight manual), B (3 days), C (10 days), D (120 days)
- **CRS**: Certificate of Release to Service — required before any aircraft returns to service
- **Fleet rule**: Minimum 4 of 6 aircraft serviceable at all times for daily operations
