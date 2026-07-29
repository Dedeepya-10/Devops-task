terraform {
  required_version = ">= 1.5.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# ---------------------------------------------------------------------------
# Cluster bootstrap.
#
# This demo runs on a local `kind` (Kubernetes-in-Docker) cluster instead of
# real AWS EKS, per the task's explicit "minikube, kind, or local Docker
# Desktop Kubernetes" allowance - it avoids continuous EKS control-plane
# billing and lets the whole stack be created/destroyed in minutes instead
# of tens of minutes. There is no mainstream, reliably-maintained Terraform
# provider for kind itself, so cluster lifecycle is driven through a
# null_resource local-exec calling the kind CLI directly - the same pattern
# real teams use for any tool without a native provider. Everything
# downstream (namespaces, RBAC, quotas, network policies, Helm releases) is
# then managed the normal Terraform way through the kubernetes/helm
# providers.
#
# In a real AWS deployment, this resource would instead be
# `module "eks" { source = "terraform-aws-modules/eks/aws" ... }` - see
# docs/architecture.md for the EKS-equivalent design this stands in for.
# ---------------------------------------------------------------------------

resource "null_resource" "kind_cluster" {
  triggers = {
    config_sha   = filesha256("${path.module}/kind-config.yaml")
    cluster_name = var.cluster_name
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      if kind get clusters | grep -qx "${var.cluster_name}"; then
        echo "kind cluster '${var.cluster_name}' already exists, skipping create"
      else
        kind create cluster --name "${var.cluster_name}" --config "${path.module}/kind-config.yaml"
      fi
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kind delete cluster --name ${self.triggers.cluster_name}"
  }
}

# kind writes/updates the standard kubeconfig with a `kind-<name>` context.
provider "kubernetes" {
  config_path    = pathexpand(var.kubeconfig_path)
  config_context = "kind-${var.cluster_name}"
}

provider "helm" {
  kubernetes {
    config_path    = pathexpand(var.kubeconfig_path)
    config_context = "kind-${var.cluster_name}"
  }
}

# ---------------------------------------------------------------------------
# Namespaces - one per environment, plus one for the monitoring stack.
# Pod Security Standards are enforced via the built-in namespace labels
# (Kubernetes 1.25+), rather than the deprecated PodSecurityPolicy API.
# Production enforces the strictest ("restricted") level; development and
# staging use "baseline" so local iteration isn't blocked by policies
# meant for production workloads.
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "env" {
  for_each = var.environments

  metadata {
    name = each.key
    labels = {
      environment                         = each.key
      "pod-security.kubernetes.io/enforce" = each.value.pod_security
      "pod-security.kubernetes.io/audit"    = each.value.pod_security
      "pod-security.kubernetes.io/warn"     = each.value.pod_security
    }
  }

  depends_on = [null_resource.kind_cluster]
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      environment = "monitoring"
    }
  }

  depends_on = [null_resource.kind_cluster]
}

# ---------------------------------------------------------------------------
# Resource quotas + default limit ranges - per-environment, so a runaway
# deployment in one namespace can't exhaust the whole cluster (or, in a
# real EKS deployment, run up the bill).
# ---------------------------------------------------------------------------

resource "kubernetes_resource_quota" "env" {
  for_each = var.environments

  metadata {
    name      = "${each.key}-quota"
    namespace = kubernetes_namespace.env[each.key].metadata[0].name
  }

  spec {
    hard = {
      "requests.cpu"    = each.value.cpu_requests
      "requests.memory" = each.value.memory_requests
      "limits.cpu"      = each.value.cpu_limits
      "limits.memory"   = each.value.memory_limits
      "pods"            = each.value.max_pods
    }
  }
}

resource "kubernetes_limit_range" "env" {
  for_each = var.environments

  metadata {
    name      = "${each.key}-default-limits"
    namespace = kubernetes_namespace.env[each.key].metadata[0].name
  }

  spec {
    limit {
      type = "Container"
      default = {
        cpu    = "200m"
        memory = "128Mi"
      }
      default_request = {
        cpu    = "50m"
        memory = "64Mi"
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Network policies - default-deny all ingress, then explicit allows:
# traffic from other pods in the same namespace (so api -> postgres and
# worker -> postgres keep working), and traffic from the monitoring
# namespace (so Prometheus can scrape /metrics on every pod).
# ---------------------------------------------------------------------------

resource "kubernetes_network_policy" "default_deny" {
  for_each = var.environments

  metadata {
    name      = "default-deny-ingress"
    namespace = kubernetes_namespace.env[each.key].metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}

resource "kubernetes_network_policy" "allow_same_namespace" {
  for_each = var.environments

  metadata {
    name      = "allow-same-namespace"
    namespace = kubernetes_namespace.env[each.key].metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            environment = each.key
          }
        }
      }
    }
  }
}

resource "kubernetes_network_policy" "allow_monitoring_scrape" {
  for_each = var.environments

  metadata {
    name      = "allow-monitoring-scrape"
    namespace = kubernetes_namespace.env[each.key].metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            environment = "monitoring"
          }
        }
      }
    }
  }
}

