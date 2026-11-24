#!/usr/bin/env bash
# Build the offline bundle on an online Ubuntu 26.04 amd64 host.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
BUNDLE_DIR="${REPO_DIR}/airgap-bundle"

# vLLM tags carry a leading v (v0.34.0); accept "0.34.0" and "v0.34.0".
vllm_tag() {
  case "$1" in
    [0-9]*) printf 'v%s\n' "$1" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

VLLM_VERSION="${VLLM_VERSION:-0.34.0}"
VLLM_IMAGE="vllm/vllm-openai:$(vllm_tag "$VLLM_VERSION")"
LITELLM_IMAGE="${LITELLM_IMAGE:-ghcr.io/berriai/litellm:main-stable}"
OPEN_WEBUI_IMAGE="${OPEN_WEBUI_IMAGE:-ghcr.io/open-webui/open-webui:v0.13.4}"
DOCLING_IMAGE="${DOCLING_IMAGE:-quay.io/docling-project/docling-serve-cu130:v1.38.2}"
DOCLING_CPU_IMAGE="${DOCLING_CPU_IMAGE:-quay.io/docling-project/docling-serve:v1.38.2}"
PGVECTOR_IMAGE="${PGVECTOR_IMAGE:-pgvector/pgvector:pg17}"
TESSDATA_URL="${TESSDATA_URL:-https://github.com/tesseract-ocr/tessdata_fast/raw/main/fra.traineddata}"
CUDA_SMOKE_IMAGE="${CUDA_SMOKE_IMAGE:-nvidia/cuda:13.0.0-base-ubuntu24.04}"

TARGET_MODEL="${TARGET_MODEL:-unsloth/Qwen3.8-27B-NVFP4}"
TARGET_MODEL_DIR="qwen3.8-27b-nvfp4"
DRAFT_MODEL="${DRAFT_MODEL:-maurienne-ai/Qwen3.8-27B-DFlash2-NVFP4-RTNcal}"
DRAFT_MODEL_DIR="qwen3.8-27b-dflash2-draft"
EMBEDDING_MODEL="${EMBEDDING_MODEL:-Qwen/Qwen3-Embedding-0.6B}"
EMBEDDING_MODEL_DIR="qwen3-embedding-0.6b"

UBUNTU_RELEASE="${UBUNTU_RELEASE:-26.04}"
LXC_TEMPLATE_FILENAME="${LXC_TEMPLATE_FILENAME:-ubuntu-26.04-standard_26.04-1_amd64.tar.zst}"
LXC_TEMPLATE_URL="${LXC_TEMPLATE_URL:-http://download.proxmox.com/images/system/${LXC_TEMPLATE_FILENAME}}"

NVIDIA_TOOLKIT_REPO="${NVIDIA_TOOLKIT_REPO:-https://nvidia.github.io/libnvidia-container/stable/deb/amd64}"
NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION:-}"
HF_TOKEN="${HF_TOKEN:-}"
FORCE="${FORCE:-false}"

# Sections --skip can disable (manifest order), plus the `models` and `all` groups.
SKIP_LEAF_SECTIONS=(host images model draft embedding apt tessdata)
SKIP_SECTIONS=("${SKIP_LEAF_SECTIONS[@]}" models all)
declare -A SKIPPED=()

RUNTIME=""
SKOPEO=""

log()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

mark_skip() {
  local section
  case "$1" in
    host|images|apt|tessdata|model|draft|embedding) SKIPPED["$1"]=true ;;
    models) SKIPPED[model]=true; SKIPPED[draft]=true; SKIPPED[embedding]=true ;;
    all) for section in "${SKIP_LEAF_SECTIONS[@]}"; do SKIPPED["$section"]=true; done ;;
    *) die "unknown --skip value: $1 (valid: ${SKIP_SECTIONS[*]})" ;;
  esac
}

is_skipped() { [[ -n "${SKIPPED[$1]:-}" ]]; }

# --skip takes a comma-separated list, e.g. --skip=model,images
parse_skip_list() {
  local list="$1" item
  local -a items=()
  [[ -n "${list//[[:space:]]/}" ]] || die "--skip needs at least one section (valid: ${SKIP_SECTIONS[*]})"
  IFS=',' read -ra items <<<"$list"
  for item in "${items[@]}"; do
    item="${item//[[:space:]]/}"
    [[ -n "$item" ]] || continue
    mark_skip "$item"
  done
}

