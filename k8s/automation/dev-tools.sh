#!/bin/bash

set -uo pipefail

# =====================
# Base paths (FIXED)
# =====================
K8S_ROOT="/home/fran23k/k8s"
APPS_DIR="$K8S_ROOT/apps"
CHARTS_DIR="$K8S_ROOT/charts"
MANIFESTS_DIR="$K8S_ROOT/manifests"

# =====================
# Colours
# =====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# =====================
# UI helpers
# =====================
section() {
  echo -e "\n${BOLD}${CYAN}---- $1 ----${RESET}"
}

hint() {
  echo -e "${YELLOW}$1${RESET}"
}

log() {
  echo -e "${CYAN}[INFO]${RESET} $1"
}

warn() {
  echo -e "${YELLOW}[WARN]${RESET} $1"
}

error() {
  echo -e "${RED}[ERROR]${RESET} $1" >&2
}

success() {
  echo -e "${GREEN}[OK]${RESET} $1"
}

pause() {
  echo ""
  read -r -p "Press Enter to continue..." _
}

clear_screen() {
  clear 2>/dev/null || printf '\033c'
}

run_step() {
  local description="$1"
  shift

  log "$description"
  "$@"
}

run_shell_step() {
  local description="$1"
  local command="$2"

  log "$description"
  bash -lc "$command"
}

# =====================
# Validation helpers
# =====================
require_commands() {
  local missing=()
  local cmd

  for cmd in kubectl helm docker curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if ! command -v jq >/dev/null 2>&1; then
    warn "jq is missing. Option 32 will not work until jq is installed."
  fi

  if [ "${#missing[@]}" -gt 0 ]; then
    error "Missing required commands: ${missing[*]}"
    exit 1
  fi
}

get_current_context() {
  kubectl config current-context 2>/dev/null || echo "unknown"
}

get_pod_name() {
  local label="$1"
  kubectl get pod -l "app=$label" -o jsonpath="{.items[0].metadata.name}" 2>/dev/null
}

require_pod_name() {
  local pod_name
  pod_name="$(get_pod_name "$1")"

  if [ -z "$pod_name" ]; then
    error "No running pod found for app=$1"
    return 1
  fi

  printf '%s\n' "$pod_name"
}