# ---------------------------------------------------------------------------
# RBAC - least privilege, and deliberately asymmetric across environments:
#
#   development: a "developer" ServiceAccount can read AND write workloads
#                (deployments/pods/services/configmaps), but never secrets.
#   staging:     the same humans get read-only access; only the CI/CD
#                pipeline's own ServiceAccount can actually change anything.
#   production:  there is no human-usable ServiceAccount at all - only the
#                CI/CD pipeline's production-deployer ServiceAccount can
#                touch this namespace, which is what backs the "separate
#                deployment approvals for production" requirement: the only
#                path into production is through the pipeline's approval
#                gate, not kubectl from a laptop.
# ---------------------------------------------------------------------------

resource "kubernetes_service_account" "dev_team" {
  for_each = toset(["development", "staging"])

  metadata {
    name      = "dev-team"
    namespace = each.key
  }
}

resource "kubernetes_role" "developer_readwrite" {
  metadata {
    name      = "developer"
    namespace = "development"
  }

  rule {
    api_groups = ["", "apps", "autoscaling"]
    resources  = ["pods", "pods/log", "deployments", "services", "configmaps", "horizontalpodautoscalers"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_role_binding" "developer_readwrite" {
  metadata {
    name      = "developer-binding"
    namespace = "development"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.developer_readwrite.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.dev_team["development"].metadata[0].name
    namespace = "development"
  }
}

resource "kubernetes_role" "viewer" {
  metadata {
    name      = "viewer"
    namespace = "staging"
  }

  rule {
    api_groups = ["", "apps", "autoscaling"]
    resources  = ["pods", "pods/log", "deployments", "services", "configmaps", "horizontalpodautoscalers"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding" "viewer" {
  metadata {
    name      = "viewer-binding"
    namespace = "staging"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.viewer.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.dev_team["staging"].metadata[0].name
    namespace = "staging"
  }
}

resource "kubernetes_service_account" "ci_deployer" {
  for_each = toset(["staging", "production"])

  metadata {
    name      = "ci-deployer"
    namespace = each.key
  }
}

resource "kubernetes_role" "deployer" {
  for_each = toset(["staging", "production"])

  metadata {
    name      = "deployer"
    namespace = each.key
  }

  rule {
    api_groups = ["", "apps", "autoscaling"]
    resources  = ["deployments", "services", "configmaps", "horizontalpodautoscalers", "pods", "pods/log"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # Deliberately no "secrets" resource in this rule - even the CI/CD
  # ServiceAccount can't read secret values, only reference them by name
  # in a Deployment spec, which Kubernetes allows without a "get" on the
  # Secret object itself.
}

resource "kubernetes_role_binding" "deployer" {
  for_each = toset(["staging", "production"])

  metadata {
    name      = "deployer-binding"
    namespace = each.key
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.deployer[each.key].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.ci_deployer[each.key].metadata[0].name
    namespace = each.key
  }
}

# ---------------------------------------------------------------------------
# metrics-server - required for HorizontalPodAutoscaler to function at all.
# kind's kubelets use certificates metrics-server doesn't trust by default,
# hence --kubelet-insecure-tls, which is a well-known, documented
# requirement specifically for kind clusters (not something you'd do on
# real EKS, which has properly trusted kubelet certs).
# ---------------------------------------------------------------------------

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = "3.12.1"

  set {
    name  = "args[0]"
    value = "--kubelet-insecure-tls"
  }

  depends_on = [null_resource.kind_cluster]
}

# ---------------------------------------------------------------------------
# Monitoring stack: Prometheus + Grafana + Alertmanager (kube-prometheus-stack)
# and Loki + Promtail for logs. Resource requests are trimmed down
# significantly from the chart defaults to fit this demo's RAM budget.
# ---------------------------------------------------------------------------

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  version    = "62.7.0"

  values = [
    templatefile("${path.module}/../monitoring/prometheus/values.yaml.tpl", {
      grafana_admin_password = var.grafana_admin_password
    })
  ]

  timeout = 600

  depends_on = [kubernetes_config_map.grafana_dashboards]
}

# Grafana dashboard provisioning. Populated with a placeholder for the
# first apply; the real 5 custom dashboards (docs/architecture.md, Part 3
# of the task) get added here as the monitoring/grafana/dashboards/*.json
# files are written.
resource "kubernetes_config_map" "grafana_dashboards" {
  metadata {
    name      = "grafana-dashboards"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    for f in fileset("${path.module}/../monitoring/grafana/dashboards", "*.json") :
    f => file("${path.module}/../monitoring/grafana/dashboards/${f}")
  }

  depends_on = [kubernetes_namespace.monitoring]
}

# Grafana's built-in sidecar (enabled by default in kube-prometheus-stack)
# auto-discovers datasources from ConfigMaps carrying this label, so Loki
# shows up in Grafana without any manual "Add data source" click-ops.
resource "kubernetes_config_map" "loki_datasource" {
  metadata {
    name      = "loki-datasource"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      grafana_datasource = "1"
    }
  }

  data = {
    "loki-datasource.yaml" = yamlencode({
      apiVersion = 1
      datasources = [
        {
          name      = "Loki"
          type      = "loki"
          uid       = "loki"
          access    = "proxy"
          url       = "http://loki-stack:3100"
          isDefault = false
        }
      ]
    })
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

# ---------------------------------------------------------------------------
# External secret management.
#
# The task asks for external secret management (AWS Secrets Manager, Vault,
# or similar) rather than only native Kubernetes Secrets. Since this demo
# runs on a local kind cluster with no real AWS account behind it, standing
# up a genuine AWS Secrets Manager integration isn't possible here - but
# rather than just writing a design doc, this stands up a real, working
# External Secrets Operator (the same controller used against AWS Secrets
# Manager / Vault in production) using its "kubernetes" provider, which
# treats a separate namespace as the external secret store.
#
# The "secrets-source" namespace plays the role AWS Secrets Manager would
# play in production: it's the one place secret VALUES actually live.
# ExternalSecret objects in each app namespace pull from it on a refresh
# interval - update a secret in secrets-source and watch it roll out to the
# app namespace automatically, which is the credential-rotation mechanism
# the task asks for. Swapping `provider.kubernetes` for `provider.aws.secretsManager`
# with an IRSA-authenticated role is the only change needed to point this
# at real AWS Secrets Manager - see docs/runbooks/secret-management.md.
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "external_secrets" {
  metadata {
    name = "external-secrets"
  }
  depends_on = [null_resource.kind_cluster]
}

resource "helm_release" "external_secrets" {
  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  namespace  = kubernetes_namespace.external_secrets.metadata[0].name
  version    = "0.10.7"

  set {
    name  = "resources.requests.cpu"
    value = "25m"
  }
  set {
    name  = "resources.requests.memory"
    value = "32Mi"
  }
  set {
    name  = "webhook.resources.requests.cpu"
    value = "25m"
  }
  set {
    name  = "certController.resources.requests.cpu"
    value = "25m"
  }

  timeout = 300
}

resource "kubernetes_namespace" "secrets_source" {
  metadata {
    name = "secrets-source"
  }
  depends_on = [null_resource.kind_cluster]
}

# The "external" credential values, one per environment - stands in for
# what would be entries in AWS Secrets Manager.
resource "kubernetes_secret" "db_credentials_source" {
  for_each = var.environments

  metadata {
    name      = "db-credentials-${each.key}"
    namespace = kubernetes_namespace.secrets_source.metadata[0].name
  }

  data = {
    POSTGRES_USER     = "appuser"
    POSTGRES_PASSWORD = "${each.key}-eso-managed-${random_id.db_password_suffix[each.key].hex}"
    POSTGRES_DB       = "appdb"
  }
}

resource "random_id" "db_password_suffix" {
  for_each    = var.environments
  byte_length = 6
}

# ServiceAccount the ClusterSecretStore authenticates as, scoped to only
# reading Secrets inside secrets-source - it cannot read anything in
# development/staging/production, and nothing in secrets-source can be
# reached except through this one narrow path.
resource "kubernetes_service_account" "eso_reader" {
  metadata {
    name      = "eso-reader"
    namespace = kubernetes_namespace.secrets_source.metadata[0].name
  }
}

resource "kubernetes_secret" "eso_reader_token" {
  metadata {
    name      = "eso-reader-token"
    namespace = kubernetes_namespace.secrets_source.metadata[0].name
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account.eso_reader.metadata[0].name
    }
  }
  type = "kubernetes.io/service-account-token"
}

resource "kubernetes_role" "eso_secret_reader" {
  metadata {
    name      = "secret-reader"
    namespace = kubernetes_namespace.secrets_source.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding" "eso_secret_reader" {
  metadata {
    name      = "eso-reader-binding"
    namespace = kubernetes_namespace.secrets_source.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.eso_secret_reader.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.eso_reader.metadata[0].name
    namespace = kubernetes_namespace.secrets_source.metadata[0].name
  }
}

resource "helm_release" "loki_stack" {
  name       = "loki-stack"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki-stack"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  version    = "2.10.2"

  values = [
    file("${path.module}/../monitoring/loki/values.yaml")
  ]

  depends_on = [helm_release.kube_prometheus_stack]
}
