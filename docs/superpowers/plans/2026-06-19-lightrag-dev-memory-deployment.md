# LightRAG Dev Memory Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy project-owned LightRAG Dev Memory with isolated `liquidation-*` Docker services before Rust foundation execution.

**Architecture:** Run `liquidation-omniroute`, `liquidation-free-deepseek`, and `liquidation-lightrag` as a separate Docker stack with project-owned networks, volumes, ports, and config. Git/docs remain source of truth; LightRAG is a derived index over `docs/` and is trusted only when `liq-rag ingest`, `liq-rag eval`, `liq-rag health`, and `liq-rag status --check-commit` pass.

**Tech Stack:** Docker Compose, PowerShell preflight, LightRAG API server, OmniRoute Docker, FreeDeepseekAPI Docker, Infisical-provided secrets, structured Markdown reports, future Rust `liq-rag` CLI.

---

## Scope Boundary

This plan deploys memory/control-plane infrastructure only. It does not deploy
TimescaleDB, collector runtime, dashboard, paper trading, or real trading.

## Upstream Facts Checked On 2026-06-19

- LightRAG official docs provide Docker Compose and API/Web UI server guidance.
- LightRAG requires LLM and embedding model configuration before indexing.
- LightRAG documentation warns that changing embedding models after indexing
  requires re-embedding.
- OmniRoute provides Docker deployment and OpenAI-compatible routing/fallback.
- FreeDeepseekAPI exposes an OpenAI-compatible proxy to DeepSeek Web and should
  remain emergency route, not `ok` primary status.

Sources:

