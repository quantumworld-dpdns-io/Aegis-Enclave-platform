output "chart_version" {
  description = "安裝的 Cilium Helm chart 版本。"
  value       = helm_release.cilium.version
}

output "namespace" {
  description = "Cilium 所在命名空間。"
  value       = helm_release.cilium.namespace
}

output "release_name" {
  description = "Cilium Helm release 名稱。"
  value       = helm_release.cilium.name
}
