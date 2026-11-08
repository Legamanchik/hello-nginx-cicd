#!/usr/bin/env bash
set -Eeuo pipefail

readonly CONTAINER_PORT=8080

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

IMAGE_NAME="${IMAGE_NAME:-}"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD 2>/dev/null || echo dev)}"
DEPLOY_HOST="${DEPLOY_HOST:-}"
DEPLOY_USER="${DEPLOY_USER:-ec2-user}"
SSH_KEY="${SSH_KEY:-}"
CONTAINER_NAME="${CONTAINER_NAME:-hello-nginx}"
HOST_PORT="${HOST_PORT:-80}"
PUSH_LATEST="${PUSH_LATEST:-true}"

IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

cmd_build() {
  log "Building ${IMAGE}"
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  docker build \
    --pull \
    --build-arg "APP_VERSION=${IMAGE_TAG}" \
    --tag "$IMAGE" \
    "$root"
  if [[ "$PUSH_LATEST" == "true" ]]; then
    docker tag "$IMAGE" "${IMAGE_NAME}:latest"
  fi
}

cmd_push() {
  log "Pushing ${IMAGE}"
  docker push "$IMAGE"
  if [[ "$PUSH_LATEST" == "true" ]]; then
    docker push "${IMAGE_NAME}:latest"
  fi
}

remote_deploy() {
  set -Eeuo pipefail
  local image="$1" name="$2" host_port="$3" container_port="$4"
  local prev="${name}_prev"

  echo "==> Pulling ${image}"
  docker pull --quiet "$image"

  if docker container inspect "$name" >/dev/null 2>&1; then
    echo "==> Keeping current container as ${prev} for rollback"
    docker rm -f "$prev" >/dev/null 2>&1 || true
    docker stop --time 10 "$name" >/dev/null
    docker rename "$name" "$prev"
  fi

  echo "==> Starting ${name}"
  docker run -d \
    --name "$name" \
    --restart unless-stopped \
    --publish "${host_port}:${container_port}" \
    --read-only \
    --tmpfs /tmp \
    --tmpfs /var/cache/nginx \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --memory 128m \
    --pids-limit 100 \
    --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 \
    "$image" >/dev/null

  echo "==> Waiting for container to become healthy"
  local status="starting"
  for _ in $(seq 1 30); do
    status="$(docker inspect --format '{{.State.Health.Status}}' "$name" 2>/dev/null || echo missing)"
    [[ "$status" == "healthy" || "$status" == "unhealthy" || "$status" == "missing" ]] && break
    sleep 2
  done

  if [[ "$status" == "healthy" ]]; then
    echo "==> ${name} is healthy, removing previous container and old images"
    docker rm -f "$prev" >/dev/null 2>&1 || true
    docker image prune -f >/dev/null
    return 0
  fi

  echo "!! ${name} is '${status}', rolling back" >&2
  docker logs --tail 50 "$name" >&2 || true
  docker rm -f "$name" >/dev/null 2>&1 || true
  if docker container inspect "$prev" >/dev/null 2>&1; then
    docker rename "$prev" "$name"
    docker start "$name" >/dev/null
    echo "!! Rolled back to the previous version" >&2
  fi
  return 1
}

cmd_deploy() {
  [[ -n "$DEPLOY_HOST" ]] || die "DEPLOY_HOST is not set"

  local ssh_opts=(-o BatchMode=yes -o ConnectTimeout=15)
  [[ -n "$SSH_KEY" ]] && ssh_opts+=(-i "$SSH_KEY")

  log "Deploying ${IMAGE} to ${DEPLOY_USER}@${DEPLOY_HOST}:${HOST_PORT}"

  ssh "${ssh_opts[@]}" "${DEPLOY_USER}@${DEPLOY_HOST}" \
    "$(declare -f remote_deploy); remote_deploy $(printf '%q ' "$IMAGE" "$CONTAINER_NAME" "$HOST_PORT" "$CONTAINER_PORT")"

  log "Checking http://${DEPLOY_HOST}:${HOST_PORT}/healthz from outside"
  for _ in $(seq 1 10); do
    if curl -fsS --max-time 5 "http://${DEPLOY_HOST}:${HOST_PORT}/healthz" >/dev/null; then
      log "Deployed ${IMAGE} -> http://${DEPLOY_HOST}:${HOST_PORT}/"
      return 0
    fi
    sleep 3
  done
  die "Service is not reachable from outside after deploy (check the security group / firewall)"
}

main() {
  case "${1:-}" in
    build|push|deploy|all)
      [[ -n "$IMAGE_NAME" ]] || die "IMAGE_NAME is not set (e.g. export IMAGE_NAME=myuser/hello-nginx)" ;;
  esac

  case "${1:-}" in
    build)  cmd_build ;;
    push)   cmd_push ;;
    deploy) cmd_deploy ;;
    all)    cmd_build; cmd_push; cmd_deploy ;;
    *)      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
  esac
}

main "$@"
