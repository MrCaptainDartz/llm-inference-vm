# --- Provider / API Proxmox ---

variable "proxmox_api_url" {
  type        = string
  description = "URL of the Proxmox API (e.g., https://10.0.0.1:8006/api2/json)"
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
  description = "Disable TLS certificate verification for the Proxmox API (set to false in production)"
  default     = true
}

# --- Cloud-Init Image ---

variable "ubuntu_cloud_image_url" {
  type        = string
  description = "URL of the Ubuntu Cloud-Init image to download on the Proxmox node"
  default     = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
}

variable "ubuntu_cloud_image_filename" {
  type        = string
  description = "Filename used to store the Cloud-Init image on Proxmox"
  default     = "ubuntu-26.04-server-cloudimg-amd64.img"
}

variable "image_datastore_id" {
  type        = string
  description = "Proxmox datastore where the Cloud-Init ISO image is stored (must be a directory-type datastore)"
  default     = "local"
}

variable "cloud_image_preuploaded" {
  type        = bool
  description = "Airgapped Proxmox: skip the image download and use the Cloud-Init image already uploaded to the node datastore (from the bundle's cloudimg/). The file must exist as <image_datastore_id>:iso/<ubuntu_cloud_image_filename>."
  default     = false
}

variable "enable_cloudinit_snippet" {
  type        = bool
  description = "Whether to upload and use a custom Cloud-Init snippet to start qemu-guest-agent on first boot (no apt packages: installed from bundle by Ansible)"
  default     = true
}

variable "snippet_datastore_id" {
  type        = string
  description = "Proxmox datastore where Cloud-Init snippets are stored (if enable_cloudinit_snippet is true). Defaults to image_datastore_id."
  default     = null
}

# --- VM Identity ---

variable "vm_name" {
  type        = string
  description = "Name of the LLM inference VM in Proxmox"
  default     = "vm-llm-inference"
}

variable "vm_node_name" {
  type        = string
  description = "Proxmox node on which the VM is created (e.g., pve-node1). No default: node placement is deployment-specific and belongs in terraform.tfvars."
}

variable "vm_id" {
  type        = number
  description = "Proxmox VM ID (Proxmox auto-assigns the next free ID if null)"
  default     = null
}

variable "vm_description" {
  type        = string
  description = "Description of the VM in Proxmox"
  default     = "Managed by OpenTofu - LLM Inference VM (vLLM / Open WebUI / RAG)"
}

variable "vm_tags" {
  type        = list(string)
  description = "Proxmox tags applied to the VM"
  default     = ["llm-inference", "opentofu"]
}

# --- VM Resources ---

variable "cpu_cores" {
  type        = number
  description = "Number of virtual CPU cores"
  default     = 8
}

variable "cpu_type" {
  type        = string
  description = "CPU type exposed to the guest. 'host' is recommended for GPU passthrough (no feature-emulation overhead)."
  default     = "host"
}

variable "memory_mb" {
  type        = number
  description = "Memory in MiB. SGLang GPU inference benefits from >= 16384."
  default     = 16384
}

variable "efi_pre_enrolled_keys" {
  type        = bool
  description = "Enroll Microsoft keys in the OVMF firmware (Secure Boot active). MUST be false for GPU VMs: DKMS-built NVIDIA open kernel modules are unsigned and Secure Boot would refuse to load them. In-place update of the efi_disk (takes effect at next VM boot)."
  default     = true
}

variable "disk_size_gb" {
  type        = number
  description = "Boot disk size in GiB. The airgap bundle alone (~50-60 GiB) plus models and container storage warrants 200 GiB."
  default     = 200
}

variable "disk_datastore_id" {
  type        = string
  description = "Proxmox datastore for the boot disk"
  default     = "local-lvm"
}

# --- VM Hardware Options ---

variable "machine_type" {
  type        = string
  description = "Machine type: 'q35' (PCIe/UEFI, required for GPU passthrough) or 'pc'"
  default     = "q35"
}

variable "bios" {
  type        = string
  description = "BIOS type: 'ovmf' (UEFI) or 'seabios'"
  default     = "ovmf"
}

variable "vga_type" {
  type        = string
  description = "VGA type: 'virtio', 'qxl' (SPICE), 'std', 'serial0', 'none'"
  default     = "virtio"
}

variable "keyboard_layout" {
  type        = string
  description = "Keyboard layout: 'fr', 'en-us', etc."
  default     = "fr"
}

variable "rng_source" {
  type        = string
  description = "Virtio-RNG entropy source (null = disabled)"
  default     = "/dev/urandom"
}

variable "start_on_boot" {
  type        = bool
  description = "Start the VM automatically when the Proxmox node boots"
  default     = true
}

# --- VM Network ---

variable "network_interfaces" {
  type = list(object({
    bridge      = string
    address     = string
    gateway     = optional(string)
    vlan_id     = optional(number)
    mac_address = optional(string)
    firewall    = optional(bool, true)
    model       = optional(string, "virtio")
  }))
  description = "Network interfaces. 'bridge' and 'address' (CIDR) are mandatory. No default: the target topology is deployment-specific and belongs in terraform.tfvars."
}

# --- GPU / PCI Passthrough ---

variable "pci_devices" {
  type = list(object({
    device   = optional(string)
    id       = optional(string)
    mapping  = optional(string)
    pcie     = optional(bool, true)
    rombar   = optional(bool, true)
    xvga     = optional(bool, false)
    mdev     = optional(string)
    rom_file = optional(string)
  }))
  description = "PCI devices to passthrough (e.g., NVIDIA GPU). Either Proxmox cluster 'mapping', or direct PCI 'id' (omit the .X suffix to passthrough all functions, e.g., '0000:01:00'). Defaults to none (CPU-only VM)."
  default     = []
}

# --- Cloud-Init / Access ---

variable "vm_user" {
  type        = string
  description = "Default SSH user for the VM (injected via Cloud-Init)"
  default     = "ubuntu"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key to inject into the VM via Cloud-Init"
  sensitive   = true
}

variable "dns_servers" {
  type        = list(string)
  description = "DNS servers to configure in the VM via Cloud-Init"
  default     = ["9.9.9.9", "1.1.1.1"]
}

variable "dns_domain" {
  type        = string
  description = "DNS search domain ('.' indicates no search domain in Proxmox)"
  default     = "."
}
