# Proxmox host and inference LXC

This document covers the **manual** part on the Proxmox host: NVIDIA driver,
toolkit, LXC template, GPU hooks, airgap bundle bind mount.

The target PVE already exists and is airgapped: this repo only adds the LXC
(and the VMs you create next to it). The local Debian/PVE repositories
(`main contrib non-free non-free-firmware`) are assumed to be configured; they
provide `dkms`, `build-essential` and the kernel headers. The bundle does not
duplicate those packages.

The LXC stays **unprivileged**. The GPU is not passed through PCI/VFIO: the
host keeps the driver and the LXC receives the devices + user-space libraries
through the Proxmox NVIDIA hook.

The front part (Open WebUI + PGVector) runs on **your existing Docker VM**
through `deploy/openwebui/docker-compose.yml`. This repo no longer creates a
front VM.

## 1. Requirements

- Proxmox VE 9.2+ with `lxc-pve >= 6.0.5` (`dpkg -l lxc-pve`).
- Local Debian/PVE repositories (`main contrib non-free non-free-firmware`).
- `dkms`, `build-essential`, `proxmox-headers-$(uname -r)` from those
  repositories.
- An NVIDIA GPU visible on the host (`lspci`, `nvidia-smi`).
- The airgap bundle transferred to the host (see `docs/AIRGAP.md`).
- A Proxmox API token and the public SSH key for Terraform.

Checks:

```bash
pveversion
dpkg -l lxc-pve | tail -1
ls -l /usr/share/lxc/hooks/nvidia
```

## 2. NVIDIA driver (version from the bundle)

The bundle contains `host/NVIDIA-Linux-x86_64-<version>.run` and
`host/NVIDIA_DRIVER_VERSION`.

```bash
cd /path/to/airgap-bundle/host
apt update
apt install -y dkms build-essential "proxmox-headers-$(uname -r)"
chmod +x NVIDIA-Linux-x86_64-*.run
./NVIDIA-Linux-x86_64-*.run --dkms --no-x-check --no-nouveau-check
```

`pve-headers` is a transitional meta package; `proxmox-headers-$(uname -r)`
targets the running kernel. Both come from your local PVE repositories, not
from the bundle.

Recommended interactive choices: no 32-bit libraries, no X, DKMS = yes.

Checks:

```bash
nvidia-smi
dkms status
modprobe nvidia_uvm
ls -l /dev/nvidia0 /dev/nvidia-uvm
```

> The script uses the **latest stable driver** from the 595 branch by default
> (`https://download.nvidia.com/XFree86/Linux-x86_64/latest.txt`, currently
> 595.112.07). `595.104.02` is the version validated on the test host
> (PVE 9.2.27, kernel 7.0). If needed, pin it:
> `NVIDIA_DRIVER_VERSION=595.104.02 ./scripts/fetch-airgap-bundle.sh`.

## 3. NVIDIA Container Toolkit (host)

The `/usr/share/lxc/hooks/nvidia` hook (shipped by `lxc-pve`) calls
`nvidia-container-cli`. The toolkit is therefore required on the host:

```bash
apt install -y /path/to/airgap-bundle/host/nvidia-container-toolkit/*.deb
nvidia-container-cli --version
nvidia-ctk --version
```

## 4. LXC template

```bash
cp /path/to/airgap-bundle/host/ubuntu-26.04-standard_26.04-1_amd64.tar.zst \
   /var/lib/vz/template/cache/
```

In `iac/terraform.tfvars` (airgap mode):

```hcl
ubuntu_lxc_template_preuploaded = true
```

Keep `proxmox_insecure = false`; only set it to `true` if the Proxmox API
uses a self-signed certificate.

Then, from the control machine:

```bash
cd iac
tofu init
tofu apply
```

This creates **only** the LXC (120 by default, `llm-lxc`). No front VM, no
cloud image, no cloud-init snippet.

## 5. LXC GPU hooks

On the Proxmox host, after the LXC is created:

```bash
/path/to/repo/scripts/proxmox-lxc-gpu.sh 120 \
  --bundle /srv/airgap-bundle
```

The script:

- stops the LXC;
- enables `nesting=1,keyctl=1,fuse=1,mknod=1`;
- detects the real NVIDIA majors (`/dev/nvidia0`, `/dev/nvidia-uvm`, …) and
  adds the `lxc.cgroup2.devices.allow` rules; in practice **195**
  (`nvidia0/ctl/modeset`) and **509** (`nvidia-uvm`) are enough. Majors
  `234`/`511` are the `nvidia-caps` nodes reserved for MIG: useless here, add
  them manually only if you enable MIG;
