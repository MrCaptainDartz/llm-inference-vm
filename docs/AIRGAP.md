# Bundle et déploiement airgap

Le site cible n'a pas d'accès internet. Tout est téléchargé sur un builder
Ubuntu 26.04 amd64 connecté, transféré, puis installé hors ligne.

Le script `scripts/fetch-airgap-bundle.sh` remplace l'ancien rôle Ansible
`bundle_download`. Il résout les dernières versions au moment du build et
écrit un `manifest.json` avec les versions/digests exacts.

## 1. Construire le bundle (machine en ligne)

Sur un builder **Ubuntu 26.04 amd64** avec internet (idéalement une instance
fraîche de la même image cloud que la VM front) :

```bash
git clone <repo> llm-inference-vm
cd llm-inference-vm
sudo ./scripts/fetch-airgap-bundle.sh --output ./airgap-bundle
```

Le script installe les outils manquants (`curl`, `jq`, `python3`, `skopeo`,
`podman`/`docker`, `dpkg-dev` dans le conteneur apt). Il télécharge :

- **host/** : dernier driver NVIDIA `.run`, `.deb` du NVIDIA Container Toolkit,
  template LXC Ubuntu 26.04, `NVIDIA_DRIVER_VERSION` ;
- **cloudimg/** : image cloud Ubuntu 26.04 ;
- **images/** : `vllm.tar` (`vllm/vllm-openai:v0.34.0`, CUDA 13),
  `litellm.tar`, `open_webui.tar`, `docling.tar` (CPU), `cuda-smoke.tar` ;
- **models/** : `unsloth/Qwen3.8-27B-NVFP4`,
  `maurienne-ai/Qwen3.8-27B-DFlash2-NVFP4-RTNcal`,
  `Qwen/Qwen3-Embedding-0.6B` (snapshots HF complets, révision figée) ;
- **repo/** : closure apt Ubuntu 26.04 pour le LXC et la VM front +
  `Packages.gz` + les `.deb` du toolkit NVIDIA ;
- **docling-artifacts/** : modèles Docling pré-téléchargés (CPU) ;
- **manifest.json** : versions, digests, modèles, révision HF.

Options utiles :

```bash
# Version de driver connue bonne (si le dernier casse DKMS sur le kernel PVE)
NVIDIA_DRIVER_VERSION=595.104.02 sudo ./scripts/fetch-airgap-bundle.sh

# Modèle Hugging Face gated
HF_TOKEN=hf_xxx sudo ./scripts/fetch-airgap-bundle.sh

# Reprendre un build interrompu
sudo ./scripts/fetch-airgap-bundle.sh --skip-apt --skip-docling
sudo ./scripts/fetch-airgap-bundle.sh --force   # tout re-télécharger
```

Le bundle pèse plusieurs dizaines de Go (modèles + images + repo apt).

## 2. Layout du bundle

```text
airgap-bundle/
  manifest.json
  host/
    NVIDIA-Linux-x86_64-<ver>.run
    NVIDIA_DRIVER_VERSION
    nvidia-container-toolkit/*.deb
    ubuntu-26.04-standard_26.04-1_amd64.tar.zst
  cloudimg/
    ubuntu-26.04-server-cloudimg-amd64.img
  images/
    vllm.tar
    litellm.tar
    open_webui.tar
    docling.tar
    cuda-smoke.tar
  models/
    qwen3.8-27b-nvfp4/
    qwen3.8-27b-dflash2-draft/
    qwen3-embedding-0.6b/
  repo/
    pool/*.deb
    Packages.gz
  docling-artifacts/
```

## 3. Transférer

Vers l'hôte Proxmox (le LXC monte ce chemin en lecture seule) :

```bash
rsync -a --info=progress2 airgap-bundle/ root@192.0.2.1:/srv/airgap-bundle/
```

Vers la VM front (elle a besoin de `repo/`, `images/`, `docling-artifacts/`) :

```bash
rsync -a --info=progress2 airgap-bundle/ ubuntu@192.0.2.11:/airgap-bundle/
```

L'hôte Proxmox a besoin de `host/` et `cloudimg/` pour l'installation du
driver/toolkit/template/image cloud. Le LXC a besoin de `repo/`, `images/`,
`models/`. La VM front a besoin de `repo/`, `images/`, `docling-artifacts/`.

## 4. Installer l'hôte Proxmox

Suivre `docs/HOST-INSTALL.md` :

1. driver NVIDIA + toolkit depuis `host/` ;
2. copie du template LXC et de l'image cloud dans les datastores ;
3. `terraform.tfvars` en mode airgap (`cloud_image_preuploaded`,
   `ubuntu_lxc_template_preuploaded`) puis `tofu apply` ;
4. `scripts/proxmox-lxc-gpu.sh <CTID> --bundle /srv/airgap-bundle` ;
5. Ansible.

## 5. Configuration Ansible airgap

Dans `ansible/group_vars/all.yml` :

```yaml
airgap_mode: true
llm_bundle_dir: /airgap-bundle

litellm_master_key: "<openssl rand -hex 32>"
litellm_base_url: "http://192.0.2.10:4000/v1"

# Sur le host 48 Go uniquement. Laisser false sur pve-node1 (GPU 8 Go).
vllm_start: true
```

Puis :

```bash
cd ansible
ansible-playbook playbook.yml
```

Ce que font les rôles en mode airgap :

- `airgap` : bascule apt sur `file:///airgap-bundle/repo` et désactive les
  sources réseau ;
- `lxc_base` / `essential_packages` / `podman` / `security_hardening` :
  installent depuis le repo local ;
- `lxc_docker` : installe Docker + toolkit depuis le repo, charge
  `images/cuda-smoke.tar`, teste `nvidia-smi` dans un conteneur ;
- `inference_stack` : charge `images/litellm.tar` (et `images/vllm.tar` si
  `vllm_start`), monte `/airgap-bundle/models` en lecture seule, démarre
  LiteLLM ± vLLM avec `--pull never` ;
- `docling` : charge `images/docling.tar`, copie `docling-artifacts/` et
  démarre Docling avec `DOCLING_SERVE_ARTIFACTS_PATH=/app/data` ;
- `open_webui` : charge `images/open_webui.tar`, `OFFLINE_MODE=true`, pointe
  vers LiteLLM.

Le LXC monte le bundle de l'hôte via `mpN -> /airgap-bundle` (script hôte).
La VM front reçoit le bundle par rsync.

## 6. Vérifier

Sur le LXC :

```bash
nvidia-smi -L
docker run --rm --gpus all nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi -L
docker ps
docker logs -f vllm          # sur le host 48 Go
curl -s http://127.0.0.1:8000/v1/models
```

Depuis le LAN :

```bash
curl -s -H "Authorization: Bearer $LITELLM_KEY" \
  http://192.0.2.10:4000/v1/models
```

Sur la VM front :

```bash
curl -s http://192.0.2.11:8080/health
curl -s http://127.0.0.1:5001/health
```

Puis ouvrir `http://192.0.2.11:8080`, créer le premier compte admin, et
indexer un PDF : Docling extrait, LiteLLM route les embeddings vers vLLM.

## 7. Notes

- Le bundle est figé au moment du build ; `manifest.json` permet de savoir
  exactement quelles images/modèles sont installés.
- Les images `open-webui:main` et `docling:latest` sont résolues au build et
  conservées dans les tarballs ; le runtime ne tire jamais depuis le réseau.
- Le script prend par défaut le **dernier** driver NVIDIA. Si le kernel PVE
  n'est pas encore supporté par DKMS, épingler une version connue bonne.
- La clé `litellm_master_key` est le seul secret applicatif partagé entre le
  LXC et la VM front ; elle est dans `all.yml` (gitignoré) et dans
  `/srv/llm/litellm/litellm.env` (0600) sur le LXC.
- vLLM n'écoute que sur `127.0.0.1:8000` dans le LXC et sur le réseau Docker
  interne ; seul LiteLLM `:4000` est exposé au LAN.
