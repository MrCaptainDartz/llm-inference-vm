# Quickstart

De zéro à une stack d'inférence LLM sur Proxmox, avec :

- un **LXC** pour vLLM (chat + embeddings), LiteLLM et Docling (GPU) ;
- **Open WebUI + PGVector** en Docker sur ta VM de services existante ;
- le GPU NVIDIA sur l'hôte, injecté dans le LXC par le hook Proxmox ;
- un mode **airgap** pour le site cible.

## 0. Prérequis

- Proxmox VE 9.2+ avec `lxc-pve >= 6.0.5`.
- Driver NVIDIA + `nvidia-container-toolkit` sur l'hôte
  ([docs/HOST-INSTALL.md](docs/HOST-INSTALL.md)).
- Poste de pilotage : `tofu` (OpenTofu ≥ 1.11), `ansible-core` +
  `community.general`, une clé SSH.
- Une VM Docker existante pour Open WebUI + PGVector (Docker Engine 24+,
  Compose v2, ~4 Go RAM, accès aux ports 4000/5001 du LXC).
- Airgap : un builder Ubuntu 26.04 amd64 avec internet.

```bash
ansible-galaxy collection install -r ansible/requirements.yml
```

## 1. Créer le LXC

```bash
cd iac
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
```

`proxmox_insecure` reste à `false` ; ne le passer à `true` que si l'API
Proxmox utilise un certificat auto-signé.

Renseigner : `proxmox_api_url`, `proxmox_api_token`, `ssh_public_key`,
`vm_node_name`, `network_bridge`, `network_gateway`, `lxc_ipv4`.

Défaut : LXC 120 `llm-lxc` → `192.0.2.10/24`.

```bash
tofu init
tofu apply
```

Le repo ne crée **que le LXC**. Open WebUI tourne sur ta VM Docker existante.

## 2. Ajouter les hooks GPU au LXC

Sur l'hôte Proxmox :

```bash
/path/to/repo/scripts/proxmox-lxc-gpu.sh 120
```

Cela active les features Docker-in-LXC, les règles cgroup NVIDIA, le hook
`/usr/share/lxc/hooks/nvidia`, 16 GiB de `/dev/shm`, et vérifie `nvidia-smi`
dans le LXC. En airgap, ajouter `--bundle /srv/airgap-bundle`.

## 3. Configurer le LXC (Ansible)

```bash
cd ../ansible
cp inventory/inventory.yml.example inventory/inventory.yml
cp group_vars/all.yml.example group_vars/all.yml
$EDITOR group_vars/all.yml
```

À renseigner :

```yaml
litellm_master_key: "<openssl rand -hex 32>"
docling_api_key: "<openssl rand -hex 32>"
litellm_base_url: "http://192.0.2.10:4000/v1"
docling_url: "http://192.0.2.10:5001"

# Serveur 48 Go :
vllm_start: true
docling_gpu: true
# pve-node1 (GPU 8 Go) :
# vllm_start: false
# docling_gpu: false

docling_ocr_preset: "tesseract"
docling_ocr_lang: ["fr"]
```

Airgap : ajouter `airgap_mode: true` et `llm_bundle_dir: /airgap-bundle`.

```bash
ansible-playbook playbook.yml
```

Avant le premier run, ajoute la clé d'hôte du LXC à `known_hosts` (Ansible
vérifie désormais les clés d'hôte) :

```bash
ssh-keyscan -H 192.0.2.10 >> ~/.ssh/known_hosts
```

Le play LXC installe Docker + toolkit NVIDIA, charge le compose vLLM +
embedding + LiteLLM + Docling, télécharge `fra`/`fr` Tesseract, et attend la
santé de LiteLLM et Docling.

Sur `pve-node1` (GPU 8 Go), `vllm_start: false` + `docling_gpu: false` : LiteLLM et
Docling CPU tournent ; vLLM n'est pas chargé.

## 4. Déployer Open WebUI + PGVector sur ta VM Docker

```bash
cd ../deploy/openwebui
cp .env.example .env
chmod 600 .env
$EDITOR .env
docker compose config --quiet
docker compose up -d
```

Renseigner :

- `LITELLM_BASE_URL` → `http://192.0.2.10:4000/v1`
- `LITELLM_API_KEY` → `litellm_master_key`
- `DOCLING_SERVER_URL` → `http://192.0.2.10:5001`
- `DOCLING_API_KEY` → `docling_api_key`
- `POSTGRES_PASSWORD` → `openssl rand -hex 24`
- `WEBUI_SECRET_KEY` → `openssl rand -hex 32`
- `DOCLING_PARAMS` :
  ```json
  {"ocr_preset":"tesseract","ocr_lang":["fr"],"table_mode":"accurate","do_table_structure":true}
  ```
  ou
  ```json
  {"ocr_preset":"easyocr","ocr_lang":["fr"],"table_mode":"accurate","do_table_structure":true}
  ```
