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

output "front_vm_id" {
  description = "Proxmox VMID of the front VM"
  value       = proxmox_virtual_environment_vm.front_vm.vm_id
}

output "front_vm_name" {
  description = "Name of the front VM"
  value       = proxmox_virtual_environment_vm.front_vm.name
}

output "front_vm_ip" {
  description = "IPv4 address of the front VM (without CIDR mask)"
  value       = split("/", var.front_vm_ipv4)[0]
}

output "front_vm_ips" {
  description = "Configured IPv4 addresses of the front VM, without CIDR masks"
  value       = [split("/", var.front_vm_ipv4)[0]]
}

output "litellm_url" {
  description = "LiteLLM OpenAI-compatible endpoint exposed on the LAN"
  value       = "http://${split("/", var.lxc_ipv4)[0]}:4000"
}

output "open_webui_url" {
  description = "Open WebUI URL exposed on the LAN"
  value       = "http://${split("/", var.front_vm_ipv4)[0]}:8080"
}
