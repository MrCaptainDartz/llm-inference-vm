# Installation de l'hôte Proxmox et du LXC d'inférence

Ce document couvre la partie **manuelle** de l'hôte Proxmox : driver NVIDIA,
toolkit, template LXC, hooks GPU et bind mount du bundle airgap. Le reste
(Docker, vLLM, LiteLLM, Open WebUI, Docling) est géré par Ansible.

Le LXC reste **non privilégié**. Le GPU n'est pas passé en PCI/VFIO : le host
garde le driver et le LXC reçoit les devices + les libs user-space via le hook
NVIDIA de Proxmox.

## 1. Prérequis

- Proxmox VE 9.2+ avec `lxc-pve >= 6.0.5` (`dpkg -l lxc-pve`).
- `dkms`, `pve-headers`, `build-essential`.
- Un GPU NVIDIA visible sur l'hôte (`lspci`, `nvidia-smi`).
- Le bundle airgap transféré sur l'hôte (voir `docs/AIRGAP.md`).
- Un token API Proxmox et la clé SSH publique pour Terraform.

Vérifications :

```bash
pveversion
dpkg -l lxc-pve | tail -1
ls -l /usr/share/lxc/hooks/nvidia
```

## 2. Driver NVIDIA (dernière version du bundle)

Le bundle contient `host/NVIDIA-Linux-x86_64-<version>.run` et
`host/NVIDIA_DRIVER_VERSION`.

```bash
cd /path/to/airgap-bundle/host
apt update
apt install -y dkms pve-headers build-essential
chmod +x NVIDIA-Linux-x86_64-*.run
./NVIDIA-Linux-x86_64-*.run --dkms --no-x-check --no-nouveau-check
```

Sélection interactive recommandée : pas de 32 bits, pas de X, DKMS = oui.

Vérifications :

```bash
nvidia-smi
dkms status
modprobe nvidia_uvm
ls -l /dev/nvidia0 /dev/nvidia-uvm
```

> Le script prend par défaut le **dernier** driver publié. Si le DKMS échoue
> avec le kernel Proxmox, relancez le builder avec une version connue bonne :
> `NVIDIA_DRIVER_VERSION=595.104.02 ./scripts/fetch-airgap-bundle.sh`.
> La version `595.104.02` est celle validée sur `pve-node1` (PVE 9.2.27, kernel 7.0).

## 3. NVIDIA Container Toolkit (hôte)

Le hook `/usr/share/lxc/hooks/nvidia` (fourni par `lxc-pve`) appelle
`nvidia-container-cli`. Il faut donc le toolkit sur l'hôte :

```bash
apt install -y /path/to/airgap-bundle/host/nvidia-container-toolkit/*.deb
nvidia-container-cli --version
nvidia-ctk --version
```

## 4. Images et templates Proxmox

```bash
cp /path/to/airgap-bundle/host/ubuntu-26.04-standard_26.04-1_amd64.tar.zst \
   /var/lib/vz/template/cache/
cp /path/to/airgap-bundle/cloudimg/ubuntu-26.04-server-cloudimg-amd64.img \
   /var/lib/vz/template/iso/
```

Dans `iac/terraform.tfvars` (mode airgap) :

```hcl
cloud_image_preuploaded        = true
ubuntu_lxc_template_preuploaded = true
# Le snippet Cloud-Init ne fait que démarrer qemu-guest-agent : pas besoin d'apt.
enable_cloudinit_snippet       = true
```

Puis, depuis le poste de pilotage :

```bash
cd iac
tofu init
tofu apply
```

Cela crée le LXC (120 par défaut) et la VM front (112 par défaut). Le LXC
démarre sans les hooks GPU ; l'étape suivante les ajoute.

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
  ajoute les règles `lxc.cgroup2.devices.allow` correspondantes ;
- ajoute le hook `lxc.hook.pre-start` (chargement de `nvidia_uvm`), le hook
  `lxc.hook.mount` (`/usr/share/lxc/hooks/nvidia`), les variables
  `NVIDIA_VISIBLE_DEVICES=all` / `NVIDIA_DRIVER_CAPABILITIES=compute,utility` ;
