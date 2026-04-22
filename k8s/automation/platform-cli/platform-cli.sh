#!/bin/bash
set -e

COMMAND=$1
SERVICE=$2
FLAG=$3

if [ "$COMMAND" != "create-service" ]; then
  echo "Usage:"
  echo "platform-cli create-service <service-name> [--database]"
  exit 1
fi

if [ -z "$SERVICE" ]; then
  echo "Service name required"
  exit 1
fi

echo "Creating service configuration for: $SERVICE"

# Generate Vault policy
sed "s/{{SERVICE}}/$SERVICE/g" vault/policies/service-policy.hcl > /tmp/$SERVICE-policy.hcl

echo "Uploading Vault policy..."

cat /tmp/$SERVICE-policy.hcl | \
kubectl exec -i vault-0 -n vault -- vault policy write $SERVICE -

rm /tmp/$SERVICE-policy.hcl

echo "Vault policy created"

# Create Kubernetes auth role
echo "Creating Kubernetes auth role..."

kubectl exec vault-0 -n vault -- vault write auth/kubernetes/role/$SERVICE \
  bound_service_account_names=$SERVICE \
  bound_service_account_namespaces=default \
  policies=$SERVICE \
  ttl=24h

echo "Kubernetes auth role created"

# Optional database role
if [ "$FLAG" == "--database" ]; then

  echo "Configuring database role..."

  kubectl exec vault-0 -n vault -- vault write database/roles/$SERVICE-role \
    db_name=orders-db \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT app_role TO \"{{name}}\";" \
    default_ttl="1h" \
    max_ttl="24h"

  echo "Database role created"

fi

echo "Service onboarding complete: $SERVICE"
