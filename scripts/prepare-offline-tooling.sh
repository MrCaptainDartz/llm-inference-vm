#!/usr/bin/env bash
# Prepare the control machine (online, once): tofu, ansible-core, providers, collections.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)

BIN_DIR="${HOME}/.local/bin"
COLLECTIONS_DIR="${HOME}/.ansible/collections"
MIRROR_DIR="${HOME}/.local/share/tofu-mirror"
TOFU_RC="${HOME}/.tofurc"
VENV_DIR="${HOME}/.local/share/airgap-tooling/venv"
OPENTOFU_VERSION="${OPENTOFU_VERSION:-}"
FORCE=false
PLATFORM=""

SKIP_LEAF_SECTIONS=(tofu ansible collections mirror tofu-rc)
declare -A SKIPPED=()

log()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

mark_skip() {
  case "$1" in
    tofu|ansible|collections|mirror|tofu-rc) SKIPPED["$1"]=true ;;
    *) die "unknown --skip value: $1 (valid: ${SKIP_LEAF_SECTIONS[*]})" ;;
  esac
}

is_skipped() { [[ -n "${SKIPPED[$1]:-}" ]]; }

# --skip takes a comma-separated list, e.g. --skip=collections,mirror
parse_skip_list() {
  local list="$1" item
  local -a items=()
  [[ -n "${list//[[:space:]]/}" ]] || die "--skip needs at least one section (valid: ${SKIP_LEAF_SECTIONS[*]})"
  IFS=',' read -ra items <<<"$list"
  for item in "${items[@]}"; do
    item="${item//[[:space:]]/}"
    [[ -n "$item" ]] || continue
    mark_skip "$item"
  done
}

run_section() {
  local section="$1" start=$SECONDS; shift
  if is_skipped "$section"; then
    info "skipped: ${section}"
    return 0
  fi
  "$@"
  info "done: ${section} ($((SECONDS - start))s)"
}

