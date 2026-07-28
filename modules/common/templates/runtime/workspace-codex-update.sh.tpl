#!/usr/bin/env bash
set -euo pipefail

# This root-owned program has fixed initialize/normalize modes. The root mode does only
# identity validation and immediately drops privileges.  Every mutation below
# /home/<workspace-user> therefore runs as that user; a pre-existing user
# symlink can never turn this bootstrap into a root filesystem write.
mode="$${1:---initialize}"
configured_user="${workspace_username}"
seed_pinned=false

usage() {
  echo "usage: agent-stack-workspace-codex-update (--initialize|--normalize) [workspace-user]" >&2
}

valid_user() {
  printf '%s' "$1" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$'
}

user_home() {
  getent passwd "$1" | cut -d: -f6
}

case "$mode" in
  --initialize|--normalize)
    if [ "$#" -gt 2 ]; then
      usage
      exit 64
    fi
    if [ "$(id -u)" -ne 0 ]; then
      echo "agent-stack workspace Codex initialization must run as root" >&2
      exit 77
    fi
    workspace_user="$${2:-$${WORKSPACE_USERNAME:-$configured_user}}"
    if ! valid_user "$workspace_user" || [ "$workspace_user" != "$configured_user" ]; then
      echo "invalid workspace user" >&2
      exit 64
    fi
    home_dir="$(user_home "$workspace_user")"
    if [ -z "$home_dir" ] || [ ! -d "$home_dir" ]; then
      echo "workspace user home is unavailable" >&2
      exit 1
    fi
    if [ "$mode" = --initialize ]; then
      inner_mode=--initialize-user
    else
      inner_mode=--normalize-user
    fi
    exec runuser -u "$workspace_user" -- \
      env -i \
        HOME="$home_dir" \
        USER="$workspace_user" \
        LOGNAME="$workspace_user" \
        PATH="/usr/local/bin:/usr/bin:/bin" \
        "$0" "$inner_mode" "$workspace_user"
    ;;
  --initialize-user)
    if [ "$#" -ne 2 ]; then
      usage
      exit 64
    fi
    workspace_user="$2"
    if [ "$(id -u)" -eq 0 ] || ! valid_user "$workspace_user" || [ "$workspace_user" != "$configured_user" ] || [ "$(id -un)" != "$workspace_user" ]; then
      echo "agent-stack workspace Codex user initialization has an invalid identity" >&2
      exit 77
    fi
    seed_pinned=true
    ;;
  --normalize-user)
    if [ "$#" -ne 2 ]; then
      usage
      exit 64
    fi
    workspace_user="$2"
    if [ "$(id -u)" -eq 0 ] || ! valid_user "$workspace_user" || [ "$workspace_user" != "$configured_user" ] || [ "$(id -un)" != "$workspace_user" ]; then
      echo "agent-stack workspace Codex user normalization has an invalid identity" >&2
      exit 77
    fi
    ;;
  *)
    usage
    exit 64
    ;;
esac

home_dir="$(user_home "$workspace_user")"
if [ -z "$home_dir" ] || [ "$HOME" != "$home_dir" ] || [ ! -d "$home_dir" ]; then
  echo "workspace user home is unavailable" >&2
  exit 1
fi

codex_home="$home_dir/.codex"
standalone_dir="$codex_home/packages/standalone"
current_link="$standalone_dir/current"
local_bin="$home_dir/.local/bin"
local_codex="$local_bin/codex"
pinned_current=/opt/codex/packages/standalone/current

log() {
  printf '[workspace-codex-init] %s\n' "$*" >&2
}

backup_path() {
  local path="$1"
  printf '%s.agent-stack-backup.%s' "$path" "$(date -u +%Y%m%dT%H%M%SZ)"
}

