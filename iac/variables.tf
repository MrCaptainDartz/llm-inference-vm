# --- Provider / API Proxmox ---

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
  description = "Disable TLS certificate verification for the Proxmox API (set to false in production)"
  default     = true
}

# --- Proxmox node / storage ---

variable "vm_node_name" {
  type        = string
  description = "Proxmox node on which the LXC and the front VM are created"
}

variable "disk_datastore_id" {
  type        = string
  description = "Datastore for the LXC rootfs and the front VM boot disk"
  default     = "local-zfs"
}

variable "image_datastore_id" {
  type        = string
  description = "Directory-type datastore for the Ubuntu cloud image (must support ISO content)"
  default     = "local"
}

variable "template_datastore_id" {
  type        = string
  description = "Directory-type datastore for the Ubuntu LXC template (must support vztmpl content)"
  default     = "local"
}

variable "snippet_datastore_id" {
  type        = string
  description = "Datastore for the Cloud-Init vendor snippet (defaults to image_datastore_id)"
  default     = null
}

# --- LXC: inference (vLLM + LiteLLM) ---

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
  default     = "Managed by OpenTofu - LLM inference LXC (vLLM + LiteLLM, GPU via Proxmox NVIDIA hook)"
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

# --- Front VM: Open WebUI + Docling ---

variable "front_vm_id" {
  type        = number
  description = "Proxmox VMID for the front VM. The old VM 103 is destroyed when this changes."
  default     = 112
}

variable "front_vm_name" {
  type        = string
  description = "Name of the front VM"
  default     = "llm-webui"
}

variable "front_vm_description" {
  type        = string
  description = "Description of the front VM in Proxmox"
  default     = "Managed by OpenTofu - LLM front VM (Open WebUI + Docling)"
}

variable "front_vm_tags" {
  type        = list(string)
  description = "Proxmox tags applied to the front VM"
  default     = ["llm-webui", "open-webui", "opentofu"]
}

variable "front_vm_cores" {
  type        = number
  description = "CPU cores allocated to the front VM"
  default     = 4
}

variable "front_vm_memory_mb" {
  type        = number
  description = "Memory of the front VM in MiB"
  default     = 8192
}

variable "front_vm_disk_size_gb" {
  type        = number
  description = "Boot disk size of the front VM in GiB"
  default     = 80
}

variable "front_vm_user" {
  type        = string
  description = "Cloud-Init SSH user for the front VM"
  default     = "ubuntu"
}

# --- Front VM hardware ---

variable "cpu_type" {
  type        = string
  description = "CPU type exposed to the front VM"
  default     = "host"
}

variable "machine_type" {
  type        = string
  description = "Machine type of the front VM (q35 for UEFI)"
  default     = "q35"
}

variable "bios" {
  type        = string
  description = "BIOS type of the front VM ('ovmf' or 'seabios')"
  default     = "ovmf"
}

variable "vga_type" {
  type        = string
  description = "VGA type of the front VM"
  default     = "virtio"
}

variable "keyboard_layout" {
  type        = string
  description = "Keyboard layout of the front VM"
  default     = "fr"
}

variable "rng_source" {
  type        = string
  description = "Virtio-RNG entropy source (null = disabled)"
  default     = "/dev/urandom"
}

variable "start_on_boot" {
  type        = bool
  description = "Start the LXC and the front VM automatically when the Proxmox node boots"
  default     = true
}

variable "efi_pre_enrolled_keys" {
  type        = bool
  description = "Enroll Microsoft keys in the front VM OVMF firmware (Secure Boot). false keeps the firmware permissive; the front VM has no GPU."
  default     = false
}

# --- Network ---

variable "network_bridge" {
  type        = string
  description = "Proxmox bridge for the LXC and the front VM (e.g. vmbr0)"
  default     = "vmbr0"
}

variable "network_gateway" {
  type        = string
  description = "IPv4 gateway for the LXC and the front VM"
  default     = null
}

variable "network_vlan_id" {
  type        = number
  description = "Optional VLAN tag applied to both network interfaces (null = bridge native VLAN)"
  default     = null
}

variable "network_firewall" {
  type        = bool
  description = "Enable the Proxmox firewall on the LXC and front VM NICs"
  default     = true
}

variable "lxc_ipv4" {
  type        = string
  description = "Static IPv4 address of the inference LXC in CIDR form (e.g. 192.0.2.10/24)"
  default     = "192.0.2.10/24"
}

variable "front_vm_ipv4" {
  type        = string
  description = "Static IPv4 address of the front VM in CIDR form (e.g. 192.0.2.11/24)"
  default     = "192.0.2.11/24"
}

variable "dns_servers" {
  type        = list(string)
  description = "DNS servers configured in the LXC and the front VM"
  default     = ["9.9.9.9", "1.1.1.1"]
}

variable "dns_domain" {
  type        = string
  description = "DNS search domain ('.' means no search domain in Proxmox)"
  default     = "."
}

# --- Images / templates ---

variable "ubuntu_cloud_image_url" {
  type        = string
  description = "URL of the Ubuntu Cloud-Init image used by the front VM"
  default     = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
}

variable "ubuntu_cloud_image_filename" {
  type        = string
  description = "Filename of the Ubuntu Cloud-Init image on Proxmox"
  default     = "ubuntu-26.04-server-cloudimg-amd64.img"
}

variable "cloud_image_preuploaded" {
  type        = bool
  description = "Airgapped Proxmox: skip the cloud image download and use the image already present in <image_datastore_id>:iso/<ubuntu_cloud_image_filename>."
  default     = false
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

variable "ubuntu_lxc_template_preuploaded" {
  type        = bool
  description = "Airgapped Proxmox: use an existing <template_datastore_id>:vztmpl/<ubuntu_lxc_template_filename> instead of downloading it."
  default     = false
}

variable "enable_cloudinit_snippet" {
  type        = bool
  description = "Upload and use a Cloud-Init vendor snippet to start qemu-guest-agent on the front VM first boot (no apt packages)."
  default     = true
}

# --- Access ---

variable "ssh_public_key" {
  type        = string
  description = "SSH public key injected into the LXC (root) and the front VM (cloud-init user)"
  sensitive   = true
}
