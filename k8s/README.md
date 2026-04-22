# Kubernetes Observability & Autoscaling Platform

A production-style Kubernetes platform demonstrating observability, security, and intelligent autoscaling using real-world tools.

## 🚀 Features

- SLO-based autoscaling using KEDA
- Full observability stack (Prometheus, Grafana, Loki)
- Secure secrets management with HashiCorp Vault
- Ingress rate limiting & traffic control (NGINX)
- Threat detection with CrowdSec
- Microservices architecture (Flask-based APIs)

## 🏗 Architecture

- Kubernetes (k3s)
- Helm-based deployments
- PostgreSQL & Redis backend
- OpenTelemetry integration

## 📊 Observability Stack

- Prometheus → Metrics
- Grafana → Dashboards
- Loki → Logs

## 🔐 Security

- Vault dynamic secrets
- CrowdSec threat detection
- Ingress-level rate limiting

## 📁 Project Structure

- `apps/` → Microservices
- `charts/` → Helm charts
- `platform/` → Infrastructure components
- `automation/` → Internal tooling
- `configs/` → Alerts & configs

## 📸 Demo

See poster / results section for:
- SLO availability tracking
- Autoscaling behaviour under load
- Rate limiting in action
