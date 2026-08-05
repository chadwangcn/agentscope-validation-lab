#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/.." && pwd)"
lock_file="${project_root}/dependencies/agentscope.lock.env"
overlay_manifest="${project_root}/dependencies/agentscope-overlay-files.txt"

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 OUTPUT_DIRECTORY" >&2
  exit 64
fi

output_dir="$1"
if [ -e "${output_dir}" ]; then
  echo "Refusing existing output path: ${output_dir}" >&2
  exit 1
fi

# shellcheck disable=SC1090
. "${lock_file}"

test "${AGENTSCOPE_SOURCE_REPOSITORY}" = "https://github.com/agentscope-ai/agentscope.git"
printf '%s' "${AGENTSCOPE_SOURCE_COMMIT}" | grep -Eq '^[0-9a-f]{40}$'
printf '%s' "${AGENTSCOPE_PACKAGE_VERSION}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'

mkdir -p "${output_dir}"
git init -q "${output_dir}"
git -C "${output_dir}" remote add origin "${AGENTSCOPE_SOURCE_REPOSITORY}"
git -C "${output_dir}" fetch --depth 1 origin "${AGENTSCOPE_SOURCE_COMMIT}"
git -C "${output_dir}" checkout -q --detach "${AGENTSCOPE_SOURCE_COMMIT}"
test "$(git -C "${output_dir}" rev-parse HEAD)" = "${AGENTSCOPE_SOURCE_COMMIT}"

patches=(
  "${project_root}/deploy/patches/agentscope-runtime-env.patch"
  "${project_root}/deploy/patches/agentscope-web-ui-ip-path.patch"
  "${project_root}/deploy/patches/agentscope-credential-redaction.patch"
  "${project_root}/deploy/patches/agentscope-credential-model-filter.patch"
)

for patch_file in "${patches[@]}"; do
  git -C "${output_dir}" apply --recount --check "${patch_file}"
  git -C "${output_dir}" apply --recount "${patch_file}"
done

git -C "${output_dir}" diff --check
actual_manifest="$(mktemp /tmp/agentscope-overlay-files.XXXXXX)"
trap 'find "${actual_manifest}" -maxdepth 0 -type f -delete' EXIT
git -C "${output_dir}" diff --name-only | LC_ALL=C sort >"${actual_manifest}"
diff -u "${overlay_manifest}" "${actual_manifest}"

reported_version="$(awk -F'"' '/^__version__ = / {print $2; exit}' \
  "${output_dir}/src/agentscope/_version.py")"
test "${reported_version}" = "${AGENTSCOPE_PACKAGE_VERSION}"

printf 'Prepared AgentScope %s (%s) at %s\n' \
  "${AGENTSCOPE_DOCS_CHANNEL}" "${AGENTSCOPE_SOURCE_COMMIT}" "${output_dir}"
