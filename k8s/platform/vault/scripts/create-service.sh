#!/bin/bash
set -e

SERVICE=$1

if [ -z "$SERVICE" ]; then
  echo "Usage: ./create-service.sh <service-name>"
  exit 1
fi

echo "Configuring Vault for service: $SERVICE"

echo "Generating policy..."
sed "s/{{SERVICE}}/$SERVICE/g" vault/policies/service-policy.hcl > /tmp/$SERVICE-policy.hcl

echo "Uploading policy to Vault..."
cat /tmp/$SERVICE-policy.hcl | \
kubectl exec -i vault-0 -n vault -- vault policy write $SERVICE -

rm /tmp/$SERVICE-policy.hcl

echo "Policy created"

echo "Creating Kubernetes auth role..."
kubectl exec vault-0 -n vault -- vault write auth/kubernetes/role/$SERVICE \
  bound_service_account_names=$SERVICE \
  bound_service_account_namespaces=default \
  policies=$SERVICE \
  ttl=24h

echo "Kubernetes auth role created"

echo "Creating database role..."
kubectl exec vault-0 -n vault -- vault write database/roles/$SERVICE-role \
  db_name=orders-db \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT app_role TO \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="24h"

echo "Database role created"

echo "Vault onboarding complete for $SERVICE"
