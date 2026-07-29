variable "cluster_name" {
  description = "Name of the kind cluster"
  type        = string
  default     = "advanced-devops"
}

variable "kubeconfig_path" {
  description = "Path to the kubeconfig file kind writes to"
  type        = string
  default     = "~/.kube/config"
}

variable "environments" {
  description = "The three application environments and their per-namespace resource quotas"
  type = map(object({
    cpu_requests    = string
    cpu_limits      = string
    memory_requests = string
    memory_limits   = string
    max_pods        = string
    pod_security    = string
  }))
  default = {
    development = {
      cpu_requests    = "1"
      cpu_limits      = "2"
      memory_requests = "1Gi"
      memory_limits   = "2Gi"
      max_pods        = "20"
      pod_security    = "baseline"
    }
    staging = {
      cpu_requests    = "2"
      cpu_limits      = "4"
      memory_requests = "2Gi"
      memory_limits   = "4Gi"
      max_pods        = "30"
      pod_security    = "baseline"
    }
    production = {
      cpu_requests    = "4"
      cpu_limits      = "8"
      memory_requests = "4Gi"
      memory_limits   = "8Gi"
      max_pods        = "50"
      pod_security    = "restricted"
    }
  }
}

variable "grafana_admin_password" {
  description = "Admin password for Grafana. Demo-only default - override with -var in a real run."
  type        = string
  default     = "admin-demo-password"
  sensitive   = true
}
