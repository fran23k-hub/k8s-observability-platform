#!/bin/bash

set -euo pipefail

# =========================================================
# PATH SETUP
# =========================================================
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
BASE_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
K8S_ROOT="$(cd "$BASE_DIR/../.." && pwd)"

APPS_DIR="$K8S_ROOT/apps"
CHARTS_DIR="$K8S_ROOT/charts"
VAULT_HELPER="$BASE_DIR/vault_db.py"

# =========================================================
# LOGGING
# =========================================================
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

log()  { echo -e "${CYAN}[INFO]${RESET} $*"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
err()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# =========================================================
# HELPERS
# =========================================================
require_commands() {
  local missing=()
  local cmd

  for cmd in docker helm kubectl sudo readlink; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    err "Missing required commands: ${missing[*]}"
  fi
}

validate_service_name() {
  local service="$1"

  if [[ -z "$service" ]]; then
    err "Service required"
  fi

  if [[ ! "$service" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    err "Invalid service name"
  fi

  return 0
}

validate_namespace() {
  local namespace="$1"

  if [[ -z "$namespace" ]]; then
    err "Namespace required"
  fi

  if [[ ! "$namespace" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    err "Invalid namespace"
  fi

  return 0
}

normalize_yes_no() {
  local value
  value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"

  case "$value" in
    y|yes) echo "y" ;;
    n|no) echo "n" ;;
    *) err "Answer y or n" ;;
  esac
}

ensure_dir() {
  mkdir -p "$1"
}

confirm() {
  local prompt="$1"
  local answer
  read -r -p "$prompt (y/n): " answer
  answer="$(normalize_yes_no "$answer")"
  [[ "$answer" = "y" ]]
}

write_file() {
  local target="$1"
  cat > "$target"
}

guard_existing_service() {
  local app_exists="n"
  local chart_exists="n"

  [ -d "$APP_DIR" ] && app_exists="y"
  [ -d "$CHART_DIR" ] && chart_exists="y"

  if [ "$app_exists" = "y" ] || [ "$chart_exists" = "y" ]; then
    warn "Existing service files detected."
    echo "  App dir:   $APP_DIR $( [ "$app_exists" = "y" ] && echo "(exists)" || echo "(new)" )"
    echo "  Chart dir: $CHART_DIR $( [ "$chart_exists" = "y" ] && echo "(exists)" || echo "(new)" )"
    echo ""
    warn "Running this generator will overwrite scaffold files for this service."

    if ! confirm "Continue and overwrite generated files for '$SERVICE'?"; then
      err "Cancelled to avoid overwriting existing service."
    fi
  fi
}

cleanup_failed_deploy() {
  warn "Cleaning up failed deployment artifacts..."

  helm uninstall "$SERVICE" -n "$NAMESPACE" >/dev/null 2>&1 || true
  kubectl delete deployment "$SERVICE" -n "$NAMESPACE" >/dev/null 2>&1 || true
  kubectl delete service "$SERVICE" -n "$NAMESPACE" >/dev/null 2>&1 || true
  kubectl delete ingress "$SERVICE" -n "$NAMESPACE" >/dev/null 2>&1 || true
  kubectl delete scaledobject "${SERVICE}-scaling" -n "$NAMESPACE" >/dev/null 2>&1 || true
  kubectl delete serviceaccount "$SERVICE" -n "$NAMESPACE" >/dev/null 2>&1 || true

  docker rmi "$SERVICE:$VERSION" >/dev/null 2>&1 || true
  sudo k3s ctr images rm "docker.io/library/$SERVICE:$VERSION" >/dev/null 2>&1 || true

  ok "Failed Kubernetes release and image artifacts cleaned up."
  warn "Scaffold files were kept:"
  echo "  App dir:   $APP_DIR"
  echo "  Chart dir: $CHART_DIR"
}

handle_rollout_failure() {
  echo ""
  warn "Rollout failed for service '$SERVICE' in namespace '$NAMESPACE'."
  echo "Version: $VERSION"
  echo "App dir: $APP_DIR"
  echo "Chart dir: $CHART_DIR"
  echo ""
  warn "Common next checks:"
  echo "  kubectl get pods -n $NAMESPACE -l app=$SERVICE"
  echo "  kubectl describe deployment/$SERVICE -n $NAMESPACE"
  echo "  kubectl logs -n $NAMESPACE -l app=$SERVICE --tail=100"
  echo ""

  if confirm "Do you want to clean up the failed Helm release and built image now?"; then
    cleanup_failed_deploy
  else
    warn "Leaving files, image, and cluster resources in place for debugging."
  fi

  exit 1
}

# =========================================================
# INPUT
# =========================================================
require_commands

echo -e "${BOLD}=== New Service ===${RESET}"

read -r -p "Service name: " SERVICE
validate_service_name "$SERVICE"

read -r -p "Namespace (default: default): " NAMESPACE
NAMESPACE="${NAMESPACE:-default}"
validate_namespace "$NAMESPACE"

read -r -p "Use database? (y/n): " USE_DB
USE_DB="$(normalize_yes_no "$USE_DB")"

read -r -p "Enable ingress? (y/n): " USE_INGRESS
USE_INGRESS="$(normalize_yes_no "$USE_INGRESS")"

read -r -p "Create ServiceAccount? (y/n): " USE_SERVICE_ACCOUNT
USE_SERVICE_ACCOUNT="$(normalize_yes_no "$USE_SERVICE_ACCOUNT")"

APP_DIR="$APPS_DIR/$SERVICE"
CHART_DIR="$CHARTS_DIR/$SERVICE"

DB_NAME=""
if [ "$USE_DB" = "y" ]; then
  read -r -p "Database name (default: ${SERVICE}-db): " DB_NAME
  DB_NAME="${DB_NAME:-${SERVICE}-db}"
fi

VERSION="$(date +%s)"

guard_existing_service

# =========================================================
# CREATE NAMESPACE
# =========================================================
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  log "Creating namespace $NAMESPACE"
  kubectl create namespace "$NAMESPACE"
fi

# =========================================================
# CREATE APP
# =========================================================
log "Creating app scaffold"
ensure_dir "$APP_DIR"

write_file "$APP_DIR/app.py" <<EOF
from flask import Flask, Response, request
from prometheus_client import Counter, generate_latest

app = Flask(__name__)

REQUESTS = Counter(
    "http_requests_total",
    "Total HTTP Requests",
    ["app", "status"],
)

@app.after_request
def track(response):
    if request.path != "/metrics":
        REQUESTS.labels(app="$SERVICE", status=str(response.status_code)).inc()
    return response

@app.route("/")
def home():
    return {"message": "$SERVICE running"}

@app.route("/health")
def health():
    return {"status": "ok"}

@app.route("/fail")
def fail():
    return {"error": "forced failure"}, 500

@app.route("/metrics")
def metrics():
    return Response(generate_latest(), mimetype="text/plain")
EOF

write_file "$APP_DIR/requirements.txt" <<EOF
flask
gunicorn
prometheus_client
EOF

if [ "$USE_DB" = "y" ]; then
  echo "psycopg2-binary" >> "$APP_DIR/requirements.txt"

  if [ -f "$VAULT_HELPER" ]; then
    cp -f "$VAULT_HELPER" "$APP_DIR/"
    ok "Copied vault_db.py"
  else
    warn "vault_db.py not found at $VAULT_HELPER"
  fi
fi

write_file "$APP_DIR/Dockerfile" <<EOF
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

CMD ["gunicorn", "app:app", "-w", "1", "-k", "gthread", "--threads", "4", "-b", "0.0.0.0:5000"]
EOF

# =========================================================
# HELM CHART
# =========================================================
log "Creating Helm chart scaffold"
ensure_dir "$CHART_DIR/templates"

write_file "$CHART_DIR/Chart.yaml" <<EOF
apiVersion: v2
name: $SERVICE
version: 0.1.0
appVersion: "$VERSION"
EOF

write_file "$CHART_DIR/values.yaml" <<EOF
name: $SERVICE
namespace: $NAMESPACE

replicaCount: 1

image:
  repository: $SERVICE
  tag: "$VERSION"
  pullPolicy: Never

serviceAccount:
  enabled: $([ "$USE_SERVICE_ACCOUNT" = "y" ] && echo true || echo false)
  name: $SERVICE

service:
  type: ClusterIP
  port: 80
  targetPort: 5000

ingress:
  enabled: $([ "$USE_INGRESS" = "y" ] && echo true || echo false)
  className: nginx
  host: $SERVICE.franciskelly.ie

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi

keda:
  enabled: true
  minReplicas: 1
  maxReplicas: 5
  cpuTarget: 80
  errorThreshold: 0.01
  prometheusServer: http://prometheus-operated.monitoring.svc:9090

env:
EOF

if [ "$USE_DB" = "y" ]; then
  cat >> "$CHART_DIR/values.yaml" <<EOF
  DB_HOST: postgres.default.svc.cluster.local
  DB_NAME: $DB_NAME
EOF
fi

write_file "$CHART_DIR/templates/deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Values.name }}
  namespace: {{ .Values.namespace }}
  labels:
    app: {{ .Values.name }}
    app.kubernetes.io/name: {{ .Values.name }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Values.name }}
      app.kubernetes.io/name: {{ .Values.name }}
  template:
    metadata:
      labels:
        app: {{ .Values.name }}
        app.kubernetes.io/name: {{ .Values.name }}
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "{{ .Values.service.targetPort }}"
        prometheus.io/path: "/metrics"
    spec:
      {{- if .Values.serviceAccount.enabled }}
      serviceAccountName: {{ .Values.serviceAccount.name }}
      {{- end }}
      containers:
      - name: {{ .Values.name }}
        image: {{ .Values.image.repository }}:{{ .Values.image.tag }}
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        ports:
        - containerPort: {{ .Values.service.targetPort }}
        livenessProbe:
          httpGet:
            path: /health
            port: {{ .Values.service.targetPort }}
          initialDelaySeconds: 10
          periodSeconds: 10
          timeoutSeconds: 2
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /health
            port: {{ .Values.service.targetPort }}
          initialDelaySeconds: 5
          periodSeconds: 10
          timeoutSeconds: 2
          failureThreshold: 3
        resources:
{{ toYaml .Values.resources | indent 10 }}
EOF

if [ "$USE_DB" = "y" ]; then
  cat >> "$CHART_DIR/templates/deployment.yaml" <<EOF
        env:
        - name: DB_HOST
          value: "{{ .Values.env.DB_HOST }}"
        - name: DB_NAME
          value: "{{ .Values.env.DB_NAME }}"
EOF
fi

write_file "$CHART_DIR/templates/service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: {{ .Values.name }}
  namespace: {{ .Values.namespace }}
  labels:
    app: {{ .Values.name }}
    app.kubernetes.io/name: {{ .Values.name }}
spec:
  type: {{ .Values.service.type }}
  selector:
    app: {{ .Values.name }}
    app.kubernetes.io/name: {{ .Values.name }}
  ports:
  - port: {{ .Values.service.port }}
    targetPort: {{ .Values.service.targetPort }}
EOF

write_file "$CHART_DIR/templates/serviceaccount.yaml" <<EOF
{{- if .Values.serviceAccount.enabled }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ .Values.serviceAccount.name }}
  namespace: {{ .Values.namespace }}
{{- end }}
EOF

