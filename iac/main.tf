# Downloads the Cloud-Init image on the node; skipped when preuploaded (airgap).
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

resource "proxmox_virtual_environment_vm" "llm_inference_vm" {
  name        = var.vm_name
  vm_id       = var.vm_id
  node_name   = var.vm_node_name
  description = var.vm_description
  tags        = var.vm_tags

  on_boot = var.start_on_boot

  machine         = var.machine_type
  bios            = var.bios
  keyboard_layout = var.keyboard_layout

  # EFI disk required if UEFI (ovmf)
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
    cores = var.cpu_cores
    type  = var.cpu_type
  }

  memory {
    dedicated = var.memory_mb
  }

  disk {
    datastore_id = var.disk_datastore_id
    file_id      = var.cloud_image_preuploaded ? "${var.image_datastore_id}:iso/${var.ubuntu_cloud_image_filename}" : proxmox_download_file.ubuntu_cloud_image[0].id
    interface    = "scsi0"
    size         = var.disk_size_gb
    discard      = "on"
    ssd          = true
    iothread     = false
    backup       = true
    file_format  = "raw"
  }

  dynamic "network_device" {
    for_each = var.network_interfaces
    content {
      bridge      = network_device.value.bridge
      model       = network_device.value.model
      vlan_id     = network_device.value.vlan_id
      mac_address = network_device.value.mac_address
      firewall    = network_device.value.firewall
    }
  }

  dynamic "hostpci" {
    for_each = var.pci_devices
    content {
      device   = hostpci.value.device != null ? hostpci.value.device : "hostpci${hostpci.key}"
      id       = hostpci.value.id
      mapping  = hostpci.value.mapping
      pcie     = hostpci.value.pcie
      rombar   = hostpci.value.rombar
      xvga     = hostpci.value.xvga
      mdev     = hostpci.value.mdev
      rom_file = hostpci.value.rom_file
    }
  }

  initialization {
    # Storage where the Cloud-Init ISO virtual disk will be generated
    datastore_id = var.image_datastore_id

    vendor_data_file_id = var.enable_cloudinit_snippet ? proxmox_virtual_environment_file.vendor_config[0].id : null

    dynamic "ip_config" {
      for_each = var.network_interfaces
      content {
        ipv4 {
          address = ip_config.value.address
          gateway = ip_config.value.gateway
        }
      }
    }

    dns {
      servers = var.dns_servers
      domain  = var.dns_domain
    }

    user_account {
      username = var.vm_user
      keys     = [var.ssh_public_key]
    }
  }

  vga {
    type = var.vga_type
  }

  # Virtio-RNG hardware entropy source; rng_source = null disables the device.
  dynamic "rng" {
    for_each = var.rng_source != null ? [var.rng_source] : []
    content {
      source = rng.value
    }
  }

  operating_system {
    type = "l26" # Linux 2.6 / 5.x / 6.x kernel
  }
}
