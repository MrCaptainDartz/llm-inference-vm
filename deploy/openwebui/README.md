# Open WebUI + PGVector (existing Docker VM)

This compose is the **front end** of the stack. It runs on your existing Docker
VM, not on the Proxmox host:

- **Open WebUI** `v0.13.4` (port 8080)
- **PostgreSQL 17 + pgvector** for both the Open WebUI application DB and the
  vector store (one database to back up)
- Chat/embeddings and document extraction are remote:
  - **LiteLLM** `http://<lxc>:4000/v1` (vLLM chat + embedding)
  - **Docling** `http://<lxc>:5001` (GPU document parsing in the LXC)

No Docling, vLLM, LiteLLM or model is downloaded on this VM.

## VM prerequisites

On your existing Docker VM, you only need Docker and this compose:

- **Docker Engine 24+** with the **Compose v2 plugin** (`docker compose version`
  must work; `docker-compose` v1 is not enough).
- About **2 vCPU, 4 GB RAM and 20 GB free disk** for the two containers, the
  PostgreSQL data and Open WebUI uploads. No GPU is required.
- `openssl` (to generate the secrets) and `curl` (health checks).
- Network access from the VM to the inference LXC on **TCP 4000** (LiteLLM) and
  **TCP 5001** (Docling).
- **TCP 8080** free, or a reverse proxy/TLS in front of it.

If Docker is not installed yet, install Docker Engine + Compose v2 for your
VM's distribution first; this repository only ships the compose stack. If
Docker is already present, there is nothing else to install.

## Why PGVector

Open WebUI officially maintains ChromaDB and PGVector. PGVector lets the same
PostgreSQL instance store the relational data and the vectors, with standard
`pg_dump` backups. ChromaDB is embedded and simpler, but less robust for
backups/migrations; Qdrant is a good dedicated vector engine (non-core Open
WebUI integration, another service to operate) if you later need very large
scale. For this deployment, PGVector is the default.

The embedding model `Qwen3-Embedding-0.6B` is **1024-dimensional**;
`PGVECTOR_INITIALIZE_MAX_VECTOR_LENGTH=1024` is set in the compose. If you
change the embedding model, update this value and recreate the knowledge base
collections.

## Setup

```bash
cp .env.example .env
chmod 600 .env
$EDITOR .env
```

Fill in:

- `LITELLM_BASE_URL` and `DOCLING_SERVER_URL` → the inference LXC IP
  (`iac/outputs.tf`: `litellm_url`, `docling_url`)
- `LITELLM_API_KEY` → `litellm_master_key` from
  `ansible/group_vars/all.yml`
- `DOCLING_API_KEY` → `docling_api_key` from `ansible/group_vars/all.yml`
- `POSTGRES_PASSWORD` → `openssl rand -hex 24`
- `WEBUI_SECRET_KEY` → `openssl rand -hex 32`
- `DOCLING_PARAMS` → OCR + table extraction (see below)
- `ENABLE_PERSISTENT_CONFIG` → keep `false` so this `.env` wins over the UI
- `ENABLE_SIGNUP` → `true` for the first boot, then `false`
- `FORWARDED_ALLOW_IPS` → your reverse-proxy IP/CIDR (default `127.0.0.1`)
- `OFFLINE_MODE` → `true` on the airgap site

Then:

```bash
docker compose config --quiet     # validation
docker compose up -d
docker compose ps
docker compose logs -f open-webui
```

Open `http://<vm>:8080`; the first account created becomes admin. Then set
`ENABLE_SIGNUP=false` in `.env` and run `docker compose up -d` (it recreates
the container with the new environment). With `ENABLE_PERSISTENT_CONFIG=false`,
the Admin UI signup toggle is not persistent.

The reverse proxy/TLS stays in front of `8080`. Keep
`FORWARDED_ALLOW_IPS=127.0.0.1` unless a proxy forwards requests; in that case
set it to the proxy IP or Docker network, not `*`.

## OCR and tables: Tesseract/EasyOCR + TableFormer

Both OCR models are available in the inference LXC. OCR and table extraction
are selected per request by Open WebUI through `DOCLING_PARAMS`:

```json
{"ocr_preset":"tesseract","ocr_lang":["fr"],"table_mode":"accurate","do_table_structure":true}
```

```json
{"ocr_preset":"easyocr","ocr_lang":["fr"],"table_mode":"accurate","do_table_structure":true}
```

- **Tesseract** (default): CPU, **0 VRAM**, fastest. Measured on a 10-page
  test PDF: **0.78 s/page**. Good for clean printed French documents.
- **EasyOCR**: better on rotated/noisy scans; on CPU it was **9.86 s/page** on
  the same 10-page test. On the 48 GB target with `docling_gpu: true`, it can
  use the GPU and is much faster; budget ~1-2 GB VRAM. Tesseract remains 0 VRAM.