validate_service_name() {
  local service="$1"

  if [ -z "$service" ]; then
    error "Service name cannot be empty."
    return 1
  fi

  if [[ ! "$service" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    error "Invalid service name. Use lowercase letters, numbers, and dashes only."
    return 1
  fi
}

validate_positive_integer() {
  local value="$1"
  local label="$2"

  if [[ ! "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ]; then
    error "$label must be a positive whole number."
    return 1
  fi
}

confirm_action() {
  local prompt="$1"
  local answer

  read -r -p "$prompt (y/n): " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]]
}

safe_remove_dir() {
  local target="$1"

  if [ -z "$target" ] || [ "$target" = "/" ]; then
    error "Refusing to delete unsafe path: '$target'"
    return 1
  fi

  case "$target" in
    "$APPS_DIR"/*|"$CHARTS_DIR"/*)
      rm -rf -- "$target"
      ;;
    *)
      error "Refusing to delete outside approved paths: '$target'"
      return 1
      ;;
  esac
}

# =====================
# Cleanup
# =====================
cleanup_vps() {
  echo "==== Disk Usage ===="
  df -h /
  echo ""
  echo "==== Largest folders ===="
  sudo du -h --max-depth=1 /var 2>/dev/null | sort -hr | head -10
  echo ""
  echo "==== Cleaning ===="
  sudo k3s crictl rmi --prune
  sudo apt clean
  sudo journalctl --vacuum-time=7d
  sudo find /tmp -type f -mtime +1 -delete
  echo ""
  df -h /
}

show_menu() {
  clear_screen

  echo -e "${BOLD}${BLUE}==============================${RESET}"
  echo -e "${BOLD}Order Services Dev Tools${RESET}"
  echo -e "${DIM}Cluster:${RESET} $(get_current_context)"
  echo -e "${DIM}Apps:${RESET} $APPS_DIR"
  echo -e "${BOLD}${BLUE}==============================${RESET}"

  section "Monitoring"
  hint "Check system health, load, scaling"
  echo "  1) Watch CPU & Memory"
  echo "  2) Show Pods"
  echo "  3) Watch Pods"
  echo "  4) Show HPA"
  echo "  5) Watch Autoscaling"
  echo "  6) Node Resources"

  section "Exec"
  hint "Debug inside containers"
  echo "  7) order-api shell"
  echo "  8) order-admin shell"
  echo "  9) postgres shell"

  section "Logs"
  hint "Troubleshoot behaviour/errors"
  echo " 10) order-api logs"
  echo " 11) postgres logs"
  echo " 12) describe order-api"

  section "Database"
  hint "Dangerous actions are confirmed"
  echo " 13) count orders"
  echo " 14) truncate orders"

  section "Testing"
  hint "Verify API after deploy"
  echo " 15) send test order"

  section "Scaling"
  hint "Manual override/testing"
  echo " 16) scale order-api"
  echo " 17) quick scale"

  section "Deployment (HELM - order-api)"
  echo -e "${CYAN}  Image change?${RESET} -> ${GREEN}18${RESET}"
  echo -e "${CYAN}  Infra change?${RESET} -> ${GREEN}19${RESET}"
  echo -e "${CYAN}  Restart only?${RESET} -> ${GREEN}20${RESET}"
  echo ""
  echo " 18) rebuild + deploy order-api"
  echo " 19) deploy order-api (helm only)"
  echo " 20) restart order-api"

  section "Deployment (HELM - order-admin)"
  echo -e "${CYAN}  Image change?${RESET} -> ${GREEN}21${RESET}"
  echo -e "${CYAN}  Infra change?${RESET} -> ${GREEN}22${RESET}"
  echo -e "${CYAN}  Restart only?${RESET} -> ${GREEN}23${RESET}"
  echo ""
  echo " 21) rebuild + deploy order-admin"
  echo " 22) deploy order-admin (helm only)"
  echo " 23) restart order-admin"

  section "Security"
  hint "Vault + secrets"
  echo " 24) show vault creds"
  echo " 25) vault status"
  echo " 26) unseal vault"

  section "Ingress"
  hint "Traffic + rate limiting"
  echo " 27) enable rate limit"
  echo " 28) disable rate limit"
  echo " 29) set custom rps"
  echo " 30) show ingress"
  echo " 31) watch 429s"
  echo " 32) helm info"
  echo " 33) helm rollback"

  section "Maintenance"
  hint "Cleanup and destructive admin actions"
  echo " 34) cleanup VPS"
  echo -e "${RED} 35) remove service (full cleanup)${RESET}"

  echo ""
  echo -e "${RED} 36) Exit${RESET}"
  echo ""
}

main() {
  require_commands

  while true; do
    local choice
    local pod_name
    local replicas
    local rps
    local rev
    local service

    show_menu
    read -r -p "Choose option: " choice

    case "$choice" in
      1) watch -n1 "kubectl top pod | egrep 'order-api|order-admin|postgres|redis'" ;;
      2) kubectl get pods -o wide; pause ;;
      3) watch kubectl get pods ;;
      4) kubectl get hpa; pause ;;
      5) watch kubectl get hpa,pods ;;
      6) kubectl top node; pause ;;

      7) kubectl exec -it deployment/order-api -c order-api -- /bin/sh ;;
      8) kubectl exec -it deployment/order-admin -- /bin/sh ;;
      9)
        pod_name="$(require_pod_name postgres)" || { pause; continue; }
        kubectl exec -it "$pod_name" -- psql -U orders -d ordersdb
        ;;

      10) kubectl logs -l app=order-api --tail=50; pause ;;
      11) kubectl logs -l app=postgres --tail=50; pause ;;
      12)
        pod_name="$(require_pod_name order-api)" || { pause; continue; }
        kubectl describe pod "$pod_name"
        pause
        ;;

      13)
        pod_name="$(require_pod_name postgres)" || { pause; continue; }
        kubectl exec -it "$pod_name" -- psql -U orders -d ordersdb -c "SELECT COUNT(*) FROM orders;"
        pause
        ;;
      14)
        if ! confirm_action "Truncate the orders table and reset IDs?"; then
          warn "Truncate cancelled."
          pause
          continue
        fi
        pod_name="$(require_pod_name postgres)" || { pause; continue; }
        kubectl exec -it "$pod_name" -- psql -U orders -d ordersdb -c "TRUNCATE TABLE orders RESTART IDENTITY;"
        pause
        ;;

      15)
        curl -X POST https://orders.franciskelly.ie/build \
          -H "Content-Type: application/json" \
          -d '{"email":"test@test.com","cpu":"1","gpu":"1","ram":"1"}'
        pause
        ;;

      16)
        read -r -p "Replicas: " replicas
        validate_positive_integer "$replicas" "Replica count" || { pause; continue; }
        kubectl scale deployment order-api --replicas="$replicas"
        pause
        ;;
      17)
        read -r -p "Replicas (1-5): " replicas
        validate_positive_integer "$replicas" "Replica count" || { pause; continue; }
        if [ "$replicas" -gt 5 ]; then
          error "Quick scale only allows values from 1 to 5."
          pause
          continue
        fi
        kubectl scale deployment order-api --replicas="$replicas"
        pause
        ;;

      18)
        run_step "Rebuilding order-api image" sudo docker build -t order-api:latest "$APPS_DIR/order-api" || { pause; continue; }
        run_shell_step "Importing image into k3s" "sudo docker save order-api:latest | sudo k3s ctr images import -" || { pause; continue; }
        run_step "Deploying chart" helm upgrade --install order-api "$CHARTS_DIR/order-api" || { pause; continue; }
        kubectl rollout status deployment/order-api
        pause
        ;;
      19)
        run_step "Helm deploy (no rebuild)" helm upgrade --install order-api "$CHARTS_DIR/order-api"
        pause
        ;;
      20)
        run_step "Restarting order-api" kubectl rollout restart deployment/order-api
        pause
        ;;

      21)
        run_step "Rebuilding order-admin image" sudo docker build -t order-admin:latest "$APPS_DIR/order-admin" || { pause; continue; }
        run_shell_step "Importing image into k3s" "sudo docker save order-admin:latest | sudo k3s ctr images import -" || { pause; continue; }
        run_step "Deploying chart" helm upgrade --install order-admin "$CHARTS_DIR/order-admin" || { pause; continue; }
        kubectl rollout status deployment/order-admin
        pause
        ;;
      22)
        run_step "Helm deploy order-admin" helm upgrade --install order-admin "$CHARTS_DIR/order-admin"
        pause
        ;;
      23)
        run_step "Restarting order-admin" kubectl rollout restart deployment/order-admin
        pause
        ;;

      24)
        kubectl exec -it deployment/order-api -c order-api -- cat /vault/secrets/db-creds
        pause
        ;;
      25)
        kubectl exec -it vault-0 -n vault -- env VAULT_ADDR=http://127.0.0.1:8200 vault status
        pause
        ;;
      26)
        for i in 1 2 3; do
          kubectl exec -it vault-0 -n vault -- env VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal || break
        done
        pause
        ;;

      27)
        helm upgrade --install order-api "$CHARTS_DIR/order-api" --set ingress.rateLimit.enabled=true
        pause
        ;;
      28)
        helm upgrade --install order-api "$CHARTS_DIR/order-api" --set ingress.rateLimit.enabled=false
        pause
        ;;
      29)
        read -r -p "RPS: " rps
        validate_positive_integer "$rps" "RPS" || { pause; continue; }
        helm upgrade --install order-api "$CHARTS_DIR/order-api" \
          --set ingress.rateLimit.enabled=true \
          --set ingress.rateLimit.rps="$rps"
        pause
        ;;
      30)
        kubectl get ingress order-api-ingress -o yaml
        pause
        ;;
      31)
        kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx -f | grep 429
        ;;
      32)
        if ! command -v jq >/dev/null 2>&1; then
          error "jq is required for this option."
          pause
          continue
        fi
        helm get values order-api --all -o json | jq '.ingress.rateLimit'
        pause
        ;;
      33)
        helm history order-api
        read -r -p "Revision: " rev
        validate_positive_integer "$rev" "Revision" || { pause; continue; }
        helm rollback order-api "$rev"
        pause
        ;;

      34)
        cleanup_vps
        pause
        ;;
      35)
        read -r -p "Service name to remove: " service
        validate_service_name "$service" || { pause; continue; }

        echo ""
        warn "This will remove Helm resources, Kubernetes resources, app/chart folders, and images for '$service'."
        if ! confirm_action "Continue with full cleanup"; then
          warn "Full cleanup cancelled."
          pause
          continue
        fi

        run_shell_step "Removing Helm release" "helm uninstall \"$service\" 2>/dev/null || echo \"No Helm release found\""
        run_shell_step "Deleting Kubernetes resources" "kubectl delete all -l app=\"$service\" 2>/dev/null || true"

        log "Removing app + chart folders..."
        safe_remove_dir "$APPS_DIR/$service" || { pause; continue; }
        safe_remove_dir "$CHARTS_DIR/$service" || { pause; continue; }

        run_shell_step "Removing image from k3s" "sudo k3s ctr images rm \"docker.io/library/$service:latest\" 2>/dev/null || true"
        run_shell_step "Removing local Docker image" "docker rmi \"$service:latest\" 2>/dev/null || true"

        success "Service '$service' fully removed."
        pause
        ;;

      36)
        success "Goodbye."
        exit 0
        ;;
      *)
        error "Invalid option."
        pause
        ;;
    esac
  done
}

main "$@"
