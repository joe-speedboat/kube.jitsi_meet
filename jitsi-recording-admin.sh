#!/usr/bin/env bash
set -Eeuo pipefail

# jitsi-recording-admin.sh
# Fresh deployment and moderator-management helper for jitsi-contrib/jitsi-helm
# with Jibri recording enabled.
#
# Override with env, for example:
#   NAMESPACE=meet RELEASE=meet PUBLIC_URL=https://meet.example.ch JVB_PUBLIC_IP=1.2.3.4 ./jitsi-recording-admin.sh render-values

NAMESPACE="${NAMESPACE:-meet}"
RELEASE="${RELEASE:-meet}"
CHART="${CHART:-jitsi/jitsi-meet}"
CHART_VERSION="${CHART_VERSION:-2.16.0}"
PUBLIC_URL="${PUBLIC_URL:-}"
JVB_PUBLIC_IP="${JVB_PUBLIC_IP:-}"
VALUES_FILE="${VALUES_FILE:-my_values.yml}"
INGRESS_FILE="${INGRESS_FILE:-my_ingress.yml}"
INGRESS_NAME="${INGRESS_NAME:-meet}"
SECRETS_FILE="${SECRETS_FILE:-.jitsi-recording.env}"
JIBRI_PVC_NAME="${JIBRI_PVC_NAME:-${RELEASE}-jitsi-meet-jibri-rwo}"
JIBRI_PVC_SIZE="${JIBRI_PVC_SIZE:-32Gi}"
JIBRI_STORAGE_CLASS="${JIBRI_STORAGE_CLASS:-local-path}"
PROSODY_RESOURCE="${PROSODY_RESOURCE:-statefulset/${RELEASE}-jitsi-meet-prosody}"
JIBRI_RESOURCE="${JIBRI_RESOURCE:-deploy/${RELEASE}-jitsi-meet-jibri}"

usage() {
  cat <<'USAGE'
Usage:
  ./jitsi-recording-admin.sh setup
  ./jitsi-recording-admin.sh init
  ./jitsi-recording-admin.sh render-values
  ./jitsi-recording-admin.sh render-ingress
  ./jitsi-recording-admin.sh deploy
  ./jitsi-recording-admin.sh reset-deploy
  ./jitsi-recording-admin.sh status
  ./jitsi-recording-admin.sh moderator add USER [PASSWORD]
  ./jitsi-recording-admin.sh moderator passwd USER [PASSWORD]
  ./jitsi-recording-admin.sh moderator delete USER
  ./jitsi-recording-admin.sh moderator list
  ./jitsi-recording-admin.sh jibri-health
  ./jitsi-recording-admin.sh logs-jibri

Environment overrides:
  NAMESPACE          Kubernetes namespace, default: meet
  RELEASE            Helm release name, default: meet
  CHART              Helm chart, default: jitsi/jitsi-meet
  CHART_VERSION      Helm chart version, default: 2.16.0
  PUBLIC_URL         External Jitsi URL, for example: https://meet.example.ch
  JVB_PUBLIC_IP      Public IP advertised by JVB; setup can auto-detect it
  VALUES_FILE        Generated Helm values file, default: my_values.yml
  INGRESS_FILE       Generated Ingress file, default: my_ingress.yml
  INGRESS_NAME       Ingress object name, default: meet
  SECRETS_FILE       Internal password file, default: .jitsi-recording.env
  JIBRI_PVC_NAME     Pre-created RWO recording PVC, default: meet-jitsi-meet-jibri-rwo
  JIBRI_PVC_SIZE     Recording PVC size, default: 32Gi
  JIBRI_STORAGE_CLASS Recording PVC storageClassName, default: local-path

Recommended fresh flow:
  ./jitsi-recording-admin.sh setup
  ./jitsi-recording-admin.sh reset-deploy
  kubectl apply -f my_ingress.yml
  ./jitsi-recording-admin.sh moderator add chris
  ./jitsi-recording-admin.sh status
USAGE
}

prompt_with_default() {
  local prompt="$1" default="${2:-}" answer
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " answer
    printf '%s\n' "${answer:-$default}"
  else
    read -r -p "$prompt: " answer
    printf '%s\n' "$answer"
  fi
}

fqdn_from_public_url() {
  local url="$1"
  url="${url#http://}"
  url="${url#https://}"
  url="${url%%/*}"
  printf '%s\n' "$url"
}

