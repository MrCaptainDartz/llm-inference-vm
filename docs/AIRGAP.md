# Airgap bundle and deployment

The target site has no internet access. Everything is downloaded on a
connected Ubuntu 26.04 amd64 builder, transferred, then installed offline.

`scripts/fetch-airgap-bundle.sh` replaces the former `bundle_download` Ansible
role. It resolves the latest versions at build time and writes a
`manifest.json` with the exact versions/digests.

The host Debian/PVE packages (`dkms`, `build-essential`,
`proxmox-headers-$(uname -r)`, etc.) are **not** in the bundle: they live in
your local Debian/PVE repositories on the airgapped PVE. The bundle only holds
what those repositories do not provide (the `.run` driver, the NVIDIA toolkit,
the LXC template, images, HF models, tessdata, and the LXC Ubuntu apt closure).

The build must run on **Ubuntu 26.04**: it uses `apt`, `dpkg`, `skopeo` and an
Ubuntu container. Ansible (`ansible/playbook-download.yml`) drives that builder
from your workstation (Mac included) over SSH; it does not replace Ubuntu for
the build. To build from macOS without an Ubuntu machine, you need a Linux
VM/container. The playbook forwards extra arguments through
`bundle_fetch_args` (a list), for example
`-e '{"bundle_fetch_args": ["--skip=model"]}'`.

## 0. Offline toolchain (control machine, online, once)

The machine that runs `tofu` and `ansible-playbook` needs its tooling before
the site goes offline:

```bash
./scripts/prepare-offline-tooling.sh        # ~150 MB, a few minutes
```

It installs `tofu` and `ansible-core` (pipx, else a venv), prefetches the
provider pinned by `iac/.terraform.lock.hcl` into a filesystem mirror, installs
`community.general` from `ansible/requirements.yml`, and points `~/.tofurc` at
the mirror. Defaults: binaries in `~/.local/bin`, collections in
`~/.ansible/collections`, mirror in `~/.local/share/tofu-mirror`. Re-running is
a no-op and works offline; `--force` re-downloads everything. Use `--platform`
when the build and run platforms differ (e.g. `--platform darwin_arm64`), and
`--skip=tofu,ansible,collections,mirror,tofu-rc` to split the work.

Check the mirror without network:

```bash
cd iac && rm -rf .terraform && tofu init && tofu providers
```

This tooling is independent from the data bundle below: each script can be
re-run on its own, and the bundle itself does not need to fit on the control
machine.

## 1. Build the bundle (online machine)

On an **Ubuntu 26.04 amd64** builder with internet access:

```bash
git clone <repo> llm-inference-vm
cd llm-inference-vm
sudo ./scripts/fetch-airgap-bundle.sh --output ./airgap-bundle
```

The bundle weighs tens of GB: point `--output` at a USB key
(`--output /media/usb/airgap-bundle`) when the deployment machine has no room.

The script installs the missing tools (`curl`, `jq`, `python3`, `skopeo`,
`podman`/`docker`). It downloads:

