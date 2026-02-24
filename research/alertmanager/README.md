# Alertmanager Webhook Integration (POC)

A proof-of-concept that lets aqsh automatically run task scripts in response to Prometheus alerts.

## Problem

Without this integration, aqsh tasks can only be triggered manually via `POST /tasks/{name}`. When a server has high memory, high latency, or any other issue that Prometheus detects, someone has to notice the alert and manually kick off the remediation script. This is slow and error-prone.

## Solution

Add a webhook endpoint (`POST /webhooks/alertmanager`) so Alertmanager can call aqsh directly when an alert fires. aqsh reads the alert payload, figures out which task to run, and executes the corresponding script automatically.

## How It Works

```
Prometheus (detects problem, e.g. high memory)
  |
  v
Alertmanager (groups alerts, waits group_wait, then sends webhook)
  |
  v
POST /webhooks/alertmanager  (aqsh receives the webhook)
  |
  v
aqsh reads aqsh_task label from alert → finds matching task in tasks.yaml → enqueues it
  |
  v
Worker picks up task → runs the shell script with alert context as env vars
```

## Alert Routing

Each Prometheus alert rule can include an `aqsh_task` label that tells aqsh which task to run. This allows different alerts to trigger different remediation scripts.

**Task name resolution order:**

1. `alert.labels.aqsh_task` (per-alert label)
2. `commonLabels.aqsh_task` (shared across alert group)
3. `alert.labels.alertname` (fallback: use the alert name itself)

**Example routing:**

| Alert Rule    | `aqsh_task` Label  | Script Executed       |
|---------------|--------------------|-----------------------|
| HighMemory    | `alert-handler`    | `alert-handler.sh`    |
| HighLatency   | `latency-handler`  | `latency-handler.sh`  |
| DiskFull      | *(none)*           | `DiskFull.sh` (fallback to alertname) |

## What Was Built

| File | Purpose |
|------|---------|
| `internal/webhook/alertmanager.go` | Parses Alertmanager payload, resolves task name (`ResolveTaskName`), maps alert fields to env vars (`AlertToEnv`) |
| `internal/webhook/alertmanager_test.go` | Unit tests for task resolution and env var mapping |
| `internal/api/api.go` | Registers `POST /webhooks/alertmanager` handler, iterates alerts, enqueues tasks |
| `tasks/alert-handler.sh` | Demo script for HighMemory alerts - logs alert details and simulates remediation |
| `tasks/latency-handler.sh` | Demo script for HighLatency alerts - logs latency info and simulates remediation |
| `tasks.yaml` | Task definitions for `alert-handler` and `latency-handler` |
| `research/alertmanager/*` | Full E2E test stack (this directory) |

## Environment Variables

Scripts receive alert context through environment variables:

| Variable | Description | Example |
|----------|-------------|---------|
| `ALERT_STATUS` | `firing` or `resolved` | `firing` |
| `ALERT_NAME` | Alert rule name | `HighMemory` |
| `ALERT_INSTANCE` | Source instance | `aqsh:8080` |
| `ALERT_SEVERITY` | Severity label | `critical` |
| `ALERT_FINGERPRINT` | Unique alert ID | `abc123...` |
| `ALERT_STARTS_AT` | When alert started (RFC3339) | `2025-01-15T10:00:00Z` |
| `ALERT_ENDS_AT` | When alert ended (RFC3339) | `0001-01-01T00:00:00Z` |
| `ALERT_GENERATOR_URL` | Prometheus URL for the alert | `http://prometheus:9090/...` |
| `ALERTMANAGER_EXTERNAL_URL` | Alertmanager URL | `http://alertmanager:9093` |
| `ALERT_GROUP_KEY` | Alert group key | `{}:{alertname="HighMemory"}` |
| `ALERT_LABELS_JSON` | All labels as JSON | `{"alertname":"HighMemory",...}` |
| `ALERT_ANNOTATIONS_JSON` | All annotations as JSON | `{"summary":"..."}` |
| `ALERT_LABEL_<KEY>` | Individual label (uppercased) | `ALERT_LABEL_SEVERITY=critical` |
| `ALERT_ANNOTATION_<KEY>` | Individual annotation (uppercased) | `ALERT_ANNOTATION_SUMMARY=...` |

## Running the E2E Test

```bash
bash research/alertmanager/test.sh
```

This starts a full docker-compose stack and validates the complete pipeline:

1. Starts Redis, aqsh, Prometheus, and Alertmanager
2. Waits for aqsh health check
3. Waits for Prometheus to fire both `HighMemory` and `HighLatency` alerts
4. Waits for Alertmanager to receive the alerts
5. Verifies aqsh enqueues both `alert-handler` and `latency-handler` tasks
6. Checks task completion and verifies log output contains expected strings
7. Cleans up all containers on exit

The test takes ~60-90 seconds (most of that is waiting for Prometheus evaluation cycles and Alertmanager group_wait).

## Files in This Directory

| File | Purpose |
|------|---------|
| `docker-compose.yaml` | Defines the 4-service stack: Redis, aqsh, Prometheus, Alertmanager |
| `prometheus.yml` | Prometheus config: scrapes aqsh metrics, sends alerts to Alertmanager |
| `alert-rules.yml` | Prometheus alert rules: `HighMemory` and `HighLatency` (both fire immediately for testing) |
| `alertmanager.yml` | Alertmanager config: routes all alerts to aqsh webhook endpoint |
| `test.sh` | E2E test script that starts the stack and validates the full pipeline |
