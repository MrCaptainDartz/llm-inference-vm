# Quickstart

De zéro à une VM d'inférence LLM sur Proxmox, avec chat WebUI + RAG sur le LAN.
~30 minutes hors téléchargement des poids du modèle.

Deux chemins d'installation, fork à l'étape 3 :

- **Chemin A — Internet** : la VM a un egress, tout se télécharge au premier
  démarrage des services.
- **Chemin B — Airgap** : la VM (et éventuellement le node Proxmox) n'ont pas
  d'accès internet ; tout transite par un bundle construit sur un builder
  Ubuntu 26.04 avec internet.

## 0. Prérequis

Commun :

- Proxmox VE avec un token API (droits sur le node cible).
- Poste de pilotage : `tofu` (OpenTofu ≥ 1.8), `ansible-core` + collection
  `community.general`, une clé SSH publique.

```bash
ansible-galaxy collection install community.general
```

Chemin B uniquement — un **builder** : host Ubuntu 26.04 amd64 avec internet,
idéalement une instance fraîche de la même image cloud que la VM (la closure
apt du bundle n'est correcte que dans ce cas), avec le repo cloné dessus.

## 1. Créer la VM

```bash
cd iac
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
```

À renseigner au minimum : `proxmox_api_url`, `proxmox_api_token`,
`ssh_public_key`, `vm_node_name`, `network_interfaces` (bridge + IP statique).

Avec GPU : ajouter le passthrough et désactiver Secure Boot —

```hcl
pci_devices = [{ mapping = "gpu", pcie = true, rombar = true, xvga = false }]
efi_pre_enrolled_keys = false
```

Chemin B avec **node Proxmox isolé** : uploader au préalable
`airgap-bundle/cloudimg/*.img` dans le datastore `local` du node
(`/var/lib/vz/template/iso/`), puis dans `terraform.tfvars` :

```hcl
cloud_image_preuploaded = true    # pas de téléchargement par OpenTofu
enable_cloudinit_snippet = false  # pas d'apt cloud-init au premier boot
```

Puis, sur tous les chemins :

```bash
tofu init
tofu apply          # noter vm_ips en sortie
```

## 2. Préparer la configuration Ansible

```bash
cd ../ansible
cp inventory/inventory.yml.example inventory/inventory.yml    # ansible_host = vm_ips
cp group_vars/all.yml.example group_vars/all.yml
$EDITOR group_vars/all.yml
```


Flags pour la VM GPU — dans `group_vars/all.yml`, passer à `true` :

```yaml
nvidia_enabled: true          # driver NVIDIA open + CDI
sglang_enabled: true          # moteur LLM, API :30000
# sglang_embedding_enabled est déjà true (embeddings RAG, Qwen3-Embedding-0.6B)
docling_gpu: true             # parsing RAG sur GPU : le pool SGLang retombe à 0.78 automatiquement
```

Sans GPU : ne rien changer — Open WebUI + Docling (CPU) fonctionnent déjà,
seul le chat LLM est absent (pas de backend).

Chemin B uniquement — déclarer le builder dans `inventory/inventory.yml`
(groupe `bundle_builder` déjà présent dans l'example) :

```yaml
bundle_builder:
  hosts:
    bundle-builder:
      ansible_host: 10.0.0.20     # ou ansible_connection: local si c'est ce host
      ansible_user: ubuntu
```

## 3. Installer

### Chemin A — Internet

```bash
ansible-playbook playbook.yml     # reboote si un kernel a été mis à jour
```

Les images conteneurs sont pullées par le playbook, les poids du modèle
(tens de GB) par SGLang à son premier start — pas de timeout systemd,
surveiller `journalctl --user -u sglang -f` depuis `ssh inference@<ip>`.

### Chemin B — Airgap

**3.1. Construire le bundle** — sur le builder (repo cloné dessus), depuis
`ansible/` :

```bash
ansible-playbook playbook-download.yml
```

Produit `<repo>/airgap-bundle/` : repo apt local (`repo/`), images conteneurs
(`images/`), snapshots HF (`models/`), artifacts Docling pré-bakés
(`docling-artifacts/`), image cloud Ubuntu (`cloudimg/`).

**3.2. Transférer** vers la VM :

```bash
rsync -a airgap-bundle/ ubuntu@<ip>:/airgap-bundle/
```

**3.3. Basculer en mode offline** — dans `group_vars/all.yml` :

```yaml
airgap_mode: true
llm_bundle_dir: /airgap-bundle
```

Tout le reste suit automatiquement : chemins de modèles (`/models/…`),
`unattended-upgrades` off, `OFFLINE_MODE` / `HF_HUB_OFFLINE=1` dans les
conteneurs, montage des modèles en lecture seule.

**3.4. Installer** — depuis le poste de pilotage, comme au chemin A :

```bash
ansible-playbook playbook.yml
```

Le rôle `airgap` bascule apt sur le repo local du bundle, les images sont
chargées via `podman load`, et SGLang sert les modèles depuis `/models` avec
`HF_HUB_OFFLINE=1`.

## 4. Vérifier

```bash
ssh ubuntu@<ip> nvidia-smi                        # VM GPU : le driver est chargé
curl -s http://<ip>:8080/health                   # Open WebUI
curl -s http://<ip>:30000/v1/models | jq '.data[].id'   # SGLang prête
```

Identique sur les deux chemins — en airgap, aucun téléchargement ne doit
apparaître dans les logs des conteneurs.

## 5. Premier chat

1. Ouvrir `http://<ip>:8080`, créer le compte (le premier devient admin).
2. Sélectionner le modèle servi (ex. `qwen3.8-27b`) et discuter.

## 6. RAG : indexer un document

1. `http://<ip>:8080` → **Espace de travail → Base de connaissances** → créer.
2. Uploader un PDF : Docling l'analyse (extraction), les chunks sont embarqués
   via le serveur d'embedding SGLang.
3. Dans un chat, mentionner la base (`#nom-de-la-base`) et poser une question
   sur le document.

## 7. Brancher un outil de code (OpenAI-compatible)

SGLang expose une API OpenAI sur le LAN — utilisable par Pi, omp, ou tout
client OpenAI :

```bash
export OPENAI_BASE_URL=http://<ip>:30000/v1
export OPENAI_API_KEY=sglang              # mettre la valeur de sglang_api_key si défini
export OPENAI_MODEL=qwen3.8-27b
```

```bash
curl -s http://<ip>:30000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.8-27b","messages":[{"role":"user","content":"Salut !"}]}' | jq -r '.choices[0].message.content'
```

## La suite

- Budget mémoire / réglages SGLang (RTX PRO 5000 48 GB) : [README](README.md).
- Détails du déploiement airgap : [README](README.md#déploiement-airgap).