- **host/**: latest stable NVIDIA driver from the 595 branch (`.run`,
  `download.nvidia.com`), NVIDIA Container Toolkit `.deb` files, Ubuntu 26.04
  LXC template, `NVIDIA_DRIVER_VERSION`;
- **images/**:
  - `vllm.tar` — `vllm/vllm-openai:v0.34.0` (CUDA 13)
  - `litellm.tar` — `ghcr.io/berriai/litellm:main-stable`
  - `open_webui.tar` — `ghcr.io/open-webui/open-webui:v0.13.4`
  - `docling.tar` — `quay.io/docling-project/docling-serve-cu130:v1.38.2`
  - `docling-cpu.tar` — `quay.io/docling-project/docling-serve:v1.38.2`
  - `pgvector.tar` — `pgvector/pgvector:pg17`
  - `cuda-smoke.tar` — `nvidia/cuda:13.0.0-base-ubuntu24.04`
- **models/**: `unsloth/Qwen3.8-27B-NVFP4`,
  `maurienne-ai/Qwen3.8-27B-DFlash2-NVFP4-RTNcal`,
  `Qwen/Qwen3-Embedding-0.6B` (full HF snapshots, pinned revision);
- **repo/**: Ubuntu 26.04 apt closure for the LXC + `Packages.gz` + the NVIDIA
  toolkit `.deb` files;
- **tessdata/**: `fra.traineddata` + `fr.traineddata` (Tesseract fast);
- **manifest.json**: versions, digests, models, HF revisions;
- **SHA256SUMS**: checksums of every bundle file, verified by the `airgap` role
  before any apt change.

> EasyOCR `latin_g2` (which covers French) is **already in the Docling image**;
> there is no separate EasyOCR model to download. Tesseract needs the
> `fra`/`fr` files above.

Useful options:

```bash
# Known-good driver version (when the latest breaks DKMS on the PVE kernel)
NVIDIA_DRIVER_VERSION=595.104.02 sudo ./scripts/fetch-airgap-bundle.sh

# Gated Hugging Face model
HF_TOKEN=hf_xxx sudo ./scripts/fetch-airgap-bundle.sh

# Resume an interrupted build: only fetch what is missing
sudo ./scripts/fetch-airgap-bundle.sh --skip=apt,tessdata

# The chat model was already downloaded on the builder: fetch only the rest
# (driver, toolkit, LXC template, images, drafter, embeddings, apt repo,
# tessdata)
sudo ./scripts/fetch-airgap-bundle.sh --skip=model

# Several sections at once
sudo ./scripts/fetch-airgap-bundle.sh --skip=model,images

sudo ./scripts/fetch-airgap-bundle.sh --force   # re-download everything
```

`--skip` takes a comma-separated list of sections:

| Section | What is not downloaded |
|---|---|
| `host` | `.run` driver, toolkit `.deb`, LXC template |
| `images` | image tarballs (`vllm.tar`, `docling.tar`, …) |
| `model` | chat model (`TARGET_MODEL`, `models/qwen3.8-27b-nvfp4/`) |
| `draft` | DFlash2 drafter (`models/qwen3.8-27b-dflash2-draft/`) |
| `embedding` | `Qwen3-Embedding-0.6B` (`models/qwen3-embedding-0.6b/`) |
| `models` | all three Hugging Face models above |
| `apt` | Ubuntu apt closure + `Packages.gz` |
| `tessdata` | French Tesseract data |
| `all` | every section (rewrite `manifest.json`/`SHA256SUMS` only) |

A skip never deletes what is already in the bundle: existing files are left
as-is and only the remaining sections are fetched. Skipped sections are listed
in `manifest.json` (`skipped`) and recalled at the end of the run. If a model
section is skipped while its `models/...` directory is empty, the script warns
about it: the bundle is then incomplete for vLLM.

The bundle weighs tens of GB (models + images + apt repo). Check its integrity
before transfer:

```bash
( cd airgap-bundle && sha256sum -c SHA256SUMS )
```

The `airgap` role repeats this check before touching apt. `SHA256SUMS` protects
against truncation/corruption; it is not a cryptographic signature of the
bundle.

## 2. Bundle layout

```text
airgap-bundle/
  manifest.json
  SHA256SUMS
  host/
    NVIDIA-Linux-x86_64-<ver>.run
    NVIDIA_DRIVER_VERSION
    nvidia-container-toolkit/*.deb
    ubuntu-26.04-standard_26.04-1_amd64.tar.zst
  images/
    vllm.tar
    litellm.tar
    open_webui.tar
    docling.tar
    docling-cpu.tar
    pgvector.tar
    cuda-smoke.tar
  models/
    qwen3.8-27b-nvfp4/
    qwen3.8-27b-dflash2-draft/
    qwen3-embedding-0.6b/
  repo/
    pool/*.deb
    Packages.gz
  tessdata/
    fra.traineddata
    fr.traineddata
```

## 3. Transfer

To the Proxmox host (the LXC mounts this path read-only):

```bash
rsync -a --info=progress2 airgap-bundle/ root@192.0.2.1:/srv/airgap-bundle/
```

To the existing Docker VM (Open WebUI + PGVector), only the images and the
compose are needed:

```bash
rsync -a airgap-bundle/images/open_webui.tar \
         airgap-bundle/images/pgvector.tar \
         ubuntu@<vm>:/tmp/
scp -r deploy/openwebui ubuntu@<vm>:/opt/openwebui
```

## 4. Install the Proxmox host

Follow `docs/HOST-INSTALL.md`:

1. NVIDIA driver + toolkit from `host/`;
2. copy the LXC template into `/var/lib/vz/template/cache/`;
3. `terraform.tfvars`: `ubuntu_lxc_template_preuploaded = true`, then
   `tofu apply` (the LXC only);
4. `scripts/proxmox-lxc-gpu.sh <CTID> --bundle /srv/airgap-bundle`;
5. Ansible.

## 5. Airgap Ansible configuration

In `ansible/group_vars/all.yml`:

```yaml
airgap_mode: true
llm_bundle_dir: /airgap-bundle

litellm_master_key: "<openssl rand -hex 32>"
docling_api_key: "<openssl rand -hex 32>"

# 48 GB site:
docling_gpu: true
vllm_start: true
# Test host (8 GB GPU): false / false

docling_ocr_preset: "tesseract"
docling_ocr_lang: ["fr"]
```

Then:

```bash
cd ansible
ansible-playbook playbook.yml
```

What the roles do in airgap mode:

- `airgap`: switches apt to `file:///airgap-bundle/repo` and disables the
  network sources;
- `lxc_base` / `lxc_security` / `lxc_docker`: install from the local repo
  (including `fail2ban`; auditd not retained);
- `lxc_docker`: installs Docker + toolkit, forces `no-cgroups=true`, loads
  `images/cuda-smoke.tar`, tests `nvidia-smi` in a container;
- `inference_stack`:
  - loads `images/litellm.tar`, `images/docling.tar` (or
    `images/docling-cpu.tar` when `docling_gpu: false`) and `images/vllm.tar`
    when `vllm_start`;
  - copies `tessdata/fra.traineddata` and `fr.traineddata` into
    `/srv/llm/docling/tessdata/`;
  - mounts `/airgap-bundle/models` into vLLM read-only;
  - starts LiteLLM + Docling (± vLLM) with `--pull never`;
  - Docling uses the CUDA image when `docling_gpu: true`, the CPU image
    otherwise; both images are in the bundle (`docling.tar` /
    `docling-cpu.tar`).

## 6. Airgap front: Open WebUI + PGVector

On the existing Docker VM:

```bash
cd /opt/openwebui
docker load -i /tmp/open_webui.tar
docker load -i /tmp/pgvector.tar
cp .env.example .env
chmod 600 .env
$EDITOR .env
```

In `.env`:

- `LITELLM_BASE_URL` / `DOCLING_SERVER_URL` → the LXC IP;
- `LITELLM_API_KEY` = `litellm_master_key`;
- `DOCLING_API_KEY` = `docling_api_key`;
- `POSTGRES_PASSWORD` / `WEBUI_SECRET_KEY` (hex);
- `DOCLING_PARAMS`:
  ```json
  {"ocr_preset":"tesseract","ocr_lang":["fr"],"table_mode":"accurate","do_table_structure":true}
  ```
  or
  ```json
  {"ocr_preset":"easyocr","ocr_lang":["fr"],"table_mode":"accurate","do_table_structure":true}
  ```
- `ENABLE_PERSISTENT_CONFIG=false` (`.env` wins over DB/UI);
- `ENABLE_SIGNUP=true` on first boot, then `false`;
- `OFFLINE_MODE=true`.

Then:

```bash
docker compose up -d --pull never
```

The compose references the exact tags `open-webui:v0.13.4` and
`pgvector/pgvector:pg17` loaded from the tarballs. No registry access.

## 7. Verify

On the LXC:

```bash
nvidia-smi -L
docker run --rm --gpus all nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi -L
docker ps
docker logs -f docling
docker exec docling tesseract --list-langs   # eng, fr, fra, osd
curl -s -H "X-Api-Key: $DOCLING_KEY" http://127.0.0.1:5001/health
```

On the front VM:

```bash
docker compose ps
curl -s http://127.0.0.1:8080/health
docker compose exec postgres psql -U openwebui -d openwebui -c '\dx vector'
```

From the LAN:

```bash
curl -s -H "Authorization: Bearer $LITELLM_KEY" \
  http://192.0.2.10:4000/v1/models
```

## 8. Notes

- The bundle is frozen at build time; `manifest.json` records exactly which
  images/models are installed. Its `skipped` field lists the sections
  deliberately omitted (`--skip=`), so a partial bundle is identifiable
  without looking back at the command.
- The `open-webui:v0.13.4` and `pgvector/pgvector:pg17` images are pinned;
  `litellm:main-stable` is resolved at build time and kept in the tarball.
- The script uses the **latest stable 595.x driver** by default through
  `https://download.nvidia.com/XFree86/Linux-x86_64/latest.txt` (currently
  595.112.07). If the PVE kernel is not yet supported by DKMS, pin
  `NVIDIA_DRIVER_VERSION=595.104.02` (validated on the test host). The 620.x
  driver from `us.download.nvidia.com` is not used by default.
- Tesseract is the default OCR engine (CPU, 0 VRAM, the fastest). EasyOCR is
  available for inverted/noisy scans; on the 48 GB site it can use the GPU
  (~1-2 GB VRAM) while Tesseract stays at 0 VRAM.
- `table_mode=accurate` enables TableFormer accurate for tables; it runs on
  CPU and GPU (not GPU-only) and is already the Docling default.
- The Docling models (layout/table) are included in the CPU image (verified:
  valid `artifacts_path`, no runtime download). The CUDA `cu130` image uses the
  same cache; confirm `DOCLING_SERVE_ARTIFACTS_PATH` on first start on the
  target.
- The local apt repository stays on `trusted=yes`: `SHA256SUMS` covers
  corruption/truncation, not a cryptographic signature. For a detached
  signature, add a GPG key kept outside the bundle.
- `ENABLE_PERSISTENT_CONFIG=false` in the Open WebUI compose: `.env` is the
  source of truth. Changes made in the UI apply until the next restart but are
  not persisted; edit `.env` then `docker compose up -d` for a durable setting.
- The only shared application secret between the LXC and the front VM is
  `litellm_master_key` + `docling_api_key`; they are in `all.yml` (gitignored),
  `/srv/llm/litellm/litellm.env` (0600) and the compose `.env`.
- vLLM only listens on `127.0.0.1:8000` / the internal Docker network; only
  LiteLLM `:4000` and Docling `:5001` are exposed to the LAN.
