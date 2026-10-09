#!/usr/bin/env bash
set -euo pipefail

# Only configure the disposable Linux runner, before it starts any containers.
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_OS:-} == Linux ]] || {
  echo 'Docker cache setup is limited to GitHub Actions Linux runners.' >&2
  exit 1
}

# Public test images do not need the runner's preconfigured Docker Hub account.
# Isolate this job's CLI config instead of mutating the runner's credentials.
docker_config="${RUNNER_TEMP:?}/pairnotes-docker"
mkdir -p "$docker_config"
printf 'DOCKER_CONFIG=%s\n' "$docker_config" >> "${GITHUB_ENV:?}"

# Keep the original image references and digest verification. Docker falls back
# to Docker Hub on a cache miss. Preserve all other runner daemon settings.
# https://docs.cloud.google.com/artifact-registry/docs/pull-cached-dockerhub-images
sudo python3 - <<'PY'
import json
from pathlib import Path

path = Path('/etc/docker/daemon.json')
config = json.loads(path.read_text()) if path.exists() else {}
mirrors = config.get('registry-mirrors', [])
config['registry-mirrors'] = list(dict.fromkeys(['https://mirror.gcr.io', *mirrors]))
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(config, indent=2) + '\n')
PY
sudo systemctl restart docker
docker info --format '{{json .RegistryConfig.Mirrors}}'