`ocr_lang` is a **list** of BCP-47 tags (`["fr"]`, `["fr","en"]`). To force OCR
on PDFs that already have a text layer, add `"force_ocr":true`.

`"table_mode":"accurate"` selects **TableFormer accurate**, which Docling
supports on **CPU, CUDA and XPU** (not MPS). It is **not GPU-only**: on the
CPU-only pve-node1 test, a 2-page PDF with a 5-column/7-row table was converted in
**~2.75 s** (4.0 s including the HTTP round trip) and both tables were emitted
correctly in Markdown. On the 48 GB target it runs on GPU and is faster. Both
`table_mode` and `do_table_structure` are Docling defaults; they are set
explicitly so a future default change cannot silently degrade table quality.
Use `"table_mode":"fast"` only when speed matters more than table structure.

## Configuration precedence (compose/.env wins)

`ENABLE_PERSISTENT_CONFIG=false` is set in the compose. Open WebUI defaults to
`true`, which makes values saved in its database (via the Admin UI) override
the environment; `false` reverses that and makes this `.env` authoritative.

- **To change OCR, tables, models, signup, etc.:** edit `.env`, then
  `docker compose up -d` (recreates the container with the new environment).
- **Admin UI changes** still apply to the running process, but they are **not
  saved** and are lost on the next restart; the `.env` value comes back.
- **If you prefer UI-managed configuration:** set
  `ENABLE_PERSISTENT_CONFIG=true` in `.env` and manage the settings in
  **Admin → Settings**. The values in `.env` then only seed the first boot.

This also applies to `DOCLING_PARAMS`: on an existing `pgdata` volume, the
`.env` value wins even if the UI previously saved another value.

The Docling LXC logs show the selected engine per request (`tesseract -l fr`,
or the EasyOCR model). The French models are local:
- Tesseract `fra.traineddata` + `fr.traineddata` in
  `/srv/llm/docling/tessdata/` (mounted into the Docling container)
- EasyOCR `latin_g2.pth` is baked in the Docling image

## PGVector backup/restore

```bash
# backup
docker compose exec -T postgres pg_dump -U openwebui openwebui \
  > openwebui-$(date +%F).sql

# restore (empty/stopped Open WebUI recommended)
docker compose exec -T postgres psql -U openwebui openwebui < openwebui-YYYY-MM-DD.sql
```

Check the extension:

```bash
docker compose exec postgres psql -U openwebui -d openwebui -c '\dx vector'
```

`pgdata` and `openwebui_data` are named volumes. Back up `pgdata` via
`pg_dump`; uploads are in `openwebui_data`.

## Airgap

Load the two images from the bundle:

```bash
docker load -i /path/to/airgap-bundle/images/open_webui.tar
docker load -i /path/to/airgap-bundle/images/pgvector.tar
```

Set `OFFLINE_MODE=true` in `.env`, then:

```bash
docker compose up -d --pull never
```

The compose references the same pinned tags (`open-webui:v0.13.4`,
`pgvector/pgvector:pg17`). No registry access is needed.

## Validation performed (dev)

The stack was started on the inference LXC (Docker 29.1.3, Compose 2.40.3) with
the exact compose and `.env` from this directory, then removed:

- Open WebUI `v0.13.4` + `pgvector/pgvector:pg17`: migrations completed,
  `/health` returned `200`, `\dx vector` reported pgvector `0.8.7`.
- Admin signup returned `200`; `/api/models` returned `qwen3.8-27b` and
  `qwen3-embedding-0.6b` through LiteLLM.
- With `ENABLE_PERSISTENT_CONFIG=false`, the `config` table stayed empty.
  Setting `ENABLE_SIGNUP=false` and recreating the container made a second
  signup return `403`, confirming that the compose environment wins.
- Open WebUI's Docling loader extracted a 10-page PDF through Docling with
  `ocr_preset=tesseract`, `ocr_lang=["fr"]`, `table_mode=accurate` and
  `do_table_structure=true`.
- Full chat/RAG was **not** tested on pve-node1 because vLLM is not started there;
  that must be validated on the 48 GB target.

## Validation

```bash
docker compose config --quiet
docker compose ps
curl -s http://127.0.0.1:8080/health
docker compose logs -f open-webui
docker compose exec postgres psql -U openwebui -d openwebui -c 'select 1'
```

If documents fail at the extraction step, check the LXC:

```bash
ssh root@<lxc>
docker logs -f docling
docker exec docling tesseract --list-langs   # should show eng, fr, fra, osd
```

If RAG embeddings fail, check LiteLLM and the vLLM embedding service:

```bash
curl -s -H "Authorization: Bearer $LITELLM_API_KEY" \
  http://<lxc>:4000/v1/models
```
