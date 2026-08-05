#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/.." && pwd)"
cd "${project_root}"

while IFS= read -r script_file; do
  bash -n "${script_file}"
done < <(find scripts talk-think-memory-lab/scripts -type f -name '*.sh' -print | LC_ALL=C sort)
sh -n deploy/oci/reme-no-provider

# Unified-diff files legitimately contain a leading context marker followed by
# a tab. Git's generic whitespace checker treats that patch syntax as source
# indentation, so validate the repository diff outside the patch artifacts;
# prepared upstream source is checked separately by the preparation script.
git diff --check -- . ':(exclude)deploy/patches/*.patch'

for required_file in \
  dependencies/agentscope.lock.env \
  dependencies/agentscope-overlay-files.txt \
  deploy/patches/agentscope-runtime-env.patch \
  deploy/oci/agentscope-service.Dockerfile \
  deploy/oci/agentscope-web.Dockerfile \
  deploy/oci/reme-no-provider \
  deploy/oci/talk-think-memory-lab.Dockerfile; do
  test -f "${required_file}"
done

forbidden_path_pattern='(^|/)(\.env($|\.)|\.venv($|/)|node_modules($|/)|dist($|/)|logs($|/)|[^/]+\.(pem|key|p12|pfx))'
if git ls-files | grep -E "${forbidden_path_pattern}"; then
  echo "Forbidden generated or secret-bearing path is tracked." >&2
  exit 1
fi

if git grep -n -I -E \
  '(-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|sk-[A-Za-z0-9_-]{24,}|AKLT[A-Za-z0-9]{16,})' \
  -- ':!scripts/check-public-repository.sh'; then
  echo "Possible secret value found in tracked content." >&2
  exit 1
fi

echo "Public repository checks passed."