detect_wan_ip() {
  local ip
  for endpoint in https://ifconfig.me https://api.ipify.org https://icanhazip.com; do
    if ip="$(curl -fsS --max-time 5 "$endpoint" 2>/dev/null | tr -d '[:space:]')"; then
      if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '%s\n' "$ip"
        return 0
      fi
    fi
  done
  return 1
}

setup() {
  require_cmd curl

  local fqdn default_fqdn detected_ip
  default_fqdn="$(fqdn_from_public_url "$PUBLIC_URL")"

  NAMESPACE="$(prompt_with_default "Kubernetes namespace" "$NAMESPACE")"
  RELEASE="$(prompt_with_default "Helm release name" "$RELEASE")"
  fqdn="$(prompt_with_default "Jitsi FQDN" "$default_fqdn")"
  if [[ -z "$fqdn" ]]; then
    echo "ERROR: FQDN is required" >&2
    exit 1
  fi
  PUBLIC_URL="https://${fqdn}"

  detected_ip="${JVB_PUBLIC_IP:-}"
  if [[ -z "$detected_ip" ]]; then
    detected_ip="$(detect_wan_ip || true)"
  fi
  JVB_PUBLIC_IP="$(prompt_with_default "JVB WAN/public IP" "$detected_ip")"
  if [[ -z "$JVB_PUBLIC_IP" ]]; then
    echo "ERROR: JVB WAN/public IP is required" >&2
    exit 1
  fi

  init_secrets
  render_values
  render_ingress

  echo
  echo "Setup files generated:"
  echo "  values:  $VALUES_FILE"
  echo "  ingress: $INGRESS_FILE"
  echo "  secrets: $SECRETS_FILE"
  echo
  echo "Next steps:"
  echo "  ./jitsi-recording-admin.sh reset-deploy"
  echo "  kubectl apply -f $INGRESS_FILE"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

require_kube_tools() {
  require_cmd kubectl
  require_cmd helm
}

rand_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    # Fallback for very minimal systems.
    tr -dc 'a-f0-9' </dev/urandom | head -c 48
    echo
  fi
}

init_secrets() {
  if [[ -f "$SECRETS_FILE" ]]; then
    echo "Secrets file already exists: $SECRETS_FILE"
    echo "Leaving it unchanged. Delete it first if you intentionally want new internal passwords."
    return 0
  fi

  umask 077
  cat >"$SECRETS_FILE" <<EOF
# Internal service passwords for Jitsi/Jibri. Keep this file private.
# Generated: $(date -Is)
JIBRI_XMPP_PASSWORD=$(rand_hex)
JIBRI_RECORDER_PASSWORD=$(rand_hex)
EOF
  chmod 0600 "$SECRETS_FILE"
  echo "Created $SECRETS_FILE with mode 0600."
}

load_secrets() {
  if [[ ! -f "$SECRETS_FILE" ]]; then
    echo "Secrets file not found: $SECRETS_FILE" >&2
    echo "Run: $0 init" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
  : "${JIBRI_XMPP_PASSWORD:?missing JIBRI_XMPP_PASSWORD in $SECRETS_FILE}"
  : "${JIBRI_RECORDER_PASSWORD:?missing JIBRI_RECORDER_PASSWORD in $SECRETS_FILE}"
}

render_values() {
  load_secrets
  : "${PUBLIC_URL:?PUBLIC_URL is required. Run setup or export PUBLIC_URL=https://meet.example.ch}"
  : "${JVB_PUBLIC_IP:?JVB_PUBLIC_IP is required. Run setup or export JVB_PUBLIC_IP=1.2.3.4}"
  umask 077
  cat >"$VALUES_FILE" <<EOF
publicURL: ${PUBLIC_URL}

enableAuth: true
enableGuests: true

# docker-jitsi-meet supports internal auth via AUTH_TYPE=internal.
# The chart passes extraCommonEnvs into the common ConfigMap used by components.
extraCommonEnvs:
  AUTH_TYPE: internal

web:
  service:
    type: ClusterIP

jvb:
  useHostNetwork: true
  service:
    type: ClusterIP
  publicIPs:
    - ${JVB_PUBLIC_IP}

# Needed because moderator accounts are stored in Prosody.
prosody:
  persistence:
    enabled: true
    size: 3Gi

jibri:
  enabled: true
  useExternalJibri: false
  replicaCount: 1

  xmpp:
    user: jibri
    password: "${JIBRI_XMPP_PASSWORD}"

  recorder:
    user: recorder
    password: "${JIBRI_RECORDER_PASSWORD}"

  singleUseMode: false
  recording: true
  livestreaming: false

  # Chart 2.16.0 hardcodes its generated Jibri PVC with both ReadWriteOnce
  # and ReadWriteMany. k3s local-path cannot satisfy RWX, so the helper
  # pre-creates an RWO PVC and points Jibri at it via existingClaim.
  persistence:
    enabled: true
    existingClaim: "${JIBRI_PVC_NAME}"
    size: ${JIBRI_PVC_SIZE}

  shm:
    enabled: true
    size: 2Gi

  resources:
    requests:
      cpu: "500m"
      memory: "1Gi"
    limits:
      cpu: "2"
      memory: "3Gi"
EOF
  chmod 0600 "$VALUES_FILE"
  echo "Rendered $VALUES_FILE."
  echo "WARNING: $VALUES_FILE contains internal service passwords; keep mode 0600 and do not commit it."
}

