# Helm values for the kube-prometheus-stack chart, trimmed down from the
# defaults to fit a small local demo cluster (this is not sized for real
# production use - see docs/architecture.md for production sizing notes).

grafana:
  adminPassword: "${grafana_admin_password}"
  service:
    type: NodePort
    nodePort: 30300
  resources:
    requests: { cpu: 50m, memory: 96Mi }
    limits: { cpu: 200m, memory: 192Mi }
  persistence:
    enabled: false
  # Loki gets added as a datasource once loki-stack is installed, via its
  # own Helm values (monitoring/loki/values.yaml) rather than here, to
  # avoid a circular dependency between the two Helm releases.
  dashboardProviders:
    dashboardproviders.yaml:
      apiVersion: 1
      providers:
        - name: default
          orgId: 1
          folder: ""
          type: file
          disableDeletion: false
          editable: true
          options:
            path: /var/lib/grafana/dashboards/default
  dashboardsConfigMaps:
    default: "grafana-dashboards"

prometheus:
  service:
    type: NodePort
    nodePort: 30090
  prometheusSpec:
    retention: 1d
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits: { cpu: 500m, memory: 512Mi }
    # Extra scrape config so plain annotation-based scraping works against
    # our app pods (api/worker), without requiring every service to also
    # ship a ServiceMonitor custom resource - keeps the Kubernetes
    # manifests usable with any Prometheus setup, not just the Operator.
    additionalScrapeConfigs:
      - job_name: annotated-pods
        kubernetes_sd_configs:
          - role: pod
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
            action: keep
            regex: "true"
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
            action: replace
            target_label: __metrics_path__
            regex: (.+)
          - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
            action: replace
            regex: ([^:]+)(?::\d+)?;(\d+)
            replacement: $1:$2
            target_label: __address__
          - source_labels: [__meta_kubernetes_namespace]
            target_label: namespace
          - source_labels: [__meta_kubernetes_pod_name]
            target_label: pod
          - source_labels: [__meta_kubernetes_pod_label_app]
            target_label: app

alertmanager:
  alertmanagerSpec:
    resources:
      requests: { cpu: 25m, memory: 32Mi }
      limits: { cpu: 100m, memory: 64Mi }

kube-state-metrics:
  resources:
    requests: { cpu: 25m, memory: 32Mi }
    limits: { cpu: 100m, memory: 96Mi }

prometheus-node-exporter:
  resources:
    requests: { cpu: 25m, memory: 32Mi }
    limits: { cpu: 50m, memory: 64Mi }

# These components aren't needed for this demo and just cost RAM.
kubeApiServer:
  enabled: true
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeEtcd:
  enabled: false
kubeProxy:
  enabled: false
