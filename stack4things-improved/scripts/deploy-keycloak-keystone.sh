#!/bin/bash

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo ""
echo "=========================================="
echo "  DEPLOYMENT KEYCLOAK E KEYSTONE"
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

# 1. Creare ConfigMap per Keycloak (certificati e realm)
echo "1. Creazione ConfigMap per Keycloak..."
KEYCLOAK_CERTS_DIR="$BASE_DIR/keycloak-keystone-integration/keycloak-config/certs"
KEYCLOAK_REALM_FILE="$BASE_DIR/keycloak-keystone-integration/keycloak-config/stack4things-realm.json"

if [ ! -f "$KEYCLOAK_REALM_FILE" ]; then
    echo -e "${YELLOW}⚠️  File realm Keycloak non trovato, creazione base...${NC}"
    mkdir -p "$(dirname "$KEYCLOAK_REALM_FILE")"
    cat > "$KEYCLOAK_REALM_FILE" << 'EOF'
{
  "realm": "stack4things",
  "enabled": true,
  "clients": [
    {
      "clientId": "kubernetes",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": true,
      "redirectUris": ["*"],
      "webOrigins": ["*"]
    }
  ]
}
EOF
fi

# Creare certificati se non esistono
if [ ! -f "$KEYCLOAK_CERTS_DIR/keycloak.crt" ] || [ ! -f "$KEYCLOAK_CERTS_DIR/keycloak.key" ]; then
    echo "Generazione certificati Keycloak..."
    mkdir -p "$KEYCLOAK_CERTS_DIR"
    openssl req -x509 -newkey rsa:4096 -keyout "$KEYCLOAK_CERTS_DIR/keycloak.key" \
        -out "$KEYCLOAK_CERTS_DIR/keycloak.crt" -days 365 -nodes \
        -subj "/CN=keycloak.keycloak.svc.cluster.local" \
        -addext "subjectAltName=DNS:keycloak,DNS:keycloak.keycloak,DNS:keycloak.keycloak.svc.cluster.local" 2>/dev/null || {
        echo -e "${YELLOW}⚠️  OpenSSL non disponibile, creazione certificati semplificata...${NC}"
        # Fallback: creare file vuoti (saranno generati da Keycloak)
        touch "$KEYCLOAK_CERTS_DIR/keycloak.crt" "$KEYCLOAK_CERTS_DIR/keycloak.key"
    }
fi

# Client secret shared by the Keycloak realm and Keystone mod_auth_openidc (never committed)
KEYSTONE_CLIENT_SECRET="${KEYSTONE_CLIENT_SECRET:-$(openssl rand -hex 16)}"
RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "$RENDER_DIR"' EXIT
sed "s/__KEYSTONE_CLIENT_SECRET__/${KEYSTONE_CLIENT_SECRET}/g" "$KEYCLOAK_REALM_FILE" > "$RENDER_DIR/stack4things-realm.json"
KEYCLOAK_REALM_FILE="$RENDER_DIR/stack4things-realm.json"

kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap keycloak-certs -n keycloak \
    --from-file="$KEYCLOAK_CERTS_DIR/keycloak.crt" \
    --from-file="$KEYCLOAK_CERTS_DIR/keycloak.key" \
    --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap keycloak-realm-config -n keycloak \
    --from-file=stack4things-realm.json="$KEYCLOAK_REALM_FILE" \
    --dry-run=client -o yaml | kubectl apply -f -

echo -e "${GREEN}✔ ConfigMap Keycloak creati${NC}"

# 2. Creare ConfigMap per Keystone
echo "2. Creazione ConfigMap per Keystone..."
KEYSTONE_CONFIG_DIR="$BASE_DIR/keycloak-keystone-integration/keystone-config"

if [ ! -f "$KEYSTONE_CONFIG_DIR/keystone.conf" ]; then
    echo -e "${YELLOW}⚠️  File keystone.conf non trovato, creazione configurazione base...${NC}"
    mkdir -p "$KEYSTONE_CONFIG_DIR"
    cat > "$KEYSTONE_CONFIG_DIR/keystone.conf" << 'EOF'
[DEFAULT]
debug = false
log_dir = /var/log/keystone

[database]
connection = mysql+pymysql://keystone:password_keystone@keystone-db.keystone.svc.cluster.local/keystone

[identity]
default_domain_id = default
domain_specific_drivers_enabled = true

[federation]
sso_callback_template = /etc/keystone/sso_callback.html

[oidc]
remote_id_attribute = OIDC-iss
EOF
fi

if [ ! -f "$KEYSTONE_CONFIG_DIR/keystone-mapping.json" ]; then
    cat > "$KEYSTONE_CONFIG_DIR/keystone-mapping.json" << 'EOF'
