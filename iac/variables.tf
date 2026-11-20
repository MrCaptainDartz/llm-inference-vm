variable "proxmox_api_url" {
  type        = string
  description = "URL of the Proxmox API (e.g., https://192.0.2.1:8006/api2/json)"
}

variable "proxmox_api_token" {
  type        = string
  description = "Proxmox API token (e.g., root@pam!mytoken=uuid)"
  sensitive   = true
}

variable "proxmox_ssh_username" {
  type        = string
  description = "SSH username used by the provider to connect to Proxmox nodes"
  default     = "root"
}

variable "proxmox_insecure" {
  type        = bool
  description = "Disable TLS certificate verification for the Proxmox API (keep false; set true only for a self-signed test endpoint)"
  default     = false
}

variable "vm_node_name" {
  type        = string
  description = "Proxmox node on which the inference LXC is created"
}

variable "disk_datastore_id" {
  type        = string
  description = "Datastore for the LXC rootfs"
  default     = "local-zfs"
}

variable "template_datastore_id" {
  type        = string
  description = "Directory-type datastore for the Ubuntu LXC template (must support vztmpl content)"
  default     = "local"
}

variable "lxc_id" {
  type        = number
  description = "Proxmox VMID for the inference LXC"
  default     = 120
}

variable "lxc_name" {
  type        = string
  description = "Hostname of the inference LXC"
  default     = "llm-lxc"
}

variable "lxc_description" {
  type        = string
  description = "Description of the inference LXC in Proxmox"
  default     = "Managed by OpenTofu - LLM inference LXC (vLLM + LiteLLM + Docling, GPU via Proxmox NVIDIA hook)"
}

variable "lxc_tags" {
  type        = list(string)
  description = "Proxmox tags applied to the inference LXC"
  default     = ["llm-lxc", "vllm", "opentofu"]
}

variable "lxc_cores" {
  type        = number
  description = "CPU cores allocated to the inference LXC"
  default     = 8
}

variable "lxc_memory_mb" {
  type        = number
  description = "Memory limit of the inference LXC in MiB. vLLM loads the model weights through CPU RAM."
  default     = 32768
}

variable "lxc_swap_mb" {
  type        = number
  description = "Swap for the inference LXC in MiB (0 = disabled)"
  default     = 0
}

variable "lxc_disk_size_gb" {
  type        = number
  description = "Rootfs size of the inference LXC in GiB (models, container images, HF cache)"
  default     = 150
}

variable "lxc_unprivileged" {
  type        = bool
  description = "Create an unprivileged LXC (recommended). GPU access uses the Proxmox NVIDIA hook."
  default     = true
}

variable "lxc_enable_nesting" {
  type        = bool
  description = "Allow Docker inside the LXC (features: nesting=1)"
  default     = true
}

variable "start_on_boot" {
  type        = bool
  description = "Start the inference LXC automatically when the Proxmox node boots"
  default     = true
}

variable "network_bridge" {
  type        = string
  description = "Proxmox bridge for the LXC (e.g. vmbr0)"
  default     = "vmbr0"
}

variable "network_gateway" {
  type        = string
  description = "IPv4 gateway for the LXC"
  default     = null
}

variable "network_vlan_id" {
  type        = number
  description = "Optional VLAN tag applied to the LXC network interface (null = bridge native VLAN)"
  default     = null
}

variable "network_firewall" {
  type        = bool
  description = "Enable the Proxmox firewall on the LXC NIC"
  default     = true
}

variable "lxc_ipv4" {
  type        = string
  description = "Static IPv4 address of the inference LXC in CIDR form (e.g. 192.0.2.10/24)"
  default     = "192.0.2.10/24"
}

variable "dns_servers" {
  type        = list(string)
  description = "DNS servers configured in the LXC (set the internal resolver on an airgapped site; empty = no explicit DNS)"
  default     = []
}

variable "ubuntu_lxc_template_url" {
  type        = string
  description = "URL of the Ubuntu 26.04 LXC template"
  default     = "http://download.proxmox.com/images/system/ubuntu-26.04-standard_26.04-1_amd64.tar.zst"
}

variable "ubuntu_lxc_template_filename" {
  type        = string
  description = "Filename of the Ubuntu 26.04 LXC template on Proxmox"
  default     = "ubuntu-26.04-standard_26.04-1_amd64.tar.zst"
}

variable "ubuntu_lxc_template_checksum" {
  type        = string
  description = "Optional checksum of the LXC template (recommended; download.proxmox.com currently serves HTTP)"
  default     = ""
}

variable "ubuntu_lxc_template_checksum_algorithm" {
  type        = string
  description = "Checksum algorithm for ubuntu_lxc_template_checksum"
  default     = "sha256"

  validation {
    condition     = contains(["md5", "sha1", "sha224", "sha256", "sha384", "sha512"], var.ubuntu_lxc_template_checksum_algorithm)
    error_message = "Use one of md5, sha1, sha224, sha256, sha384, sha512."
  }
}

variable "ubuntu_lxc_template_preuploaded" {
  type        = bool
  description = "Airgapped Proxmox: use an existing <template_datastore_id>:vztmpl/<ubuntu_lxc_template_filename> instead of downloading it."
  default     = false
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key injected into the LXC (root)"
  sensitive   = true
}
