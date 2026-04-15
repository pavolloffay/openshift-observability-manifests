#!/bin/bash
# Install the opensearch-k8s-operator on OpenShift via Helm.
#
# The operator is NOT available in OperatorHub (redhat-operators or community-operators).
# The project publishes OLM bundle files but no pre-built catalog image,
# so Helm is the primary supported installation method.
#
# See: https://github.com/opensearch-project/opensearch-k8s-operator

set -euo pipefail

# The operator requires cert-manager for TLS certificate management.
echo "Installing cert-manager..."
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.17.2/cert-manager.yaml
kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=120s

echo "Installing opensearch-k8s-operator..."
helm repo add opensearch-operator https://opensearch-project.github.io/opensearch-k8s-operator/
helm repo update

oc create namespace opensearch-operator --dry-run=client -o yaml | oc apply -f -

helm upgrade --install opensearch-operator opensearch-operator/opensearch-operator \
  --namespace opensearch-operator \
  --wait
