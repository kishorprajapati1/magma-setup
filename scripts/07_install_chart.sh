#!/bin/bash

# Enable/disable verbose output
VERBOSE=false

# Constants
MAGMA_VERSION="v1.8.0"
WORK_DIR="/tmp/magma-installer"
REPO_DIR="$WORK_DIR/magma-repo"
CREDENTIALS_FILE="$WORK_DIR/magma-credentials.txt"

# Function to enable verbose mode
verbose() {
    if [ "$VERBOSE" = true ]; then
        echo -e "\n?? VERBOSE: $1"
    fi
}

# Function to check if a command succeeded
check_error() {
    if [ $? -ne 0 ]; then
        echo "? ERROR: $1"
        exit 1
    fi
}

# Function to read credentials from file
read_credentials() {
    if [ ! -f "$CREDENTIALS_FILE" ]; then
        echo "? ERROR: Credentials file not found at $CREDENTIALS_FILE"
        echo "Please run the main script and set credentials first (option 1)"
        exit 1
    fi

    ORC8R_DOMAIN=$(grep "Domain:" "$CREDENTIALS_FILE" | cut -d':' -f2 | tr -d ' ')
    EMAIL=$(grep "Admin Email:" "$CREDENTIALS_FILE" | cut -d':' -f2 | tr -d ' ')
    NMS_DB_PWD=$(grep "NMS MySQL Password:" "$CREDENTIALS_FILE" | cut -d':' -f2 | tr -d ' ')
    ORC8R_DB_PWD=$(grep "Orchestrator DB Password:" "$CREDENTIALS_FILE" | cut -d':' -f2 | tr -d ' ')

    if [ -z "$ORC8R_DOMAIN" ] || [ -z "$EMAIL" ] || [ -z "$NMS_DB_PWD" ] || [ -z "$ORC8R_DB_PWD" ]; then
        echo "? ERROR: Missing required credentials"
        exit 1
    fi

    verbose "Using domain: $ORC8R_DOMAIN"
    verbose "Database passwords retrieved successfully"
}

# Function to patch deprecated APIs safely
patch_helm_templates() {
    echo "??? Patching deprecated apiVersions for Kubernetes >= 1.25..."

    # Replace all policy/v1beta1 with policy/v1
    find "$CHART_DIR" -type f -name "*.yaml" \
        -exec sed -i 's/apiVersion: policy\/v1beta1/apiVersion: policy\/v1/g' {} +

    # Replace PDB YAMLs with valid safe templates
    find "$CHART_DIR" -type f -name "*pdb*.yaml" | while read -r file; do
        if grep -q "kind: PodDisruptionBudget" "$file"; then
            echo "?? Replacing $file with valid PDB spec"
            cat > "$file" <<EOF
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: $(basename "$file" .yaml)
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: orc8r
EOF
        fi
    done
}

# Function to install Magma Helm chart
install_chart() {
    echo "?? Installing Magma Orchestrator chart..."

    read_credentials
    mkdir -p "$WORK_DIR"

    if ! kubectl get namespace orc8r &>/dev/null; then
        echo "?? Creating orc8r namespace..."
        kubectl create namespace orc8r
        check_error "Failed to create namespace"
    fi

    echo "?? Creating Helm values file..."
    VALUES_FILE="$WORK_DIR/orc8r-values.yaml"
    cat > "$VALUES_FILE" <<EOF
imagePullSecrets: []

secrets:
  create: false

nginx:
  service:
    type: NodePort
    ports:
      http:
        nodePort: 30080
      https:
        nodePort: 30443
  spec:
    hostname: orc8r.${ORC8R_DOMAIN}

controller:
  podDisruptionBudget:
    enabled: false
  replicas: 1
  spec:
    database:
      driver: postgres
      sql_dialect: psql
      db: orc8r
      host: orc8r-postgresql.db.svc.cluster.local
      port: 5432
      user: postgres
      pass: ${ORC8R_DB_PWD}

nms:
  enabled: true
  nginx:
    service:
      type: NodePort
      port: 80
      nodePort: 31080
  magmalte:
    env:
      api_host: ${ORC8R_DOMAIN}
      mysql_host: orc8r-mysql.db.svc.cluster.local
      mysql_user: root
      mysql_pass: ${NMS_DB_PWD}
      mysql_db: magma_nms
EOF

    if [ ! -d "$REPO_DIR" ]; then
        echo "?? Cloning Magma repository..."
        git clone --branch "$MAGMA_VERSION" https://github.com/magma/magma.git "$REPO_DIR"
        check_error "Failed to clone Magma repository"
    fi

    CHART_DIR="$REPO_DIR/orc8r/cloud/helm/orc8r"
    cd "$CHART_DIR" || exit 1

    echo "?? Fetching Helm chart dependencies..."
    helm dependency update
    helm dependency build
    check_error "Failed to update or build Helm dependencies"

    patch_helm_templates

    echo "?? Installing Helm chart from local source..."
    helm upgrade --install orc8r . \
        --namespace orc8r --create-namespace \
        -f "$VALUES_FILE"
    check_error "Chart installation failed"

    echo "? Waiting for controller pod to be ready..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=controller -n orc8r --timeout=300s || true

    echo "? Magma Orchestrator chart installed successfully!"
    kubectl get pods -n orc8r
}

# Main execution
main() {
    if [[ "$*" == *"--verbose"* ]]; then
        VERBOSE=true
        echo "?? Verbose mode enabled"
    fi

    install_chart
}

# Run the script
main "$@"