- adds the `lxc.hook.pre-start` hook (`nvidia_uvm`), the `lxc.hook.mount` hook
  (`/usr/share/lxc/hooks/nvidia`), and the
  `NVIDIA_VISIBLE_DEVICES=all` / `NVIDIA_DRIVER_CAPABILITIES=compute,utility`
  variables;
- adds 16 GiB of `/dev/shm`;
- mounts the bundle read-only on `/airgap-bundle` (`mpN`);
- restarts the LXC and checks `nvidia-smi` inside it.

It does **not** touch `/dev/dri`: CUDA does not need it, and an unprivileged
LXC could not use the `0660 root:video` nodes without mapping the GIDs. The
script only adds the NVIDIA majors.

### Proxmox firewall

The LXC is created with `network_firewall = true`. If the Proxmox firewall is
active, open at least `22` (Ansible/SSH), `4000` (LiteLLM) and `5001`
(Docling), or set `network_firewall = false` in `terraform.tfvars`. Without a
rule, `tofu apply` can succeed while Ansible/Open WebUI cannot reach the LXC.

Checks:

```bash
pct config 120 | grep -E 'features|lxc.cgroup2|lxc.hook|lxc.environment|mp[0-9]'
pct exec 120 -- nvidia-smi -L
ssh root@192.0.2.10 nvidia-smi -L
```

## 6. Ansible: inference LXC

```bash
cd ansible
cp inventory/inventory.yml.example inventory/inventory.yml
cp group_vars/all.yml.example group_vars/all.yml
$EDITOR group_vars/all.yml
```

Fill in at least:

```yaml
litellm_master_key: "<openssl rand -hex 32>"
docling_api_key: "<openssl rand -hex 32>"

# Test host (8 GB GPU):
vllm_start: false
docling_gpu: false

# 48 GB site:
# vllm_start: true
# docling_gpu: true
```

Then:

```bash
ssh-keyscan -H <lxc-ip> >> ~/.ssh/known_hosts
ansible-playbook playbook.yml
```

Ansible verifies host keys (`host_key_checking = true`); without the
`known_hosts` entry, the first run fails on purpose.

The `lxc_docker` role installs Docker + `nvidia-container-toolkit`, configures
the Docker `nvidia` runtime with `no-cgroups=true`, loads the CUDA smoke-test
image and runs `nvidia-smi` in a container.

The `inference_stack` role:

