# Hôte Proxmox et LXC d'inférence

Ce document couvre la partie **manuelle** de l'hôte Proxmox : driver NVIDIA,
toolkit, template LXC, hooks GPU, bind mount du bundle airgap.

Le PVE cible existe déjà et est airgap : ce dépôt ajoute seulement le LXC
(et les VM que tu crées à côté). Les dépôts Debian/PVE locaux
(`main contrib non-free non-free-firmware`) sont supposés configurés ; ils
fournissent `dkms`, `build-essential` et les headers du kernel. Le bundle ne
duplique pas ces paquets.

Le LXC reste **non privilégié**. Le GPU n'est pas passé en PCI/VFIO : le host
garde le driver et le LXC reçoit les devices + les libs user-space via le hook
NVIDIA de Proxmox.

La partie front (Open WebUI + PGVector) tourne sur **ta VM Docker existante**
via `deploy/openwebui/docker-compose.yml`. Ce repo ne crée plus de VM front.

## 1. Prérequis

- Proxmox VE 9.2+ avec `lxc-pve >= 6.0.5` (`dpkg -l lxc-pve`).
- Dépôts Debian/PVE locaux (`main contrib non-free non-free-firmware`).
- `dkms`, `build-essential`, `proxmox-headers-$(uname -r)` depuis ces dépôts.
- Un GPU NVIDIA visible sur l'hôte (`lspci`, `nvidia-smi`).
- Le bundle airgap transféré sur l'hôte (voir `docs/AIRGAP.md`).
- Un token API Proxmox et la clé SSH publique pour Terraform.

Vérifications :

```bash
pveversion
dpkg -l lxc-pve | tail -1
ls -l /usr/share/lxc/hooks/nvidia
```

## 2. Driver NVIDIA (version du bundle)

Le bundle contient `host/NVIDIA-Linux-x86_64-<version>.run` et
`host/NVIDIA_DRIVER_VERSION`.

```bash
cd /path/to/airgap-bundle/host
apt update
apt install -y dkms build-essential "proxmox-headers-$(uname -r)"
chmod +x NVIDIA-Linux-x86_64-*.run
./NVIDIA-Linux-x86_64-*.run --dkms --no-x-check --no-nouveau-check
```

`pve-headers` est une méta transitionnelle ; `proxmox-headers-$(uname -r)`
cible le kernel courant. Les deux viennent de tes dépôts PVE locaux, pas du
bundle.

Sélection interactive recommandée : pas de 32 bits, pas de X, DKMS = oui.

Vérifications :

```bash
nvidia-smi
dkms status
modprobe nvidia_uvm
ls -l /dev/nvidia0 /dev/nvidia-uvm
```

> Le script prend par défaut le **dernier driver stable** de la branche 595
> (`https://download.nvidia.com/XFree86/Linux-x86_64/latest.txt`, actuellement
> 595.112.07). La version `595.104.02` est celle validée sur `pve-node1`
> (PVE 9.2.27, kernel 7.0). Si besoin, pin :
> `NVIDIA_DRIVER_VERSION=595.104.02 ./scripts/fetch-airgap-bundle.sh`.

## 3. NVIDIA Container Toolkit (hôte)

Le hook `/usr/share/lxc/hooks/nvidia` (fourni par `lxc-pve`) appelle
`nvidia-container-cli`. Il faut donc le toolkit sur l'hôte :

```bash
apt install -y /path/to/airgap-bundle/host/nvidia-container-toolkit/*.deb
nvidia-container-cli --version
nvidia-ctk --version
```

## 4. Template LXC

```bash
cp /path/to/airgap-bundle/host/ubuntu-26.04-standard_26.04-1_amd64.tar.zst \
   /var/lib/vz/template/cache/
```

Dans `iac/terraform.tfvars` (mode airgap) :

```hcl
ubuntu_lxc_template_preuploaded = true
```

Garder `proxmox_insecure = false` ; le passer à `true` uniquement si l'API
Proxmox a un certificat auto-signé.

Puis, depuis le poste de pilotage :

```bash
cd iac
tofu init
tofu apply
```

Cela crée **uniquement** le LXC (120 par défaut, `llm-lxc`). Pas de VM
front, pas d'image cloud, pas de snippet cloud-init.

## 5. Hooks GPU du LXC

Sur l'hôte Proxmox, après la création du LXC :

```bash
/path/to/repo/scripts/proxmox-lxc-gpu.sh 120 \
  --bundle /srv/airgap-bundle
```

Le script :

