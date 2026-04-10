#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="${ZMK_WORKSPACE_DIR:-$ROOT_DIR/tools/zmk-workspace}"
PYTHON_VENV_DIR="${ZMK_PYTHON_VENV_DIR:-$ROOT_DIR/tools/python-venv}"
CONFIG_DIR="$ROOT_DIR/config"
MODULE_DIR="$ROOT_DIR"
BUILD_DIR="$ROOT_DIR/build"
ZMK_REVISION="${ZMK_REVISION:-main}"
ZMK_MANIFEST_FILE="${ZMK_MANIFEST_FILE:-app/west.yml}"
ZMK_APP_DIR="${ZMK_APP_DIR:-}"
SHIELD="${ZMK_SHIELD:-nice_view}"

TARGET="all"
PRISTINE=0
UPDATE=0
WEST_BIN=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [all|left|right] [--pristine] [--update]

Builds Eyelash Sofle firmware locally using a private ZMK workspace.

Options:
  all         Build both halves (default)
  left        Build only the left half
  right       Build only the right half
  --pristine  Run a pristine build
  --update    Run 'west update' before building
  -h, --help  Show this help

Environment:
  ZMK_WORKSPACE_DIR  Override the local workspace path
  ZMK_PYTHON_VENV_DIR Override the local Python virtualenv path
  ZMK_REVISION       Override the ZMK revision used for bootstrap
  ZMK_MANIFEST_FILE  Override the west manifest path inside the ZMK repo
  ZMK_APP_DIR        Override the ZMK app path inside the workspace
  ZMK_SHIELD         Override the shield (default: nice_view)
EOF
}

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
}

ensure_west() {
  if command -v west >/dev/null 2>&1; then
    WEST_BIN="$(command -v west)"
    return
  fi

  require_command python3

  if [ ! -x "$PYTHON_VENV_DIR/bin/west" ]; then
    mkdir -p "$(dirname "$PYTHON_VENV_DIR")"
    python3 -m venv "$PYTHON_VENV_DIR"
    "$PYTHON_VENV_DIR/bin/python" -m pip install --upgrade pip west
  fi

  WEST_BIN="$PYTHON_VENV_DIR/bin/west"
}

ensure_zephyr_python_requirements() {
  local requirements_file="$WORKSPACE_DIR/zephyr/scripts/requirements-base.txt"

  if [ ! -f "$requirements_file" ]; then
    return
  fi

  if "$PYTHON_VENV_DIR/bin/python" -c "import patoolib, requests, semver, tqdm, yaml" >/dev/null 2>&1; then
    return
  fi

  "$PYTHON_VENV_DIR/bin/python" -m pip install -r "$requirements_file"
}

current_zmk_ref() {
  local zmk_repo="$WORKSPACE_DIR/zmk.git"

  if [ ! -d "$zmk_repo/.git" ]; then
    return
  fi

  git -C "$zmk_repo" symbolic-ref --quiet --short HEAD 2>/dev/null ||
    git -C "$zmk_repo" describe --tags --exact-match 2>/dev/null ||
    git -C "$zmk_repo" rev-parse --short HEAD
}

workspace_zmk_revision() {
  local revision_file="$WORKSPACE_DIR/.zmk-revision"

  if [ -f "$revision_file" ]; then
    cat "$revision_file"
    return
  fi

  current_zmk_ref
}

sync_zmk_repo() {
  local zmk_repo="$WORKSPACE_DIR/zmk.git"
  local current_ref=""

  if [ ! -d "$zmk_repo/.git" ]; then
    return
  fi

  current_ref="$(workspace_zmk_revision)"

  if [ "$UPDATE" -ne 1 ] && [ "$current_ref" = "$ZMK_REVISION" ]; then
    return
  fi

  git -C "$zmk_repo" fetch --tags origin "$ZMK_REVISION"

  if git -C "$zmk_repo" rev-parse -q --verify "refs/remotes/origin/$ZMK_REVISION" >/dev/null; then
    git -C "$zmk_repo" checkout --detach "refs/remotes/origin/$ZMK_REVISION"
    printf '%s\n' "$ZMK_REVISION" > "$WORKSPACE_DIR/.zmk-revision"
    return
  fi

  git -C "$zmk_repo" checkout --detach FETCH_HEAD
  printf '%s\n' "$ZMK_REVISION" > "$WORKSPACE_DIR/.zmk-revision"
}

