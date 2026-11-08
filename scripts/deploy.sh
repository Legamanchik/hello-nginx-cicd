#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

IMAGE_NAME="${IMAGE_NAME:-}"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD 2>/dev/null || echo dev)}"
DEPLOY_HOST="${DEPLOY_HOST:-}"
DEPLOY_METHOD="${DEPLOY_METHOD:-ssm}"
DEPLOY_INSTANCE_ID="${DEPLOY_INSTANCE_ID:-}"
DEPLOY_USER="${DEPLOY_USER:-ec2-user}"
SSH_KEY="${SSH_KEY:-}"
SITE_DOMAIN="${SITE_DOMAIN:-${DEPLOY_HOST//./-}.sslip.io}"
CONTAINER_NAME="${CONTAINER_NAME:-hello-nginx}"
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
  local image="$1" name="$2" domain="$3"
  local net="${name}-net" proxy="${name}-proxy" proxy_image="caddy:2.11-alpine"
  local new conf_dir="/opt/${name}"
  new="${name}-$(date +%s)"

  echo "==> Pulling ${image}"
  docker pull --quiet "$image"
  docker network inspect "$net" >/dev/null 2>&1 || docker network create "$net" >/dev/null

  echo "==> Starting ${new}"
  docker run -d \
    --name "$new" \
    --label "app=${name}" \
    --network "$net" \
    --network-alias "$name" \
    --restart unless-stopped \
    --read-only \
    --tmpfs /tmp \
    --tmpfs /var/cache/nginx \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --memory 128m \
    --pids-limit 100 \
    --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 \
    "$image" >/dev/null

  echo "==> Waiting for ${new} to become healthy"
  local status="starting"
  for _ in $(seq 1 30); do
    status="$(docker inspect --format '{{.State.Health.Status}}' "$new" 2>/dev/null || echo missing)"
    [[ "$status" == "healthy" || "$status" == "unhealthy" || "$status" == "missing" ]] && break
    sleep 2
  done

  if [[ "$status" != "healthy" ]]; then
    echo "!! ${new} is '${status}'; keeping the current version" >&2
    docker logs --tail 50 "$new" >&2 || true
    docker rm -f "$new" >/dev/null 2>&1 || true
    return 1
  fi

  echo "==> ${new} is healthy, removing old containers"
  local old
  for old in $(docker ps -aq --filter "label=app=${name}"); do
    [[ "$(docker inspect --format '{{.Name}}' "$old")" == "/${new}" ]] || docker rm -f "$old" >/dev/null
  done
  docker rm -f "$name" "${name}_prev" >/dev/null 2>&1 || true

  echo "==> Ensuring HTTPS proxy (Caddy) for ${domain}"
  mkdir -p "$conf_dir"
  local site caddyfile
  site="reverse_proxy ${name}:8080 {\n\t\tlb_try_duration 5s\n\t}"
  caddyfile="$(printf '%s {\n\t%b\n}\n\n:80 {\n\t%b\n}' "$domain" "$site" "$site")"
  docker pull --quiet "$proxy_image" >/dev/null
  if [[ "$(cat "${conf_dir}/Caddyfile" 2>/dev/null)" != "$caddyfile" ]] || ! docker container inspect "$proxy" >/dev/null 2>&1; then
    printf '%s\n' "$caddyfile" > "${conf_dir}/Caddyfile"
    docker rm -f "$proxy" >/dev/null 2>&1 || true
    docker run -d \
      --name "$proxy" \
      --network "$net" \
      --restart unless-stopped \
      --publish 80:80 \
      --publish 443:443 \
      --read-only \
      --tmpfs /tmp \
      --cap-drop ALL \
      --cap-add NET_BIND_SERVICE \
      --security-opt no-new-privileges \
      --memory 128m \
      --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 \
      --volume "${conf_dir}/Caddyfile:/etc/caddy/Caddyfile:ro" \
      --volume "${name}-caddy-data:/data" \
      --volume "${name}-caddy-config:/config" \
      "$proxy_image" >/dev/null
  fi

  docker image prune -f >/dev/null
  echo "==> Deployed ${image}"
}

remote_script() {
  printf '%s\n' "$(declare -f remote_deploy)"
  printf 'remote_deploy %q %q %q\n' "$IMAGE" "$CONTAINER_NAME" "$SITE_DOMAIN"
}

deploy_ssh() {
  local ssh_opts=(-o BatchMode=yes -o ConnectTimeout=15)
  [[ -n "$SSH_KEY" ]] && ssh_opts+=(-i "$SSH_KEY")
  log "Deploying ${IMAGE} to ${DEPLOY_USER}@${DEPLOY_HOST} over SSH"
  remote_script | ssh "${ssh_opts[@]}" "${DEPLOY_USER}@${DEPLOY_HOST}" 'sudo bash -s'
}

deploy_ssm() {
  [[ -n "$DEPLOY_INSTANCE_ID" ]] || die "DEPLOY_INSTANCE_ID is not set"
  command -v aws >/dev/null || die "aws CLI is required for DEPLOY_METHOD=ssm"
  log "Deploying ${IMAGE} to ${DEPLOY_INSTANCE_ID} via AWS SSM"

  local params cmd_id status
  params="$(jq -n --arg b64 "$(remote_script | base64 | tr -d '\n')" \
    '{commands: ["echo \($b64) | base64 -d | bash"], executionTimeout: ["600"]}')"
  cmd_id="$(aws ssm send-command \
    --instance-ids "$DEPLOY_INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --comment "deploy ${IMAGE_TAG:0:12}" \
    --parameters "$params" \
    --query Command.CommandId --output text)"

  for _ in $(seq 1 120); do
    sleep 5
    status="$(aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$DEPLOY_INSTANCE_ID" \
      --query Status --output text 2>/dev/null || echo Pending)"
    case "$status" in Pending|InProgress|Delayed) continue ;; *) break ;; esac
  done

  aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$DEPLOY_INSTANCE_ID" \
    --query '[StandardOutputContent, StandardErrorContent]' --output text
  [[ "$status" == "Success" ]] || die "Remote deploy finished with status: ${status}"
}

cmd_deploy() {
  [[ -n "$DEPLOY_HOST" ]] || die "DEPLOY_HOST is not set"
  case "$DEPLOY_METHOD" in
    ssm) deploy_ssm ;;
    ssh) deploy_ssh ;;
    *)   die "DEPLOY_METHOD must be ssm or ssh" ;;
  esac

  log "Checking https://${SITE_DOMAIN}/version.txt from outside"
  local got=""
  for _ in $(seq 1 20); do
    got="$(curl -fsS --max-time 5 "https://${SITE_DOMAIN}/version.txt" 2>/dev/null || true)"
    if [[ "$got" == "$IMAGE_TAG" ]]; then
      log "Deployed ${IMAGE} -> https://${SITE_DOMAIN}/"
      return 0
    fi
    sleep 3
  done
  die "https://${SITE_DOMAIN}/ serves '${got:-nothing}' instead of ${IMAGE_TAG} (check security group, Caddy logs)"
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
    *)      sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
  esac
}

main "$@"
