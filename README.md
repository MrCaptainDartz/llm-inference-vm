# llm-inference-vm

Local LLM inference stack on Proxmox VE, split in two parts:

- **`llm-lxc` container** (unprivileged, 192.0.2.10): **vLLM** (chat +
  embeddings), **LiteLLM** (OpenAI-compatible proxy) and **Docling** (GPU
  parsing). The GPU stays on the Proxmox host and is injected into the LXC by
  the NVIDIA hook + cgroup rules — **no PCI/VFIO passthrough**.
- **Existing Docker VM** (the one running your services): **Open WebUI**
  (:8080) + **PostgreSQL/pgvector**. No GPU, no vLLM, no Docling on that VM: it
  consumes LiteLLM and Docling over the LAN.

LiteLLM is the only entry point for chat/embeddings; Docling is exposed with
its own API key. vLLM is never exposed.

## Architecture

```mermaid
flowchart LR
    subgraph LAN
        U[Existing Docker VM<br/>Open WebUI :8080<br/>PostgreSQL + pgvector]
        T[Tools / browser<br/>Pi, omp, Claude Code]
    end
    subgraph PVE[Proxmox VE]
        subgraph LXC[LXC llm-lxc 192.0.2.10]
            V[vLLM chat :8000<br/>localhost]
            E[vLLM embedding :8001<br/>internal]
            L[LiteLLM :4000<br/>LAN]
            D[Docling :5001<br/>LAN, API key]
            V --> L
            E --> L
        end
        G[(GPU 48 GB<br/>host driver<br/>NVIDIA LXC hook)]
        G -. CUDA .-> V
        G -. CUDA .-> E
        G -. CUDA .-> D
    end
    U -->|/v1| L
    U -->|5001| D
    T --> U
    T -->|:4000 /v1| L
```

| Component | Where | Exposure | Role |
|---|---|---|---|
| vLLM chat | LXC | `127.0.0.1:8000` / Docker network | Qwen3.8-27B-NVFP4 + DFlash2 |
| vLLM embedding | LXC | Docker network | Qwen3-Embedding-0.6B |
| LiteLLM | LXC | LAN `:4000` | proxy, master key |
| Docling | LXC | LAN `:5001` | parsing + OCR, API key |
| Open WebUI | Existing Docker VM | LAN `:8080` | chat + RAG |
| PostgreSQL/pgvector | Existing Docker VM | internal | application DB + vectors |

LAN ports: `8080` (Open WebUI), `4000` (LiteLLM), `5001` (Docling).
`8000/8001` stay local. TLS is terminated by the internal reverse proxy.

## Requirements

Examples use placeholder values (`192.0.2.0/24`, `vmbr0`, `pve-node1`,
`llm-lxc`); real values stay in the gitignored files (`terraform.tfvars`,
`inventory.yml`, `group_vars/all.yml`).

- **Proxmox VE 9.2+**, `lxc-pve >= 6.0.5`.
- NVIDIA driver + `nvidia-container-toolkit` on the host
  ([docs/HOST-INSTALL.md](docs/HOST-INSTALL.md)).
- Local Debian/PVE repositories (`main contrib non-free non-free-firmware`) on
  the airgapped PVE: they provide `dkms`, `build-essential` and the kernel
  headers; the bundle does not duplicate them.
- Control machine: `tofu` (OpenTofu ≥ 1.11), `ansible-core` +
  `community.general`, an SSH key (`scripts/prepare-offline-tooling.sh`
  installs them and prefetches the providers/collections).
- An existing Docker VM with **Docker Engine 24+ / Compose v2**, ~4 GB RAM,
  ~20 GB free, and network access to ports `4000`/`5001` of the LXC
  ([deploy/openwebui/README.md](deploy/openwebui/README.md)).
- For airgap: an Ubuntu 26.04 amd64 builder with internet access
  ([docs/AIRGAP.md](docs/AIRGAP.md)).

## Layout

