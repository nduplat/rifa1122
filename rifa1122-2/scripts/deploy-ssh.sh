#!/usr/bin/env bash
set -euo pipefail

PROG_NAME=$(basename "$0")
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $PROG_NAME [--dry-run] [--remote-dir DIR] [--ssh-key-file FILE] [--image IMAGE]
  --dry-run           Print actions but don't execute remote commands
  --remote-dir DIR    Remote deploy directory (default: ~/deploy/rifa1122)
  --ssh-key-file PATH Path to SSH private key file (optional)
  --image IMAGE       Image to deploy (overrides IMAGE env)

If no args provided the script will attempt to use env vars and sensible defaults.
EOF
  exit 1
}

while [[ ${#} -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --remote-dir) REMOTE_DIR="$2"; shift 2 ;;
    --ssh-key-file) SSH_KEY_FILE="$2"; shift 2 ;;
    --image) IMAGE_OVERRIDE="$2"; shift 2 ;;
    -h|--help) usage ;;
    --) shift; break;;
    *) break ;;
  esac
done

# Positional fallback for ssh host/user
SSH_HOST=${1:-${SSH_HOST:-}}
SSH_USER=${2:-${SSH_USER:-}}

IMAGE=${IMAGE_OVERRIDE:-${IMAGE:-ghcr.io/nduplat/rifa1122:latest}}
REMOTE_DIR=${REMOTE_DIR:-${STAGING_REMOTE_DIR:-/home/${SSH_USER:-deploy}/deploy/rifa1122}}

if [[ -z "$SSH_HOST" || -z "$SSH_USER" ]]; then
  echo "Need SSH_HOST and SSH_USER (as positional args or env vars)." >&2
  usage
fi

SSH_OPTS='-o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=10'

# Add known_hosts entry (idempotent)
mkdir -p ~/.ssh
ssh-keyscan -H "$SSH_HOST" >> ~/.ssh/known_hosts || true

# If key file provided, add to ssh-agent
if [[ -n "${SSH_KEY_FILE:-}" ]]; then
  eval "$(ssh-agent -s)" >/dev/null
  ssh-add "$SSH_KEY_FILE"
fi

echo "Remote: ${SSH_USER}@${SSH_HOST}  -> ${REMOTE_DIR}"
echo "Image: ${IMAGE}"
if [[ $DRY_RUN -eq 1 ]]; then
  echo "DRY RUN enabled - no remote commands will be executed"
fi

# Sync files
RSYNC_CMD=(rsync -avz -e "ssh ${SSH_OPTS}")
SYNC_SRC=(docker-compose.prod.yml nginx/ .env.prod.example)
if [[ $DRY_RUN -eq 1 ]]; then
  echo "Would create remote dir and rsync files: ${SYNC_SRC[*]} to ${SSH_USER}@${SSH_HOST}:${REMOTE_DIR}/"
else
  ssh ${SSH_OPTS} ${SSH_USER}@${SSH_HOST} "mkdir -p ${REMOTE_DIR} && chmod 700 ${REMOTE_DIR}"
  "${RSYNC_CMD[@]}" "${SYNC_SRC[@]}" ${SSH_USER}@${SSH_HOST}:${REMOTE_DIR}/
fi

# Optional GHCR login
if [[ -n "${GHCR_USERNAME:-}" && -n "${GHCR_PAT:-}" ]]; then
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "Would login to GHCR with user ${GHCR_USERNAME} on remote host"
  else
    echo "Logging in to GHCR on remote host"
    echo "${GHCR_PAT}" | ssh ${SSH_OPTS} ${SSH_USER}@${SSH_HOST} "docker login ghcr.io -u ${GHCR_USERNAME} --password-stdin"
  fi
fi

# Validate compose and deploy using docker compose on remote
if [[ $DRY_RUN -eq 1 ]]; then
  echo "Would validate, pull and bring up compose at ${REMOTE_DIR} using IMAGE=${IMAGE}"
else
  ssh ${SSH_OPTS} ${SSH_USER}@${SSH_HOST} "cd ${REMOTE_DIR} && docker compose -f docker-compose.prod.yml config"
  ssh ${SSH_OPTS} ${SSH_USER}@${SSH_HOST} "cd ${REMOTE_DIR} && docker compose -f docker-compose.prod.yml pull"
  ssh ${SSH_OPTS} ${SSH_USER}@${SSH_HOST} "cd ${REMOTE_DIR} && IMAGE=${IMAGE} docker compose -f docker-compose.prod.yml up -d"

  # Capture image digest and write to deploy.log
  DIGEST=$(ssh ${SSH_OPTS} ${SSH_USER}@${SSH_HOST} "docker image inspect --format '{{index .RepoDigests 0}}' ${IMAGE} || true") || true
  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  LOG_LINE="${TIMESTAMP} ${USER:-local} ${IMAGE} ${DIGEST:-unknown}"
  echo "Logging deployment: ${LOG_LINE}"
  ssh ${SSH_OPTS} ${SSH_USER}@${SSH_HOST} "mkdir -p ${REMOTE_DIR} && echo '${LOG_LINE}' >> ${REMOTE_DIR}/deploy.log"

  # Verify services
  ssh ${SSH_OPTS} ${SSH_USER}@${SSH_HOST} "cd ${REMOTE_DIR} && docker compose -f docker-compose.prod.yml ps --services --filter status=running"

  # Attempt healthcheck if curl exists
  ssh ${SSH_OPTS} ${SSH_USER}@${SSH_HOST} "command -v curl >/dev/null 2>&1 && curl -sSf http://localhost:8000/health || echo 'healthcheck skipped or failed'"
fi

echo "Done."