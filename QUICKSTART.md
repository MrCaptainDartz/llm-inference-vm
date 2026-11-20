# Quickstart

De zéro à une stack d'inférence LLM sur Proxmox, avec :

- un **LXC** pour vLLM (chat + embeddings) et LiteLLM ;
- une **VM** pour Open WebUI + Docling ;
- le GPU NVIDIA sur l'hôte, injecté dans le LXC par le hook Proxmox ;
- un mode **airgap** pour le site cible.

~30 minutes hors téléchargement des modèles et build du bundle.

## 0. Prérequis

- Proxmox VE 9.2+ avec `lxc-pve >= 6.0.5`.
- Driver NVIDIA + `nvidia-container-toolkit` sur l'hôte
  ([docs/HOST-INSTALL.md](docs/HOST-INSTALL.md)).
- Poste de pilotage : `tofu` (OpenTofu ≥ 1.11), `ansible-core` +
  `community.general`, une clé SSH.
- Airgap : un builder Ubuntu 26.04 amd64 avec internet.

```bash
ansible-galaxy collection install community.general
```

## 1. Créer le LXC et la VM front

```bash
cd iac
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
```

Renseigner au minimum : `proxmox_api_url`, `proxmox_api_token`,
`ssh_public_key`, `vm_node_name`, `network_bridge`, `network_gateway`,
`lxc_ipv4`, `front_vm_ipv4`.

Défauts : LXC 120 `llm-lxc` → `192.0.2.10/24`, VM 112 `llm-webui` →
`192.0.2.11/24`.

```bash
tofu init
tofu apply
```

L'ancienne VM 103 de l'ancienne architecture est détruite si elle est encore
dans le state. Le LXC et la VM démarrent ; les hooks GPU sont ajoutés ensuite.

## 2. Ajouter les hooks GPU au LXC

Sur l'hôte Proxmox :

```bash
/path/to/repo/scripts/proxmox-lxc-gpu.sh 120
```

Cela active les features Docker-in-LXC, les règles cgroup NVIDIA, le hook
`/usr/share/lxc/hooks/nvidia`, 16 GiB de `/dev/shm`, et vérifie `nvidia-smi`
dans le LXC. En airgap, ajouter
`--bundle /srv/airgap-bundle`.

## 3. Configurer Ansible

```bash
cd ../ansible
cp inventory/inventory.yml.example inventory/inventory.yml
cp group_vars/all.yml.example group_vars/all.yml
$EDITOR group_vars/all.yml
```

À renseigner :

```yaml
litellm_master_key: "<openssl rand -hex 32>"
litellm_base_url: "http://192.0.2.10:4000/v1"   # aligné sur lxc_ipv4

# Serveur 48 Go :
vllm_start: true
# pve-node1 (GPU 8 Go, test) :
# vllm_start: false
```

Airgap : ajouter `airgap_mode: true` et `llm_bundle_dir: /airgap-bundle`.

## 4. Installer

### Chemin A — Online

```bash
ansible-playbook playbook.yml
```

Le play LXC installe Docker + toolkit NVIDIA, configure le runtime Docker et
démarre LiteLLM (et vLLM si `vllm_start: true`). Le play VM installe Podman
rootless, Docling et Open WebUI.

Sur `pve-node1` (GPU 8 Go), `vllm_start: false` : LiteLLM démarre seul, Open WebUI
et Docling fonctionnent. Le chat LLM n'est pas disponible sur cette machine.

### Chemin B — Airgap

1. Sur le builder :

   ```bash
   sudo ./scripts/fetch-airgap-bundle.sh --output ./airgap-bundle
   ```

2. Transférer le bundle :

   ```bash
   rsync -a airgap-bundle/ root@<pve>:/srv/airgap-bundle/
   rsync -a airgap-bundle/ ubuntu@<front>:/airgap-bundle/
   ```

3. `iac/terraform.tfvars` :

   ```hcl
   cloud_image_preuploaded        = true
   ubuntu_lxc_template_preuploaded = true
   enable_cloudinit_snippet       = true
   ```

4. `tofu apply`, puis `scripts/proxmox-lxc-gpu.sh <CTID> --bundle ...`.

5. `all.yml` : `airgap_mode: true`, `llm_bundle_dir: /airgap-bundle`, puis
   `ansible-playbook playbook.yml`.

Détails : [docs/AIRGAP.md](docs/AIRGAP.md).

## 5. Vérifier

```bash
# Hôte / LXC
ssh root@192.0.2.10 nvidia-smi
ssh root@192.0.2.10 docker ps
ssh root@192.0.2.10 'docker run --rm --gpus all nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi -L'

# LiteLLM
curl -s -H "Authorization: Bearer $LITELLM_KEY" \
  http://192.0.2.10:4000/v1/models

# VM front
curl -s http://192.0.2.11:8080/health
ssh ubuntu@192.0.2.11 'curl -s http://127.0.0.1:5001/health'
```

Sur le serveur 48 Go, le premier démarrage vLLM charge les poids (long) :

```bash
ssh root@192.0.2.10
docker logs -f vllm
curl -s http://127.0.0.1:8000/v1/models
```

## 6. Premier chat

1. Ouvrir `http://192.0.2.11:8080`.
2. Créer le premier compte (admin), puis fermer l'inscription dans le panneau
   admin.
3. Le modèle `qwen3.8-27b` est exposé par LiteLLM ; discuter.

## 7. RAG : indexer un document

1. **Espace de travail → Base de connaissances** → créer.
2. Uploader un PDF : Docling l'analyse, LiteLLM route les embeddings vers vLLM.
3. Dans un chat, mentionner la base (`#nom-de-la-base`) et poser une question.

## 8. Brancher un outil de code

LiteLLM est le seul endpoint public :

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

## La suite

- Profil VRAM, DFlash2/NVFP4 et limites : [README](README.md).
- Hôte Proxmox : [docs/HOST-INSTALL.md](docs/HOST-INSTALL.md).
- Airgap : [docs/AIRGAP.md](docs/AIRGAP.md).