# Run a fetch step unless its section was excluded.
run_section() {
  local section="$1"; shift
  if is_skipped "$section"; then
    info "skipped: ${section}"
    return 0
  fi
  "$@"
}

skipped_sections() {
  local section
  for section in "${SKIP_LEAF_SECTIONS[@]}"; do
    if is_skipped "$section"; then printf '%s\n' "$section"; fi
  done
}

# A skipped model must still be in the bundle: roles mount it read-only and vLLM fails.
warn_empty_models() {
  local section dir
  for section in model draft embedding; do
    is_skipped "$section" || continue
    case "$section" in
      model) dir="$TARGET_MODEL_DIR" ;;
      draft) dir="$DRAFT_MODEL_DIR" ;;
      embedding) dir="$EMBEDDING_MODEL_DIR" ;;
    esac
    if ! compgen -G "${BUNDLE_DIR}/models/${dir}/*" >/dev/null; then
      info "warning: models/${dir}/ is empty (section skipped, copy it manually)"
    fi
  done
}

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/fetch-airgap-bundle.sh --output ./airgap-bundle [--skip=LIST]

Options:
  --output DIR          Bundle directory (default: <repo>/airgap-bundle)
  --vllm-version VER    vLLM version (default: 0.34.0, tag v0.34.0)
  --skip LIST           Comma-separated sections, e.g. --skip=model,images
  --force               Re-download files that already exist
  -h, --help            Show this help

Sections accepted by --skip:
  host        NVIDIA driver .run, container toolkit .deb, Ubuntu LXC template
  images      container image tarballs
  model       chat model (TARGET_MODEL)
  draft       DFlash2 draft model (DRAFT_MODEL)
  embedding   embedding model (EMBEDDING_MODEL)
  models      all three Hugging Face models
  apt         Ubuntu apt closure + Packages.gz
  tessdata    French Tesseract data
  all         every section (e.g. to rewrite manifest/SHA256SUMS only)

Skipping a section keeps existing files in the bundle and fetches the rest.

Environment:
  TARGET_MODEL/DRAFT_MODEL/EMBEDDING_MODEL  Hugging Face repos to bundle
  VLLM_VERSION           vLLM version, tag v<version> (default: 0.34.0)
  NVIDIA_DRIVER_VERSION  Pin the NVIDIA driver (empty = latest stable 595.x)
  HF_TOKEN               Hugging Face token for gated models
  VLLM_IMAGE/LITELLM_IMAGE/OPEN_WEBUI_IMAGE/DOCLING_IMAGE/DOCLING_CPU_IMAGE/PGVECTOR_IMAGE/CUDA_SMOKE_IMAGE/TESSDATA_URL

