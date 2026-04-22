#!/bin/bash
# =============================================================================
# vault-bootstrap.sh
# Restores all Vault configuration after a reboot or restart.
#
# Run this whenever Vault loses its runtime configuration:
#   chmod +x ~/k8s/vault-bootstrap.sh
#   ~/k8s/vault-bootstrap.sh
#
# What this script configures:
#   - Kubernetes auth backend
#   - Vault policies for order-api and order-admin
#   - Kubernetes auth roles for order-api and order-admin
#   - Database secrets engine connection to PostgreSQL
#   - Database roles for dynamic credential generation
# =============================================================================

set -e

# --------------------------------------------------------------------------
# Colours
# --------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()     { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
header() { echo -e "\n${BOLD}$*${RESET}"; }

# Resolve script directory so paths work regardless of where script is called from
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLATFORM_CLI="$SCRIPT_DIR/platform-cli/platform-cli"

VAULT_POD="vault-0"
VAULT_NS="vault"
VAULT_EXEC="kubectl exec -i ${VAULT_POD} -n ${VAULT_NS} --"

# --------------------------------------------------------------------------
# Check Vault is reachable and unsealed
# --------------------------------------------------------------------------
header "============================================================"
header "  Vault Bootstrap"
header "============================================================"

log "Checking Vault pod is running..."
kubectl get pod ${VAULT_POD} -n ${VAULT_NS} > /dev/null 2>&1 || \
  error "Vault pod ${VAULT_POD} not found in namespace ${VAULT_NS}"

log "Waiting for Vault API to be ready..."
for i in {1..30}; do
  if kubectl exec ${VAULT_POD} -n ${VAULT_NS} -- vault status > /dev/null 2>&1; then
    ok "Vault API is responding"
    break
  fi
  sleep 2
done

if ! kubectl exec ${VAULT_POD} -n ${VAULT_NS} -- vault status > /dev/null 2>&1; then
  error "Vault API did not become ready after 60 seconds"
fi

log "Checking Vault is unsealed..."
VAULT_STATUS=$(kubectl exec ${VAULT_POD} -n ${VAULT_NS} -- vault status 2>/dev/null | grep "Sealed" | awk '{print $2}')
if [[ "$VAULT_STATUS" == "true" ]]; then
  error "Vault is sealed. Unseal it first then re-run this script."
fi
ok "Vault is running and unsealed"

# ==========================================================================
# 1. KUBERNETES AUTH BACKEND
# ==========================================================================
header "1. Kubernetes Auth Backend"

log "Enabling Kubernetes auth backend..."
${VAULT_EXEC} vault auth enable kubernetes 2>/dev/null || \
  warn "Kubernetes auth already enabled — skipping"

# Pull cluster address dynamically — no hardcoded IP
K8S_HOST=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
log "Kubernetes API host: ${K8S_HOST}"

log "Configuring Kubernetes auth..."
${VAULT_EXEC} vault write auth/kubernetes/config \
  token_reviewer_jwt="$(kubectl exec ${VAULT_POD} -n ${VAULT_NS} -- \
    cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
  kubernetes_host="${K8S_HOST}" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
ok "Kubernetes auth configured"

# ==========================================================================
# 2. VAULT POLICIES + ROLES (via platform-cli)
# ==========================================================================
header "2. Service Policies and Roles"

if [[ -x "$PLATFORM_CLI" ]]; then
  log "Using platform-cli to onboard services..."
  $PLATFORM_CLI create-service order-api --database
  $PLATFORM_CLI create-service order-admin --database
else
  warn "platform-cli not found at $PLATFORM_CLI — creating policies and roles manually"

  log "Writing policy for order-api..."
  cat <<EOF | ${VAULT_EXEC} vault policy write order-api -
path "database/creds/order-api-role" {
  capabilities = ["read"]
}
EOF
  ok "order-api policy created"

  log "Writing policy for order-admin..."
  cat <<EOF | ${VAULT_EXEC} vault policy write order-admin -