- ajoute 16 GiB de `/dev/shm` ;
- monte le bundle en lecture seule sur `/airgap-bundle` (`mpN`) ;
- redémarre le LXC et vérifie `nvidia-smi` dedans.

Il ne touche **pas** à `/dev/dri` : CUDA n'en a pas besoin, et un LXC
non privilégié ne pourrait pas utiliser les nodes `0660 root:video` sans
mapper les GID. Le script n'ajoute que les majors NVIDIA.

Vérifications :

```bash
pct config 120 | grep -E 'features|lxc.cgroup2|lxc.hook|lxc.environment|mp[0-9]'
pct exec 120 -- nvidia-smi -L
ssh root@192.0.2.10 nvidia-smi -L
```

## 6. Docker + toolkit dans le LXC (Ansible)

Le rôle `lxc_docker` fait le reste :

```bash
cd ansible
cp inventory/inventory.yml.example inventory/inventory.yml
cp group_vars/all.yml.example group_vars/all.yml
# Renseigner : IPs, litellm_master_key, airgap_mode: true, llm_bundle_dir,
#              vllm_start: true (sur le host 48 Go)
$EDITOR group_vars/all.yml
ansible-playbook playbook.yml
```

Le rôle installe Docker et `nvidia-container-toolkit` depuis le repo local,
force `no-cgroups = true` (obligatoire en LXC non privilégié), configure le
runtime Docker `nvidia`, charge l'image CUDA de smoke test et exécute
`nvidia-smi` dans un conteneur.

Test manuel éventuel dans le LXC :

```bash
docker run --rm --gpus all nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi -L
```

## 7. Cible 48 Go : démarrer vLLM

Sur `pve-node1` (GPU 8 Go), `vllm_start: false` : seuls LiteLLM, Open WebUI et
Docling tournent. Sur le serveur cible (GPU 48 Go), passer à
`vllm_start: true` puis relancer :

```bash
ansible-playbook playbook.yml --limit inference_lxc
```

Le rôle `inference_stack` charge les images vLLM/LiteLLM du bundle et démarre
la stack. Le premier démarrage charge `unsloth/Qwen3.8-27B-NVFP4` + le drafter
DFlash2 ; suivre :

```bash
docker ps
docker logs -f vllm
curl -s http://127.0.0.1:8000/v1/models
```

Puis depuis le LAN :

```bash
curl -s -H "Authorization: Bearer $LITELLM_KEY" \
  http://192.0.2.10:4000/v1/models
```

Points de vigilance sur la 48 Go :

- `--gpu-memory-utilization 0.82` (chat) + `0.06` (embedding) ;
- `--kv-cache-dtype nvfp4`, `--attention-backend flash_attn`,
  `--speculative-config '{"method":"dflash",...,"num_speculative_tokens":7}'` ;
- `num_speculative_tokens = block_size - 1` du drafter (bloc 8 → 7) ;
- si le décode NVFP4/DFlash sm120 plante, passer `vllm_enforce_eager: true` ;
- si `--reasoning-parser qwen3` / `--tool-call-parser qwen3_coder` n'existent
  pas dans l'image vLLM, les vider dans `all.yml` ;
- ne jamais exposer vLLM (8000) sur le LAN : seul LiteLLM (4000) est publié.

## 8. Notes de sécurité

- LXC non privilégié, `nesting/keyctl/fuse/mknod` pour Docker, hook NVIDIA.
- Les devices NVIDIA sont en `0666` (défaut du driver) ; l'autorisation réelle
  est le cgroup `lxc.cgroup2.devices.allow` (majors 195/509).
- Pas de `/dev/dri` : inutile pour CUDA, et impossible à utiliser proprement
  dans un LXC non privilégié sans mapping des GID `video`/`render`.
- `nvidia-container-cli` tourne avec `--no-cgroups` : le cgroup est géré par le
  parent LXC, pas par le toolkit.
- LiteLLM porte la seule clé d'API LAN ; le master key est dans
  `group_vars/all.yml` (gitignoré) et dans `/srv/llm/litellm/litellm.env` (0600)
  sur le LXC.