- `ENABLE_PERSISTENT_CONFIG` → `false` (le `.env` gagne sur l'UI)
- `ENABLE_SIGNUP` → `true` au premier démarrage, puis `false`
- `OFFLINE_MODE` → `true` en airgap.

Le compose inclut PostgreSQL 17 + pgvector et Open WebUI `v0.13.4`. Avec
`ENABLE_PERSISTENT_CONFIG=false`, le `.env` est la source de vérité : les
changements faits dans l'UI s'appliquent jusqu'au redémarrage mais ne sont pas
enregistrés. `table_mode=accurate` (TableFormer) fonctionne sur CPU et GPU,
pas seulement sur GPU ; il est déjà le défaut Docling.

## 5. Vérifier

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

# VM Docker
curl -s http://<vm>:8080/health
docker compose exec postgres psql -U openwebui -d openwebui -c '\dx vector'
```

Sur le serveur 48 Go, le premier démarrage vLLM charge les poids (long) :

```bash
ssh root@192.0.2.10
docker logs -f vllm
curl -s http://127.0.0.1:8000/v1/models
```

## 6. Premier chat

1. Ouvrir `http://<vm>:8080`.
2. Créer le premier compte (admin), puis passer `ENABLE_SIGNUP=false` dans
   `deploy/openwebui/.env` et faire `docker compose up -d` (l'UI ne persiste
   pas ce réglage avec `ENABLE_PERSISTENT_CONFIG=false`).
3. Le modèle `qwen3.8-27b` est exposé par LiteLLM ; discuter.

## 7. RAG : indexer un document

1. **Espace de travail → Base de connaissances** → créer.
2. Uploader un PDF : Docling l'analyse (Tesseract/EasyOCR et TableFormer
   accurate selon `DOCLING_PARAMS`), LiteLLM route les embeddings vers vLLM.
3. Dans un chat, mentionner la base (`#nom-de-la-base`) et poser une question.

Pour tester EasyOCR (scans inversés) : modifier `DOCLING_PARAMS` dans
`deploy/openwebui/.env`, puis `docker compose up -d` (recrée le conteneur avec
le nouvel environnement) et réindexer. Ne pas se contenter de
l'UI : avec `ENABLE_PERSISTENT_CONFIG=false`, la modification serait perdue au
redémarrage.

## 8. Brancher un outil de code

LiteLLM est le seul endpoint public pour les modèles :

```bash
export OPENAI_BASE_URL=http://192.0.2.10:4000/v1
export OPENAI_API_KEY=<litellm_master_key>
export OPENAI_MODEL=qwen3.8-27b
```

```bash
curl -s $OPENAI_BASE_URL/chat/completions \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.8-27b","messages":[{"role":"user","content":"Salut !"}]}' \
  | jq -r '.choices[0].message.content'
```

Ne jamais pointer un client directement sur `:8000` (vLLM) : il n'est pas
exposé au LAN.

## 9. Airgap

1. Sur le builder :

   ```bash
   sudo ./scripts/fetch-airgap-bundle.sh --output ./airgap-bundle
   ```

2. Transférer le bundle vers le Proxmox host et les images
   `open_webui.tar`/`pgvector.tar` vers la VM Docker.
3. `terraform.tfvars` : `ubuntu_lxc_template_preuploaded = true` ;
   `tofu apply`, puis `scripts/proxmox-lxc-gpu.sh <CTID> --bundle ...`.
4. `all.yml` : `airgap_mode: true`, `llm_bundle_dir: /airgap-bundle`.
5. `ansible-playbook playbook.yml`.
6. Sur la VM Docker : `docker load` des deux images, `OFFLINE_MODE=true`,
   `docker compose up -d --pull never`.

Détails : [docs/AIRGAP.md](docs/AIRGAP.md).

## La suite

- Profil VRAM, DFlash2/NVFP4, Docling GPU, OCR : [README](README.md).
- Hôte Proxmox : [docs/HOST-INSTALL.md](docs/HOST-INSTALL.md).
- Airgap : [docs/AIRGAP.md](docs/AIRGAP.md).
- Compose Open WebUI/PGVector : [deploy/openwebui/README.md](deploy/openwebui/README.md).
