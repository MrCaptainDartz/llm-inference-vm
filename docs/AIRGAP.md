# Bundle et déploiement airgap

Le site cible n'a pas d'accès internet. Tout est téléchargé sur un builder
Ubuntu 26.04 amd64 connecté, transféré, puis installé hors ligne.

Le script `scripts/fetch-airgap-bundle.sh` remplace l'ancien rôle Ansible
`bundle_download`. Il résout les dernières versions au moment du build et
écrit un `manifest.json` avec les versions/digests exacts.

Les paquets Debian/PVE de l'hôte (`dkms`, `build-essential`,
`proxmox-headers-$(uname -r)`, etc.) ne sont **pas** dans le bundle : ils sont
dans tes dépôts Debian/PVE locaux sur le PVE airgap. Le bundle ne contient que
ce qui n'y est pas (driver `.run`, toolkit NVIDIA, template LXC, images,
modèles HF, tessdata, closure apt Ubuntu du LXC).

Le build doit tourner sur **Ubuntu 26.04** : il utilise `apt`, `dpkg`, `skopeo`
et un conteneur Ubuntu. Ansible (`ansible/playbook-download.yml`) sert à
piloter ce builder depuis ton poste (Mac inclus) via SSH ; il ne remplace pas
Ubuntu pour le build. Pour builder depuis macOS sans machine Ubuntu, il faut
une VM/container Linux.

## 1. Construire le bundle (machine en ligne)

Sur un builder **Ubuntu 26.04 amd64** avec internet :

```bash
git clone <repo> llm-inference-vm
cd llm-inference-vm
sudo ./scripts/fetch-airgap-bundle.sh --output ./airgap-bundle
```

Le script installe les outils manquants (`curl`, `jq`, `python3`, `skopeo`,
`podman`/`docker`). Il télécharge :

