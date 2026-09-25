output "vm_id" {
  description = "Proxmox VM ID of the inference VM"
  value       = proxmox_virtual_environment_vm.llm_inference_vm.vm_id
}

output "vm_name" {
  description = "Name of the inference VM"
  value       = proxmox_virtual_environment_vm.llm_inference_vm.name
}

output "vm_ips" {
  description = "Configured IP addresses of the VM (all interfaces)"
  value       = [for nic in var.network_interfaces : nic.address]
}