resolve_app_dir() {
  local west_config="$WORKSPACE_DIR/.west/config"
  local manifest_path=""
  local manifest_file=""

  if [ -n "$ZMK_APP_DIR" ]; then
    if [ ! -d "$WORKSPACE_DIR/$ZMK_APP_DIR" ]; then
      echo "Configured ZMK_APP_DIR does not exist: $WORKSPACE_DIR/$ZMK_APP_DIR" >&2
      exit 1
    fi
    return
  fi

  if [ -f "$west_config" ]; then
    manifest_path="$(sed -n 's/^path = //p' "$west_config" | head -n 1)"
    manifest_file="$(sed -n 's/^file = //p' "$west_config" | head -n 1)"

    if [ -n "$manifest_path" ] && [ -n "$manifest_file" ]; then
      ZMK_APP_DIR="$manifest_path/$(dirname "$manifest_file")"
      if [ -d "$WORKSPACE_DIR/$ZMK_APP_DIR" ]; then
        return
      fi
    fi
  fi

  if [ -d "$WORKSPACE_DIR/app" ]; then
    ZMK_APP_DIR="app"
    return
  fi

  if [ -d "$WORKSPACE_DIR/zmk/app" ]; then
    ZMK_APP_DIR="zmk/app"
    return
  fi

  if [ -d "$WORKSPACE_DIR/zmk.git/app" ]; then
    ZMK_APP_DIR="zmk.git/app"
    return
  fi

  echo "Could not find ZMK app directory in $WORKSPACE_DIR" >&2
  echo "Checked west manifest metadata and common locations such as app/, zmk/app/, and zmk.git/app/" >&2
  exit 1
}

bootstrap_workspace() {
  local current_ref=""
  local refresh_workspace=0

  if [ ! -d "$WORKSPACE_DIR/.west" ]; then
    mkdir -p "$(dirname "$WORKSPACE_DIR")"
    "$WEST_BIN" init \
      -m https://github.com/zmkfirmware/zmk.git \
      --mr "$ZMK_REVISION" \
      --mf "$ZMK_MANIFEST_FILE" \
      "$WORKSPACE_DIR"
    (
      cd "$WORKSPACE_DIR"
      "$WEST_BIN" update
      "$WEST_BIN" zephyr-export
    )
    printf '%s\n' "$ZMK_REVISION" > "$WORKSPACE_DIR/.zmk-revision"
    return
  fi

  current_ref="$(workspace_zmk_revision)"
  if [ "$UPDATE" -eq 1 ] || [ "$current_ref" != "$ZMK_REVISION" ]; then
    refresh_workspace=1
  fi

  if [ "$refresh_workspace" -eq 1 ]; then
    sync_zmk_repo
    (
      cd "$WORKSPACE_DIR"
      "$WEST_BIN" update
      "$WEST_BIN" zephyr-export
    )
  fi
}

build_target() {
  local side="$1"
  local board="eyelash_sofle_${side}/nrf52840/zmk"
  local build_path="$BUILD_DIR/$side"
  local pristine_args=()

  mkdir -p "$BUILD_DIR"

  if [ "$PRISTINE" -eq 1 ]; then
    pristine_args+=(--pristine)
  fi

  (
    cd "$WORKSPACE_DIR"
    "$WEST_BIN" build \
      -s "$ZMK_APP_DIR" \
      -d "$build_path" \
      -b "$board" \
      "${pristine_args[@]}" \
      -- \
      -DZMK_CONFIG="$CONFIG_DIR" \
      -DZMK_EXTRA_MODULES="$MODULE_DIR" \
      -DSHIELD="$SHIELD"
  )

  echo "Built $side firmware at: $build_path/zephyr/zmk.uf2"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    all|left|right)
      TARGET="$1"
      ;;
    --pristine)
      PRISTINE=1
      ;;
    --update)
      UPDATE=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

ensure_west

bootstrap_workspace
ensure_zephyr_python_requirements
resolve_app_dir

case "$TARGET" in
  all)
    build_target left
    build_target right
    ;;
  left|right)
    build_target "$TARGET"
    ;;
esac
