#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SUBMODULE_DIR="${REPO_ROOT}/core/Clash.Meta"
PATCH_FILE="${REPO_ROOT}/core/patches/mihomo-fixes.patch"

if [ ! -d "${SUBMODULE_DIR}" ]; then
  echo "Error: Submodule directory ${SUBMODULE_DIR} does not exist." >&2
  exit 1
fi

if [ ! -f "${PATCH_FILE}" ]; then
  echo "Error: Patch file ${PATCH_FILE} not found." >&2
  exit 1
fi

if git -C "${SUBMODULE_DIR}" apply --check "${PATCH_FILE}" 2>/dev/null; then
  echo "Applying Mihomo companion patch to ${SUBMODULE_DIR}..."
  git -C "${SUBMODULE_DIR}" apply "${PATCH_FILE}"
  echo "Successfully applied Mihomo companion patch."
elif git -C "${SUBMODULE_DIR}" apply --reverse --check "${PATCH_FILE}" 2>/dev/null; then
  echo "Mihomo companion patch is already applied in ${SUBMODULE_DIR}."
else
  echo "Error: Submodule has conflicts or cannot apply Mihomo companion patch cleanly." >&2
  git -C "${SUBMODULE_DIR}" apply --check "${PATCH_FILE}" || true
  exit 1
fi