```text
iac/                                  # OpenTofu — LXC only
  providers.tf
  main.tf                             # LXC 120, Ubuntu 26.04 template
  variables.tf                        # network (bridge/VLAN/IP), resources
  outputs.tf                          # lxc_ip, litellm_url, docling_url
  terraform.tfvars.example

ansible/
  playbook.yml                        # LXC: base, Docker, vLLM/LiteLLM/Docling
  playbook-download.yml               # airgap script wrapper (builder)
  requirements.yml                    # community.general collection
  inventory/inventory.yml.example
  group_vars/all.yml.example
  roles/
    airgap                            # apt from the bundle
    lxc_base                          # LXC base, key-only SSH, timezone
    lxc_security                      # temporary fail2ban
    developer_config
    inference_user                    # non-admin user
    lxc_docker                        # Docker + NVIDIA toolkit + smoke test
    inference_stack                   # vLLM + embedding + LiteLLM + Docling compose

deploy/openwebui/                     # Docker Compose for the existing VM
  docker-compose.yml                  # Open WebUI + PostgreSQL/pgvector
  .env.example
  initdb/01-vector.sql
  README.md

scripts/
  proxmox-lxc-gpu.sh                  # LXC features/hooks/cgroup/SHM/bundle
  fetch-airgap-bundle.sh              # online builder: host + images + models
  prepare-offline-tooling.sh          # control machine: tofu, ansible, providers
  test.pdf                            # benchmark/validation PDF

docs/
  HOST-INSTALL.md                     # Proxmox driver/toolkit/hooks/template
  AIRGAP.md                           # offline build/transfer/install
```

## Deployment

### 1. Prepare the Proxmox host

Follow [docs/HOST-INSTALL.md](docs/HOST-INSTALL.md): NVIDIA driver, toolkit,
LXC template. The Proxmox host is already prepared.

### 2. Create the LXC

```bash
cd iac
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars      # Proxmox API, SSH, node, bridge, IP
tofu init
tofu apply
```

Default: LXC `llm-lxc` **120** → `192.0.2.10/24`. Bridge, gateway, VLAN and IP
are variables (`network_bridge`, `network_gateway`, `network_vlan_id`,
`lxc_ipv4`). No front VM is created.

### 3. Add the GPU hooks to the LXC

On the Proxmox host:

```bash
/path/to/repo/scripts/proxmox-lxc-gpu.sh 120
# airgap: add --bundle /srv/airgap-bundle
```

The script enables `nesting/keyctl/fuse/mknod`, adds the cgroup rules for the
detected NVIDIA majors, the `/usr/share/lxc/hooks/nvidia` hook, 16 GiB of
`/dev/shm`, and checks `nvidia-smi` inside the LXC. It does not mount `/dev/dri`
(not needed for CUDA).

### 4. Provision the LXC

```bash
cd ansible
cp inventory/inventory.yml.example inventory/inventory.yml
cp group_vars/all.yml.example group_vars/all.yml
$EDITOR group_vars/all.yml
ansible-playbook playbook.yml
```

The play installs Docker + `nvidia-container-toolkit`, configures the Docker
`nvidia` runtime with `no-cgroups=true`, then deploys the vLLM + embedding +
LiteLLM + Docling compose.

### 5. Deploy Open WebUI + PGVector on your Docker VM

```bash
cd deploy/openwebui
cp .env.example .env
chmod 600 .env
$EDITOR .env
docker compose config --quiet
docker compose up -d
```

The `.env` carries the keys and the LiteLLM/Docling URLs (`LITELLM_BASE_URL`,
`DOCLING_SERVER_URL`). The compose forces `ENABLE_PERSISTENT_CONFIG=false`:
`.env` is the source of truth and UI changes do not survive a restart. Details:
[deploy/openwebui/README.md](deploy/openwebui/README.md).

### 6. Access

- LXC admin: `ssh root@192.0.2.10`.
- LiteLLM: `http://192.0.2.10:4000/v1` (bearer = `litellm_master_key`).
- Docling: `http://192.0.2.10:5001` (`X-Api-Key` header).
- Open WebUI: `http://<vm>:8080`.
- vLLM: `127.0.0.1:8000` from the LXC only.

## Main flags (`ansible/group_vars/all.yml`)

