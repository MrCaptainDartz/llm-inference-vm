# Quickstart

From zero to an LLM inference stack on Proxmox, with:

- an **LXC** for vLLM (chat + embeddings), LiteLLM and Docling (GPU);
- **Open WebUI + PGVector** in Docker on your existing services VM;
- the NVIDIA GPU on the host, injected into the LXC by the Proxmox hook;
- an **airgap** mode for the target site.

## 0. Requirements

- Proxmox VE 9.2+ with `lxc-pve >= 6.0.5`.
- NVIDIA driver + `nvidia-container-toolkit` on the host
  ([docs/HOST-INSTALL.md](docs/HOST-INSTALL.md)).
- Control machine: `tofu` (OpenTofu ≥ 1.11), `ansible-core` +
  `community.general`, an SSH key (see `scripts/prepare-offline-tooling.sh`).
- An existing Docker VM for Open WebUI + PGVector (Docker Engine 24+,
  Compose v2, ~4 GB RAM, access to ports 4000/5001 of the LXC).
- Airgap: an Ubuntu 26.04 amd64 builder with internet access.

```bash
ansible-galaxy collection install -r ansible/requirements.yml
```

## 1. Create the LXC

```bash
cd iac
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
```

`proxmox_insecure` stays `false`; only set it to `true` if the Proxmox API
uses a self-signed certificate.

Fill in: `proxmox_api_url`, `proxmox_api_token`, `ssh_public_key`,
`vm_node_name`, `network_bridge`, `network_gateway`, `lxc_ipv4`.

Default: LXC 120 `llm-lxc` → `192.0.2.10/24`.

```bash
tofu init
tofu apply
```

The repo creates **only the LXC**. Open WebUI runs on your existing Docker VM.

## 2. Add the GPU hooks to the LXC

On the Proxmox host:

```bash
/path/to/repo/scripts/proxmox-lxc-gpu.sh 120
```

This enables the Docker-in-LXC features, the NVIDIA cgroup rules, the
`/usr/share/lxc/hooks/nvidia` hook, 16 GiB of `/dev/shm`, and checks
`nvidia-smi` inside the LXC. In airgap, add `--bundle /srv/airgap-bundle`.

## 3. Configure the LXC (Ansible)

```bash
cd ../ansible
cp inventory/inventory.yml.example inventory/inventory.yml
cp group_vars/all.yml.example group_vars/all.yml
$EDITOR group_vars/all.yml
```

To fill in:

```yaml
litellm_master_key: "<openssl rand -hex 32>"
docling_api_key: "<openssl rand -hex 32>"

# 48 GB server:
vllm_start: true
docling_gpu: true
# Test host (8 GB GPU):
# vllm_start: false
# docling_gpu: false

docling_ocr_preset: "tesseract"
docling_ocr_lang: ["fr"]
```

Airgap: add `airgap_mode: true` and `llm_bundle_dir: /airgap-bundle`.

```bash
ansible-playbook playbook.yml
```

Before the first run, add the LXC host key to `known_hosts` (Ansible now
verifies host keys):

```bash
ssh-keyscan -H 192.0.2.10 >> ~/.ssh/known_hosts
```

The LXC play installs Docker + the NVIDIA toolkit, loads the vLLM + embedding +
LiteLLM + Docling compose, downloads Tesseract `fra`/`fr`, and waits for the
health of vLLM (when started), LiteLLM and Docling.

On the test host (8 GB GPU), `vllm_start: false` + `docling_gpu: false`:
LiteLLM and Docling CPU run; vLLM is not loaded.

## 4. Deploy Open WebUI + PGVector on your Docker VM

```bash
cd ../deploy/openwebui
cp .env.example .env
chmod 600 .env
$EDITOR .env
docker compose config --quiet
docker compose up -d
```

Fill in:

- `LITELLM_BASE_URL` → `http://192.0.2.10:4000/v1`
- `LITELLM_API_KEY` → `litellm_master_key`
- `DOCLING_SERVER_URL` → `http://192.0.2.10:5001`
- `DOCLING_API_KEY` → `docling_api_key`
- `POSTGRES_PASSWORD` → `openssl rand -hex 24`
- `WEBUI_SECRET_KEY` → `openssl rand -hex 32`
- `DOCLING_PARAMS`:
  ```json
  {"ocr_preset":"tesseract","ocr_lang":["fr"],"table_mode":"accurate","do_table_structure":true}
  ```
  or
  ```json
  {"ocr_preset":"easyocr","ocr_lang":["fr"],"table_mode":"accurate","do_table_structure":true}
  ```
- `ENABLE_PERSISTENT_CONFIG` → `false` (`.env` wins over the UI)
- `ENABLE_SIGNUP` → `true` on first boot, then `false`
- `OFFLINE_MODE` → `true` in airgap.

