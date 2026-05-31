#!/usr/bin/env bash
# =============================================================================
# Open WebUI — Financial Services Setup Script
# =============================================================================
# This script creates the required directory structure, generates secrets,
# generates self-signed TLS certs for local testing, pulls initial Ollama
# models, and validates the environment before first boot of the stack
# defined in deploy/docker-compose.yml.
#
# Run from the financial-services blog directory:
#   chmod +x setup.sh && ./setup.sh
# =============================================================================

set -euo pipefail

# --- Resolve paths ----------------------------------------------------------
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DEPLOY_DIR="${SCRIPT_DIR}/deploy"

# --- Colors -----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Pre-flight checks ------------------------------------------------------
info "Running pre-flight checks..."

command -v docker >/dev/null 2>&1 || error "Docker is not installed."
command -v docker compose >/dev/null 2>&1 || error "Docker Compose v2 is not installed."
command -v openssl >/dev/null 2>&1 || error "openssl is required for secret and cert generation."

DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null)
info "Docker version: ${DOCKER_VERSION}"

# Check for NVIDIA GPU (optional)
if command -v nvidia-smi >/dev/null 2>&1; then
    GPU_INFO=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || echo "GPU detected but nvidia-smi query failed")
    info "GPU detected: ${GPU_INFO}"
else
    warn "No NVIDIA GPU detected. Ollama will run on CPU (slower inference)."
    warn "vLLM is not included in this local stack (requires GPU)."
fi

# --- Create directory structure ---------------------------------------------
info "Creating deploy directory structure..."

mkdir -p "${DEPLOY_DIR}/nginx/certs"
mkdir -p "${DEPLOY_DIR}/oikb"
mkdir -p "${DEPLOY_DIR}/kb-sources"

# --- Generate self-signed TLS cert for local testing ------------------------
CERT_DIR="${DEPLOY_DIR}/nginx/certs"
if [ ! -f "${CERT_DIR}/fullchain.pem" ] || [ ! -f "${CERT_DIR}/privkey.pem" ]; then
    info "Generating self-signed TLS certificate for localhost..."
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "${CERT_DIR}/privkey.pem" \
        -out "${CERT_DIR}/fullchain.pem" \
        -subj "/CN=localhost" \
        -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
        2>/dev/null
    info "Self-signed cert written to ${CERT_DIR}/"
    warn "Browsers will warn about the self-signed cert — accept it for local testing only."
else
    info "TLS certificate already present at ${CERT_DIR}/ — skipping."
fi

# --- Generate secrets / .env ------------------------------------------------
generate_secret() {
    openssl rand -base64 32 | tr -d '/+=' | head -c 48
}

ENV_FILE="${DEPLOY_DIR}/.env"
if [ ! -f "${ENV_FILE}" ]; then
    info "Generating ${ENV_FILE}..."
    cat > "${ENV_FILE}" << EOF
# =============================================================================
# Open WebUI — Financial Services Local Testing Environment
# Generated on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# =============================================================================
# These values are for LOCAL TESTING ONLY. Regenerate every secret before any
# non-local deployment. This file is in .gitignore and must never be committed.
# =============================================================================

# --- Core ---
WEBUI_URL=https://localhost
WEBUI_NAME=Financial Services AI
WEBUI_SECRET_KEY=$(generate_secret)

# --- Database ---
POSTGRES_USER=openwebui
POSTGRES_PASSWORD=$(generate_secret)
POSTGRES_DB=openwebui

# --- Admin account (created on first startup) ---
ADMIN_EMAIL=admin@localhost
ADMIN_PASSWORD=$(generate_secret)
ADMIN_NAME=IT Admin

# =============================================================================
# oikb — Knowledge Base Sync Daemon
# =============================================================================
# Populate these AFTER the stack is up and you have:
#   1. Logged into Open WebUI as the admin
#   2. Created the four knowledge bases in Workspace → Knowledge:
#        - Investment Research
#        - AML & BSA Compliance
#        - Consumer Lending & Credit
#        - Model Risk Management
#      Copy each KB ID from the URL bar after opening the KB
#      (e.g., /workspace/knowledge/<KB_ID>) into the variables below.
#   3. Generated an admin API key in Settings → Account → API Keys
#      and pasted it into OIKB_OPEN_WEBUI_API_KEY below.
#   4. Restarted the oikb container: docker compose restart oikb
# =============================================================================

OIKB_OPEN_WEBUI_API_KEY=
OIKB_DAEMON_API_KEY=$(generate_secret)
KB_INVESTMENT_RESEARCH=
KB_AML_BSA=
KB_CONSUMER_LENDING=
KB_MODEL_RISK=
EOF
    chmod 600 "${ENV_FILE}"
    info ".env file created. Generated admin password is in .env — save it securely."
else
    warn "${ENV_FILE} already exists — skipping generation."
fi

# --- Start Ollama and pull models ------------------------------------------
info "Pulling recommended Ollama models (this may take a while on first run)..."

if (cd "${DEPLOY_DIR}" && docker compose ps ollama 2>/dev/null | grep -q "running"); then
    info "Ollama is already running."
else
    info "Starting Ollama service to pull models..."
    (cd "${DEPLOY_DIR}" && docker compose up -d ollama)
    sleep 10
fi

MODELS=(
    "llama3.1:8b"       # Fast — summarization, Q&A, drafting
    "nomic-embed-text"  # Embedding model for RAG
)

for model in "${MODELS[@]}"; do
    info "Pulling ${model}..."
    (cd "${DEPLOY_DIR}" && docker compose exec -T ollama ollama pull "${model}") \
        || warn "Failed to pull ${model}. You can pull it later via: docker compose exec ollama ollama pull ${model}"
done

# --- Validate Docker Compose ------------------------------------------------
info "Validating Docker Compose configuration..."
(cd "${DEPLOY_DIR}" && docker compose config --quiet) \
    && info "Docker Compose configuration is valid." \
    || error "Docker Compose validation failed."

# --- Summary ----------------------------------------------------------------
cat << SUMMARY

=============================================================================
  Setup complete.
=============================================================================

  Next steps:

  1. Start the stack:
       cd deploy && docker compose up -d

  2. Open the UI at:
       https://localhost
     (accept the self-signed certificate warning)

  3. Log in with the admin credentials from deploy/.env:
       ADMIN_EMAIL    and    ADMIN_PASSWORD

  4. To enable oikb auto-sync of the four knowledge bases:
       a. Create the four KBs in Workspace → Knowledge:
            - Investment Research
            - AML & BSA Compliance
            - Consumer Lending & Credit
            - Model Risk Management
       b. Open each KB and copy its UUID from the URL bar into deploy/.env
          (KB_INVESTMENT_RESEARCH, KB_AML_BSA, KB_CONSUMER_LENDING, KB_MODEL_RISK)
       c. Generate an admin API key in Settings → Account → API Keys
          and paste it into OIKB_OPEN_WEBUI_API_KEY in deploy/.env
       d. Start the oikb daemon (it lives behind the "sync" profile until
          KB IDs are populated):
            cd deploy && docker compose --profile sync up -d oikb
       e. Confirm sync activity:
            curl http://localhost:8765/health
            curl http://localhost:8765/history \\
              -H "Authorization: Bearer \$OIKB_DAEMON_API_KEY"

  Helpful commands:
    Service health:  cd deploy && docker compose ps
    Open WebUI logs: cd deploy && docker compose logs -f open-webui-1
    oikb logs:       cd deploy && docker compose logs -f oikb
    Pull more models: cd deploy && docker compose exec ollama ollama pull <model>

=============================================================================
SUMMARY