is_within() {
  local candidate="$1"
  local parent="$2"
  case "$candidate" in
    "$parent"/*) return 0 ;;
    *) return 1 ;;
  esac
}

release_codex_relative_path() {
  local target="$1"
  local candidate resolved

  # `codex app-server daemon` resolves current/codex directly.  Modern
  # packages provide it as a shim to bin/codex, so prefer that stable daemon
  # path and use bin/codex only long enough to add a missing shim.
  for candidate in "$target/codex" "$target/bin/codex"; do
    resolved="$(readlink -f "$candidate" 2>/dev/null || true)"
    if is_within "$resolved" "$target" && [ -f "$resolved" ] && [ -x "$resolved" ]; then
      if [ "$candidate" = "$target/codex" ]; then
        printf '%s\n' codex
      else
        printf '%s\n' bin/codex
      fi
      return 0
    fi
  done
  return 1
}

normalize_daemon_launcher() {
  local target="$1"
  local direct="$target/codex"
  local resolved

  if [ -e "$direct" ] || [ -L "$direct" ]; then
    resolved="$(readlink -f "$direct" 2>/dev/null || true)"
    is_within "$resolved" "$target" && [ -f "$resolved" ] && [ -x "$resolved" ]
    return
  fi
  [ "$(release_codex_relative_path "$target" 2>/dev/null || true)" = "bin/codex" ] || return 1
  ln -s bin/codex "$direct"
  resolved="$(readlink -f "$direct" 2>/dev/null || true)"
  is_within "$resolved" "$target" && [ -f "$resolved" ] && [ -x "$resolved" ]
}

current_target() {
  local target
  [ -L "$current_link" ] || return 1
  target="$(readlink -f "$current_link" 2>/dev/null || true)"
  [ -n "$target" ] && is_within "$target" "$standalone_dir" || return 1
  [ -d "$target" ] || return 1
  release_codex_relative_path "$target" >/dev/null || return 1
  printf '%s\n' "$target"
}

release_version() {
  local target="$1"
  local relative binary

  relative="$(release_codex_relative_path "$target")" || return 1
  binary="$target/$relative"
  "$binary" --version 2>/dev/null | sed -nE 's/.*([0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.]+)?).*/\1/p' | head -n 1
}

is_stable_version() {
  printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
}

pinned_fallback_version() {
  local pinned_target version

  pinned_target="$(readlink -f "$pinned_current" 2>/dev/null || true)"
  if [ -z "$pinned_target" ] || ! is_within "$pinned_target" /opt/codex/packages/standalone || ! release_codex_relative_path "$pinned_target" >/dev/null; then
    return 1
  fi
  version="$(release_version "$pinned_target" 2>/dev/null || true)"
  is_stable_version "$version" || return 1
  printf '%s\n' "$version"
}