See docs/AIRGAP.md for the full workflow.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output|-o)
      [[ $# -ge 2 ]] || die "$1 needs a directory"
      BUNDLE_DIR="$2"; shift 2 ;;
    --vllm-version)
      [[ $# -ge 2 ]] || die "$1 needs a version"
      VLLM_VERSION="$2"; VLLM_IMAGE="vllm/vllm-openai:$(vllm_tag "$2")"; shift 2 ;;
    --skip)
      [[ $# -ge 2 ]] || die "$1 needs a section list (use --help)"
      parse_skip_list "$2"; shift 2 ;;
    --skip=*)
      parse_skip_list "${1#*=}"; shift ;;
    --force) FORCE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (use --help)" ;;
  esac
done

[[ ${EUID} -eq 0 ]] || die "run as root (or with sudo) on the online builder"

TARGET_MODEL_URL="https://huggingface.co/api/models/${TARGET_MODEL}"
DRAFT_MODEL_URL="https://huggingface.co/api/models/${DRAFT_MODEL}"
EMBEDDING_MODEL_URL="https://huggingface.co/api/models/${EMBEDDING_MODEL}"

install_tools() {
  local missing=()
  for cmd in curl jq python3 skopeo; do
    command -v "$cmd" >/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log "Installing missing tools: ${missing[*]}"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl jq python3 skopeo ca-certificates
  fi

  if command -v docker >/dev/null; then
    RUNTIME=docker; SKOPEO=skopeo
  elif command -v podman >/dev/null; then
    RUNTIME=podman; SKOPEO=skopeo
  else
    log "Installing podman (container runtime for apt/Docling baking)"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq podman
    RUNTIME=podman; SKOPEO=skopeo
  fi
  command -v "$SKOPEO" >/dev/null || die "skopeo not available"
}

# Download to <dest>.part then rename; HF_TOKEN goes through a temp 0600 curl config.
fetch_url() {
  local url="$1" dest="$2" part="${2}.part" auth_config=""
  local -a curl_args=()
  mkdir -p "$(dirname "$dest")"
  if [[ -s "$dest" && "$FORCE" != "true" ]]; then
    info "exists: ${dest#"$BUNDLE_DIR"/}"
    return 0
  fi
  if [[ "$FORCE" == "true" ]]; then
    rm -f "$dest" "$part"
  fi
  if [[ -n "$HF_TOKEN" && "$url" == *huggingface.co* ]]; then
    auth_config=$(mktemp "${TMPDIR:-/tmp}/hf-curl.XXXXXX")
    chmod 600 "$auth_config"
    printf 'header = "Authorization: Bearer %s"\n' "$HF_TOKEN" > "$auth_config"
    curl_args=(--config "$auth_config")
  fi
  info "download: ${url}"
  local rc=0
  curl -fL --retry 5 --retry-delay 5 --continue-at - \
    "${curl_args[@]}" -o "$part" "$url" || rc=$?
  [[ -n "$auth_config" ]] && rm -f "$auth_config"
  [[ $rc -eq 0 ]] || return $rc
  mv -f "$part" "$dest"
}

image_digest() {
  "$SKOPEO" inspect --format '{{.Digest}}' "docker://$1" 2>/dev/null || true
}

skopeo_image() {
  local image="$1" name="$2"
  local tar="${BUNDLE_DIR}/images/${name}.tar" part="${BUNDLE_DIR}/images/${name}.tar.part"
  if [[ -s "$tar" && "$FORCE" != "true" ]]; then
    info "image exists: images/${name}.tar"
    return 0
  fi
  if [[ "$FORCE" == "true" ]]; then rm -f "$tar" "$part"; fi
  log "Copying ${image} -> images/${name}.tar"
  if ! "$SKOPEO" copy --override-arch amd64 --override-os linux --retry-times 3 \
      "docker://${image}" "docker-archive:${part}:${image}"; then
    rm -f "$part"
    return 1
  fi
  mv -f "$part" "$tar"
}

fetch_nvidia_driver() {
  log "NVIDIA driver"
  local version="$NVIDIA_DRIVER_VERSION"
  if [[ -z "$version" ]]; then
    local latest
    # download.nvidia.com tracks the stable 595.x branch.
    latest=$(curl -fsSL --max-time 20 https://download.nvidia.com/XFree86/Linux-x86_64/latest.txt) \
      || die "cannot resolve the latest stable NVIDIA driver"
    version=$(awk '{print $1}' <<<"$latest" | tr -d '\r')
  fi
  [[ -n "$version" ]] || die "empty NVIDIA driver version"
  local url="https://download.nvidia.com/XFree86/Linux-x86_64/${version}/NVIDIA-Linux-x86_64-${version}.run"
  fetch_url "$url" "${BUNDLE_DIR}/host/NVIDIA-Linux-x86_64-${version}.run"
  chmod +x "${BUNDLE_DIR}/host/NVIDIA-Linux-x86_64-${version}.run"
  echo "$version" > "${BUNDLE_DIR}/host/NVIDIA_DRIVER_VERSION"
  info "NVIDIA driver: ${version}"
}

fetch_nvidia_toolkit() {
  log "NVIDIA container toolkit debs (latest versions)"
  local dir="${BUNDLE_DIR}/host/nvidia-container-toolkit"
  mkdir -p "$dir" "${BUNDLE_DIR}/repo/pool"
  local index="${dir}/Packages"
  curl -fsSL --max-time 30 "${NVIDIA_TOOLKIT_REPO}/Packages" -o "$index" \
    || die "cannot fetch the NVIDIA toolkit Packages index"
  local pkg ver filename
  while IFS=$'\t' read -r pkg ver filename; do
    [[ -n "$pkg" && -n "$filename" ]] || continue
    local base="${filename#./}"
    fetch_url "${NVIDIA_TOOLKIT_REPO}/${base}" "${dir}/${base}"
    cp -f "${dir}/${base}" "${BUNDLE_DIR}/repo/pool/${base}"
  done < <(python3 - "$index" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
want = {
    "libnvidia-container1",
    "libnvidia-container-tools",
    "nvidia-container-toolkit-base",
    "nvidia-container-toolkit",
}
def key(v):
    return [int(x) if x.isdigit() else x for x in re.split(r"[.\-~]", v)]
best = {}
for para in text.split("\n\n"):
    d = {}
    for line in para.splitlines():
        if ": " in line:
            k, v = line.split(": ", 1)
            d[k] = v
    p = d.get("Package")
    if p in want:
        v = d.get("Version", "")
        f = d.get("Filename", "")
        if p not in best or key(v) > key(best[p][0]):
            best[p] = (v, f)
for p in sorted(want):
    if p in best:
        print(f"{p}\t{best[p][0]}\t{best[p][1]}")
PY
  )
  local count
  count=$(find "$dir" -name '*.deb' | wc -l)
  [[ "$count" -ge 4 ]] || die "expected 4 NVIDIA toolkit debs, found ${count}"
  info "NVIDIA toolkit debs: ${count} files"
}

fetch_lxc_template() {
  log "Ubuntu LXC template"
  fetch_url "$LXC_TEMPLATE_URL" "${BUNDLE_DIR}/host/${LXC_TEMPLATE_FILENAME}"
}

fetch_host() {
  fetch_nvidia_driver
  fetch_nvidia_toolkit
  fetch_lxc_template
}

fetch_images() {
  log "Container images"
  mkdir -p "${BUNDLE_DIR}/images"
  skopeo_image "$VLLM_IMAGE" vllm
  skopeo_image "$LITELLM_IMAGE" litellm
  skopeo_image "$OPEN_WEBUI_IMAGE" open_webui
  skopeo_image "$DOCLING_IMAGE" docling
  skopeo_image "$DOCLING_CPU_IMAGE" docling-cpu
  skopeo_image "$PGVECTOR_IMAGE" pgvector
  skopeo_image "$CUDA_SMOKE_IMAGE" cuda-smoke
}

fetch_hf_model() {
  local repo="$1" dir="$2" api_url="$3"
  log "Hugging Face model: ${repo}"
  local api sha
  api=$(curl -fsSL --retry 3 --max-time 60 "$api_url") \
    || die "cannot fetch HF metadata for ${repo}"
  sha=$(jq -r '.sha // empty' <<<"$api")
  [[ -n "$sha" ]] || die "no sha in HF metadata for ${repo}"
  local file
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    fetch_url "https://huggingface.co/${repo}/resolve/${sha}/${file}" \
      "${BUNDLE_DIR}/models/${dir}/${file}"
  done < <(jq -r '.siblings[]?.rfilename // empty' <<<"$api")
  echo "$sha" > "${BUNDLE_DIR}/models/${dir}/.hf_revision"
}

fetch_models() {
  run_section model fetch_hf_model \
    "$TARGET_MODEL" "$TARGET_MODEL_DIR" "$TARGET_MODEL_URL"
  run_section draft fetch_hf_model \
    "$DRAFT_MODEL" "$DRAFT_MODEL_DIR" "$DRAFT_MODEL_URL"
  run_section embedding fetch_hf_model \
    "$EMBEDDING_MODEL" "$EMBEDDING_MODEL_DIR" "$EMBEDDING_MODEL_URL"
}

APT_PACKAGES=(
  openssh-server sudo python3 ca-certificates curl gnupg jq
  vim nano git htop rsync less unzip zstd acl
  iproute2 net-tools pciutils lsof tmux tree procps
  docker.io docker-compose-v2 fail2ban
)

build_apt_repo() {
  log "Ubuntu ${UBUNTU_RELEASE} apt closure"
  mkdir -p "${BUNDLE_DIR}/repo/pool"
  if [[ "$FORCE" == "true" ]]; then
    rm -rf "${BUNDLE_DIR}/repo/pool"/*
  fi

  log "Downloading guest packages in an ubuntu:${UBUNTU_RELEASE} container"
  "$RUNTIME" run --rm \
    -v "${BUNDLE_DIR}/repo:/repo" \
    -e DEBIAN_FRONTEND=noninteractive \
    "ubuntu:${UBUNTU_RELEASE}" \
    bash -lc '
      set -e
      apt-get update -qq
      apt-get install -y -qq --download-only --no-install-recommends '"${APT_PACKAGES[*]}"'
      cp -f /var/cache/apt/archives/*.deb /repo/pool/ 2>/dev/null || true
      apt-get install -y -qq dpkg-dev >/dev/null
      cd /repo
      dpkg-scanpackages pool /dev/null | gzip -9 > Packages.gz
      echo "Packages: $(zcat Packages.gz | grep -c "^Package:")"
    '

  local nvdir="${BUNDLE_DIR}/host/nvidia-container-toolkit"
  if compgen -G "${nvdir}/*.deb" >/dev/null; then
    cp -f "${nvdir}"/*.deb "${BUNDLE_DIR}/repo/pool/"
    "$RUNTIME" run --rm -v "${BUNDLE_DIR}/repo:/repo" "ubuntu:${UBUNTU_RELEASE}" \
      bash -lc 'set -e; apt-get update -qq; apt-get install -y -qq dpkg-dev >/dev/null; cd /repo; dpkg-scanpackages pool /dev/null | gzip -9 > Packages.gz' \
      >/dev/null
  fi
  info "apt repo: ${BUNDLE_DIR}/repo/Packages.gz"
}

fetch_tessdata() {
  log "French Tesseract data"
  mkdir -p "${BUNDLE_DIR}/tessdata"
  fetch_url "$TESSDATA_URL" "${BUNDLE_DIR}/tessdata/fra.traineddata"
  cp -f "${BUNDLE_DIR}/tessdata/fra.traineddata" "${BUNDLE_DIR}/tessdata/fr.traineddata"
  info "Tesseract: fra.traineddata + fr.traineddata"
}

write_manifest() {
  log "Writing manifest"
  local nvidia_driver=""
  [[ -f "${BUNDLE_DIR}/host/NVIDIA_DRIVER_VERSION" ]] && \
    nvidia_driver=$(cat "${BUNDLE_DIR}/host/NVIDIA_DRIVER_VERSION")

  local target_revision="" draft_revision="" embedding_revision=""
  [[ -f "${BUNDLE_DIR}/models/${TARGET_MODEL_DIR}/.hf_revision" ]] && \
    target_revision=$(cat "${BUNDLE_DIR}/models/${TARGET_MODEL_DIR}/.hf_revision")
  [[ -f "${BUNDLE_DIR}/models/${DRAFT_MODEL_DIR}/.hf_revision" ]] && \
    draft_revision=$(cat "${BUNDLE_DIR}/models/${DRAFT_MODEL_DIR}/.hf_revision")
  [[ -f "${BUNDLE_DIR}/models/${EMBEDDING_MODEL_DIR}/.hf_revision" ]] && \
    embedding_revision=$(cat "${BUNDLE_DIR}/models/${EMBEDDING_MODEL_DIR}/.hf_revision")

  local vllm_digest litellm_digest webui_digest docling_digest docling_cpu_digest pgvector_digest cuda_digest  vllm_digest=$(image_digest "$VLLM_IMAGE")
  litellm_digest=$(image_digest "$LITELLM_IMAGE")
  webui_digest=$(image_digest "$OPEN_WEBUI_IMAGE")
  docling_digest=$(image_digest "$DOCLING_IMAGE")
  docling_cpu_digest=$(image_digest "$DOCLING_CPU_IMAGE")
  pgvector_digest=$(image_digest "$PGVECTOR_IMAGE")
  cuda_digest=$(image_digest "$CUDA_SMOKE_IMAGE")

  if ! is_skipped images; then
    [[ -n "$vllm_digest" ]] || die "cannot resolve the vLLM image digest"
    [[ -n "$litellm_digest" ]] || die "cannot resolve the LiteLLM image digest"
    [[ -n "$webui_digest" ]] || die "cannot resolve the Open WebUI image digest"
    [[ -n "$docling_digest" ]] || die "cannot resolve the Docling CUDA image digest"
    [[ -n "$docling_cpu_digest" ]] || die "cannot resolve the Docling CPU image digest"
    [[ -n "$pgvector_digest" ]] || die "cannot resolve the pgvector image digest"
    [[ -n "$cuda_digest" ]] || die "cannot resolve the CUDA smoke image digest"
  fi

  jq -n \
    --arg generated "$(date -Is)" \
    --argjson skipped "$(skipped_sections | jq -R . | jq -s .)" \
    --arg vllm_image "$VLLM_IMAGE" \
    --arg vllm_digest "$vllm_digest" \
    --arg litellm_image "$LITELLM_IMAGE" \
    --arg litellm_digest "$litellm_digest" \
    --arg webui_image "$OPEN_WEBUI_IMAGE" \
    --arg webui_digest "$webui_digest" \
    --arg docling_image "$DOCLING_IMAGE" \
    --arg docling_digest "$docling_digest" \
    --arg docling_cpu_image "$DOCLING_CPU_IMAGE" \
    --arg docling_cpu_digest "$docling_cpu_digest" \
    --arg pgvector_image "$PGVECTOR_IMAGE" \
    --arg pgvector_digest "$pgvector_digest" \
    --arg cuda_image "$CUDA_SMOKE_IMAGE" \
    --arg cuda_digest "$cuda_digest" \
    --arg nvidia_driver "$nvidia_driver" \
    --arg nvidia_toolkit_repo "$NVIDIA_TOOLKIT_REPO" \
    --arg lxc_template "$LXC_TEMPLATE_FILENAME" \
    --arg tessdata_url "$TESSDATA_URL" \
    --arg target_model "$TARGET_MODEL" \
    --arg target_dir "$TARGET_MODEL_DIR" \
    --arg target_revision "$target_revision" \
    --arg draft_model "$DRAFT_MODEL" \
    --arg draft_dir "$DRAFT_MODEL_DIR" \
    --arg draft_revision "$draft_revision" \
    --arg embedding_model "$EMBEDDING_MODEL" \
    --arg embedding_dir "$EMBEDDING_MODEL_DIR" \
    --arg embedding_revision "$embedding_revision" \
    --arg ubuntu_release "$UBUNTU_RELEASE" \
    '{
      generated_at: $generated,
      skipped: $skipped,
      images: {
        vllm: {reference: $vllm_image, digest: $vllm_digest},
        litellm: {reference: $litellm_image, digest: $litellm_digest},
        open_webui: {reference: $webui_image, digest: $webui_digest},
        docling: {reference: $docling_image, digest: $docling_digest},
        docling_cpu: {reference: $docling_cpu_image, digest: $docling_cpu_digest},
        pgvector: {reference: $pgvector_image, digest: $pgvector_digest},
        cuda_smoke: {reference: $cuda_image, digest: $cuda_digest}
      },
      host: {
        nvidia_driver: $nvidia_driver,
        nvidia_toolkit_repo: $nvidia_toolkit_repo,
        lxc_template: $lxc_template,
        tessdata_url: $tessdata_url
      },
      models: {
        target: {repo: $target_model, dir: $target_dir, revision: $target_revision},
        draft: {repo: $draft_model, dir: $draft_dir, revision: $draft_revision},
        embedding: {repo: $embedding_model, dir: $embedding_dir, revision: $embedding_revision}
      },
      ubuntu_release: $ubuntu_release
    }' > "${BUNDLE_DIR}/manifest.json"
  info "manifest: ${BUNDLE_DIR}/manifest.json"
}

# SHA256SUMS detects transfer corruption; it is not a signature.
write_checksums() {
  log "Writing SHA256SUMS"
  (
    cd "$BUNDLE_DIR"
    find . -type f ! -name 'SHA256SUMS' ! -name 'SHA256SUMS.tmp' ! -name '*.part' -print0 \
      | sort -z | xargs -0 sha256sum > SHA256SUMS.tmp
    mv -f SHA256SUMS.tmp SHA256SUMS
  )
  info "checksums: ${BUNDLE_DIR}/SHA256SUMS"
}

install_tools
mkdir -p "${BUNDLE_DIR}"/{host,images,models,repo/pool,tessdata}

run_section host fetch_host
run_section images fetch_images
fetch_models
run_section apt build_apt_repo
run_section tessdata fetch_tessdata
write_manifest
write_checksums

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  log "Partial bundle: skipped $(skipped_sections | paste -sd, -)"
  info "Files already present for skipped sections were kept as-is."
  warn_empty_models
fi

log "Bundle ready: ${BUNDLE_DIR}"
du -sh "${BUNDLE_DIR}"/* 2>/dev/null || true
cat <<'EOF'

Next:
  1. Transfer the bundle to the Proxmox host (LXC hook + airgap mount) and to
     the front VM at /airgap-bundle.
  2. Follow docs/HOST-INSTALL.md for the Proxmox host driver/toolkit/LXC.
  3. Set airgap_mode: true and llm_bundle_dir: /airgap-bundle in all.yml.
  4. Run ansible-playbook playbook.yml.
EOF