usage() {
  cat <<'EOF'
Usage: ./scripts/prepare-offline-tooling.sh [options]

Installs tofu + ansible-core and prefetches the OpenTofu providers and Ansible
collections, so the control machine works offline. Run it once, online.

Options:
  --bin-dir DIR        Where to install the binaries (default: ~/.local/bin)
  --collections DIR    Ansible collections path (default: ~/.ansible/collections)
  --mirror DIR         OpenTofu provider mirror (default: ~/.local/share/tofu-mirror)
  --tofu-rc FILE       OpenTofu CLI config using the mirror (default: ~/.tofurc)
  --platform OS_ARCH   Provider platform (default: detected, e.g. linux_amd64)
  --skip LIST          Comma-separated sections: tofu, ansible, collections,
                       mirror, tofu-rc
  --force              Reinstall or re-download even when already present
  -h, --help           Show this help

Sections:
  tofu         OpenTofu binary
  ansible      ansible-core (pipx, else a venv under ~/.local/share)
  collections  community.general from ansible/requirements.yml
  mirror       bpg/proxmox provider, pinned by iac/.terraform.lock.hcl
  tofu-rc      Write the filesystem_mirror block in the OpenTofu CLI config

Environment:
  OPENTOFU_VERSION   Pin the OpenTofu release (default: latest stable)

The data bundle (drivers, images, models, apt repo) is a separate script:
scripts/fetch-airgap-bundle.sh, meant for the USB key.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin-dir)
      [[ $# -ge 2 ]] || die "$1 needs a directory"
      BIN_DIR="$2"; shift 2 ;;
    --collections)
      [[ $# -ge 2 ]] || die "$1 needs a directory"
      COLLECTIONS_DIR="$2"; shift 2 ;;
    --mirror)
      [[ $# -ge 2 ]] || die "$1 needs a directory"
      MIRROR_DIR="$2"; shift 2 ;;
    --tofu-rc)
      [[ $# -ge 2 ]] || die "$1 needs a file"
      TOFU_RC="$2"; shift 2 ;;
    --platform)
      [[ $# -ge 2 ]] || die "$1 needs an OS_ARCH value"
      PLATFORM="$2"; shift 2 ;;
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

detect_platform() {
  local os arch
  case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=darwin ;;
    *) die "unsupported OS: $(uname -s) (pass --platform)" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    arm64|aarch64) arch=arm64 ;;
    *) die "unsupported architecture: $(uname -m) (pass --platform)" ;;
  esac
  printf '%s_%s\n' "$os" "$arch"
}

latest_tofu_tag() {
  curl -fsSL --max-time 30 https://api.github.com/repos/opentofu/opentofu/releases/latest \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1
}

install_tofu() {
  log "OpenTofu"
  if [[ -x "${BIN_DIR}/tofu" ]] && [[ "$FORCE" != "true" ]]; then
    info "already installed: ${BIN_DIR}/tofu"
    return 0
  fi
  if command -v tofu >/dev/null && [[ "$FORCE" != "true" ]]; then
    info "already installed: $(command -v tofu) ($(tofu version | head -1))"
    return 0
  fi
  local tag="$OPENTOFU_VERSION" version url tmp
  if [[ -z "$tag" ]]; then
    tag=$(latest_tofu_tag || true)
    [[ -n "$tag" ]] || die "cannot resolve the latest OpenTofu release (set OPENTOFU_VERSION)"
  fi
  tag="v${tag#v}"
  version="${tag#v}"
  url="https://github.com/opentofu/opentofu/releases/download/${tag}/tofu_${version}_${PLATFORM}.zip"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/tofu.XXXXXX")
  info "download: ${url}"
  curl -fL --progress-bar --retry 3 --retry-delay 5 -o "${tmp}/tofu.zip" "$url" \
    || die "cannot download ${url}"
  mkdir -p "$BIN_DIR"
  if command -v unzip >/dev/null; then
    mkdir -p "${tmp}/x" && unzip -oq "${tmp}/tofu.zip" -d "${tmp}/x"
  elif command -v python3 >/dev/null; then
    python3 -m zipfile -e "${tmp}/tofu.zip" "${tmp}/x"
  else
    die "need unzip or python3 to extract ${url}"
  fi
  install -m 0755 "${tmp}/x/tofu" "${BIN_DIR}/tofu"
  rm -rf "$tmp"
  info "installed: ${BIN_DIR}/tofu (${version})"
}

install_ansible() {
  log "ansible-core"
  if [[ -x "${BIN_DIR}/ansible-galaxy" && "$FORCE" != "true" ]]; then
    info "already installed: ${BIN_DIR}/ansible-galaxy"
    return 0
  fi
  if command -v ansible-galaxy >/dev/null && [[ "$FORCE" != "true" ]]; then
    info "already installed: $(command -v ansible-galaxy)"
    return 0
  fi
  if command -v pipx >/dev/null; then
    info "pipx install ansible-core (a few minutes)"
    if [[ "$FORCE" == "true" ]]; then
      pipx install --force ansible-core
    else
      pipx install ansible-core
    fi
  elif command -v python3 >/dev/null; then
    info "venv ${VENV_DIR} + pip install ansible-core (a few minutes)"
    python3 -m venv "$VENV_DIR" \
      || die "cannot create ${VENV_DIR} (install python3-venv or pipx)"
    "${VENV_DIR}/bin/pip" install --disable-pip-version-check --upgrade pip
    "${VENV_DIR}/bin/pip" install --disable-pip-version-check ansible-core \
      || die "cannot install ansible-core from PyPI"
    mkdir -p "$BIN_DIR"
    ln -sf "${VENV_DIR}/bin/ansible" "${VENV_DIR}/bin/ansible-playbook" \
      "${VENV_DIR}/bin/ansible-galaxy" "$BIN_DIR/"
    info "binaries: ${BIN_DIR}/ansible*"
  else
    die "pipx or python3 is required to install ansible-core"
  fi
}

galaxy_bin() {
  if [[ -x "${BIN_DIR}/ansible-galaxy" ]]; then
    printf '%s\n' "${BIN_DIR}/ansible-galaxy"
    return 0
  fi
  command -v ansible-galaxy
}

requirement_names() {
  sed -n "s/^[[:space:]]*-[[:space:]]*name:[[:space:]]*[\"']\{0,1\}\([A-Za-z0-9_.-]*\).*/\1/p" \
    "${REPO_DIR}/ansible/requirements.yml"
}

collections_installed() {
  local galaxy="$1" name
  local -a installed
  mapfile -t installed < <("$galaxy" collection list -p "$COLLECTIONS_DIR" 2>/dev/null | awk 'NR>2 {print $1}')
  while read -r name; do
    [[ -n "$name" ]] || continue
    [[ " ${installed[*]} " == *" $name "* ]] || return 1
  done < <(requirement_names)
}

install_collections() {
  log "Ansible collections"
  local galaxy
  galaxy=$(galaxy_bin) || die "ansible-galaxy not found (drop --skip=ansible)"
  if [[ "$FORCE" != "true" ]] && collections_installed "$galaxy"; then
    info "already installed in ${COLLECTIONS_DIR}"
    return 0
  fi
  local -a args=(collection install -r "${REPO_DIR}/ansible/requirements.yml" -p "$COLLECTIONS_DIR")
  if [[ "$FORCE" == "true" ]]; then args+=(--force-with-deps); fi
  "$galaxy" "${args[@]}"
  info "collections: ${COLLECTIONS_DIR}"
  if [[ "$COLLECTIONS_DIR" != "${HOME}/.ansible/collections" ]]; then
    info "hint: export ANSIBLE_COLLECTIONS_PATH=${COLLECTIONS_DIR}"
  fi
}

install_mirror() {
  log "OpenTofu provider mirror (${PLATFORM})"
  local tofu_bin
  tofu_bin=$(command -v tofu || true)
  [[ -n "$tofu_bin" ]] || tofu_bin="${BIN_DIR}/tofu"
  [[ -x "$tofu_bin" ]] || die "tofu not found (drop --skip=tofu)"
  if [[ "$FORCE" == "true" ]]; then rm -rf "$MIRROR_DIR"; fi
  if compgen -G "${MIRROR_DIR}/registry.opentofu.org/*/*/*_${PLATFORM}.zip" >/dev/null; then
    info "exists: ${MIRROR_DIR} (${PLATFORM})"
    return 0
  fi
  mkdir -p "$MIRROR_DIR"
  "$tofu_bin" -chdir="${REPO_DIR}/iac" providers mirror -platform="$PLATFORM" "$MIRROR_DIR"
  info "mirror: ${MIRROR_DIR}"
}

write_tofu_rc() {
  log "OpenTofu CLI config"
  local block
  block=$(cat <<EOF
# Added by scripts/prepare-offline-tooling.sh: offline provider mirror.
provider_installation {
  filesystem_mirror {
    path = "${MIRROR_DIR}"
  }
}
EOF
)
  mkdir -p "$(dirname "$TOFU_RC")"
  if [[ -f "$TOFU_RC" ]]; then
    if grep -qF "$MIRROR_DIR" "$TOFU_RC"; then
      info "already configured: ${TOFU_RC}"
      return 0
    fi
    if grep -q "provider_installation" "$TOFU_RC"; then
      printf '\n%s\n' "$block"
      die "${TOFU_RC} already has a provider_installation block; add the mirror manually"
    fi
    printf '\n%s\n' "$block" >>"$TOFU_RC"
  else
    printf '%s\n' "$block" >"$TOFU_RC"
  fi
  info "config: ${TOFU_RC}"
}

[[ -n "$PLATFORM" ]] || PLATFORM=$(detect_platform)
mkdir -p "$BIN_DIR"

info "about 150 MB to download; the first run can take a few minutes"

run_section tofu install_tofu
run_section ansible install_ansible
run_section collections install_collections
run_section mirror install_mirror
run_section tofu-rc write_tofu_rc

if [[ ":${PATH}:" != *":${BIN_DIR}:"* ]]; then
  info "warning: ${BIN_DIR} is not in PATH"
fi

log "Offline toolchain ready"
printf '    platform:    %s\n' "$PLATFORM"
if [[ -d "$MIRROR_DIR" ]]; then
  printf '    mirror:      %s (%s)\n' "$MIRROR_DIR" "$(du -sh "$MIRROR_DIR" | cut -f1)"
fi
printf '    collections: %s\n' "$COLLECTIONS_DIR"
cat <<'EOF'

Verify without network:
  cd iac && rm -rf .terraform && tofu init && tofu providers
EOF
