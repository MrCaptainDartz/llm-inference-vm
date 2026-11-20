output "lxc_id" {
  description = "Proxmox VMID of the inference LXC"
  value       = proxmox_virtual_environment_container.inference.vm_id
}

output "lxc_name" {
  description = "Hostname of the inference LXC"
  value       = var.lxc_name
}

output "lxc_ip" {
  description = "IPv4 address of the inference LXC (without CIDR mask)"
  value       = split("/", var.lxc_ipv4)[0]
}

output "litellm_url" {
  description = "LiteLLM OpenAI-compatible endpoint exposed on the LAN"
  value       = "http://${split("/", var.lxc_ipv4)[0]}:4000"
}

output "docling_url" {
  description = "Docling document extraction endpoint exposed to the Open WebUI VM"
  value       = "http://${split("/", var.lxc_ipv4)[0]}:5001"
}