| Variable | Default | Role |
|---|---|---|
| `vllm_start` | `true` | starts vLLM chat + embedding; **`false` on an 8 GB GPU** |
| `vllm_embedding_enabled` | `true` | second vLLM for RAG embeddings |
| `docling_gpu` | `true` (48 GB target); `false` in the role defaults | CUDA image + layout/table on GPU; **`false` on an 8 GB GPU** |
| `docling_ocr_preset` | `tesseract` | OCR engine used by Open WebUI (`DOCLING_PARAMS`) |
| `docling_ocr_lang` | `["fr"]` | BCP-47 OCR languages |
| `vllm_enforce_eager` | `false` | workaround if the sm120 NVFP4/DFlash decode is unstable |
| `vllm_gpu_memory_utilization` | `0.78` with Docling GPU, else `0.82` | chat VRAM budget |
| `vllm_embedding_gpu_memory_utilization` | `0.06` | embedding VRAM budget |
| `airgap_mode` | `false` | switches apt/images/models to offline |

Tables are configured in `deploy/openwebui/.env` through `DOCLING_PARAMS`
(`table_mode=accurate`, TableFormer), not in `all.yml`.

## Docling, OCR, tables and ingestion

Docling runs in the LXC with **two OCR engines available**:

- **Tesseract** (`fra` + `fr` in `/srv/llm/docling/tessdata/`):
  CPU, **0 VRAM**, the fastest.
- **EasyOCR** (`latin_g2`, already in the Docling image): more robust on
  inverted/noisy scans; slower on CPU, ~1-2 GB VRAM when it uses the GPU.

Docling's `auto` preset selects **RapidOCR (Chinese/English)**; that is why
“you only see Chinese” unless the preset is forced. The choice is made in
Open WebUI through `DOCLING_PARAMS`:

```json
{"ocr_preset":"tesseract","ocr_lang":["fr"],"table_mode":"accurate","do_table_structure":true}
```

```json
{"ocr_preset":"easyocr","ocr_lang":["fr"],"table_mode":"accurate","do_table_structure":true}
```

`ocr_lang` is a **list** of BCP-47 tags. `ocr_engine` is deprecated in
docling-serve; use `ocr_preset`.

Measurements on a 10-page PDF (Docling CPU container, `--network none`, local
models):

| Engine | Total time | Time/page |
|---|---|---|
| Tesseract/fr | 7.8 s | **0.78 s/page** |
| EasyOCR/fr | 98.6 s | 9.86 s/page |

On the 48 GB site, EasyOCR can use the GPU; Tesseract stays at 0 VRAM.
Both models are local: the offline test downloads nothing.

**Table recognition**: `table_mode=accurate` selects **TableFormer accurate**.
Docling supports it on **CPU, CUDA and XPU** (not MPS): it is therefore **not
GPU-only**. Tested on the CPU Docling test container, 2-page PDF with a
5-column × 7-row table: **~2.75 s** of processing (4.0 s including the HTTP
round trip), correct Markdown tables. On the 48 GB site it runs on GPU and is
faster. `table_mode` and `do_table_structure` are already Docling defaults; we
state them explicitly so that a default change cannot silently regress
quality.

**Configuration precedence**: the Open WebUI compose forces
`ENABLE_PERSISTENT_CONFIG=false`, so `.env` wins over the DB and the UI. Edit
`DOCLING_PARAMS` (or `ENABLE_SIGNUP`) in `deploy/openwebui/.env`, then
`docker compose up -d` (recreates the container with the new environment).
Changes made in **Admin → Settings → Documents** apply until the next restart
but are not persisted. To go back to UI-driven configuration:
`ENABLE_PERSISTENT_CONFIG=true`.

To force OCR on a PDF that already has a text layer, add `"force_ocr":true`.
For scientific documents with formulas, MinerU or Marker may perform better;
Docling remains the best trade-off for Open WebUI / airgap / table-layout
integration in this project.

## Vector DB: PGVector

Open WebUI uses **PostgreSQL + pgvector** in `deploy/openwebui`:

- Open WebUI officially maintains ChromaDB and PGVector;
- the same Postgres database serves as the application DB (`DATABASE_URL`) and
  the vector DB (`PGVECTOR_DB_URL`);
- standard `pg_dump`/restore, no embedded database inside the container;
- `PGVECTOR_INITIALIZE_MAX_VECTOR_LENGTH=1024` (Qwen3-Embedding-0.6B).

Chroma remains possible for a small deployment, but is less robust for
backups/migrations. Qdrant is a good “vector-native” alternative for very
large volumes or several instances; it adds a service and is not maintained
by Open WebUI itself. For this single site, PGVector is the retained choice.

## Target GPU profile: 48 GB