The compose includes PostgreSQL 17 + pgvector and Open WebUI `v0.13.4`. With
`ENABLE_PERSISTENT_CONFIG=false`, `.env` is the source of truth: changes made
in the UI apply until the next restart but are not persisted.
`table_mode=accurate` (TableFormer) works on CPU and GPU, not GPU only; it is
already the Docling default.

## 5. Verify

```bash
# LXC
ssh root@192.0.2.10 nvidia-smi
ssh root@192.0.2.10 docker ps
ssh root@192.0.2.10 docker exec docling tesseract --list-langs
ssh root@192.0.2.10 'docker run --rm --gpus all nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi -L'

# LiteLLM
curl -s -H "Authorization: Bearer $LITELLM_KEY" \
  http://192.0.2.10:4000/v1/models

# Docling
curl -s -H "X-Api-Key: $DOCLING_KEY" \
  http://192.0.2.10:5001/health

# Docker VM
curl -s http://<vm>:8080/health
docker compose exec postgres psql -U openwebui -d openwebui -c '\dx vector'
```

On the 48 GB server, the first vLLM start loads the weights (slow):

```bash
ssh root@192.0.2.10
docker logs -f vllm
curl -s http://127.0.0.1:8000/v1/models
```

## 6. First chat

1. Open `http://<vm>:8080`.
2. Create the first account (admin), then set `ENABLE_SIGNUP=false` in
   `deploy/openwebui/.env` and run `docker compose up -d` (the UI does not
   persist this setting with `ENABLE_PERSISTENT_CONFIG=false`).
3. The `qwen3.8-27b` model is exposed by LiteLLM; start chatting.

## 7. RAG: index a document

1. **Workspace → Knowledge** → create a knowledge base.
2. Upload a PDF: Docling parses it (Tesseract/EasyOCR and TableFormer accurate
   depending on `DOCLING_PARAMS`), LiteLLM routes the embeddings to vLLM.
3. In a chat, mention the base (`#knowledge-base-name`) and ask a question.

To test EasyOCR (inverted scans): edit `DOCLING_PARAMS` in
`deploy/openwebui/.env`, then `docker compose up -d` (recreates the container
with the new environment) and reindex. Do not rely on the UI: with
`ENABLE_PERSISTENT_CONFIG=false`, the change would be lost on restart.

## 8. Connect a coding tool

LiteLLM is the only public endpoint for the models:

```bash
export OPENAI_BASE_URL=http://192.0.2.10:4000/v1
export OPENAI_API_KEY=<litellm_master_key>
export OPENAI_MODEL=qwen3.8-27b
```

```bash
curl -s $OPENAI_BASE_URL/chat/completions \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.8-27b","messages":[{"role":"user","content":"Hello!"}]}' \
  | jq -r '.choices[0].message.content'
```

Never point a client directly at `:8000` (vLLM): it is not exposed to the LAN.

## 9. Airgap

1. Prepare the control machine once, while it still has internet (tofu,
   ansible-core, providers, collections; ~150 MB, re-runnable):

   ```bash
   ./scripts/prepare-offline-tooling.sh
   ```

2. Build the data bundle on the online builder; `--output` can point at a USB
   key, since the bundle is tens of GB and does not have to fit on the
   deployment machine:

   ```bash
   sudo ./scripts/fetch-airgap-bundle.sh --output /media/usb/airgap-bundle
   ```

   To avoid downloading again what is already there, use
   `--skip=<section>[,<section>]` (for example `--skip=model`: the chat model
   is already on the builder and everything else — driver, toolkit, LXC
   template, images, drafter, embeddings — is fetched).

3. Transfer the bundle to the Proxmox host and the
   `open_webui.tar`/`pgvector.tar` images to the Docker VM.
4. `terraform.tfvars`: `ubuntu_lxc_template_preuploaded = true`;
   `tofu apply`, then `scripts/proxmox-lxc-gpu.sh <CTID> --bundle ...`.
5. `all.yml`: `airgap_mode: true`, `llm_bundle_dir: /airgap-bundle`.
6. `ansible-playbook playbook.yml`.
7. On the Docker VM: `docker load` both images, `OFFLINE_MODE=true`,
   `docker compose up -d --pull never`.

Details: [docs/AIRGAP.md](docs/AIRGAP.md).

## Next

- VRAM profile, DFlash2/NVFP4, Docling GPU, OCR: [README](README.md).
- Proxmox host: [docs/HOST-INSTALL.md](docs/HOST-INSTALL.md).
- Airgap: [docs/AIRGAP.md](docs/AIRGAP.md).
- Open WebUI/PGVector compose: [deploy/openwebui/README.md](deploy/openwebui/README.md).