write_file "$CHART_DIR/templates/ingress.yaml" <<EOF
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .Values.name }}
  namespace: {{ .Values.namespace }}
  labels:
    app: {{ .Values.name }}
    app.kubernetes.io/name: {{ .Values.name }}
spec:
  ingressClassName: {{ .Values.ingress.className }}
  rules:
  - host: {{ .Values.ingress.host }}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: {{ .Values.name }}
            port:
              number: {{ .Values.service.port }}
{{- end }}
EOF

write_file "$CHART_DIR/templates/keda.yaml" <<EOF
{{- if .Values.keda.enabled }}
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: {{ .Values.name }}-scaling
  namespace: {{ .Values.namespace }}
spec:
  scaleTargetRef:
    name: {{ .Values.name }}
  minReplicaCount: {{ .Values.keda.minReplicas }}
  maxReplicaCount: {{ .Values.keda.maxReplicas }}
  triggers:
  - type: cpu
    metricType: Utilization
    metadata:
      value: "{{ .Values.keda.cpuTarget }}"
  - type: prometheus
    metadata:
      serverAddress: {{ .Values.keda.prometheusServer | quote }}
      metricName: error_rate
      threshold: "{{ .Values.keda.errorThreshold }}"
      query: |
        sum(rate(http_requests_total{app="{{ .Values.name }}", status=~"5.."}[1m]))
        /
        clamp_min(sum(rate(http_requests_total{app="{{ .Values.name }}"}[1m])), 1)
{{- end }}
EOF

# =========================================================
# BUILD + DEPLOY
# =========================================================
log "Building image"
docker build -t "$SERVICE:$VERSION" "$APP_DIR"

log "Importing image into k3s"
docker save "$SERVICE:$VERSION" | sudo k3s ctr images import -

log "Deploying with Helm"
helm upgrade --install "$SERVICE" "$CHART_DIR" -n "$NAMESPACE"

log "Waiting for rollout"
if ! kubectl rollout status deployment/"$SERVICE" -n "$NAMESPACE" --timeout=180s; then
  handle_rollout_failure
fi

ok "Service deployed"
echo "Version: $VERSION"
echo "Namespace: $NAMESPACE"
echo "App dir: $APP_DIR"
echo "Chart dir: $CHART_DIR"