version_is_older() {
  local left="$1"
  local right="$2"
  local left_major left_minor left_patch right_major right_minor right_patch

  is_stable_version "$left" && is_stable_version "$right" || return 1
  IFS=. read -r left_major left_minor left_patch <<<"$left"
  IFS=. read -r right_major right_minor right_patch <<<"$right"

  if (( 10#$left_major != 10#$right_major )); then
    (( 10#$left_major < 10#$right_major ))
    return
  fi
  if (( 10#$left_minor != 10#$right_minor )); then
    (( 10#$left_minor < 10#$right_minor ))
    return
  fi
  (( 10#$left_patch < 10#$right_patch ))
}

install_current_link() {
  local target="$1"
  local temporary="$current_link.agent-stack-new.$$"

  rm -f "$temporary"
  ln -s "$target" "$temporary"
  mv -Tf "$temporary" "$current_link"
}

bootstrap_pinned_user_release() {
  local pinned_target version release target backup

  pinned_target="$(readlink -f "$pinned_current" 2>/dev/null || true)"
  if [ -z "$pinned_target" ] || ! is_within "$pinned_target" /opt/codex/packages/standalone || ! release_codex_relative_path "$pinned_target" >/dev/null; then
    log "the pinned image Codex fallback is incomplete"
    return 1
  fi
  version="$(release_version "$pinned_target")"
  if ! is_stable_version "$version"; then
    log "the pinned image Codex fallback is not a stable release"
    return 1
  fi
  release="agent-stack-pinned-$version"
  target="$standalone_dir/releases/$release"

  mkdir -p "$standalone_dir/releases"
  chmod 0700 "$codex_home" "$standalone_dir" "$standalone_dir/releases"
  if ! release_codex_relative_path "$target" >/dev/null; then
    rm -rf "$target"
    mkdir -p "$target"
    cp -R "$pinned_target/." "$target/"
  fi
  if ! normalize_daemon_launcher "$target"; then
    log "the pinned image Codex fallback is missing its daemon launcher"
    return 1
  fi

  if [ -e "$current_link" ] || [ -L "$current_link" ]; then
    backup="$(backup_path "$current_link")"
    mv "$current_link" "$backup"
    log "backed up an invalid or non-stable user Codex current target"
  fi
  install_current_link "$target"
}

is_image_fallback_launcher() {
  local literal="$1"
  local resolved

  # `/usr/local/bin/codex` is owned by the immutable image. Accept only its
  # exact conventional link and prove it resolves into the image standalone
  # package; any other external launcher remains fail-closed.
  [ "$literal" = /usr/local/bin/codex ] || return 1
  resolved="$(readlink -f "$literal" 2>/dev/null || true)"
  is_within "$resolved" /opt/codex/packages/standalone && [ -f "$resolved" ] && [ -x "$resolved" ]
}

ensure_user_launcher() {
  local target relative expected resolved literal backup

  target="$(current_target)" || {
    log "user-scoped Codex current target is invalid"
    return 1
  }
  normalize_daemon_launcher "$target" || return 1
  relative="$(release_codex_relative_path "$target")" || return 1
  [ "$relative" = codex ] || return 1
  expected="$current_link/codex"
  mkdir -p "$local_bin"
  chmod 0755 "$local_bin"

  if [ -e "$local_codex" ] || [ -L "$local_codex" ]; then
    if [ ! -L "$local_codex" ]; then
      log "an unmanaged workspace Codex executable would be overwritten; refusing"
      return 1
    fi
    literal="$(readlink "$local_codex" 2>/dev/null || true)"
    if [ "$literal" = "$expected" ]; then
      return 0
    fi
    if is_image_fallback_launcher "$literal"; then
      backup="$(backup_path "$local_codex")"
      mv "$local_codex" "$backup"
      log "backed up the image fallback workspace Codex launcher"
    else
      resolved="$(readlink -f "$local_codex" 2>/dev/null || true)"
      case "$resolved" in
        "$standalone_dir"/*/bin/codex|"$standalone_dir"/*/codex)
          backup="$(backup_path "$local_codex")"
          mv "$local_codex" "$backup"
          log "backed up a prior managed workspace Codex launcher"
          ;;
        *)
          log "an unmanaged workspace Codex launcher would be overwritten; refusing"
          return 1
          ;;
      esac
    fi
  fi

  ln -s "$expected" "$local_codex"
}

verify_effective_command() {
  local target expected effective resolved
  target="$(current_target)" || return 1
  normalize_daemon_launcher "$target" || return 1
  expected="$(readlink -f "$current_link/codex" 2>/dev/null || true)"
  [ -n "$expected" ] || return 1

  effective="$(env PATH="$local_bin:/usr/local/bin:/usr/bin:/bin" /bin/bash -c 'command -v codex' 2>/dev/null || true)"
  resolved="$(readlink -f "$effective" 2>/dev/null || true)"
  if [ "$effective" != "$local_codex" ] || [ "$resolved" != "$expected" ]; then
    log "workspace Codex command does not resolve to the canonical user target"
    return 1
  fi
  env HOME="$home_dir" CODEX_HOME="$codex_home" PATH="$local_bin:/usr/local/bin:/usr/bin:/bin" "$local_codex" --version >/dev/null
}

umask 077
mkdir -p "$codex_home"
chmod 0700 "$codex_home"
current="$(current_target 2>/dev/null || true)"
current_version=""
if [ -n "$current" ] && normalize_daemon_launcher "$current"; then
  current_version="$(release_version "$current" 2>/dev/null || true)"
else
  current=""
fi
if [ "$seed_pinned" = true ]; then
  pinned_version="$(pinned_fallback_version 2>/dev/null || true)"
  if [ -z "$current" ] || ! is_stable_version "$current_version" || \
     { [ -n "$pinned_version" ] && version_is_older "$current_version" "$pinned_version"; }; then
    # Do not downgrade a valid user-installed release, but seed a stale user
    # target from the reproducible image fallback so a deployment never moves
    # an existing workspace back to an older CLI. Daily normalization never
    # changes current; it must not surprise a live app-server between updates.
    bootstrap_pinned_user_release
  fi
fi
ensure_user_launcher
verify_effective_command
log "workspace Codex uses the canonical user-scoped installation"