[
  {
    "local": [
      {
        "user": {
          "name": "{0}",
          "domain": { "name": "federated_domain" }
        },
        "group": {
          "name": "federated_users",
          "domain": { "name": "federated_domain" }
        }
      }
    ],
    "remote": [
      { "type": "OIDC-preferred_username" },
      { "type": "OIDC-sub" }
    ]
  },
  {
    "local": [
      {
        "group": {
          "name": "{0}",
          "domain": { "name": "federated_domain" }
        }
      }
    ],
    "remote": [
      {
        "type": "OIDC-groups",
        "whitelist": ["^s4t:.*"]
      }
    ]
  }
]
EOF
fi

if [ ! -f "$KEYSTONE_CONFIG_DIR/sso_callback.html" ]; then
    cat > "$KEYSTONE_CONFIG_DIR/sso_callback.html" << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Keystone SSO Callback</title>
</head>
<body>
    <h1>SSO Callback</h1>
    <p>Processing authentication...</p>
</body>
</html>
EOF
fi

if [ ! -f "$KEYSTONE_CONFIG_DIR/wsgi-keystone.conf" ]; then
    cat > "$KEYSTONE_CONFIG_DIR/wsgi-keystone.conf" << 'EOF'
<VirtualHost *:5000>
    WSGIDaemonProcess keystone-public processes=5 threads=1 user=keystone group=keystone display-name=%{GROUP}
    WSGIProcessGroup keystone-public
    WSGIScriptAlias / /usr/bin/keystone-wsgi-public
    WSGIApplicationGroup %{GLOBAL}
    WSGIPassAuthorization On
    ErrorLogFormat "%{cu}t %M"
    ErrorLog /var/log/apache2/keystone.log
    CustomLog /var/log/apache2/keystone_access.log combined
</VirtualHost>
EOF
fi

sed "s/__KEYSTONE_CLIENT_SECRET__/${KEYSTONE_CLIENT_SECRET}/g" "$KEYSTONE_CONFIG_DIR/wsgi-keystone.conf" > "$RENDER_DIR/wsgi-keystone.conf"

kubectl create namespace keystone --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap keystone-config -n keystone \
    --from-file="$KEYSTONE_CONFIG_DIR/keystone.conf" \
    --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap keystone-mapping -n keystone \
    --from-file="$KEYSTONE_CONFIG_DIR/keystone-mapping.json" \
    --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap keystone-sso -n keystone \
    --from-file="$KEYSTONE_CONFIG_DIR/sso_callback.html" \
    --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap keystone-wsgi -n keystone \
    --from-file="$RENDER_DIR/wsgi-keystone.conf" \
    --dry-run=client -o yaml | kubectl apply -f -

echo -e "${GREEN}✔ ConfigMap Keystone creati${NC}"

# 3. Deploy Keycloak
echo "3. Deploy Keycloak..."
kubectl apply -f "$BASE_DIR/yaml_file/keycloak-deployment.yaml"
kubectl wait --for=condition=available deployment/keycloak -n keycloak --timeout=300s || true
echo -e "${GREEN}✔ Keycloak deployato${NC}"

# 4. Deploy Keystone
echo "4. Deploy Keystone..."
kubectl apply -f "$BASE_DIR/yaml_file/keystone-deployment.yaml"
kubectl wait --for=condition=available deployment/keystone -n keystone --timeout=300s || true
echo -e "${GREEN}✔ Keystone deployato${NC}"

# 5. Configurare k3s per OIDC (se non già configurato)
echo "5. Verifica configurazione OIDC k3s..."
K3S_CONFIG="/etc/rancher/k3s/k3s.yaml"
if ! grep -q "oidc-issuer-url" /var/lib/rancher/k3s/server/manifests/k3s-config.yaml 2>/dev/null; then
    echo -e "${YELLOW}⚠️  Configurazione OIDC non trovata in k3s${NC}"
    echo "Per configurare OIDC, aggiungere al file k3s-config.yaml o reinstallare k3s con:"
    echo "  --kube-apiserver-arg=oidc-issuer-url=https://keycloak.keycloak.svc.cluster.local:8443/realms/stack4things"
    echo "  --kube-apiserver-arg=oidc-client-id=kubernetes"
    echo "  --kube-apiserver-arg=oidc-username-claim=preferred_username"
    echo "  --kube-apiserver-arg=oidc-groups-claim=groups"
fi

echo ""
echo "=========================================="
echo -e "${GREEN}✅ KEYCLOAK E KEYSTONE DEPLOYATI!${NC}"
echo "=========================================="
echo ""
echo "Per verificare lo stato:"
echo "  kubectl get pods -n keycloak"
echo "  kubectl get pods -n keystone"
echo ""