- downloads `fra.traineddata` and copies it to `fr.traineddata` in
  `/srv/llm/docling/tessdata/` (Docling's Tesseract preset looks for `fr`);
- deploys the vLLM + embedding + LiteLLM + **Docling** compose;
- with `docling_gpu: false` it uses the Docling CPU image; with `true`, the
  CUDA image `docling-serve-cu130:v1.38.2` and the `nvidia` runtime (Docling
  detects CUDA by itself; there is no `DOCLING_DEVICE` to force);
- exposes LiteLLM `:4000` and Docling `:5001` to the LAN; vLLM stays on
  `127.0.0.1:8000` / the internal Docker network;
- waits for the health of vLLM (when started), LiteLLM and Docling (API key).

Docling ships **both OCR engines**:
- **Tesseract** (`fra`/`fr`): CPU, 0 VRAM, fast;
- **EasyOCR** (`latin_g2` included in the image): more robust on
  inverted/noisy scans, slower on CPU and ~1-2 GB VRAM when it uses the GPU.

The choice is made on the Open WebUI side through `DOCLING_PARAMS` (see
`deploy/openwebui/README.md`). `table_mode=accurate` enables TableFormer
accurate for tables; it runs on CPU **and** GPU (not GPU only), and is already
the Docling default.

## 7. Front: Open WebUI + PGVector on your Docker VM

On your existing VM:

```bash
cd deploy/openwebui
cp .env.example .env
chmod 600 .env
$EDITOR .env
docker compose config --quiet
docker compose up -d
```

Fill in `LITELLM_BASE_URL`, `LITELLM_API_KEY` (the master key),
`DOCLING_SERVER_URL`, `DOCLING_API_KEY`, `POSTGRES_PASSWORD`,
`WEBUI_SECRET_KEY`, and `DOCLING_PARAMS`:

```json
{"ocr_preset":"tesseract","ocr_lang":["fr"],"table_mode":"accurate","do_table_structure":true}
```

or EasyOCR:

```json
{"ocr_preset":"easyocr","ocr_lang":["fr"],"table_mode":"accurate","do_table_structure":true}
```

Keep `ENABLE_PERSISTENT_CONFIG=false`: `.env` wins over the DB/UI. Change the
settings in `.env` then `docker compose up -d`; changes made in the UI do not
survive a restart.

The compose includes PostgreSQL 17 + pgvector for the application DB **and**
the vectors. `PGVECTOR_INITIALIZE_MAX_VECTOR_LENGTH=1024` matches
Qwen3-Embedding-0.6B. See `deploy/openwebui/README.md` for the VM
requirements (Docker Engine + Compose v2, 4 GB RAM, access to ports 4000/5001),
backups, airgap and troubleshooting.

## 8. 48 GB target

On the target server (48 GB GPU):

```yaml
vllm_start: true
docling_gpu: true
```

Then:

```bash
ansible-playbook playbook.yml --limit inference_lxc
```

The profile:
- vLLM chat `--gpu-memory-utilization 0.78` when Docling GPU is active
  (0.82 otherwise), embedding `0.06`;
- Docling GPU layout/table ~4-5 GB, Tesseract CPU OCR 0 VRAM (EasyOCR ~1-2 GB
  when selected);
- remaining margin ~2.7-3.7 GB out of 48 GB, to be measured at first start
  (Docling peaks can reduce it).

First vLLM start (weight loading):

```bash
docker logs -f vllm
curl -s http://127.0.0.1:8000/v1/models
```

Check the Docling rendering and OCR in the logs:

```bash
docker logs -f docling
docker exec docling tesseract --list-langs   # eng, fr, fra, osd
```

Watch points:
- `--kv-cache-dtype nvfp4`, `--attention-backend flash_attn`,
  `--speculative-config '{"method":"dflash",...,"num_speculative_tokens":7}'`;
- if the sm120 NVFP4/DFlash decode crashes, set `vllm_enforce_eager: true`;
- if `--reasoning-parser qwen3` / `--tool-call-parser qwen3_coder` do not
  exist in the vLLM image, clear them in `all.yml`;
- never expose vLLM (8000) on the LAN: only LiteLLM (4000) and Docling (5001)
  are published, protected by their keys.

## 9. Security notes

- Unprivileged LXC, `nesting/keyctl/fuse/mknod` for Docker, NVIDIA hook.
- NVIDIA devices are `0666` (driver default); the real authorisation is the
  `lxc.cgroup2.devices.allow` cgroup (majors 195/509; MIG `nvidia-caps` not
  needed).
- No `/dev/dri`: useless for CUDA, and impossible to use cleanly in an
  unprivileged LXC without mapping the `video`/`render` GIDs.
- `nvidia-container-cli` runs with `--no-cgroups`: the cgroup is managed by the
  LXC parent, not by the toolkit.
- LiteLLM and Docling each carry an API key; vLLM is not exposed.
- Docling `DOCLING_SERVE_API_KEY` and LiteLLM `litellm_master_key` are in
  `group_vars/all.yml` (gitignored) and in `/srv/llm/...` (0600 for LiteLLM and
  for the compose, which also holds the keys).

The former `firewall` and `security_hardening` roles are not applied again:
their `net.ipv4.ip_forward=0` sysctl breaks Docker, and UFW does not filter the
ports published by Docker. The network boundary remains the Proxmox firewall
(see above). The `lxc_security` role adds:

- **fail2ban** with **temporary** bans (`bantime = 1h`,
  `bantime.increment = false`, so never a permanent ban);
- an `lxc_security_fail2ban_ignore_cidrs` list in
  `ansible/group_vars/all.yml` to exclude a network/site from banning
  (e.g. `["192.0.2.0/24"]`);

`auditd` is **not** included in this project: in an unprivileged LXC, the
kernel refuses `set-pid`/`set-enable` (audit is not namespaced), even with
`cap_audit_control` visible. We stay with `fail2ban` + the Proxmox firewall;
no auditd on the host.

The LXC keeps key-only SSH, and the containers run with `no-new-privileges` +
`pids_limit`.
