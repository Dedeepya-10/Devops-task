output "cluster_name" {
  description = "Name of the kind cluster"
  value       = var.cluster_name
}

output "kubectl_context" {
  description = "kubectl context to use for this cluster"
  value       = "kind-${var.cluster_name}"
}

output "namespaces" {
  description = "Application namespaces created"
  value       = [for ns in kubernetes_namespace.env : ns.metadata[0].name]
}

output "grafana_url" {
  description = "Grafana URL (NodePort, mapped to localhost via kind's extraPortMappings)"
  value       = "http://localhost:30300"
}

output "prometheus_url" {
  description = "Prometheus URL (NodePort, mapped to localhost via kind's extraPortMappings)"
  value       = "http://localhost:30090"
}

output "grafana_admin_password" {
  description = "Grafana admin password"
  value       = var.grafana_admin_password
  sensitive   = true
}