- arrête le LXC ;
- active `nesting=1,keyctl=1,fuse=1,mknod=1` ;
- détecte les majors NVIDIA réels (`/dev/nvidia0`, `/dev/nvidia-uvm`, …) et
  ajoute les règles `lxc.cgroup2.devices.allow` ;
- ajoute le hook `lxc.hook.pre-start` (`nvidia_uvm`), le hook
  `lxc.hook.mount` (`/usr/share/lxc/hooks/nvidia`), les variables
  `NVIDIA_VISIBLE_DEVICES=all` / `NVIDIA_DRIVER_CAPABILITIES=compute,utility` ;
- ajoute 16 GiB de `/dev/shm` ;
- monte le bundle en lecture seule sur `/airgap-bundle` (`mpN`) ;
- redémarre le LXC et vérifie `nvidia-smi` dedans.

Il ne touche **pas** à `/dev/dri` : CUDA n'en a pas besoin, et un LXC
non privilégié ne pourrait pas utiliser les nodes `0660 root:video` sans
mapper les GID. Le script n'ajoute que les majors NVIDIA.

### Firewall Proxmox

Le LXC est créé avec `network_firewall = true`. Si le firewall Proxmox est
actif, ouvre au minimum `22` (Ansible/SSH), `4000` (LiteLLM) et `5001`
(Docling), ou passe `network_firewall = false` dans `terraform.tfvars`.
Sans règle, `tofu apply` peut réussir mais Ansible/Open WebUI ne joindra pas
le LXC.

Vérifications :

```bash
pct config 120 | grep -E 'features|lxc.cgroup2|lxc.hook|lxc.environment|mp[0-9]'
pct exec 120 -- nvidia-smi -L
ssh root@192.0.2.10 nvidia-smi -L
```

## 6. Ansible : LXC d'inférence

```bash
cd ansible
cp inventory/inventory.yml.example inventory/inventory.yml
cp group_vars/all.yml.example group_vars/all.yml
$EDITOR group_vars/all.yml
```

Renseigner au minimum :

```yaml
litellm_master_key: "<openssl rand -hex 32>"
docling_api_key: "<openssl rand -hex 32>"
litellm_base_url: "http://<ip-lxc>:4000/v1"
docling_url: "http://<ip-lxc>:5001"

# pve-node1 (GPU 8 Go) :
vllm_start: false
docling_gpu: false

# Site 48 Go :
# vllm_start: true
# docling_gpu: true
```

Puis :

```bash
ssh-keyscan -H <ip-lxc> >> ~/.ssh/known_hosts
ansible-playbook playbook.yml
```

Ansible vérifie les clés d'hôte (`host_key_checking = true`) ; sans l'entrée
`known_hosts`, le premier run échoue volontairement.

Le rôle `lxc_docker` installe Docker + `nvidia-container-toolkit`, configure le
runtime Docker `nvidia` avec `no-cgroups=true`, charge l'image CUDA de smoke
test et exécute `nvidia-smi` dans un conteneur.

Le rôle `inference_stack` :

- télécharge `fra.traineddata` et le duplique en `fr.traineddata` dans
  `/srv/llm/docling/tessdata/` (le preset Tesseract de Docling cherche `fr`) ;
- déploie le compose vLLM + embedding + LiteLLM + **Docling** ;
- avec `docling_gpu: false`, utilise l'image Docling CPU ; avec `true`,
  l'image CUDA `docling-serve-cu130:v1.38.2` et le runtime `nvidia` (Docling
  détecte CUDA automatiquement ; il n'y a pas de `DOCLING_DEVICE` à forcer) ;
- expose LiteLLM `:4000` et Docling `:5001` au LAN ; vLLM reste sur
  `127.0.0.1:8000` / réseau Docker interne ;
- attend la santé de LiteLLM et de Docling (API key).