path "database/creds/order-admin-role" {
  capabilities = ["read"]
}
EOF
  ok "order-admin policy created"

  log "Creating Kubernetes auth role for order-api..."
  ${VAULT_EXEC} vault write auth/kubernetes/role/order-api \
    bound_service_account_names=order-api \
    bound_service_account_namespaces=default \
    policies=order-api \
    ttl=24h
  ok "order-api Kubernetes auth role created"

  log "Creating Kubernetes auth role for order-admin..."
  ${VAULT_EXEC} vault write auth/kubernetes/role/order-admin \
    bound_service_account_names=order-admin \
    bound_service_account_namespaces=default \
    policies=order-admin \
    ttl=24h
  ok "order-admin Kubernetes auth role created"
fi

# ==========================================================================
# 3. DATABASE SECRETS ENGINE
# ==========================================================================
header "3. Database Secrets Engine"

log "Enabling database secrets engine..."
${VAULT_EXEC} vault secrets enable database 2>/dev/null || \
  warn "Database secrets engine already enabled — skipping"

log "Configuring PostgreSQL connection..."
${VAULT_EXEC} vault write database/config/orders-db \
  plugin_name=postgresql-database-plugin \
  allowed_roles="orders-role,order-api-role,order-admin-role" \
  connection_url="postgresql://{{username}}:{{password}}@postgres.default.svc.cluster.local:5432/ordersdb?sslmode=disable" \
  username="orders" \
  password='Shamrock23$'
ok "PostgreSQL connection configured"

# ==========================================================================
# 4. DATABASE ROLES
# ==========================================================================
header "4. Database Roles"

log "Creating database role for order-api..."
${VAULT_EXEC} vault write database/roles/order-api-role \
  db_name=orders-db \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT app_role TO \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="24h"
ok "order-api database role created"

log "Creating database role for order-admin..."
${VAULT_EXEC} vault write database/roles/order-admin-role \
  db_name=orders-db \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT app_role TO \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="24h"
ok "order-admin database role created"

log "Creating legacy orders-role..."
${VAULT_EXEC} vault write database/roles/orders-role \
  db_name=orders-db \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT app_role TO \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="24h"
ok "orders-role created"

# ==========================================================================
# 5. VERIFY
# ==========================================================================
header "5. Verification"

log "Testing dynamic credential generation for order-api..."
${VAULT_EXEC} vault read -field=username database/creds/order-api-role > /dev/null && \
  ok "order-api dynamic credentials working" || \
  warn "order-api credential test failed — check database connection"

log "Testing dynamic credential generation for order-admin..."
${VAULT_EXEC} vault read -field=username database/creds/order-admin-role > /dev/null && \
  ok "order-admin dynamic credentials working" || \
  warn "order-admin credential test failed — check database connection"

# ==========================================================================
# 6. RESTART PODS
# ==========================================================================
header "6. Restarting Application Pods"

log "Restarting order-api..."
kubectl rollout restart deployment -l app=order-api
log "Restarting order-admin..."
kubectl rollout restart deployment -l app=order-admin

log "Waiting for rollouts to complete..."
kubectl rollout status deployment -l app=order-api --timeout=120s || \
  warn "order-api rollout timed out — check: kubectl get pods -l app=order-api"
kubectl rollout status deployment -l app=order-admin --timeout=120s || \
  warn "order-admin rollout timed out — check: kubectl get pods -l app=order-admin"

# ==========================================================================
# SUMMARY
# ==========================================================================
header "✅ Vault bootstrap complete"
echo ""
echo -e "  Kubernetes auth backend  ${GREEN}configured${RESET}"
echo -e "  Policies                 ${GREEN}order-api, order-admin${RESET}"
echo -e "  Kubernetes auth roles    ${GREEN}order-api, order-admin${RESET}"
echo -e "  Database engine          ${GREEN}configured${RESET}"
echo -e "  Database roles           ${GREEN}order-api-role, order-admin-role${RESET}"
echo -e "  Pods restarted           ${GREEN}order-api, order-admin${RESET}"
echo ""
echo -e "  Verify pods are running:"
echo -e "  ${CYAN}kubectl get pods -l app=order-api${RESET}"
echo -e "  ${CYAN}kubectl get pods -l app=order-admin${RESET}"
echo ""