- model `unsloth/Qwen3.8-27B-NVFP4` (NVFP4 body, FP8 lm_head);
- drafter `maurienne-ai/Qwen3.8-27B-DFlash2-NVFP4-RTNcal`
  (`block_size = 8` → `num_speculative_tokens = 7`);
- vLLM `v0.34.0` (CUDA 13.0);
- `--speculative-config '{"method":"dflash","model":"<drafter>","num_speculative_tokens":7}'`;
- `--attention-backend flash_attn`, `--kv-cache-dtype nvfp4`;
- `--max-model-len 262144`, `--max-num-seqs 4`,
  `--max-num-batched-tokens 32768`;
- budget: chat `0.78 × 48 = 37.4 GB` (Docling GPU active), embedding
  `0.06 × 48 = 2.9 GB`, Docling layout/table ~4-5 GB; the remaining margin is
  about **2.7-3.7 GB**, to be measured at first start (Docling peaks can
  reduce it).

The test host only has an **8 GB GPU**: `vllm_start: false` and
`docling_gpu: false`. It validates the LXC, Docker, the GPU hook (`nvidia-smi`),
LiteLLM, Docling CPU (Tesseract + EasyOCR), and the Open WebUI/PGVector
compose. The 27B, DFlash2 and Docling CUDA are validated on the 48 GB server.

## Airgap

Two independent artifacts, prepared while the machines still have internet:

```bash
# control machine (tofu + ansible-playbook), once: ~150 MB
./scripts/prepare-offline-tooling.sh

# data bundle on the online builder; --output may be a USB key
sudo ./scripts/fetch-airgap-bundle.sh --output /media/usb/airgap-bundle
```

The tooling (tofu binary, provider mirror, `community.general`) stays on the
control machine; the data bundle (tens of GB) can live on a USB key. Both
scripts are re-runnable on their own and skip what is already present.

`--skip=<section>[,<section>]` excludes part of the bundle (`host`, `images`,
`model`, `draft`, `embedding`, `models`, `apt`, `tessdata`, `all`) without ever
deleting what is already downloaded, for example `--skip=model` when the chat
model is already on the builder.

Then transfer, install the driver/toolkit, create the LXC, run Ansible, and
deploy Open WebUI/PGVector on the Docker VM from the
`open_webui.tar`/`pgvector.tar` images. Details and layout:
[docs/AIRGAP.md](docs/AIRGAP.md). The script resolves the latest versions at
build time and writes `manifest.json` (images/digests, models, driver,
Tesseract). It does not duplicate the host Debian/PVE packages (`dkms`,
`build-essential`, `proxmox-headers-$(uname -r)`): they come from your local
repositories. The stable 595.x driver (`download.nvidia.com`), the NVIDIA
toolkit, the LXC template, the images, the models and the LXC Ubuntu closure
are in the bundle. The bundle also contains `SHA256SUMS`, verified by the
`airgap` role.

## Operations

LXC:

```bash
ssh root@192.0.2.10
nvidia-smi
docker ps
docker compose -f /srv/llm/compose/compose.yaml ps
docker logs -f vllm
docker logs -f docling
docker exec docling tesseract --list-langs
curl -s -H "X-Api-Key: $DOCLING_KEY" http://127.0.0.1:5001/health
curl -s -H "Authorization: Bearer $KEY" http://127.0.0.1:4000/v1/models
```

Docker VM:

```bash
cd deploy/openwebui
docker compose ps
docker compose logs -f open-webui
docker compose exec postgres psql -U openwebui -d openwebui -c '\dx vector'
```

## Next steps

1. On the 48 GB server: `vllm_start: true`, `docling_gpu: true`, then
   `ansible-playbook playbook.yml --limit inference_lxc`.
2. Check the 27B load, DFlash2 and the Docling GPU rendering:
   `docker logs -f vllm`, `docker logs -f docling`, `curl :8000/v1/models`.
3. Test Tesseract then EasyOCR in production via `DOCLING_PARAMS` in
   `deploy/openwebui/.env` (inverted scans, quality, `table_mode`) then
   `docker compose up -d`; keep the best for your corpus.
4. Build/test the airgap bundle on the target site.
5. Back up PGVector (`pg_dump`) and the Open WebUI volumes.

## License

MIT — see [LICENSE](LICENSE).