Le Docling contient **les deux moteurs OCR** :
- **Tesseract** (`fra`/`fr`) : CPU, 0 VRAM, rapide ;
- **EasyOCR** (`latin_g2` inclus dans l'image) : plus robuste sur les scans
  inversés/bruités, plus lent sur CPU et ~1-2 GB VRAM s'il utilise le GPU.

Le choix se fait côté Open WebUI via `DOCLING_PARAMS` (voir
`deploy/openwebui/README.md`). `table_mode=accurate` active TableFormer
accurate pour les tableaux ; il tourne sur CPU **et** GPU (pas uniquement
GPU), et c'est déjà le défaut Docling.

## 7. Front : Open WebUI + PGVector sur ta VM Docker

Sur ta VM existante :

```bash
cd deploy/openwebui
cp .env.example .env
chmod 600 .env
$EDITOR .env
docker compose config --quiet
docker compose up -d
```

Renseigner `LITELLM_BASE_URL`, `LITELLM_API_KEY` (le master key),
`DOCLING_SERVER_URL`, `DOCLING_API_KEY`, `POSTGRES_PASSWORD`,
`WEBUI_SECRET_KEY`, et `DOCLING_PARAMS` :

```json
{"ocr_preset":"tesseract","ocr_lang":["fr"],"table_mode":"accurate","do_table_structure":true}
```

ou EasyOCR :

```json
{"ocr_preset":"easyocr","ocr_lang":["fr"],"table_mode":"accurate","do_table_structure":true}
```

Garder `ENABLE_PERSISTENT_CONFIG=false` : le `.env` gagne sur la DB/UI. Modifier
les réglages dans `.env` puis `docker compose up -d` ; les changements faits
dans l'UI ne survivent pas au redémarrage.

Le compose inclut PostgreSQL 17 + pgvector pour la DB applicative **et** les
vecteurs. `PGVECTOR_INITIALIZE_MAX_VECTOR_LENGTH=1024` correspond à
Qwen3-Embedding-0.6B. Voir `deploy/openwebui/README.md` pour les prérequis de
la VM (Docker Engine + Compose v2, 4 Go RAM, accès aux ports 4000/5001), les
backups, l'airgap et le dépannage.

## 8. Cible 48 Go

Sur le serveur cible (GPU 48 Go) :

```yaml
vllm_start: true
docling_gpu: true
```

Puis :

```bash
ansible-playbook playbook.yml --limit inference_lxc
```

Le profil :
- vLLM chat `--gpu-memory-utilization 0.78` quand Docling GPU est actif
  (0.82 sinon), embedding `0.06` ;
- Docling GPU layout/table ~4-5 GB, OCR Tesseract CPU 0 VRAM (EasyOCR ~1-2 GB
  s'il est sélectionné) ;
- marge résiduelle ~2,7-3,7 GB sur 48 Go, à mesurer au premier démarrage
  (les pics Docling peuvent la réduire).

Premier démarrage vLLM (chargement des poids) :

```bash
docker logs -f vllm
curl -s http://127.0.0.1:8000/v1/models
```

Vérifier le rendu Docling et l'OCR dans les logs :

```bash
docker logs -f docling
docker exec docling tesseract --list-langs   # eng, fr, fra, osd
```

Points de vigilance :
- `--kv-cache-dtype nvfp4`, `--attention-backend flash_attn`,
  `--speculative-config '{"method":"dflash",...,"num_speculative_tokens":7}'` ;
- si le décode NVFP4/DFlash sm120 plante, passer `vllm_enforce_eager: true` ;
- si `--reasoning-parser qwen3` / `--tool-call-parser qwen3_coder` n'existent
  pas dans l'image vLLM, les vider dans `all.yml` ;
- ne jamais exposer vLLM (8000) sur le LAN : seuls LiteLLM (4000) et Docling
  (5001) sont publiés, protégés par leurs clés.

## 9. Notes de sécurité

- LXC non privilégié, `nesting/keyctl/fuse/mknod` pour Docker, hook NVIDIA.
- Les devices NVIDIA sont en `0666` (défaut du driver) ; l'autorisation réelle
  est le cgroup `lxc.cgroup2.devices.allow` (majors 195/509).
- Pas de `/dev/dri` : inutile pour CUDA, et impossible à utiliser proprement
  dans un LXC non privilégié sans mapping des GID `video`/`render`.
- `nvidia-container-cli` tourne avec `--no-cgroups` : le cgroup est géré par le
  parent LXC, pas par le toolkit.
- LiteLLM et Docling portent chacun une clé API ; vLLM n'est pas exposé.
- Docling `DOCLING_SERVE_API_KEY` et LiteLLM `litellm_master_key` sont dans
  `group_vars/all.yml` (gitignoré) et dans `/srv/llm/...` (0600 pour LiteLLM et
  pour le compose, qui contient aussi les clés).

Les anciens rôles `firewall` et `security_hardening` ne sont pas réappliqués :
leur sysctl `net.ipv4.ip_forward=0` casse Docker, et UFW ne filtre pas les
ports publiés par Docker. La frontière réseau est donc le firewall Proxmox
(voir ci-dessus) ; le LXC garde SSH key-only, et les conteneurs ont
`no-new-privileges` + `pids_limit`. Ajouter fail2ban/auditd est possible mais
n'est pas inclus dans le bundle airgap.
