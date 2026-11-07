#!/bin/bash

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RBAC_OPERATOR_DIR="$BASE_DIR/rbac-operator"

echo ""
echo "=========================================="
echo "  DEPLOYMENT RBAC OPERATOR"
echo "=========================================="
echo ""

# Configurazione kubeconfig
if [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
elif [ -f /etc/rancher/k3s/k3s.yaml_backup ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml_backup
else
    echo -e "${RED}ERROR: kubeconfig not found${NC}"
    exit 1
fi

# Verificare che il repository rbac-operator esista
# (the operator sources are not part of this repository: set RBAC_OPERATOR_REPO to a git URL to clone them)
if [ ! -f "$RBAC_OPERATOR_DIR/Makefile" ]; then
    if [ -n "${RBAC_OPERATOR_REPO:-}" ]; then
        rm -rf "$RBAC_OPERATOR_DIR"
        git clone "$RBAC_OPERATOR_REPO" "$RBAC_OPERATOR_DIR" || exit 1
    else
        echo -e "${RED}ERROR: rbac-operator sources not found in $RBAC_OPERATOR_DIR (set RBAC_OPERATOR_REPO=<git url>)${NC}"
        exit 1
    fi
fi

cd "$RBAC_OPERATOR_DIR"

# 1. Installare CRDs
echo "1. Installazione CRDs RBAC Operator..."
make install || {
    echo -e "${YELLOW}⚠️  Make install fallito, provo installazione diretta CRD...${NC}"
    kubectl apply -f config/crd/bases/s4t.s4t.io_projects.yaml || {
        echo -e "${RED}ERROR: Impossibile installare CRD${NC}"
        exit 1
    }
}
echo -e "${GREEN}✔ CRDs installate${NC}"

# 2. Build e push immagine (se necessario)
echo "2. Build immagine RBAC Operator..."
if command -v docker &> /dev/null; then
    IMG="${IMG:-localhost:5000/s4t-rbac-operator:latest}"
    echo "Building image: $IMG"
    make docker-build IMG="$IMG" || {
        echo -e "${YELLOW}⚠️  Build Docker fallito, uso immagine pre-esistente${NC}"
    }
    
    # Se abbiamo un registry locale, push
    if echo "$IMG" | grep -q "localhost:5000"; then
        make docker-push IMG="$IMG" || echo -e "${YELLOW}⚠️  Push fallito (registry locale potrebbe non essere disponibile)${NC}"
    fi
else
    echo -e "${YELLOW}⚠️  Docker non disponibile, uso immagine pre-esistente${NC}"
    IMG="${IMG:-quay.io/s4t/rbac-operator:latest}"
fi

# 3. Deploy RBAC Operator
echo "3. Deploy RBAC Operator..."
if [ -f "dist/install.yaml" ]; then
    # Usa il bundle pre-generato se disponibile
    kubectl apply -f dist/install.yaml
else
    # Altrimenti usa make deploy
    make deploy IMG="${IMG:-localhost:5000/s4t-rbac-operator:latest}" || {
        echo -e "${YELLOW}⚠️  Make deploy fallito, provo deploy manuale...${NC}"
        # Deploy manuale
        kubectl apply -f config/rbac/ || true
        kubectl apply -f config/manager/ || true
        kubectl apply -f config/webhook/ || true
    }
fi

# 4. Attendere che l'operator sia ready
echo "4. Attesa RBAC Operator ready..."
kubectl wait --for=condition=available deployment/s4t-rbac-operator-controller-manager -n s4t-rbac-operator-system --timeout=300s || {
    echo -e "${YELLOW}⚠️  Timeout attesa operator, verificare manualmente${NC}"
}

# 5. Creare ClusterRole e ClusterRoleBinding per project-creator
echo "5. Creazione ClusterRole per project-creator..."
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: s4t-project-creator
rules:
- apiGroups: ["s4t.s4t.io"]
  resources: ["projects"]
  verbs: ["create","get","patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: s4t-project-creator-binding
subjects:
- kind: Group
  name: s4t:project-creator
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: s4t-project-creator
  apiGroup: rbac.authorization.k8s.io
EOF

echo -e "${GREEN}✔ ClusterRole e ClusterRoleBinding creati${NC}"

echo ""
echo "=========================================="
echo -e "${GREEN}✅ RBAC OPERATOR DEPLOYATO!${NC}"
echo "=========================================="
echo ""
echo "Per verificare lo stato:"
echo "  kubectl get pods -n s4t-rbac-operator-system"
echo "  kubectl get projects.s4t.s4t.io"
echo ""