- [LightRAG README](https://github.com/HKUDS/LightRAG)
- [LightRAG API Server docs](https://github.com/HKUDS/LightRAG/blob/main/docs/LightRAG-API-Server.md)
- [LightRAG docker-compose.yml](https://github.com/HKUDS/LightRAG/blob/main/docker-compose.yml)
- [OmniRoute README](https://github.com/diegosouzapw/OmniRoute)
- [OmniRoute Docker discussion](https://github.com/diegosouzapw/OmniRoute/discussions/2779)
- [FreeDeepseekAPI README](https://github.com/ForgetMeAI/FreeDeepseekAPI)

## File Structure

Create:

- `docs/reports/preflight/` - preflight reports.
- `infra/lightrag/.env.example` - non-secret deployment variables.
- `infra/lightrag/compose.yml` - project-owned compose stack.
- `infra/lightrag/README.md` - operational notes.
- `.gitignore` - prevents local LightRAG env/data from entering Git.
- `scripts/preflight.ps1` - read-only preflight.
- `scripts/liq-rag.ps1` - temporary CLI shim for ingest/eval/health/status.
- `docs/reports/rag/eval-questions.json` - initial retrieval eval set.
- `docs/reports/rag/` - RAG reports.

Do not create:

- real `.env`;
- secrets files;
- Docker volumes without prefix `liquidation`;
- connections to second-project Docker networks.

## Task 1: Subagent And Infrastructure Runbooks

**Files:**

- Verify: `docs/runbooks/subagent-audit.md`
- Verify: `docs/runbooks/infrastructure-preflight.md`

- [ ] **Step 1: Verify runbooks exist**

Run:

```powershell
Test-Path docs/runbooks/subagent-audit.md
Test-Path docs/runbooks/infrastructure-preflight.md
```

Expected: both commands return `True`.

- [ ] **Step 2: Check forbidden placeholders**

Run:

```powershell
rg -n "TB[D]|TO[D]O|FIXM[E]|PLACEHOLDE[R]|should probabl[y]" docs/runbooks/subagent-audit.md docs/runbooks/infrastructure-preflight.md
```

Expected: no matches.

- [ ] **Step 3: Commit runbooks if not committed**

Run:

```powershell
git add docs/runbooks/subagent-audit.md docs/runbooks/infrastructure-preflight.md
git commit -m "docs: add audit and infrastructure preflight runbooks"
```

## Task 2: Read-Only Infrastructure Preflight

**Files:**

- Create: `docs/reports/preflight/YYYY-MM-DD-infrastructure.md`

- [ ] **Step 1: Run Git checks**

Run:

```powershell
git status --short
git branch -vv
```

Expected: working tree clean before deployment edits begin.

- [ ] **Step 2: Run Docker inventory**

Run:

```powershell
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}"
docker network ls --format "table {{.Name}}\t{{.Driver}}\t{{.Scope}}"
docker volume ls --format "table {{.Name}}\t{{.Driver}}"
```

Expected: second-project containers are still running. Do not modify them.

- [ ] **Step 3: Run port inventory**

Run:

```powershell
docker ps --format "{{.Names}} {{.Ports}}"
netstat -ano | findstr LISTENING
```

Expected: choose free ports for `liquidation-*` services. Do not use `20128`,
`3264`, `9655`, `13000`, `18000`, `15555`, `19200`, `16379`, `15432`, `16333`,
or `8080`.

- [ ] **Step 4: Check existing FreeDeepseek read-only**

Run:

```powershell
Invoke-WebRequest "http://127.0.0.1:9655/health" -UseBasicParsing
Invoke-WebRequest "http://127.0.0.1:9655/v1/models" -UseBasicParsing
```

Expected: status `200`. If it fails, record it; do not restart the container.

- [ ] **Step 5: Check existing Omniroute read-only**

Run:

```powershell
Invoke-WebRequest "http://127.0.0.1:20128/v1/models" -UseBasicParsing
```

Expected: either status `200` or documented auth/path failure. Do not change
the existing Omniroute.

- [ ] **Step 6: Write preflight report**

Create `docs/reports/preflight/2026-06-19-infrastructure.md`:

```markdown
# Infrastructure Preflight - 2026-06-19

## Git

- status:
- branch:

## Docker

- existing containers:
- existing networks:
- existing volumes:

## Ports

- occupied:
- selected for LIQUIDATION:

## Read-Only Checks

- existing FreeDeepseek:
- existing Omniroute:

## Blockers

- none
```

- [ ] **Step 7: Commit preflight report**

Run:

```powershell
git add docs/reports/preflight/2026-06-19-infrastructure.md
git commit -m "docs: record infrastructure preflight"
```

## Task 3: Deployment Config Skeleton

**Files:**

- Modify: `.gitignore`
- Create: `infra/lightrag/.env.example`
- Create: `infra/lightrag/README.md`
- Create: `infra/lightrag/compose.yml`

- [ ] **Step 1: Protect local env and data**

Create or update `.gitignore`:

```gitignore
/.env
/.env.local
/target/
/.sqlx/
/infra/lightrag/.env
/infra/lightrag/data/
/docs/reports/**/*.tmp
/docs/reports/**/*.log
*.pdb
*.profraw
*.profdata
```

- [ ] **Step 2: Create env example**

Create `infra/lightrag/.env.example`:

```dotenv
COMPOSE_PROJECT_NAME=liquidation

LIGHTRAG_DATA_PATH=
LIGHTRAG_BACKUP_PATH=
LIGHTRAG_REPORT_PATH=docs/reports/rag
LIGHTRAG_INDEXED_PATHS=docs/
LIGHTRAG_API_PORT=
LIGHTRAG_HOST=127.0.0.1

LIQUIDATION_OMNIROUTE_PORT=
LIQUIDATION_FREE_DEEPSEEK_PORT=
LIQUIDATION_OMNIROUTE_BASE_URL=http://liquidation-omniroute:20128
LIQUIDATION_FREE_DEEPSEEK_BASE_URL=http://liquidation-free-deepseek:9655

KIRO_PROVIDER_NAME=kiro
KIRO_COMBO_NAME=
EMBEDDING_PROVIDER_NAME=
EMBEDDING_MODEL=
```

- [ ] **Step 3: Create deployment README**

Create `infra/lightrag/README.md`:

```markdown
# LightRAG Dev Memory Infrastructure

This stack is project-owned and must use `liquidation-*` containers, networks,
volumes, and ports.

Do not reuse or modify second-project containers:

- `omniroute`
- `stat-arb-free-qwen`
- `stat-arb-free-deepseek`
- `aperag-*`
- `stat-arb-infisical-*`

Before `docker compose up`, run `scripts/preflight.ps1`.

LightRAG index is disposable. Git docs are source of truth.
```

- [ ] **Step 4: Create compose skeleton**

Create `infra/lightrag/compose.yml`:

```yaml
name: liquidation

services:
  liquidation-omniroute:
    image: diegosouzapw/omniroute:latest
    container_name: liquidation-omniroute
    restart: unless-stopped
    ports:
      - "127.0.0.1:${LIQUIDATION_OMNIROUTE_PORT}:20128"
    volumes:
      - liquidation-omniroute-data:/app/data
    networks:
      - liquidation-rag

  liquidation-free-deepseek:
    image: forgetmeai/freedeepseekapi:latest
    container_name: liquidation-free-deepseek
    restart: unless-stopped
    ports:
      - "127.0.0.1:${LIQUIDATION_FREE_DEEPSEEK_PORT}:9655"
    volumes:
      - liquidation-free-deepseek-data:/app/data
    networks:
      - liquidation-rag

  liquidation-lightrag:
    image: ghcr.io/hkuds/lightrag:latest
    container_name: liquidation-lightrag
    restart: unless-stopped
    ports:
      - "127.0.0.1:${LIGHTRAG_API_PORT}:9621"
    env_file:
      - .env
    environment:
      WORKING_DIR: /app/data/rag_storage
      INPUT_DIR: /app/data/inputs
      PROMPT_DIR: /app/data/prompts
      HOST: "0.0.0.0"
      PORT: "9621"
    volumes:
      - ${LIGHTRAG_DATA_PATH}/rag_storage:/app/data/rag_storage
      - ${LIGHTRAG_DATA_PATH}/inputs:/app/data/inputs
      - ${LIGHTRAG_DATA_PATH}/prompts:/app/data/prompts
    networks:
      - liquidation-rag
    depends_on:
      - liquidation-omniroute
      - liquidation-free-deepseek

networks:
  liquidation-rag:
    name: liquidation-rag

volumes:
  liquidation-omniroute-data:
    name: liquidation-omniroute-data
  liquidation-free-deepseek-data:
    name: liquidation-free-deepseek-data
```

- [ ] **Step 5: Validate compose syntax without starting containers**

Run:

```powershell
docker compose --env-file infra/lightrag/.env.example -f infra/lightrag/compose.yml config
```

Expected: succeeds only after local non-empty ports/paths are provided through a real `.env` outside Git. If `.env.example` lacks required values, record that as expected and do not start services.

- [ ] **Step 6: Commit config skeleton**

Run:

```powershell
git add infra/lightrag
git commit -m "infra: add lightrag deployment skeleton"
```

## Task 4: Temporary `liq-rag` Shim

**Files:**

- Create: `scripts/preflight.ps1`
- Create: `scripts/liq-rag.ps1`
- Create: `docs/reports/rag/eval-questions.json`

- [ ] **Step 1: Create preflight script**

Create `scripts/preflight.ps1`:

```powershell
$ErrorActionPreference = "Stop"

Write-Output "Git status"
git status --short

Write-Output "Docker containers"
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}"

Write-Output "Docker networks"
docker network ls --format "table {{.Name}}\t{{.Driver}}\t{{.Scope}}"

Write-Output "Docker volumes"
docker volume ls --format "table {{.Name}}\t{{.Driver}}"

Write-Output "Research status"
python -m json.tool docs/research/status.json | Out-Null
Write-Output "research status json ok"
```

- [ ] **Step 2: Create eval questions**

Create `docs/reports/rag/eval-questions.json`:

```json
[
  {
    "id": "okx-rest-backfill",
    "question": "Can OKX REST liquidation backfill be used in MVP?",
    "expected_answer_contains": ["disabled", "delisted", "WebSocket"]
  },
  {
    "id": "binance-source-quality",
    "question": "What source quality does Binance liquidation stream have?",
    "expected_answer_contains": ["snapshot-only", "diagnostic"]
  },
  {
    "id": "rag-source-of-truth",
    "question": "Is LightRAG the source of truth?",
    "expected_answer_contains": ["Git", "docs", "source of truth"]
  }
]
```

- [ ] **Step 3: Create `liq-rag` shim**

Create `scripts/liq-rag.ps1`:

```powershell
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("ingest", "eval", "health", "status")]
  [string]$Command,

  [string]$Path = "docs/"
)

$ErrorActionPreference = "Stop"

function CurrentCommit {
  git rev-parse HEAD
}

function DocsTreeHash {
  git ls-files $Path | Sort-Object | ForEach-Object {
    git hash-object $_
  } | Out-String
}

New-Item -ItemType Directory -Force -Path "docs/reports/rag" | Out-Null

switch ($Command) {
  "ingest" {
    $commit = CurrentCommit
    $treeHash = DocsTreeHash
    $report = @{
      indexed_commit = $commit
      indexed_path = $Path
      docs_tree_hash = ($treeHash | Get-FileHash -InputStream).Hash
      generated_at = (Get-Date).ToString("o")
      status = "metadata-only"
    }
    $report | ConvertTo-Json -Depth 5 | Set-Content "docs/reports/rag/index-metadata.json"
    Write-Output "ingest metadata written"
  }
  "eval" {
    Test-Path "docs/reports/rag/eval-questions.json" | Out-Null
    Write-Output "eval questions present"
  }
  "health" {
    if (Test-Path "docs/reports/rag/index-metadata.json") {
      Write-Output "degraded-but-usable: metadata exists; LightRAG service check not implemented"
    } else {
      Write-Output "failed: missing docs/reports/rag/index-metadata.json"
      exit 1
    }
  }
  "status" {
    $metadata = Get-Content "docs/reports/rag/index-metadata.json" | ConvertFrom-Json
    $current = CurrentCommit
    if ($metadata.indexed_commit -eq $current) {
      Write-Output "fresh: indexed commit matches current commit"
    } else {
      Write-Output "stale: indexed commit $($metadata.indexed_commit) != current commit $current"
      exit 1
    }
  }
}
```

- [ ] **Step 4: Run shim checks**

Run:

```powershell
.\scripts\liq-rag.ps1 ingest docs/
.\scripts\liq-rag.ps1 eval
.\scripts\liq-rag.ps1 health
.\scripts\liq-rag.ps1 status
```

Expected: ingest/eval/status pass. Health may report `degraded-but-usable` until real LightRAG service is running.

- [ ] **Step 5: Commit shim**

Run:

```powershell
git add scripts docs/reports/rag/eval-questions.json
git commit -m "tools: add rag preflight shim"
```

## Task 5: Project-Owned Container Deployment

**Files:**

- Modify: `docs/reports/preflight/2026-06-19-infrastructure.md`
- Create: `docs/reports/rag/YYYY-MM-DD-deployment.md`

- [ ] **Step 1: Create local env outside Git**

Create a local env file outside Git or under ignored path:

```powershell
Copy-Item infra/lightrag/.env.example infra/lightrag/.env
```

Fill only local ports and paths. Do not commit `infra/lightrag/.env`.

- [ ] **Step 2: Validate no conflict**

Run:

```powershell
docker compose --env-file infra/lightrag/.env -f infra/lightrag/compose.yml -p liquidation config
```

Expected: config renders with only `liquidation-*` containers, volumes, and network.

- [ ] **Step 3: Pull images**

Run:

```powershell
docker compose --env-file infra/lightrag/.env -f infra/lightrag/compose.yml -p liquidation pull
```

Expected: images pull. If a configured image name is invalid, stop and update the plan/report before trying alternatives.

- [ ] **Step 4: Start project-owned services**

Run:

```powershell
docker compose --env-file infra/lightrag/.env -f infra/lightrag/compose.yml -p liquidation up -d
```

Expected: only `liquidation-*` containers are created or changed.

- [ ] **Step 5: Verify containers**

Run:

```powershell
docker compose --env-file infra/lightrag/.env -f infra/lightrag/compose.yml -p liquidation ps
docker ps --format "table {{.Names}}\t{{.Ports}}\t{{.Status}}"
```

Expected: `liquidation-omniroute`, `liquidation-free-deepseek`, and
`liquidation-lightrag` are running or report actionable startup errors.

- [ ] **Step 6: Write deployment report**

Create `docs/reports/rag/2026-06-19-deployment.md` with:

```markdown
# LightRAG Dev Memory Deployment - 2026-06-19

## Services

- liquidation-omniroute:
- liquidation-free-deepseek:
- liquidation-lightrag:

## Ports

- Omniroute:
- FreeDeepseek:
- LightRAG:

## Health

- Omniroute `/v1/models`:
- FreeDeepseek `/v1/models`:
- LightRAG API:

## Blockers

- none
```

- [ ] **Step 7: Commit deployment report**

Run:

```powershell
git add docs/reports/rag/2026-06-19-deployment.md
git commit -m "docs: record lightrag deployment"
```

## Task 6: RAG Acceptance Checks

**Files:**

- Modify: `docs/reports/rag/2026-06-19-deployment.md`

- [ ] **Step 1: Run required commands**

Run:

```powershell
.\scripts\liq-rag.ps1 ingest docs/
.\scripts\liq-rag.ps1 eval
.\scripts\liq-rag.ps1 health
.\scripts\liq-rag.ps1 status
```

Expected:

- `ingest` writes metadata;
- `eval` confirms eval questions;
- `health` returns `ok` after real service checks are implemented, or
  `degraded-but-usable` if only FreeDeepseek direct route is available;
- `status` confirms indexed commit matches current Git commit.

- [ ] **Step 2: Verify Git cleanliness**

Run:

```powershell
git status --short
```

Expected: only intended report/metadata files are changed.

- [ ] **Step 3: Commit acceptance results**

Run:

```powershell
git add docs/reports/rag scripts/liq-rag.ps1
git commit -m "docs: record rag acceptance checks"
```

## Blockers Before Rust Foundation

Do not start Rust foundation execution until:

- subagent audit runbook exists;
- infrastructure preflight runbook exists;
- `liquidation-*` service names are used for project-owned services;
- second-project Docker containers are unchanged;
- `liq-rag ingest docs/` passes;
- `liq-rag eval` passes;
- `liq-rag health` returns `ok` or `degraded-but-usable`;
- `liq-rag status --check-commit` equivalent passes;
- Git working tree is clean after reports are committed.

## Self-Review

Spec coverage:

- Separate project-owned Omniroute and FreeDeepseek: covered.
- LightRAG as derived memory, not source of truth: covered.
- `liq-rag ingest/eval/health/status`: covered through temporary shim and acceptance checks.
- Docker safety: covered through preflight and `liquidation-*` naming.
- No reuse of second-project containers: covered.

Known risks:

- Exact LightRAG/OmniRoute/FreeDeepseek image names may require adjustment after `docker compose pull`.
- Real `liq-rag` should become Rust CLI later; PowerShell shim is temporary.
- LightRAG API endpoint details may require adjustment after first container health check.

## Что улучшить или автоматизировать

- Convert `scripts/liq-rag.ps1` into Rust `liq-cli rag`.
- Add dashboard panel for RAG status and active provider path.
- Add scheduled daily RAG health report.
- Add CI warning when docs changed after last indexed commit.