- **host/** : dernier driver NVIDIA stable de la branche 595 (`.run`,
  `download.nvidia.com`), `.deb` du NVIDIA Container Toolkit, template LXC
  Ubuntu 26.04, `NVIDIA_DRIVER_VERSION` ;
- **images/** :
  - `vllm.tar` — `vllm/vllm-openai:v0.34.0` (CUDA 13)
  - `litellm.tar` — `ghcr.io/berriai/litellm:main-stable`
  - `open_webui.tar` — `ghcr.io/open-webui/open-webui:v0.13.4`
  - `docling.tar` — `quay.io/docling-project/docling-serve-cu130:v1.38.2`
  - `docling-cpu.tar` — `quay.io/docling-project/docling-serve:v1.38.2`
  - `pgvector.tar` — `pgvector/pgvector:pg17`
  - `cuda-smoke.tar` — `nvidia/cuda:13.0.0-base-ubuntu24.04`
- **models/** : `unsloth/Qwen3.8-27B-NVFP4`,
  `maurienne-ai/Qwen3.8-27B-DFlash2-NVFP4-RTNcal`,
  `Qwen/Qwen3-Embedding-0.6B` (snapshots HF complets, révision figée) ;
- **repo/** : closure apt Ubuntu 26.04 pour le LXC + `Packages.gz` + les `.deb`
  du toolkit NVIDIA ;
- **tessdata/** : `fra.traineddata` + `fr.traineddata` (Tesseract fast) ;
- **manifest.json** : versions, digests, modèles, révision HF ;
- **SHA256SUMS** : empreintes de tous les fichiers du bundle, vérifiées par le
  rôle `airgap` avant toute modification d'apt.

> EasyOCR `latin_g2` (qui couvre le français) est **déjà dans l'image Docling** ;
> il n'y a pas de modèle EasyOCR à télécharger séparément. Tesseract a besoin
> des fichiers `fra`/`fr` ci-dessus.

Options utiles :

```bash
# Version de driver connue bonne (si le dernier casse DKMS sur le kernel PVE)
NVIDIA_DRIVER_VERSION=595.104.02 sudo ./scripts/fetch-airgap-bundle.sh

# Modèle Hugging Face gated
HF_TOKEN=hf_xxx sudo ./scripts/fetch-airgap-bundle.sh

# Reprendre un build interrompu
sudo ./scripts/fetch-airgap-bundle.sh --skip-apt --skip-tessdata
sudo ./scripts/fetch-airgap-bundle.sh --force   # tout re-télécharger
```

Le bundle pèse plusieurs dizaines de Go (modèles + images + repo apt).
Vérifier son intégrité avant transfert :

```bash
( cd airgap-bundle && sha256sum -c SHA256SUMS )
```

Le rôle `airgap` refait cette vérification avant de toucher à apt. `SHA256SUMS`
protège contre la troncature/corruption ; ce n'est pas une signature
cryptographique du bundle.

## 2. Layout du bundle

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

## 3. Transférer

Vers l'hôte Proxmox (le LXC monte ce chemin en lecture seule) :

```bash
rsync -a --info=progress2 airgap-bundle/ root@192.0.2.1:/srv/airgap-bundle/
```

Vers la VM Docker existante (Open WebUI + PGVector), il faut seulement les
images et le compose :

```bash
rsync -a airgap-bundle/images/open_webui.tar \
         airgap-bundle/images/pgvector.tar \
         ubuntu@<vm>:/tmp/
scp -r deploy/openwebui ubuntu@<vm>:/opt/openwebui
```

## 4. Installer l'hôte Proxmox

Suivre `docs/HOST-INSTALL.md` :

1. driver NVIDIA + toolkit depuis `host/` ;
2. copie du template LXC dans `/var/lib/vz/template/cache/` ;
3. `terraform.tfvars` : `ubuntu_lxc_template_preuploaded = true`, puis
   `tofu apply` (le LXC uniquement) ;
4. `scripts/proxmox-lxc-gpu.sh <CTID> --bundle /srv/airgap-bundle` ;
5. Ansible.

## 5. Configuration Ansible airgap

Dans `ansible/group_vars/all.yml` :

```yaml
airgap_mode: true
llm_bundle_dir: /airgap-bundle

litellm_master_key: "<openssl rand -hex 32>"
docling_api_key: "<openssl rand -hex 32>"
litellm_base_url: "http://192.0.2.10:4000/v1"
docling_url: "http://192.0.2.10:5001"

# Site 48 Go :
docling_gpu: true
vllm_start: true
# pve-node1 (GPU 8 Go) : false / false

docling_ocr_preset: "tesseract"
docling_ocr_lang: ["fr"]
```

Puis :

```bash
cd ansible
ansible-playbook playbook.yml
```

Ce que font les rôles en mode airgap :

- `airgap` : bascule apt sur `file:///airgap-bundle/repo` et désactive les
  sources réseau ;
- `lxc_base` / `lxc_security` / `lxc_docker` : installent depuis le repo local
  (dont `fail2ban` ; auditd n'est pas utilisable dans un LXC non privilégié) ;
- `lxc_docker` : installe Docker + toolkit, force `no-cgroups=true`, charge
  `images/cuda-smoke.tar`, teste `nvidia-smi` dans un conteneur ;
- `inference_stack` :
  - charge `images/litellm.tar`, `images/docling.tar` (ou
    `images/docling-cpu.tar` si `docling_gpu: false`) et `images/vllm.tar` si
    `vllm_start` ;
  - copie `tessdata/fra.traineddata` et `fr.traineddata` dans
    `/srv/llm/docling/tessdata/` ;
  - monte `/airgap-bundle/models` dans vLLM en lecture seule ;
  - démarre LiteLLM + Docling (± vLLM) avec `--pull never` ;
  - Docling utilise l'image CUDA si `docling_gpu: true`, sinon l'image CPU ;
    les deux images sont dans le bundle (`docling.tar` / `docling-cpu.tar`).

## 6. Front airgap : Open WebUI + PGVector

Sur la VM Docker existante :

```bash
cd /opt/openwebui
docker load -i /tmp/open_webui.tar
docker load -i /tmp/pgvector.tar
cp .env.example .env
chmod 600 .env
$EDITOR .env
```

Dans `.env` :

- `LITELLM_BASE_URL` / `DOCLING_SERVER_URL` → l'IP du LXC ;
- `LITELLM_API_KEY` = `litellm_master_key` ;
- `DOCLING_API_KEY` = `docling_api_key` ;
- `POSTGRES_PASSWORD` / `WEBUI_SECRET_KEY` (hex) ;
- `DOCLING_PARAMS` :
  ```json
  {"ocr_preset":"tesseract","ocr_lang":["fr"],"table_mode":"accurate","do_table_structure":true}
  ```
  ou
  ```json
  {"ocr_preset":"easyocr","ocr_lang":["fr"],"table_mode":"accurate","do_table_structure":true}
  ```
- `ENABLE_PERSISTENT_CONFIG=false` (le `.env` gagne sur la DB/UI) ;
- `ENABLE_SIGNUP=true` au premier boot puis `false` ;
- `OFFLINE_MODE=true`.

Puis :

```bash
docker compose up -d --pull never
```

Le compose référence les tags exacts `open-webui:v0.13.4` et
`pgvector/pgvector:pg17` chargés depuis les tarballs. Aucun accès registre.

## 7. Vérifier

Sur le LXC :

```bash
nvidia-smi -L
docker run --rm --gpus all nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi -L
docker ps
docker logs -f docling
docker exec docling tesseract --list-langs   # eng, fr, fra, osd
curl -s -H "X-Api-Key: $DOCLING_KEY" http://127.0.0.1:5001/health
```

Sur la VM front :

```bash
docker compose ps
curl -s http://127.0.0.1:8080/health
docker compose exec postgres psql -U openwebui -d openwebui -c '\dx vector'
```

Depuis le LAN :

```bash
curl -s -H "Authorization: Bearer $LITELLM_KEY" \
  http://192.0.2.10:4000/v1/models
```

## 8. Notes

- Le bundle est figé au moment du build ; `manifest.json` permet de savoir
  exactement quelles images/modèles sont installés.
- Les images `open-webui:v0.13.4` et `pgvector/pgvector:pg17` sont épinglées ;
  `litellm:main-stable` est résolue au build et conservée dans le tarball.
- Le script prend par défaut le **dernier driver stable 595.x** via
  `https://download.nvidia.com/XFree86/Linux-x86_64/latest.txt` (actuellement
  595.112.07). Si le kernel PVE n'est pas encore supporté par DKMS, épingler
  `NVIDIA_DRIVER_VERSION=595.104.02` (validé sur pve-node1). Le driver 620.x de
  `us.download.nvidia.com` n'est pas utilisé par défaut.
- Tesseract est le moteur OCR par défaut (CPU, 0 VRAM, le plus rapide).
  EasyOCR est disponible pour les scans inversés/bruités ; sur le site 48 Go,
  il peut utiliser le GPU (~1-2 GB VRAM) et Tesseract reste à 0 VRAM.
- `table_mode=accurate` active TableFormer accurate pour les tableaux ; il
  tourne sur CPU et GPU (pas GPU-only) et c'est déjà le défaut Docling.
- Les modèles Docling (layout/table) sont inclus dans l'image CPU (vérifié :
  `artifacts_path` valide, aucun téléchargement au runtime). L'image CUDA
  `cu130` utilise le même cache ; confirmer `DOCLING_SERVE_ARTIFACTS_PATH` au
  premier démarrage sur la cible.
- Le dépôt apt local reste en `trusted=yes` : `SHA256SUMS` couvre la
  corruption/troncature, pas une signature cryptographique. Pour une signature
  détachée, ajouter une clé GPG détenue hors bundle.
- `ENABLE_PERSISTENT_CONFIG=false` dans le compose Open WebUI : le `.env` est
  la source de vérité. Les changements faits dans l'UI s'appliquent jusqu'au
  redémarrage mais ne sont pas enregistrés ; modifier `.env` puis
  `docker compose up -d` pour un réglage durable.
- Le seul secret applicatif partagé LXC ↔ VM front est
  `litellm_master_key` + `docling_api_key` ; ils sont dans `all.yml`
  (gitignoré), `/srv/llm/litellm/litellm.env` (0600) et le `.env` du compose.
- vLLM n'écoute que sur `127.0.0.1:8000` / le réseau Docker interne ; seuls
  LiteLLM `:4000` et Docling `:5001` sont exposés au LAN.
