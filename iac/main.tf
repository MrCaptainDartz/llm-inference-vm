# Inference LXC only (Open WebUI runs on an existing VM); the GPU hook is added afterwards.
resource "proxmox_download_file" "ubuntu_lxc_template" {
  count               = var.ubuntu_lxc_template_preuploaded ? 0 : 1
  content_type        = "vztmpl"
  datastore_id        = var.template_datastore_id
  node_name           = var.vm_node_name
  url                 = var.ubuntu_lxc_template_url
  file_name           = var.ubuntu_lxc_template_filename
  checksum            = var.ubuntu_lxc_template_checksum != "" ? var.ubuntu_lxc_template_checksum : null
  checksum_algorithm  = var.ubuntu_lxc_template_checksum != "" ? var.ubuntu_lxc_template_checksum_algorithm : null
  overwrite           = false
  overwrite_unmanaged = true
}

resource "proxmox_virtual_environment_container" "inference" {
  node_name     = var.vm_node_name
  vm_id         = var.lxc_id
  description   = var.lxc_description
  tags          = var.lxc_tags
  unprivileged  = var.lxc_unprivileged
  start_on_boot = var.start_on_boot
  started       = true

  features {
    nesting = var.lxc_enable_nesting
  }

  # Ignore features: scripts/proxmox-lxc-gpu.sh owns these flags.
  lifecycle {
    ignore_changes = [features]
  }

  cpu {
    cores = var.lxc_cores
  }

  memory {
    dedicated = var.lxc_memory_mb
    swap      = var.lxc_swap_mb
  }

  disk {
    datastore_id = var.disk_datastore_id
    size         = var.lxc_disk_size_gb
  }

  operating_system {
    template_file_id = var.ubuntu_lxc_template_preuploaded ? "${var.template_datastore_id}:vztmpl/${var.ubuntu_lxc_template_filename}" : proxmox_download_file.ubuntu_lxc_template[0].id
    type             = "ubuntu"
  }

  initialization {
    hostname = var.lxc_name

    ip_config {
      ipv4 {
        address = var.lxc_ipv4
        gateway = var.network_gateway
      }
    }

    dns {
      servers = var.dns_servers
    }

    user_account {
      keys = [var.ssh_public_key]
    }
  }

  network_interface {
    name     = "eth0"
    bridge   = var.network_bridge
    vlan_id  = var.network_vlan_id
    firewall = var.network_firewall
    enabled  = true
  }
}
