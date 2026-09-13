output "cluster_name" {
  description = "Kind 叢集名稱。"
  value       = kind_cluster.this.name
}

output "kubeconfig_path" {
  description = "kubeconfig 寫出路徑。"
  value       = kind_cluster.this.kubeconfig_path
}

output "kubeconfig" {
  description = "kubeconfig 原文。含憑證，敏感。"
  value       = kind_cluster.this.kubeconfig
  sensitive   = true
}

output "endpoint" {
  description = "Kubernetes API Server 端點。"
  value       = kind_cluster.this.endpoint
}

output "client_certificate" {
  description = "API Server 用戶端憑證（PEM）。"
  value       = kind_cluster.this.client_certificate
  sensitive   = true
}

output "client_key" {
  description = "API Server 用戶端私鑰（PEM）。"
  value       = kind_cluster.this.client_key
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "叢集 CA 憑證（PEM）。"
  value       = kind_cluster.this.cluster_ca_certificate
  sensitive   = true
}
