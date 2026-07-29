# Runbook: On-Call

## Where alerts come from

Prometheus evaluates the rules in `monitoring/prometheus/alert-rules.yaml`
continuously and sends firing alerts to Alertmanager (bundled with the
`kube-prometheus-stack` Helm release). This demo doesn't wire Alertmanager
to a real notification channel (Slack/PagerDuty/email) - see "Production
enhancement" below - so for now, alerts are checked via:

- Alertmanager's UI: `kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093`, then open `http://localhost:9093`
- Prometheus's own alert list: `http://localhost:30090/alerts` (NodePort, no port-forward needed)
- The **Alertmanager / Overview** Grafana dashboard (bundled by default with kube-prometheus-stack)

## First response checklist

1. **What's actually firing?** Check the alert's `severity` label -
   `critical` vs `warning` - and which `namespace` it's scoped to.
2. **Is it isolated to one environment, or all three?** If all three fire
   the same alert simultaneously, suspect something cluster-wide (node
   resource pressure, the monitoring stack itself, a bad shared change)
   rather than an application bug in one service.
3. **Check the relevant Grafana dashboard first**, not raw `kubectl`
   commands - the 5 dashboards under `monitoring/grafana/dashboards/` are
   built specifically to answer "what changed right before this fired."
4. **Consult `troubleshooting.md`** for the specific alert name - each of
   the 12 rules has a documented first-check.

## Alert severity guide (from `alert-rules.yaml`)

| Severity | Meaning | Response expectation |
|---|---|---|
| `critical` | User-facing impact likely already happening (Postgres down, high error rate, worker stalled, imminent OOM) | Respond immediately |
| `warning` | Heading toward a problem, not yet critical (resource pressure, quota approaching limit, HPA maxed) | Respond same business day; don't let it silently become critical |

## Escalation

This is a demo project without a real on-call rotation. In a production
setup, the natural extension here is:
- Alertmanager routes `severity: critical` to PagerDuty/Opsgenie with a
  short acknowledgement SLA, and `severity: warning` to a Slack channel
  with no page.
- A `route` block in Alertmanager's config groups alerts by `namespace` so
  a production incident doesn't get lost in a wall of unrelated
  development-namespace warnings.

## Common on-call scenarios

**"Everything in production is throwing 500s."**
1. Check `HighAPIErrorRate` in Prometheus/Alertmanager to confirm scope.
2. `kubectl logs deployment/api -n production --tail=50` for the actual error.
3. If it correlates with a recent deploy: `kubectl rollout undo deployment/api -n production` -
   this is the same command `scripts/deploy.sh` runs automatically on a
   failed rollout, but a bad deploy that *passes* its health check yet
   still misbehaves under real traffic wouldn't be caught automatically,
   so a manual rollback is still a valid on-call action.

**"Jobs aren't being processed."**
1. `WorkerStalled` firing means the poll loop itself has stopped - check
   `kubectl logs deployment/worker -n <namespace>` for a crash or hang.
2. `HighJobFailureRate` firing (not stalled) means jobs are being
   attempted but erroring - check the specific error in the logs; this
   points at a bug or bad data, not an infrastructure problem.

**"The database is unreachable."**
See `disaster-recovery.md` for the full backup/restore procedure. Quick
triage first: `kubectl get pods -n <namespace> -l app=postgres` -
`Pending` means a scheduling/PVC issue (see `troubleshooting.md`),
`CrashLoopBackOff` means the Postgres process itself is failing (check
logs), not necessarily data loss.

## Production enhancement not implemented here

Real alert routing (Alertmanager -> PagerDuty/Slack webhook) needs a
webhook URL / API key that doesn't exist for this demo project. The
`alertmanager` Helm values would need a `config.receivers` block pointing
at that webhook - everything else (the alert rules themselves, severity
labels, routing logic) is already structured to support it without
further changes.
