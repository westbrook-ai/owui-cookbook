# Technical Setup Guide

This guide is a technical reference companion to [What Would It Take for a Financial Services Firm to Run AI In-House?](article.md). It walks through one possible production architecture for self-hosting Open WebUI, along with configuration examples that firms in regulated industries may find relevant. **This is a starting point for evaluation, not a prescriptive deployment guide — your firm's engineering, security, risk, and compliance teams should adapt this architecture to your specific requirements and regulatory regime.**

*This guide is for informational purposes only and does not constitute legal, regulatory, compliance, financial, tax, or investment advice. Firms should validate controls, policies, and use cases with qualified legal, compliance, risk, and information security counsel.*

---

## Table of Contents

1. [Architecture Deep Dive](#architecture-deep-dive)
2. [Pre-Requisites](#pre-requisites)
3. [Docker Compose Reference](#docker-compose-reference)
4. [Setup Script](#setup-script)
5. [Environment Variable Reference](#environment-variable-reference)
6. [RBAC Configuration Guide](#rbac-configuration-guide)
7. [Knowledge Base Setup Guide](#knowledge-base-setup-guide)
8. [oikb — Knowledge Base Auto-Sync](#oikb--knowledge-base-auto-sync)
9. [Security Hardening Checklist](#security-hardening-checklist)
10. [Backup & Disaster Recovery](#backup--disaster-recovery)

---

## Architecture Deep Dive

This section explains each component in the production stack and why it exists. For the high-level overview and business rationale, see the [blog post](article.md).

### Reverse Proxy + TLS Termination

All traffic enters through a single reverse proxy that enforces TLS encryption in transit. This is the network boundary — traffic is routed through it before reaching Open WebUI. For firms with existing network infrastructure, this integrates with current certificate management and firewall rules. The proxy also handles load balancing across Open WebUI instances, distributing requests evenly to prevent any single node from becoming a bottleneck.

### Stateless Open WebUI Nodes

Open WebUI instances run as stateless containers. This means you can:

- Scale horizontally — add nodes during peak usage (quarter-end research production, month-end transaction review, regulatory reporting deadlines) and remove them during quieter times
- Lose any single node without service interruption
- Restart containers without losing data — all persistent state lives in PostgreSQL and Redis

Some configuration settings are particularly relevant in environments where customer data sensitivity, supervisory expectations, and access control matter. Examples worth considering:

- `ENABLE_ADMIN_CHAT_ACCESS=False` — Restricts IT administrators from viewing user conversation content at the application level. *(Firms evaluating this should consult information security, compliance, and HR/legal on their specific obligations.)*
- `ENABLE_SIGNUP=False` — No self-registration; user provisioning is controlled
- `DEFAULT_USER_ROLE=pending` — New accounts require admin approval before accessing any AI capabilities
- `ENABLE_ADMIN_EXPORT=False` — Disables bulk data extraction at the application level

### PostgreSQL + PGVector

PostgreSQL serves dual duty: it stores chat history, user records, and configuration, and with the PGVector extension, it also acts as the vector database for RAG knowledge bases. One database to back up, monitor, and secure rather than two.

Conversations are persisted, timestamped, and associated with a user identity. When combined with `USER_PERMISSIONS_CHAT_DELETE=False`, chat deletion is disabled at the application level, which firms can evaluate against books-and-records, supervisory, and BSA recordkeeping requirements. Connection pooling and proper indexing ensure performance holds at firm-wide scale.

### Redis

Redis handles session management and WebSocket coordination across stateless nodes. When a research analyst starts a conversation on one Open WebUI instance and their next request routes to a separate instance, Redis supports session continuity. Without it, multi-node deployments cannot function. Redis Sentinel or Cluster mode is recommended for production HA.

### Shared Document Storage

Uploaded documents — model documentation, validation workpapers, transaction exports, policy manuals, vendor SOC 2 reports — need to be accessible from any Open WebUI instance. An S3-compatible object store (MinIO for on-prem, or your cloud provider's offering) or NFS mount provides this shared layer. Open WebUI's file management dashboard provides a centralized interface to search, view, and manage them.

### Ollama — Local Model Inference

Ollama runs models directly on your infrastructure. When configured for local-only inference, prompts and completions stay on your network — a property that supports obligations under GLBA Safeguards, NYDFS 23 NYCRR Part 500, and jurisdictional data-residency regimes. Ollama supports GPU passthrough via NVIDIA Container Toolkit, and Open WebUI can load-balance across multiple Ollama instances for concurrent users.

### vLLM — GPU-Optimized Inference

For firms needing maximum throughput from large models (70B+ parameters), vLLM provides optimized GPU inference with continuous batching and PagedAttention. It exposes an OpenAI-compatible API, so Open WebUI connects to it just like any other API endpoint.

vLLM is the right choice when:

- Dozens of users are running concurrent queries (cross-desk research, AML alert review, model validation drafting)
- You're serving 70B+ parameter models that need tensor parallelism across multiple GPUs
- You need consistent throughput for SLA-sensitive workflows

Both Ollama and vLLM can run side-by-side. A common pattern is to use Ollama to serve smaller models for quick tasks (summarization, Q&A), while using vLLM to handle the large reasoning models for complex analysis tasks (multi-document research synthesis, model validation report assembly).

### Functions (Optional)

Open WebUI's built-in [Functions](https://docs.openwebui.com/features/plugin/functions/) plugin system enables custom processing logic without external services. Examples include:

- **Rate limiting** — Prevent runaway local LLM usage during bulk document processing
- **Toxic message filtering** — Content safety guardrails
- **LLM-Guard prompt injection scanning** — Scan for adversarial inputs that might attempt to extract sensitive customer or supervisory information
- **Langfuse monitoring** — Detailed usage analytics per user, model, and functional group (Investment Research, AML, Consumer Lending, MRM, etc.)
- **Custom RAG functions** — Firm-specific retrieval logic (for example, prioritizing the most recent FinCEN advisory, the most recent SEC release, or the most recent internal model documentation revision)

### OpenTelemetry (Optional)

Built-in OpenTelemetry support exports traces, metrics, and logs to your existing observability stack (Prometheus, Grafana, Jaeger, Splunk, Datadog, Sentinel, Chronicle). This provides infrastructure-level visibility into how AI systems are being used and is the natural integration point for a SIEM audit sink supporting supervisory and security workflows.

### oikb Sync Daemon

A separate companion service that keeps each knowledge base aligned with an upstream source of truth — a Confluence space for the MRM policy, a SharePoint library for the AML procedures, a GitHub repository for the credit policy, an S3 bucket for archived FinCEN advisories. See the dedicated [oikb section](#oikb--knowledge-base-auto-sync) for configuration details and the financial-services rationale.

---

## Pre-Requisites

### Hardware Requirements

For a firm with 500–10,000+ employees and concurrent usage of ~50–500 users:

| Component | Minimum | Recommended |
|---|---|---|
| **Open WebUI nodes** | 2× (4 vCPU, 8 GB RAM each) | 3× (8 vCPU, 16 GB RAM each) |
| **PostgreSQL** | 4 vCPU, 16 GB RAM, 500 GB SSD | 8 vCPU, 32 GB RAM, 1 TB NVMe |
| **Redis** | 2 vCPU, 4 GB RAM | 2 vCPU, 8 GB RAM (Sentinel: 3 nodes) |
| **Ollama (small models, ≤13B)** | 1× NVIDIA GPU (24 GB VRAM, e.g., RTX 4090) | 2× GPUs behind load balancer |
| **vLLM (large models, 70B+)** | 2× NVIDIA A100 80 GB (tensor parallel) | 4× A100 80 GB or 2× H100 |
| **Shared storage** | 1 TB S3-compatible or NFS | 5 TB+ with lifecycle policies |
| **oikb daemon** | 1 vCPU, 1 GB RAM | 2 vCPU, 2 GB RAM (more for high-frequency syncs) |

### Software Requirements

- **Docker Engine** ≥ 24.0 and **Docker Compose** ≥ 2.20
- **NVIDIA Container Toolkit** (for GPU nodes) — [installation guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
- **TLS certificates** — from the firm's internal CA, public CA, or Let's Encrypt
- **SSO/OIDC credentials** — for OAuth integration (Okta, Microsoft Entra ID, Ping Identity, Google Workspace, etc.), with MFA enforced at the IdP layer to meet 23 NYCRR Part 500's authentication baseline
- **DNS entry** — e.g., `ai.yourfirm.com` pointing to the reverse proxy

### Network Requirements

- All services communicate on an internal Docker network — no public exposure except the reverse proxy
- Outbound internet access is **not required** for inference if models are pre-pulled (fully air-gappable)
- Outbound access to upstream content sources (Confluence, SharePoint, GitHub Enterprise, S3) is required only for the `oikb` daemon, and only for the sources the firm chooses to sync
- Ports: only `443` (HTTPS) exposed externally

---

## Docker Compose Reference

The repository's [`deploy/docker-compose.yml`](deploy/docker-compose.yml) is a local-testing variant (single Open WebUI node, no GPU reservations, no vLLM, self-signed TLS). The reference below is the multi-node production shape that adds load-balanced Open WebUI instances, vLLM, and production tuning. An accompanying `.env` file is generated by the [setup script](#setup-script) below.

```yaml
# =============================================================================
# Open WebUI — Financial Services Production Stack (Reference)
# =============================================================================
# Usage:
#   1. Run ./setup.sh to generate .env and required directories
#   2. docker compose up -d
#   3. Access via https://ai.yourfirm.com
# =============================================================================

services:
  # ---------------------------------------------------------------------------
  # Reverse Proxy — TLS termination and load balancing
  # ---------------------------------------------------------------------------
  nginx:
    image: nginx:alpine
    container_name: owui-proxy
    restart: unless-stopped
    ports:
      - "443:443"
      - "80:80"       # Redirect to HTTPS
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/certs:/etc/nginx/certs:ro
    depends_on:
      open-webui-1:
        condition: service_healthy
    networks:
      - owui-net

  # ---------------------------------------------------------------------------
  # Open WebUI — Stateless application nodes
  # ---------------------------------------------------------------------------
  open-webui-1:
    image: ghcr.io/open-webui/open-webui:0.6  # Pin to a specific version for production
    container_name: owui-node-1
    restart: unless-stopped
    environment:
      # --- Core ---
      - WEBUI_URL=${WEBUI_URL}
      - WEBUI_NAME=${WEBUI_NAME:-Financial Services AI}
      - WEBUI_SECRET_KEY=${WEBUI_SECRET_KEY}
      - PORT=8080

      # --- Database ---
      - DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}

      # --- Vector DB (PGVector, same PostgreSQL instance) ---
      - VECTOR_DB=pgvector
      - PGVECTOR_DB_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}

      # --- Redis ---
      - REDIS_URL=redis://redis:6379/0
      - WEBSOCKET_MANAGER=redis
      - WEBSOCKET_REDIS_URL=redis://redis:6379/0
      - ENABLE_WEBSOCKET_SUPPORT=True

      # --- Inference backends ---
      - OLLAMA_BASE_URL=http://ollama:11434
      - ENABLE_OLLAMA_API=True
      - OPENAI_API_BASE_URL=http://vllm:8000/v1
      - OPENAI_API_KEY=${VLLM_API_KEY:-sk-none}
      - ENABLE_OPENAI_API=True

      # --- Security defaults ---
      - ENABLE_SIGNUP=False
      - DEFAULT_USER_ROLE=pending
      - ENABLE_ADMIN_CHAT_ACCESS=False
      - ENABLE_ADMIN_EXPORT=False
      - BYPASS_MODEL_ACCESS_CONTROL=False
      - BYPASS_ADMIN_ACCESS_CONTROL=False
      - ENABLE_COMMUNITY_SHARING=False

      # --- User permissions ---
      - USER_PERMISSIONS_CHAT_DELETE=False
      - USER_PERMISSIONS_CHAT_TEMPORARY=False

      # --- RAG tuning ---
      - RAG_TOP_K=5
      - RAG_SYSTEM_CONTEXT=True
      - ENABLE_RAG_HYBRID_SEARCH=True

      # --- Admin provisioning (first startup only) ---
      - WEBUI_ADMIN_EMAIL=${ADMIN_EMAIL}
      - WEBUI_ADMIN_PASSWORD=${ADMIN_PASSWORD}
      - WEBUI_ADMIN_NAME=${ADMIN_NAME:-IT Admin}

      # --- Workers ---
      - UVICORN_WORKERS=${UVICORN_WORKERS:-4}
      - ENABLE_DB_MIGRATIONS=True  # Only on node-1; set False on others

      # --- Observability (optional) ---
      - ENABLE_OTEL=${ENABLE_OTEL:-False}
      - OTEL_EXPORTER_OTLP_ENDPOINT=${OTEL_ENDPOINT:-}

      # --- Persistent config ---
      - ENABLE_PERSISTENT_CONFIG=True
    volumes:
      - owui-data:/app/backend/data
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks:
      - owui-net

  # Note: open-webui-2 duplicates the environment from open-webui-1 because
  # Docker Compose list-style environment blocks do not support YAML merge keys.
  # If you add or change a variable above, update it here as well.
  open-webui-2:
    image: ghcr.io/open-webui/open-webui:0.6
    container_name: owui-node-2
    restart: unless-stopped
    environment:
      - WEBUI_URL=${WEBUI_URL}
      - WEBUI_NAME=${WEBUI_NAME:-Financial Services AI}
      - WEBUI_SECRET_KEY=${WEBUI_SECRET_KEY}
      - PORT=8080
      - DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}
      - VECTOR_DB=pgvector
      - PGVECTOR_DB_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}
      - REDIS_URL=redis://redis:6379/0
      - WEBSOCKET_MANAGER=redis
      - WEBSOCKET_REDIS_URL=redis://redis:6379/0
      - ENABLE_WEBSOCKET_SUPPORT=True
      - OLLAMA_BASE_URL=http://ollama:11434
      - ENABLE_OLLAMA_API=True
      - OPENAI_API_BASE_URL=http://vllm:8000/v1
      - OPENAI_API_KEY=${VLLM_API_KEY:-sk-none}
      - ENABLE_OPENAI_API=True
      - ENABLE_SIGNUP=False
      - DEFAULT_USER_ROLE=pending
      - ENABLE_ADMIN_CHAT_ACCESS=False
      - ENABLE_ADMIN_EXPORT=False
      - BYPASS_MODEL_ACCESS_CONTROL=False
      - BYPASS_ADMIN_ACCESS_CONTROL=False
      - ENABLE_COMMUNITY_SHARING=False
      - USER_PERMISSIONS_CHAT_DELETE=False
      - USER_PERMISSIONS_CHAT_TEMPORARY=False
      - RAG_TOP_K=5
      - RAG_SYSTEM_CONTEXT=True
      - ENABLE_RAG_HYBRID_SEARCH=True
      - WEBUI_ADMIN_EMAIL=${ADMIN_EMAIL}
      - WEBUI_ADMIN_PASSWORD=${ADMIN_PASSWORD}
      - WEBUI_ADMIN_NAME=${ADMIN_NAME:-IT Admin}
      - UVICORN_WORKERS=${UVICORN_WORKERS:-4}
      - ENABLE_DB_MIGRATIONS=False  # Node-1 handles migrations
      - ENABLE_OTEL=${ENABLE_OTEL:-False}
      - OTEL_EXPORTER_OTLP_ENDPOINT=${OTEL_ENDPOINT:-}
      - ENABLE_PERSISTENT_CONFIG=True
    volumes:
      - owui-data:/app/backend/data
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks:
      - owui-net

  # ---------------------------------------------------------------------------
  # PostgreSQL 16 + PGVector — Database and vector store
  # ---------------------------------------------------------------------------
  postgres:
    image: pgvector/pgvector:pg16
    container_name: owui-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=${POSTGRES_DB}
    volumes:
      - postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    networks:
      - owui-net
    # Recommended: tune postgresql.conf for your hardware
    command: >
      postgres
        -c shared_buffers=2GB
        -c effective_cache_size=6GB
        -c work_mem=64MB
        -c maintenance_work_mem=512MB
        -c max_connections=200
        -c wal_level=replica
        -c max_wal_senders=3

  # ---------------------------------------------------------------------------
  # Redis — Session management and WebSocket coordination
  # ---------------------------------------------------------------------------
  redis:
    image: redis:7-alpine
    container_name: owui-redis
    restart: unless-stopped
    command: >
      redis-server
        --maxmemory 2gb
        --maxmemory-policy allkeys-lru
        --maxclients 10000
        --timeout 1800
        --save 60 1000
        --appendonly yes
    volumes:
      - redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - owui-net

  # ---------------------------------------------------------------------------
  # Ollama — Local model inference (smaller models, ≤13B)
  # ---------------------------------------------------------------------------
  ollama:
    image: ollama/ollama:latest
    container_name: owui-ollama
    restart: unless-stopped
    volumes:
      - ollama-data:/root/.ollama
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    networks:
      - owui-net

  # ---------------------------------------------------------------------------
  # vLLM — GPU-optimized inference (large models, 70B+)
  # ---------------------------------------------------------------------------
  vllm:
    image: vllm/vllm-openai:latest
    container_name: owui-vllm
    restart: unless-stopped
    command: >
      --model ${VLLM_MODEL:-meta-llama/Llama-3.1-70B-Instruct}
      --tensor-parallel-size ${VLLM_TP_SIZE:-2}
      --max-model-len ${VLLM_MAX_MODEL_LEN:-8192}
      --gpu-memory-utilization 0.90
      --enforce-eager
      --api-key ${VLLM_API_KEY:-sk-none}
    environment:
      - HUGGING_FACE_HUB_TOKEN=${HF_TOKEN}
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: ${VLLM_TP_SIZE:-2}
              capabilities: [gpu]
    networks:
      - owui-net

  # ---------------------------------------------------------------------------
  # oikb — Knowledge base auto-sync daemon
  # ---------------------------------------------------------------------------
  oikb:
    image: ghcr.io/open-webui/oikb:latest
    container_name: owui-oikb
    restart: unless-stopped
    command: ["daemon", "--port", "8765", "--config", "/app/.oikb.yaml"]
    environment:
      - OPEN_WEBUI_URL=http://open-webui-1:8080
      - OPEN_WEBUI_API_KEY=${OIKB_OPEN_WEBUI_API_KEY}
      - OIKB_API_KEY=${OIKB_DAEMON_API_KEY}
      - KB_INVESTMENT_RESEARCH=${KB_INVESTMENT_RESEARCH}
      - KB_AML_BSA=${KB_AML_BSA}
      - KB_CONSUMER_LENDING=${KB_CONSUMER_LENDING}
      - KB_MODEL_RISK=${KB_MODEL_RISK}
    volumes:
      - ./oikb/.oikb.yaml:/app/.oikb.yaml:ro
      # Production deployments typically omit the local kb-sources mount and
      # configure remote connectors (github:, confluence:, sharepoint:, s3:)
      # in .oikb.yaml instead.
      - ./kb-sources:/kb-sources:ro
    depends_on:
      open-webui-1:
        condition: service_healthy
    networks:
      - owui-net

# =============================================================================
# Named Volumes
# =============================================================================
volumes:
  owui-data:
    driver: local
  postgres-data:
    driver: local
  redis-data:
    driver: local
  ollama-data:
    driver: local

# =============================================================================
# Network
# =============================================================================
networks:
  owui-net:
    driver: bridge
```

### Nginx Configuration

Save this as `nginx/nginx.conf`:

```nginx
events {
    worker_connections 1024;
}

http {
    upstream openwebui {
        least_conn;
        server open-webui-1:8080;
        server open-webui-2:8080;
    }

    # Redirect HTTP to HTTPS
    server {
        listen 80;
        return 301 https://$host$request_uri;
    }

    server {
        listen 443 ssl;
        server_name ai.yourfirm.com;

        ssl_certificate     /etc/nginx/certs/fullchain.pem;
        ssl_certificate_key /etc/nginx/certs/privkey.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_ciphers         HIGH:!aNULL:!MD5;

        # Security headers
        add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;

        # Max upload size for document ingestion
        client_max_body_size 100M;

        location / {
            proxy_pass http://openwebui;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            # WebSocket support (required for streaming responses)
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";

            # Timeouts for long-running LLM responses
            proxy_read_timeout 300s;
            proxy_send_timeout 300s;
        }
    }
}
```

---

## Setup Script

The repository ships [`setup.sh`](setup.sh) in the financial-services blog directory. It performs pre-flight checks, creates the deploy directory structure, generates a self-signed TLS certificate for local testing, generates secrets into `deploy/.env`, pulls baseline Ollama models, and validates the Docker Compose configuration. Run it from the blog directory:

```bash
chmod +x setup.sh && ./setup.sh
```

The script prints a numbered guide for the post-setup `oikb` bootstrap (see [Knowledge Base Auto-Sync](#oikb--knowledge-base-auto-sync) for the full procedure).

For production deployments, the script is a useful starting point but should be adapted to the firm's secrets management practices — secrets should ultimately live in a dedicated secrets manager (HashiCorp Vault, AWS Secrets Manager, Azure Key Vault) rather than a `.env` file on the host.

---

## Environment Variable Reference

The Docker Compose file above includes the most important variables for this deployment pattern. This section explains the rationale for each configuration choice. **These descriptions explain what each setting does — they do not constitute compliance guidance. The firm's security, risk, and compliance teams should determine which settings are appropriate for the environment and supervisory regime.**

### Security & Access Control

| Variable | Value | Why |
|---|---|---|
| `ENABLE_SIGNUP` | `False` | Disables self-registration. All users are provisioned by an admin or synced via SSO. |
| `DEFAULT_USER_ROLE` | `pending` | New SSO users land in a "pending" state until an admin explicitly approves them. |
| `ENABLE_ADMIN_CHAT_ACCESS` | `False` | Restricts IT administrators from viewing user conversation content at the application level. *(Firms should determine the appropriate posture with information security, compliance, and HR/legal.)* |
| `ENABLE_ADMIN_EXPORT` | `False` | Disables bulk database exports at the application level. |
| `BYPASS_MODEL_ACCESS_CONTROL` | `False` | Enforces RBAC model restrictions — users only see models assigned to their group. |
| `BYPASS_ADMIN_ACCESS_CONTROL` | `False` | Admins are subject to the same workspace access rules as regular users. |
| `ENABLE_COMMUNITY_SHARING` | `False` | Disables sharing prompts/models to the Open WebUI Community hub. |
| `USER_PERMISSIONS_CHAT_DELETE` | `False` | Disables chat deletion at the application level — supports books-and-records, BSA, and supervisory recordkeeping. |
| `USER_PERMISSIONS_CHAT_TEMPORARY` | `False` | Disables temporary (unlogged) chats. |

### RAG Configuration

| Variable | Value | Why |
|---|---|---|
| `VECTOR_DB` | `pgvector` | Uses PostgreSQL's PGVector extension. Officially maintained by Open WebUI. Safe for multi-replica. |
| `RAG_TOP_K` | `5` | Returns the top 5 most relevant document chunks. Increase for broader recall, decrease for precision. |
| `RAG_SYSTEM_CONTEXT` | `True` | Places RAG context in the system message for better KV prefix caching performance with Ollama/vLLM. |
| `ENABLE_RAG_HYBRID_SEARCH` | `True` | Enables BM25 + vector ensemble search with reranking for higher retrieval quality. |

### Multi-Node Infrastructure

| Variable | Value | Why |
|---|---|---|
| `DATABASE_URL` | `postgresql://...` | **Required** for multi-node. SQLite cannot handle concurrent writes from multiple instances. |
| `REDIS_URL` | `redis://redis:6379/0` | Required for session coordination across stateless Open WebUI nodes. |
| `WEBSOCKET_MANAGER` | `redis` | Routes WebSocket events through Redis so streaming responses work across all nodes. |
| `ENABLE_WEBSOCKET_SUPPORT` | `True` | Enables real-time streaming responses via WebSocket. |
| `UVICORN_WORKERS` | `4` | Number of worker processes per container. Tune based on CPU cores available. |
| `ENABLE_DB_MIGRATIONS` | `True` (node-1 only) | Only one node should run database migrations on startup to prevent race conditions. |

### Redis Configuration Notes

The Redis `command` in the Docker Compose file includes settings worth calling out:

```
maxclients 10000    # Default is often 1000 — too low for production
timeout 1800        # Close idle connections after 30 minutes
save 60 1000        # Snapshot every 60s if 1000+ keys changed
appendonly yes      # AOF persistence for durability
```

**Without `timeout 1800`**, idle Redis connections accumulate indefinitely. Over days or weeks, you will hit `maxclients` and all logins will fail with `500 Internal Server Error`. This is a documented failure mode — see the [Open WebUI Redis documentation](https://docs.openwebui.com/reference/env-configuration/#redis_url).

### oikb Variables

| Variable | Where set | Why |
|---|---|---|
| `OPEN_WEBUI_URL` | `oikb` service env | Internal Open WebUI URL the daemon targets. Use the internal Docker DNS name in production. |
| `OPEN_WEBUI_API_KEY` | `oikb` service env (from `.env`) | API key the daemon uses to upload to knowledge bases. Generated in Open WebUI Settings → Account → API Keys. |
| `OIKB_API_KEY` | `oikb` service env (from `.env`) | API key protecting the `oikb` daemon's own HTTP endpoints (`/health`, `/metrics`, `/history`, `/sync/...`). |
| `KB_INVESTMENT_RESEARCH`, `KB_AML_BSA`, `KB_CONSUMER_LENDING`, `KB_MODEL_RISK` | `oikb` service env (from `.env`) | UUIDs of the knowledge bases created in Open WebUI. Interpolated into `.oikb.yaml` via `${KB_*}` placeholders. |

---

## RBAC Configuration Guide

After first deployment, you can configure groups via the Admin Panel. The following is an example workflow — **the firm should design its own group structure based on its charter, supervisory regime, lines of business, risk tolerance, and applicable regulations.**

### Step 1: Configure OAuth / SSO

SSO is configured entirely through environment variables — there is no admin panel UI for it. Add the following to `.env` or the Docker Compose environment block and restart the container:

```
OPENID_PROVIDER_URL=https://login.yourfirm.com/.well-known/openid-configuration
OAUTH_CLIENT_ID=<your-client-id>
OAUTH_CLIENT_SECRET=<your-client-secret>
OAUTH_SCOPES=openid email profile groups
OAUTH_GROUP_CLAIM=groups
ENABLE_OAUTH_SIGNUP=True
ENABLE_OAUTH_GROUP_MANAGEMENT=True
ENABLE_OAUTH_GROUP_CREATION=True
ENABLE_OAUTH_ROLE_MANAGEMENT=True
```

> **Tip:** Set `ENABLE_OAUTH_GROUP_MANAGEMENT=True` so functional-area membership syncs automatically from your identity provider. When a credit analyst moves from Consumer Lending to Operations in your directory, their Open WebUI permissions update on next login. MFA at the IdP layer is the baseline expectation under 23 NYCRR Part 500 (since November 2025).
>
> For troubleshooting, see the [Open WebUI SSO documentation](https://docs.openwebui.com/troubleshooting/sso/).

### Step 2: Create Functional Groups

Navigate to **Admin Panel → Groups** and create groups matching the firm's functional structure. The article describes eight illustrative groups; this guide replicates them as a starting point.

![Groups management page](images/admin_groups.png)

1. **Investment Research**
   - Models: All available models
   - Knowledge bases: Internal models, published notes, call transcripts, management meeting memos
   - Permissions: Web search enabled, document extraction enabled

2. **Wealth and Advisory**
   - Models: Advanced analysis only
   - Knowledge bases: Approved product literature, suitability templates, regulatory bulletins
   - Permissions: RAG-only mode (responses grounded in approved internal materials)

3. **AML and BSA Compliance**
   - Models: All available models
   - Knowledge bases: Transaction monitoring exports, SAR libraries, FinCEN advisories, prior regulator correspondence
   - Permissions: Document extraction (extract entities and patterns from transaction history)

4. **Consumer Lending and Credit**
   - Models: Advanced analysis only
   - Knowledge bases: Credit policy, model factor libraries, approved adverse action language, CFPB circulars
   - Permissions: RAG-only mode (responses grounded in approved policy documents)

5. **Model Risk Management**
   - Models: All available models, including code interpreter
   - Knowledge bases: Model inventory, validation workpapers, MRM policy, interagency guidance
   - Permissions: Code interpreter enabled

6. **Operations and Treasury**
   - Models: Advanced analysis only
   - Knowledge bases: Operations SOPs, reconciliation procedures, payment scheme rulebooks
   - Permissions: Document extraction enabled

7. **Customer Service**
   - Models: Small models only (e.g., Llama 3.1 8B via Ollama)
   - Knowledge bases: Approved FAQs, complaint-handling procedures, regulatory disclosure templates
   - Permissions: No file upload, no web search

8. **Information Security**
   - Models: All available models
   - Knowledge bases: Vendor SOC 2 reports, NYDFS guidance, internal incident playbooks, threat intelligence feeds
   - Permissions: Automation management (schedule recurring monitoring workflows)

### Step 3: Assign Models to Groups

For each model in **Admin Panel → Models**:

1. Set visibility to **Private** (not Public)
2. Under **Access Control**, add the groups that should have access
3. Ensure `BYPASS_MODEL_ACCESS_CONTROL=False` in your environment so these restrictions are enforced

### Step 4: Assign Knowledge Bases to Groups

For each knowledge base in **Workspace → Knowledge**:

1. Set access control to the relevant functional group(s)
2. Users will only see knowledge bases assigned to their group(s) in the chat interface

---

## Knowledge Base Setup Guide

Open WebUI's RAG system ingests documents and creates searchable vector embeddings in PGVector. This section walks through configuring knowledge bases for the four illustrative scenarios in the article. The next section covers using `oikb` to keep these knowledge bases continuously aligned with upstream sources of truth.

### Recommended Knowledge Base Structure

| Knowledge Base | Contents | Functional Groups |
|---|---|---|
| `Investment Research` | Prior coverage notes, internal earnings models, management meeting memos, call transcripts | Investment Research |
| `AML & BSA Compliance` | BSA/AML policy, FinCEN advisories, prior SAR narratives, redacted closed-alert corpus | AML and BSA Compliance |
| `Consumer Lending & Credit` | Credit policy, approved adverse action language library, model factor library, CFPB circulars | Consumer Lending and Credit |
| `Model Risk Management` | MRM policy (SR 26-02 aligned), prior validation reports, model inventory, interagency guidance | Model Risk Management |
| `Wealth & Advisory` | Approved product literature, suitability templates, regulatory bulletins | Wealth and Advisory |
| `Operations & Treasury` | Operations SOPs, reconciliation procedures, payment scheme rulebooks | Operations and Treasury |
| `Customer Service` | Approved FAQs, complaint-handling procedures, regulatory disclosure templates | Customer Service |
| `Information Security` | Vendor SOC 2 reports, NYDFS guidance, incident playbooks, threat intelligence feeds | Information Security |

### Upload Workflow (Manual)

1. Navigate to **Workspace → Knowledge → Create Knowledge Base**
2. Name the knowledge base and set access control to the relevant functional group(s)
3. Upload documents (supported formats: PDF, DOCX, TXT, Markdown, HTML, CSV, XLSX, PPTX)
4. Open WebUI automatically:
   - Extracts text from uploaded documents
   - Chunks the content for optimal retrieval
   - Generates vector embeddings and stores them in PGVector
5. Users in the assigned groups can reference this knowledge base in chat by typing `#` followed by the knowledge base name

For production use, the manual upload workflow does not scale and does not produce an audit trail of *which version* of *which document* was current in the knowledge base on a given date. The next section covers `oikb`, the auto-sync mechanism that addresses this.

### RAG Best Practices

- **Chunk size**: The default works well for most policy and analysis documents. For very long contracts, model documentation, or validation reports, consider uploading individual sections as separate documents for more precise retrieval.
- **Citation verification**: RAG provides relevance scores with each retrieved chunk. Staff must always verify citations against the source document — RAG reduces hallucination but does not eliminate it. **All AI-generated content must be reviewed and verified by qualified personnel before reliance or use in any decision that affects a customer, an order, a filing, or a regulatory record.**
- **Version control**: When a policy, advisory, or model document updates, the new version should supersede the prior version in the knowledge base. `oikb` handles this automatically by computing per-file checksums and uploading only changed files.
- **Document naming**: Use descriptive filenames (e.g., `FIN-2014-A001-summary.md` rather than `advisory1.md`). Open WebUI displays filenames in citation references, which staff verify against during review.

### Embedding Model Selection

The Docker Compose stack pulls `nomic-embed-text` via Ollama for generating embeddings locally. Configure this in **Admin Panel → Settings → Documents → Embedding Model**.

For higher-quality embeddings (recommended for 10,000+ document deployments), consider a dedicated embedding endpoint. Set `RAG_OPENAI_API_BASE_URL` to point to a self-hosted embedding service or use Ollama's built-in embedding support (both options keep data on the firm's infrastructure when configured accordingly).

---

## oikb — Knowledge Base Auto-Sync

[`oikb`](https://github.com/open-webui/oikb) is the companion utility for keeping Open WebUI knowledge bases aligned with an upstream source of truth. It computes SHA-256 checksums for each file, sends a manifest to Open WebUI for diff comparison, and uploads only files that have actually changed since the last run.

For a regulated financial services firm, three properties make this material:

- **Source-of-truth alignment.** Policies, advisories, model documentation, and procedure manuals live in systems the firm already runs (Confluence, SharePoint, GitHub Enterprise, S3). `oikb` keeps the knowledge base in step with those systems on a schedule, on a webhook, or on demand.
- **An auditable freshness record.** `oikb` records what file changed, when, from which source, with which checksum. Combined with Open WebUI's conversation logs, the firm can evidence both *that* a specific draft was grounded against a specific revision of a policy and *when* that revision entered the knowledge base — a record that supports supervisory review and model-risk change-management documentation.
- **Filtered, scoped ingestion.** Include/exclude patterns and size limits restrict which files reach each knowledge base. The Consumer Lending knowledge base can ingest the approved adverse-action language file and exclude the drafts folder; the AML knowledge base can ingest the FinCEN advisories archive and exclude internal investigation working files.

### Supported Sources

`oikb` supports 44 connectors out of the box, including the categories most relevant for financial services:

- **Code/document repositories**: GitHub, GitLab, Bitbucket
- **Knowledge systems**: Confluence, Notion, BookStack, GitBook, Outline, Document360, DokuWiki
- **Cloud storage**: S3, Google Cloud Storage, Azure Blob, SharePoint, Dropbox, Google Drive, Cloudflare R2, Egnyte, Oracle Cloud
- **Work management**: Jira, Linear, Zendesk, ServiceNow
- **Communication**: Slack, Microsoft Teams (typically scoped to specific channels for incident or supervisory records)
- **Local directories**: For air-gapped deployments or when content is staged via the firm's own ETL

Source-specific optional dependencies install via extras: `pip install oikb[s3]`, `pip install oikb[gdrive]`, or `pip install oikb[all]`.

### Configuration

The repository ships an illustrative configuration at [`deploy/oikb/.oikb.yaml`](deploy/oikb/.oikb.yaml) that maps the local `kb-sources/` tree to the four illustrative knowledge bases. The configuration below shows a more realistic mix that would be appropriate for a firm syncing from remote systems of record.

```yaml
# =============================================================================
# .oikb.yaml — Production reference configuration
# =============================================================================

defaults:
  interval: 1h
  concurrency: 4

sources:
  # ---------------------------------------------------------------------------
  # Investment Research — internal research repo and prior coverage notes
  # ---------------------------------------------------------------------------
  - name: investment-research
    source: github:yourfirm-internal/research-library
    kb-id: ${KB_INVESTMENT_RESEARCH}
    interval: 1h
    filter:
      include: ["coverage-notes/**/*.md", "models/**/*.md", "transcripts/**/*.md"]
      exclude: ["drafts/**", "embargoed/**"]
      max-size: 25mb

  # ---------------------------------------------------------------------------
  # AML & BSA Compliance — BSA policy and FinCEN advisories
  # ---------------------------------------------------------------------------
  - name: aml-policy
    source: confluence:https://yourfirm.atlassian.net/wiki/spaces/AML
    kb-id: ${KB_AML_BSA}
    interval: 6h

  - name: fincen-advisories
    source: s3://yourfirm-compliance-archives/fincen-advisories/
    kb-id: ${KB_AML_BSA}
    interval: "0 6 * * 1-5"   # Weekday morning sync
    filter:
      include: ["**/*.pdf", "**/*.md"]
      max-size: 25mb

  # ---------------------------------------------------------------------------
  # Consumer Lending — credit policy and approved language library
  # ---------------------------------------------------------------------------
  - name: credit-policy
    source: github:yourfirm-internal/credit-policy
    kb-id: ${KB_CONSUMER_LENDING}
    interval: 1h
    filter:
      include: ["policy/**/*.md", "approved-language/**/*.md", "factor-library/**/*.md"]
      exclude: ["drafts/**", "proposed/**"]
      max-size: 10mb

  # ---------------------------------------------------------------------------
  # Model Risk Management — MRM policy and validation workpapers
  # ---------------------------------------------------------------------------
  - name: mrm-policy
    source: sharepoint:https://yourfirm.sharepoint.com/sites/ModelRisk
    kb-id: ${KB_MODEL_RISK}
    interval: 6h
    filter:
      include: ["Policy/**", "Validation Reports/**", "Templates/**"]
      max-size: 50mb
```

### First-Time Bootstrap

The `oikb` daemon needs three things before it can sync: an Open WebUI URL, an Open WebUI API key, and the UUIDs of the knowledge bases it is to sync into. The Docker Compose service in `deploy/` is wired so these are read from `.env`. The bootstrap procedure is:

1. **Start the stack** (without functional `oikb` syncing):
    ```bash
    cd deploy && docker compose up -d
    ```

2. **Log into Open WebUI** as the admin (credentials in `deploy/.env`).

3. **Create the four knowledge bases** in **Workspace → Knowledge → Create Knowledge Base**:
    - Investment Research
    - AML & BSA Compliance
    - Consumer Lending & Credit
    - Model Risk Management

    Open each KB after creating it and copy the UUID from the URL bar (the segment after `/workspace/knowledge/`).

4. **Generate an admin API key** in **Settings → Account → API Keys**.

5. **Edit `deploy/.env`** and fill in:
    ```
    OIKB_OPEN_WEBUI_API_KEY=<the API key from step 4>
    KB_INVESTMENT_RESEARCH=<UUID from step 3>
    KB_AML_BSA=<UUID from step 3>
    KB_CONSUMER_LENDING=<UUID from step 3>
    KB_MODEL_RISK=<UUID from step 3>
    ```

6. **Start the daemon.** The `oikb` service lives behind the `sync` Compose profile so that `docker compose up -d` on first boot does not start a container that would crash on missing KB IDs. Bring it up explicitly once `.env` is populated:
    ```bash
    cd deploy && docker compose --profile sync up -d oikb
    ```
    Subsequent restarts (after editing `.env` again, for example) use the same flag:
    ```bash
    cd deploy && docker compose --profile sync up -d --force-recreate oikb
    ```

7. **Verify sync activity**:
    ```bash
    # Health
    curl -s http://localhost:8765/health

    # Sync history (requires daemon API key)
    curl -s http://localhost:8765/history \
      -H "Authorization: Bearer $OIKB_DAEMON_API_KEY"

    # On-demand sync trigger
    curl -s -X POST http://localhost:8765/sync/investment-research \
      -H "Authorization: Bearer $OIKB_DAEMON_API_KEY"
    ```

After the first sync, the four knowledge bases will populate from the configured sources. Subsequent syncs run on the schedule defined in `.oikb.yaml`.

### Operational Properties

- **Health endpoint** at `GET /health` — wire into the firm's container orchestration health checks.
- **Prometheus metrics** at `GET /metrics` — export to the observability stack for sync success rates, durations, and per-source counts.
- **Sync history** at `GET /history` — queryable record of what changed, when, from which source, with what checksum. Forward to the SIEM for supervisory review.
- **Webhooks** — `oikb` can listen for push events from GitHub, GitLab, Confluence, and Slack to sync on commit rather than on schedule. Configure webhook endpoints in `.oikb.yaml` and expose them through the reverse proxy with appropriate IP allowlisting.
- **Error notifications** — `oikb` can post failure events to Slack, PagerDuty, or Opsgenie webhooks for alerting.
- **OpenAPI tool server integration** — `oikb` itself exposes an OpenAPI specification that can be registered as a tool inside Open WebUI, allowing authorized administrators to trigger syncs or inspect history from within the platform.

### Scope and Governance

`oikb` is plumbing. The governance work is upstream:

- **Source authoritativeness.** A sync from a drafts folder is worse than no sync at all. Each source mapped to a knowledge base should be the firm's source of truth for that content, with appropriate change-management controls on who can modify it.
- **Filter discipline.** Include/exclude patterns are the application-level guard against ingesting working files, drafts, or restricted material into a knowledge base accessible to a broader group than intended.
- **API key management.** The `OPEN_WEBUI_API_KEY` used by the daemon is a privileged credential — it can write to any knowledge base in Open WebUI. Store it in the firm's secrets manager, rotate on the cadence the firm requires for service-account credentials, and limit which administrators can mint or use such keys.
- **Sync history retention.** The daemon's sync history is supervisory evidence. Forward it to the firm's SIEM or audit sink and retain it on the firm's regulatory recordkeeping schedule alongside the conversation logs.

---

## Security Hardening Checklist

The following checklist describes operational security measures. **This is not a compliance checklist — the firm's security, risk, and compliance teams should determine which items apply to the environment and what additional measures are needed under the firm's supervisory regime.**

### Network Layer

- [ ] TLS 1.2+ enforced on the reverse proxy — no plaintext HTTP traffic reaches Open WebUI
- [ ] Only port 443 is exposed to the user network; all other services are on internal Docker network
- [ ] HSTS header set with `max-age=63072000; includeSubDomains`
- [ ] Security headers: `X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN`, `Referrer-Policy: strict-origin-when-cross-origin`
- [ ] Rate limiting configured on the reverse proxy to prevent abuse
- [ ] DNS resolves only to the reverse proxy — no direct access to application nodes
- [ ] If `oikb` webhooks are exposed, restrict by IP allowlist and require webhook signature verification

### Authentication & Authorization

- [ ] `ENABLE_SIGNUP=False` — no self-registration
- [ ] `DEFAULT_USER_ROLE=pending` — new SSO users require admin approval
- [ ] SSO/OIDC configured with the firm's identity provider, with MFA enforced at the IdP layer (baseline expectation under 23 NYCRR Part 500 since November 2025)
- [ ] `ENABLE_OAUTH_GROUP_MANAGEMENT=True` — groups sync from IdP
- [ ] `ENABLE_OAUTH_ROLE_MANAGEMENT=True` — roles sync from IdP
- [ ] `BYPASS_MODEL_ACCESS_CONTROL=False` — RBAC enforced on model access
- [ ] `BYPASS_ADMIN_ACCESS_CONTROL=False` — admins subject to workspace ACLs

### Data Protection

- [ ] `ENABLE_ADMIN_CHAT_ACCESS=False` — restricts IT administrators from viewing user conversation content at the application level
- [ ] `ENABLE_ADMIN_EXPORT=False` — disables bulk data extraction at the application level
- [ ] `USER_PERMISSIONS_CHAT_DELETE=False` — disables chat deletion at the application level (supports books-and-records, BSA, and supervisory recordkeeping)
- [ ] `USER_PERMISSIONS_CHAT_TEMPORARY=False` — no unlogged conversations
- [ ] `ENABLE_COMMUNITY_SHARING=False` — no external data sharing
- [ ] PostgreSQL configured with encryption at rest (transparent data encryption or full-disk encryption on the host)
- [ ] Redis `requirepass` set if Redis is network-accessible (not needed when Redis is internal-only via Docker network)
- [ ] Backup encryption enabled (see [Backup & Disaster Recovery](#backup--disaster-recovery))

### Model & Inference Security

- [ ] When configured for local-only inference, all models run via Ollama or vLLM on the firm's infrastructure
- [ ] Hugging Face token is stored only in `.env` for local testing; production deployments source it from a dedicated secrets manager
- [ ] `.env` file has restrictive permissions: `chmod 600 .env`
- [ ] For production, migrate all secrets from `.env` to a dedicated secrets manager (HashiCorp Vault, AWS Secrets Manager, Azure Key Vault)
- [ ] vLLM API key (`VLLM_API_KEY`) is set to prevent unauthorized direct access to the inference endpoint
- [ ] Docker image tags pinned to specific versions (not `:main` or `:latest`) for reproducible, auditable deployments
- [ ] If Functions are used: LLM-Guard or equivalent function installed for prompt injection scanning

### oikb-Specific Hardening

- [ ] `OIKB_API_KEY` set to protect the daemon's HTTP endpoints (`/health`, `/history`, `/metrics`, `/sync/...`)
- [ ] `OPEN_WEBUI_API_KEY` for the daemon stored in a secrets manager, not in plaintext on the host
- [ ] Daemon's `/sync/...` and webhook endpoints not exposed to the public internet without IP allowlisting and authentication
- [ ] Source connectors (GitHub PAT, Confluence token, SharePoint cert, S3 IAM role) follow least-privilege — read-only on the specific space, repository, or bucket; nothing broader
- [ ] Sync history forwarded to the SIEM and retained per the firm's regulatory recordkeeping schedule
- [ ] Include/exclude filters reviewed periodically to ensure drafts, working files, and restricted materials are not ingested into a broader-access knowledge base

### Operational Security

- [ ] `ENABLE_DB_MIGRATIONS=True` on exactly one node; `False` on all others
- [ ] Redis `maxclients` set to 10000+ and `timeout` set to 1800 (see [Redis Configuration Notes](#redis-configuration-notes))
- [ ] Log aggregation configured (OpenTelemetry, Splunk, Sentinel, Datadog, Chronicle, or equivalent)
- [ ] Alerting on container restarts, database connection failures, GPU memory exhaustion, and `oikb` sync failures
- [ ] Docker image tags pinned to specific versions in production (not `:main` or `:latest`)
- [ ] Regular security updates for base images (`docker compose pull && docker compose up -d`)

---

## Backup & Disaster Recovery

### What to Back Up

| Component | Data Location | Backup Method |
|---|---|---|
| **PostgreSQL** | `postgres-data` volume | `pg_dump` (logical) or continuous WAL archiving |
| **Redis** | `redis-data` volume | AOF + RDB snapshots (handled by Redis config) |
| **Ollama models** | `ollama-data` volume | Volume snapshot or re-pull (models are public) |
| **Open WebUI data** | `owui-data` volume | Volume snapshot |
| **Configuration** | `.env`, `nginx/`, `docker-compose.yml`, `oikb/.oikb.yaml` | Git repository (exclude secrets) |
| **TLS certificates** | `nginx/certs/` | Certificate management system |
| **oikb sync history** | inside `oikb` container state | Forward to SIEM; the upstream sources of truth are themselves the system of record |

### Automated PostgreSQL Backup Script

Add this to crontab (`crontab -e`) or the firm's scheduling system:

```bash
#!/usr/bin/env bash
# Daily PostgreSQL backup — run via cron at 02:00 UTC
# 0 2 * * * /opt/openwebui/backup-postgres.sh

set -euo pipefail

BACKUP_DIR="/opt/openwebui/backups"
RETENTION_DAYS=30
TIMESTAMP=$(date -u +"%Y%m%d_%H%M%S")
BACKUP_FILE="${BACKUP_DIR}/openwebui_${TIMESTAMP}.sql.gz"

mkdir -p "${BACKUP_DIR}"

docker compose exec -T postgres pg_dump \
    -U "${POSTGRES_USER:-openwebui}" \
    -d "${POSTGRES_DB:-openwebui}" \
    --format=custom \
    --compress=9 \
    > "${BACKUP_FILE}"

# Verify backup integrity (pg_restore runs on the host against the host-side file)
pg_restore --list "${BACKUP_FILE}" > /dev/null 2>&1 \
    && echo "[OK] Backup verified: ${BACKUP_FILE}" \
    || echo "[ERROR] Backup verification failed: ${BACKUP_FILE}"

# Prune old backups
find "${BACKUP_DIR}" -name "openwebui_*.sql.gz" -mtime +${RETENTION_DAYS} -delete

echo "[INFO] Backup complete. Size: $(du -h "${BACKUP_FILE}" | cut -f1)"
```

### Recovery Procedure

1. **Stop Open WebUI nodes**: `docker compose stop open-webui-1 open-webui-2 oikb`
2. **Restore PostgreSQL**: `docker compose exec -T postgres pg_restore -U openwebui -d openwebui --clean < backup.sql.gz`
3. **Restart**: `docker compose up -d`
4. **Verify**: Check health endpoints, run a test query, and confirm `oikb` resumes scheduled syncing.

### RPO / RTO Targets

| Scenario | RPO (Data Loss) | RTO (Downtime) |
|---|---|---|
| Single node failure | 0 (stateless, auto-recovered) | < 30 seconds (health check interval) |
| Database corruption | ≤ 24 hours (daily backups) | < 1 hour |
| Full infrastructure loss | ≤ 24 hours | 2–4 hours (restore from backups) |
| With WAL archiving | ≤ 5 minutes | < 1 hour |

For mission-critical deployments, enable PostgreSQL WAL archiving for point-in-time recovery with an RPO of minutes rather than hours.

Knowledge base content recovery is straightforward when `oikb` is in use: after restoring the database and Open WebUI volumes, `oikb` re-checksums each source on its next scheduled run and re-uploads any missing or stale content. The upstream sources of truth (Confluence, SharePoint, GitHub, S3) are themselves backed up under the firm's broader backup program; `oikb`'s role is to keep the knowledge base aligned with them.

---

*This guide is maintained alongside [What Would It Take for a Financial Services Firm to Run AI In-House?](article.md). For questions about enterprise deployment, contact [sales@openwebui.com](mailto:sales@openwebui.com).*