render_ingress() {
  : "${PUBLIC_URL:?PUBLIC_URL is required. Run setup or export PUBLIC_URL=https://meet.example.ch}"
  local fqdn
  fqdn="$(fqdn_from_public_url "$PUBLIC_URL")"
  if [[ -z "$fqdn" ]]; then
    echo "ERROR: could not derive FQDN from PUBLIC_URL=$PUBLIC_URL" >&2
    exit 1
  fi
  cat >"$INGRESS_FILE" <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${INGRESS_NAME}
  namespace: ${NAMESPACE}
spec:
  rules:
    - host: ${fqdn}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${RELEASE}-jitsi-meet-web
                port:
                  number: 80
EOF
  echo "Rendered $INGRESS_FILE."
}

helm_repo_ensure() {
  require_kube_tools
  if ! helm repo list 2>/dev/null | awk '{print $1}' | grep -qx 'jitsi'; then
    helm repo add jitsi https://jitsi-contrib.github.io/jitsi-helm/
  fi
  helm repo update jitsi >/dev/null
}

apply_jibri_pvc() {
  require_kube_tools
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${JIBRI_PVC_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: jitsi-meet
    app.kubernetes.io/instance: ${RELEASE}
    app.kubernetes.io/component: jibri
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${JIBRI_STORAGE_CLASS}
  resources:
    requests:
      storage: ${JIBRI_PVC_SIZE}
EOF
}

deploy() {
  require_kube_tools
  [[ -f "$VALUES_FILE" ]] || {
    echo "Values file missing: $VALUES_FILE" >&2
    echo "Run: $0 render-values" >&2
    exit 1
  }
  helm_repo_ensure
  apply_jibri_pvc
  helm upgrade --install "$RELEASE" "$CHART" \
    --version "$CHART_VERSION" \
    -n "$NAMESPACE" \
    --create-namespace \
    -f "$VALUES_FILE"
}

reset_deploy() {
  require_kube_tools
  echo "This removes the Helm release and all PVCs in namespace '$NAMESPACE'."
  echo "Only use this for a fresh deployment with no data to keep."
  read -r -p "Type DELETE to continue: " answer
  if [[ "$answer" != "DELETE" ]]; then
    echo "Aborted."
    exit 1
  fi
  helm uninstall "$RELEASE" -n "$NAMESPACE" || true
  kubectl delete pvc -n "$NAMESPACE" --all || true
  deploy
}

prosody_env() {
  local key="$1"
  kubectl exec -n "$NAMESPACE" "$PROSODY_RESOURCE" -- printenv "$key" 2>/dev/null || true
}

moderator_domain() {
  local domain
  # Human moderator accounts for docker-jitsi-meet internal auth belong to
  # XMPP_DOMAIN (normally meet.jitsi). XMPP_AUTH_DOMAIN (normally
  # auth.meet.jitsi) is used by internal components; registering human users
  # there can lead to the UI accepting credentials but asking again.
  domain="$(prosody_env XMPP_DOMAIN)"
  if [[ -z "$domain" ]]; then
    domain="meet.jitsi"
  fi
  printf '%s\n' "$domain"
}

prosodyctl_exec() {
  require_cmd kubectl
  kubectl exec -n "$NAMESPACE" "$PROSODY_RESOURCE" -- \
    prosodyctl --config /config/prosody.cfg.lua "$@"
}

read_password() {
  local prompt="$1"
  local pw1 pw2
  read -r -s -p "$prompt: " pw1
  echo >&2
  read -r -s -p "Repeat password: " pw2
  echo >&2
  if [[ "$pw1" != "$pw2" ]]; then
    echo "ERROR: passwords did not match" >&2
    exit 1
  fi
  if [[ -z "$pw1" ]]; then
    echo "ERROR: empty password rejected" >&2
    exit 1
  fi
  printf '%s\n' "$pw1"
}

moderator_add() {
  local user="${1:-}" password="${2:-}" domain
  [[ -n "$user" ]] || { echo "Usage: $0 moderator add USER [PASSWORD]" >&2; exit 1; }
  domain="$(moderator_domain)"
  if [[ -z "$password" ]]; then
    password="$(read_password "Password for moderator '$user'")"
  fi
  prosodyctl_exec register "$user" "$domain" "$password"
  echo "Moderator added: $user@$domain"
}

moderator_passwd() {
  local user="${1:-}" password="${2:-}" domain
  [[ -n "$user" ]] || { echo "Usage: $0 moderator passwd USER [PASSWORD]" >&2; exit 1; }
  domain="$(moderator_domain)"
  if [[ -z "$password" ]]; then
    password="$(read_password "New password for moderator '$user'")"
  fi
  prosodyctl_exec passwd "$user" "$domain" "$password"
  echo "Moderator password changed: $user@$domain"
}

moderator_delete() {
  local user="${1:-}" domain
  [[ -n "$user" ]] || { echo "Usage: $0 moderator delete USER" >&2; exit 1; }
  domain="$(moderator_domain)"
  prosodyctl_exec unregister "$user" "$domain"
  echo "Moderator deleted: $user@$domain"
}

moderator_list() {
  local domain data_dir encoded_domain
  domain="$(moderator_domain)"
  data_dir="$(prosody_env XMPP_CONFIG_PATH)"
  data_dir="${data_dir:-/config}"

  # Prosody stores internal auth accounts below /config/data/<escaped-domain>/accounts.
  # Dots in the domain are escaped as %2e in current Prosody storage layout.
  encoded_domain="${domain//./%2e}"

  echo "Auth domain: $domain"
  kubectl exec -n "$NAMESPACE" "$PROSODY_RESOURCE" -- \
    sh -c "set -eu; d='${data_dir%/}/data/${encoded_domain}/accounts'; if [ -d \"\$d\" ]; then for f in \"\$d\"/*.dat; do [ -e \"\$f\" ] || exit 0; basename \"\$f\" .dat; done | sort; else echo 'No account directory found: '\"\$d\" >&2; exit 2; fi"
}

status() {
  require_cmd kubectl
  echo "## Pods"
  kubectl get pods -n "$NAMESPACE" -o wide
  echo
  echo "## PVCs"
  kubectl get pvc -n "$NAMESPACE" || true
  echo
  echo "## Relevant Prosody env"
  kubectl exec -n "$NAMESPACE" "$PROSODY_RESOURCE" -- printenv | sort \
    | grep -E '^(ENABLE_AUTH|ENABLE_GUESTS|AUTH_TYPE|XMPP_|JIBRI_)' \
    | sed -E 's/^(JIBRI_.*PASSWORD)=.*/\1=<redacted>/' || true
}

jibri_health() {
  require_cmd kubectl
  kubectl exec -n "$NAMESPACE" "$JIBRI_RESOURCE" -- \
    sh -c "curl -sq localhost:2222/jibri/api/v1.0/health || true; echo"
}

logs_jibri() {
  require_cmd kubectl
  kubectl logs -n "$NAMESPACE" "$JIBRI_RESOURCE" --tail=200 -f
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    setup)
      setup
      ;;
    init)
      init_secrets
      ;;
    render-values)
      render_values
      ;;
    render-ingress)
      render_ingress
      ;;
    deploy)
      deploy
      ;;
    reset-deploy)
      reset_deploy
      ;;
    status)
      status
      ;;
    moderator)
      local sub="${2:-}"
      shift 2 || true
      case "$sub" in
        add) moderator_add "$@" ;;
        passwd) moderator_passwd "$@" ;;
        delete|del|remove|rm) moderator_delete "$@" ;;
        list|ls) moderator_list ;;
        *) usage; exit 1 ;;
      esac
      ;;
    jibri-health)
      jibri_health
      ;;
    logs-jibri)
      logs_jibri
      ;;
    -h|--help|help|"")
      usage
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
