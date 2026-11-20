# ---------------------------------------------------------------------------
# Inference LXC (vLLM + LiteLLM + embedding)
#
# The GPU is owned by the Proxmox host and exposed to the unprivileged LXC by
# the Proxmox NVIDIA hook (lxc.hook.mount: /usr/share/lxc/hooks/nvidia). The
# hook lines are added after creation by the host bootstrap step documented in
# docs/HOST-INSTALL.md; they are not expressible through the bpg provider.
# ---------------------------------------------------------------------------

resource "proxmox_download_file" "ubuntu_lxc_template" {
  count               = var.ubuntu_lxc_template_preuploaded ? 0 : 1
  content_type        = "vztmpl"
  datastore_id        = var.template_datastore_id
  node_name           = var.vm_node_name
  url                 = var.ubuntu_lxc_template_url
  file_name           = var.ubuntu_lxc_template_filename
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

  # keyctl/fuse/mknod are added by the host bootstrap script: the API token
  # cannot change them (Proxmox only allows root@pam for those flags).
  features {
    nesting = var.lxc_enable_nesting
  }

  # keyctl/fuse/mknod are added by scripts/proxmox-lxc-gpu.sh with root
  # (the API token cannot change them). Never let Terraform remove them.
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

# ---------------------------------------------------------------------------
# Front VM (Open WebUI + Docling, no GPU)
#
# VM 103 from the previous architecture is no longer declared: Terraform
# destroys it and creates this VM (default VMID 112).
# ---------------------------------------------------------------------------

resource "proxmox_download_file" "ubuntu_cloud_image" {
  count               = var.cloud_image_preuploaded ? 0 : 1
  content_type        = "iso"
  datastore_id        = var.image_datastore_id
  node_name           = var.vm_node_name
  url                 = var.ubuntu_cloud_image_url
  file_name           = var.ubuntu_cloud_image_filename
  overwrite           = false
  overwrite_unmanaged = true
}

resource "proxmox_virtual_environment_file" "vendor_config" {
  count        = var.enable_cloudinit_snippet ? 1 : 0
  content_type = "snippets"
  datastore_id = coalesce(var.snippet_datastore_id, var.image_datastore_id)
  node_name    = var.vm_node_name

  source_raw {
    data      = <<EOF
#cloud-config
# Starts qemu-guest-agent if present in the base image; Ansible installs it from the bundle if missing.
runcmd:
  - systemctl enable --now qemu-guest-agent
EOF
    file_name = "vendor-cloudinit-opentofu.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "front_vm" {
  name        = var.front_vm_name
  vm_id       = var.front_vm_id
  node_name   = var.vm_node_name
  description = var.front_vm_description
  tags        = var.front_vm_tags
  started     = true

  on_boot = var.start_on_boot

  machine         = var.machine_type
  bios            = var.bios
  keyboard_layout = var.keyboard_layout

  dynamic "efi_disk" {
    for_each = var.bios == "ovmf" ? [1] : []
    content {
      datastore_id      = var.disk_datastore_id
      file_format       = "raw"
      type              = "4m"
      pre_enrolled_keys = var.efi_pre_enrolled_keys
    }
  }

  agent {
    enabled = true
    trim    = true
    timeout = "15m"

    wait_for_ip {
      disabled = true
    }
  }

  cpu {
    cores = var.front_vm_cores
    type  = var.cpu_type
  }

  memory {
    dedicated = var.front_vm_memory_mb
  }

  disk {
    datastore_id = var.disk_datastore_id
    file_id      = var.cloud_image_preuploaded ? "${var.image_datastore_id}:iso/${var.ubuntu_cloud_image_filename}" : proxmox_download_file.ubuntu_cloud_image[0].id
    interface    = "scsi0"
    size         = var.front_vm_disk_size_gb
    discard      = "on"
    ssd          = true
    iothread     = false
    backup       = true
    file_format  = "raw"
  }

  network_device {
    bridge   = var.network_bridge
    model    = "virtio"
    vlan_id  = var.network_vlan_id
    firewall = var.network_firewall
  }

  initialization {
    datastore_id        = var.image_datastore_id
    vendor_data_file_id = var.enable_cloudinit_snippet ? proxmox_virtual_environment_file.vendor_config[0].id : null

    ip_config {
      ipv4 {
        address = var.front_vm_ipv4
        gateway = var.network_gateway
      }
    }

    dns {
      servers = var.dns_servers
      domain  = var.dns_domain
    }

    user_account {
      username = var.front_vm_user
      keys     = [var.ssh_public_key]
    }
  }

  vga {
    type = var.vga_type
  }

  dynamic "rng" {
    for_each = var.rng_source != null ? [var.rng_source] : []
    content {
      source = rng.value
    }
  }

  operating_system {
    type = "l26"
  }
}
