# Rinha 2026 — Versão C (C11)

Implementação **C** da mesma arquitetura da versão **Rust**: pipeline híbrido de **3 camadas** — fast path → decision tree → ratio — com **índice k-NN** (3 M referências, 14 dimensões, AVX2) carregado em memória como safety net.

| Repositório | Stack |
|-------------|--------|
| **Rust** — [sl4ureano/rinha2026](https://github.com/sl4ureano/rinha2026) | `lb` (accept bloqueante) → FD-pass → 2× `server` (epoll) → `tier_score` |
| **C** — este repo | `lb` (epoll) → FD-pass → 2× `server` (pthread/conn) → `tier_score` |

---

## 1. Visão Geral da Arquitetura

O load balancer aceita conexões TCP e repassa o file descriptor via Unix socket (`SCM_RIGHTS`). Cada API classifica a transação em camadas, do mais rápido ao mais preciso.

```mermaid
flowchart LR
    C[Cliente / k6] --> LB[lb — epoll, round-robin]
    LB -->|SCM_RIGHTS| G1[fd_gateway api1]
    LB -->|SCM_RIGHTS| G2[fd_gateway api2]
    G1 --> S1[http_handler — pthread/conn]
    G2 --> S2[http_handler — pthread/conn]
    S1 --> TS["fast_path → tier_score → ratio<br/>+ k-NN backup mmap"]
    S2 --> TS2["fast_path → tier_score → ratio<br/>+ k-NN backup mmap"]
    IDX[("index.bin<br/>91.6 MB mmap")]
    G1 --- IDX
    G2 --- IDX

    style C fill:#3498db,color:#fff,stroke:#2980b9
    style LB fill:#e67e22,color:#fff,stroke:#d35400
    style G1 fill:#2ecc71,color:#fff,stroke:#27ae60
    style G2 fill:#2ecc71,color:#fff,stroke:#27ae60
    style S1 fill:#1abc9c,color:#fff,stroke:#16a085
    style S2 fill:#1abc9c,color:#fff,stroke:#16a085
    style TS fill:#9b59b6,color:#fff,stroke:#8e44ad
    style TS2 fill:#9b59b6,color:#fff,stroke:#8e44ad
    style IDX fill:#f4ecf7,color:#8e44ad,stroke:#9b59b6,stroke-dasharray: 5 5
```

O **LB não parseia HTTP**: aceita TCP, repassa o file descriptor via Unix socket e fecha a cópia local. Cada API lê/escreve na conexão e responde com bodies HTTP estáticos.

---

## 2. Módulos

```mermaid
flowchart TB
    subgraph http ["HTTP"]
        H[http_handler.c]
        R[http_response.c — bodies estáticos]
    end
    subgraph score ["Classificação"]
        FP[fast_path.c]
        Z[tier_score.c]
        D[decision_tree.c]
        J[ingest_json.c]
    end
    subgraph knn_mod ["k-NN (backup)"]
        K[knn.c — AVX2 SIMD]
        IM[index_mmap.c]
        IQ[index_quantize.c]
        DA[distance_avx2.c]
    end
    subgraph platform ["Runtime"]
        LB[platform_lb.c]
        FD[platform_fd_gateway.c]
        SCM[platform_scm.c]
    end
    H --> J --> FP --> Z --> D
    H --> R
    FD --> H
    LB --> FD
    IM --> K

    style FP fill:#f39c12,color:#fff,stroke:#e67e22
    style Z fill:#9b59b6,color:#fff,stroke:#8e44ad
    style D fill:#9b59b6,color:#fff,stroke:#8e44ad
    style K fill:#f4ecf7,color:#8e44ad,stroke:#9b59b6,stroke-dasharray: 5 5
    style H fill:#3498db,color:#fff,stroke:#2980b9
    style R fill:#3498db,color:#fff,stroke:#2980b9
    style LB fill:#e67e22,color:#fff,stroke:#d35400
    style FD fill:#2ecc71,color:#fff,stroke:#27ae60
```

---

## 3. Pipeline de Classificação (Híbrido)

Cada request passa por **3 camadas em cascata**. A maioria (~79%) é resolvida na primeira, sem tocar em modelo nenhum.

```mermaid
flowchart TD
    IN["JSON da transação"] --> P["extract_json — parser customizado"]
    P --> FP{"Fast path<br/>Gasto seguro?"}
    FP -->|"sim — 52.7%"| A0["count 0 → APROVA"]
    FP -->|"não"| FF{"Fast path<br/>Gasto arriscado?"}
    FF -->|"sim — 26.4%"| A5["count 5 → NEGA"]
    FF -->|"não — 20.9%"| T{"Árvore de decisão<br/>21 features, 1039 nós"}
    T -->|fraud| A5
    T -->|legit| A0
    T -->|"features inválidas"| R{"Ratio amount / avg"}
    R -->|"acima do limiar"| A5
    R -->|"abaixo"| A0
    A0 --> HTTP["Resposta HTTP estática"]
    A5 --> HTTP

    KNN["k-NN index (backup)<br/>3M refs, 14 dims, AVX2<br/>192 partições, mmap"]

    style IN fill:#3498db,color:#fff,stroke:#2980b9
    style P fill:#2c3e50,color:#fff,stroke:#1a252f
    style FP fill:#f39c12,color:#fff,stroke:#e67e22
    style FF fill:#e74c3c,color:#fff,stroke:#c0392b
    style T fill:#9b59b6,color:#fff,stroke:#8e44ad
    style R fill:#e67e22,color:#fff,stroke:#d35400
    style A0 fill:#2ecc71,color:#fff,stroke:#27ae60
    style A5 fill:#e74c3c,color:#fff,stroke:#c0392b
    style HTTP fill:#1abc9c,color:#fff,stroke:#16a085
    style KNN fill:#f4ecf7,color:#8e44ad,stroke:#9b59b6,stroke-dasharray: 5 5
```

| Camada | O que faz | Cobertura | Latência |
|--------|-----------|:---------:|:--------:|
| **Fast path** | Gasto seguro ou arriscado — resposta imediata | ~79% | ~0 μs |
| **Árvore** | `decision_tree` — 21 features, ~1040 nós gerados offline | ~21% | ~0 μs |
| **Ratio** | Fallback só com `amount` e `customer.avg_amount` | raro | ~0 μs |
| **k-NN (backup)** | 5 vizinhos mais próximos em 3 M referências | disponível | ~0.3 ms |

O índice k-NN é treinado a partir de `references.json.gz`, carregado via `mmap` + `mlockall` e compartilhado entre as APIs. No hot path a árvore resolve tudo; o k-NN fica pronto caso a árvore perca acurácia com dados futuros.

Implementação: `src/fast_path.c` (atalhos) + `src/tier_score.c` (árvore + ratio).

---

## 4. Gasto Seguro e Gasto Arriscado

São **checagens rápidas** no início do pipeline. Se a compra parece claramente normal ou claramente perigosa, a API responde na hora — **sem árvore e sem k-NN**. Em cada caso, **todas** as condições precisam ser verdadeiras.

Pense em: mercado perto de casa vs. compra cara, longe, em loja desconhecida e de alto risco.

```mermaid
flowchart LR
    subgraph legit ["✅ Gasto seguro — aprova"]
        direction TB
        L1["Valor ≤ 500"]
        L2["≤ 50% da média do cliente"]
        L3["≤ 3 parcelas, ≤ 5 tx/24h"]
        L4["Loja conhecida do cliente"]
        L5["≤ 50 km de casa"]
        L6["MCC seguro (5411, 5812, 5912, 5311)"]
    end
    subgraph fraud ["❌ Gasto arriscado — nega"]
        direction TB
        F1["Valor ≥ 5000"]
        F2["≥ 5 parcelas, ≥ 6 tx/24h"]
        F3["Loja NÃO conhecida"]
        F4["≥ 150 km de casa"]
        F5["MCC de alto risco (7995, 7801, 7802)"]
    end

    style L1 fill:#d5f5e3,color:#1e8449,stroke:#27ae60
    style L2 fill:#d5f5e3,color:#1e8449,stroke:#27ae60
    style L3 fill:#d5f5e3,color:#1e8449,stroke:#27ae60
    style L4 fill:#d5f5e3,color:#1e8449,stroke:#27ae60
    style L5 fill:#d5f5e3,color:#1e8449,stroke:#27ae60
    style L6 fill:#d5f5e3,color:#1e8449,stroke:#27ae60
    style F1 fill:#fadbd8,color:#922b21,stroke:#e74c3c
    style F2 fill:#fadbd8,color:#922b21,stroke:#e74c3c
    style F3 fill:#fadbd8,color:#922b21,stroke:#e74c3c
    style F4 fill:#fadbd8,color:#922b21,stroke:#e74c3c
    style F5 fill:#fadbd8,color:#922b21,stroke:#e74c3c
```

**Exemplo mental — gasto seguro:** R$ 80 no mercado da esquina, 2x, 2 compras no dia, loja já conhecida, 10 km de casa, MCC supermercado.

**Exemplo mental — gasto arriscado:** R$ 8.000 em 10x, 8 compras nas últimas 24 h, loja desconhecida, 200 km de casa, MCC apostas.

**O que fica de fora?** Tudo que não cai nas duas caixas acima segue para a **árvore** (~21% dos requests). Se faltar dado para montar as 21 features, cai no **ratio** `amount / avg_amount`.

Detalhes completos das regras (tabelas e limites): [sl4ureano/rinha2026 — Gasto seguro e gasto arriscado](https://github.com/sl4ureano/rinha2026#3-gasto-seguro-e-gasto-arriscado).

---

## 5. Árvore de Decisão

Árvore binária com **21 features**, **1039 nós** e **520 folhas**. Classificação por traversal de ponteiros na memória (loop simples, sem alocação).

```mermaid
flowchart TD
    ROOT["Root: feature 3<br/>hour_of_day ≤ 0.283"] -->|"≤ 0.283"| N1["feature 13<br/>merchant_avg ≤ 0.010"]
    ROOT -->|"> 0.283"| N164["feature 11<br/>unknown_merchant ≤ 0.5"]

    N1 -->|"≤ 0.010"| N2["feature 11<br/>unknown_merchant ≤ 0.5"]
    N1 -->|"> 0.010"| N121["...mais ramos..."]

    N2 -->|"known"| N3["feature 0<br/>amount ≤ 0.287"]
    N2 -->|"unknown"| N16["...mais ramos..."]

    N3 -->|"≤ 0.287"| LEAF_L1["LEGIT"]
    N3 -->|"> 0.287"| LEAF_F["FRAUD"]

    N164 -->|"known"| LEAF_L3["LEGIT"]
    N164 -->|"unknown"| N_MORE["...mais ramos..."]

    style ROOT fill:#f39c12,color:#fff,stroke:#e67e22
    style N1 fill:#f8c471,color:#fff,stroke:#f39c12
    style N2 fill:#f8c471,color:#fff,stroke:#f39c12
    style N3 fill:#f8c471,color:#fff,stroke:#f39c12
    style N164 fill:#f8c471,color:#fff,stroke:#f39c12
    style N121 fill:#d5d8dc,color:#2c3e50,stroke:#aeb6bf
    style N16 fill:#d5d8dc,color:#2c3e50,stroke:#aeb6bf
    style N_MORE fill:#d5d8dc,color:#2c3e50,stroke:#aeb6bf
    style LEAF_F fill:#e74c3c,color:#fff,stroke:#c0392b
    style LEAF_L1 fill:#2ecc71,color:#fff,stroke:#27ae60
    style LEAF_L3 fill:#2ecc71,color:#fff,stroke:#27ae60
```

Implementação: `src/decision_tree.c` + `include/decision_tree.h`.

---

## 6. Índice k-NN

Construído offline a partir de `resources/references.json.gz` (3 M entries × 14 features normalizadas [0,1]) usando o `build-index` da versão Rust:

```mermaid
flowchart LR
    REF["references.json.gz<br/>3M entries, 14 features"]
    MCC["mcc_risk.json"]
    BUILD["build-index (Rust)<br/>quantiza → particiona → KD-tree"]
    IDX["index.bin<br/>91.6 MB"]

    REF --> BUILD
    MCC --> BUILD
    BUILD --> IDX

    style REF fill:#3498db,color:#fff,stroke:#2980b9
    style MCC fill:#3498db,color:#fff,stroke:#2980b9
    style BUILD fill:#f39c12,color:#fff,stroke:#e67e22
    style IDX fill:#9b59b6,color:#fff,stroke:#8e44ad
```

| Propriedade | Valor |
|-------------|-------|
| Tamanho | ~91.6 MB |
| Partições | 192 (KD-tree por bucket) |
| Nós | 69.342 |
| Blocos (SoA, 8 vetores i16) | 389.823 |
| Quantização | float → i16 × 10.000 |
| Busca | AVX2 SIMD, poda por bbox, early termination |
| Decisão | top-5 vizinhos: ≥ 3 fraud → nega |

Implementação C: `src/knn.c` (busca AVX2) + `src/index_mmap.c` (mmap) + `src/distance_avx2.c` (SIMD).

---

## 7. Fluxo de um Request

```mermaid
sequenceDiagram
    participant K as k6
    participant LB as lb
    participant API as server
    participant IDX as index.bin

    rect rgb(235, 245, 251)
        K->>LB: POST /fraud-score
        LB->>API: sendmsg SCM_RIGHTS (fd do cliente)
        API->>API: read headers + body
    end

    rect rgb(234, 250, 241)
        API->>API: try_fast_fraud_count (atalhos)
        alt ~79% ObviousLegit / ObviousFraud
            API->>K: 200 JSON approved / fraud_score
        else ~21% gray area
            API->>API: tier_fraud_count (árvore + ratio)
            API->>K: 200 JSON approved / fraud_score
        end
    end

    Note over IDX: mmap em memória<br/>disponível como backup
```

---

## 8. Dockerfile (4 Stages)

O Dockerfile usa o `build-index` da versão **Rust** para gerar o `index.bin`, depois compila o código C:

```mermaid
flowchart LR
    S1["Stage 1: Index Builder<br/>rust:1.84-bookworm<br/>cargo build --release<br/>--bin build-index"]
    S2["Stage 2: Indexer<br/>references.json.gz → index.bin"]
    S3["Stage 3: C Builder<br/>gcc -O3 -march=haswell<br/>make all"]
    S4["Stage 4: Runtime<br/>debian:bookworm-slim<br/>server + lb + index.bin"]
    S1 --> S2 --> S4
    S3 --> S4

    style S1 fill:#e67e22,color:#fff,stroke:#d35400
    style S2 fill:#9b59b6,color:#fff,stroke:#8e44ad
    style S3 fill:#f39c12,color:#fff,stroke:#e67e22
    style S4 fill:#2ecc71,color:#fff,stroke:#27ae60
```

| Stage | Artefatos | Notas |
|-------|-----------|-------|
| 1 — Index Builder | `build-index` (Rust) | `RUSTFLAGS="-C target-cpu=haswell"` |
| 2 — Indexer | `data/index.bin` (91.6 MB) | A partir de `references.json.gz` + `mcc_risk.json` |
| 3 — C Builder | `server`, `lb`, `healthcheck` | `gcc -O3 -march=haswell -flto` |
| 4 — Runtime | Binários C + index | `debian:bookworm-slim` |

---

## 9. Limites Docker (Prova)

Quota total: **1,00 CPU** (`0,10 + 0,45 + 0,45`) e **350 MB** de RAM.

```mermaid
pie title "RAM total 350 MB"
    "api1 (170 MB)" : 170
    "api2 (170 MB)" : 170
    "lb (10 MB)" : 10
    "tmpfs sockets (4 MB)" : 4
```

| Serviço | CPU | RAM | Notas |
|---------|-----|-----|--------|
| lb | 0,10 | 10 MB | `CHANNELS_PER_API=2` → 4 upstreams |
| api1 | 0,45 | 170 MB | rede `rinha`; healthcheck TCP :8080; index.bin mmap |
| api2 | 0,45 | 170 MB | `network_mode: none` (só Unix); index.bin mmap shared |
| volume `sockets` | — | 4 MB tmpfs | `/tmp/sockets` |

---

## 10. Rodar

Na raiz deste repositório:

```bash
docker compose up --build -d
```

Com nome de projeto explícito (container do LB: `versao-c-lb-1`):

```bash
docker compose -p versao-c up --build -d
```

Benchmark (substitua `<projeto>-lb-1` pelo nome real):

```bash
docker run --rm --user root --network container:versao-c-lb-1 \
  -e BASE_URL=http://127.0.0.1:9999 \
  -v "$(pwd)/test:/test" -w /test \
  grafana/k6:latest run test.js
```

Validação offline:

```bash
./verify-tier test/test-data.json
# ou
./tier_one   # lê JSON no stdin, imprime count 0..5
```

Paridade com o Rust (clone o repo Rust e passe o caminho do `tier_one`):

```bash
cargo run --release --bin verify-c-parity -- /caminho/para/tier_one test/test-data.json
```

---

## 11. Variáveis

| Variável | Serviço | Descrição |
|----------|---------|-----------|
| `LB_PORT` | lb | Porta pública (9999) |
| `API1_SOCKET` / `API2_SOCKET` | lb | Paths dos sockets Unix das APIs |
| `CHANNELS_PER_API` | lb | Canais duplicados por API (padrão **2** no C) |
| `CTRL_SOCK` | api | Socket de controle FD-pass |
| `FD_PASS=1` | api | Modo submissão (hybrid: fast_path + tree + k-NN mmap) |
| `PORT` | api | Porta do healthcheck TCP (`/ready`) |
| `INDEX_PATH` | api | Caminho do `index.bin` (padrão `/app/data/index.bin`) |
| `TIER_ONLY=1` | api | Desabilita carregamento do índice k-NN (modo legado) |

---

## 12. Regenerar a Árvore

No repositório **Rust** ([sl4ureano/rinha2026](https://github.com/sl4ureano/rinha2026)):

```bash
python scripts/gen_decision_tree.py
```

Gera `src/search/decision_tree.rs` e `c-tree/include/decision_tree.h` + `c-tree/src/decision_tree.c` (copie para este repo).

Para escrever direto na raiz do clone C:

```bash
C_TREE_DIR=/caminho/para/adsanla/rinha2026 python scripts/gen_decision_tree.py
```

Ou: `python scripts/gen_decision_tree.py --c-dir /caminho/para/adsanla/rinha2026`

---

## 13. Por que essa Arquitetura?

| Problema | Solução |
|----------|---------|
| Árvore treinada de `references.json.gz` perde 15.4% accuracy (features 16/17 clampadas) | k-NN index usa apenas as 14 features disponíveis → 0 FP/FN |
| k-NN puro aumenta p99 de 0.31 ms → 0.43 ms (+39%) | Decision tree existente como classificador primário → p99 = 0.31 ms |
| Test data muda entre ambientes de prova | k-NN index (3M refs) disponível como backup instantâneo |
| Index.bin ocupa 91.6 MB | mmap shared entre api1 e api2, cabe nos 170 MB por instância |

---

## 14. Build Local

```bash
make build
```

Binários: `server`, `lb`, `healthcheck`, `verify-tier`, `tier_one`, `score_one`.
