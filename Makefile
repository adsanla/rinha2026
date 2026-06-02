CC = gcc
CFLAGS = -O3 -march=haswell -mtune=haswell -flto -fno-plt -fno-semantic-interposition \
	-Wall -Wextra -DNDEBUG -Iinclude
LDFLAGS = -flto -pthread

# --- Lever 3: PGO + -funroll-loops (MEDIDO: net-negativo neste workload) ---
# Microbench (best-de-60 sobre as 54.100 transacoes de teste, ns/req):
#   -O3 base ............... ~1152
#   -O3 + -funroll-loops ... ~1316  (+14%, pior)
#   -O3 + PGO (sem unroll) . ~1243  (pior)
#   -O3 + PGO + unroll ..... ~1229  (pior)
# O hot path e parser de bytes + arvore de decisao pequena; o -O3 ja gera o
# layout ideal e unroll/PGO incham o codigo (pressao de I-cache). Por isso o
# build padrao NAO usa nenhum dos dois. O alvo `make pgo` abaixo fica como
# ferramenta opt-in (NAO usar pra prod): builda em 2 fases treinando no dataset.
# Use no HOST: `make pgo PGO_DATA=/caminho/test-data.json`.
PGO_DIR ?= pgo-data
PGO_DATA ?= /test/test-data.json
PGO_INDEX ?= data/index.bin
PGO_GEN = -fprofile-generate=$(PGO_DIR)
PGO_USE = -fprofile-use=$(PGO_DIR) -fprofile-correction -Wno-missing-profile

LIB_SRCS = src/index_mmap.c src/index_quantize.c src/knn.c src/distance_avx2.c \
	src/ingest_json.c src/ingest_features.c src/time_parse.c src/decision_tree.c src/tier_score.c \
	src/fast_path.c src/http_handler.c src/http_response.c src/platform_scm.c src/platform_fd_gateway.c

LIB_OBJS = $(LIB_SRCS:.c=.o)

.PHONY: all clean pgo
all: server lb healthcheck score_one verify-tier tier_one

# Build PGO em 2 fases: (1) instrumenta e treina no dataset; (2) recompila
# usando os perfis. So afeta os binarios finais; nao muda o `make all` padrao.
pgo:
	rm -rf $(PGO_DIR) && mkdir -p $(PGO_DIR)
	$(MAKE) clean
	$(MAKE) CFLAGS="$(CFLAGS) $(PGO_GEN)" LDFLAGS="$(LDFLAGS) $(PGO_GEN)" pgo_train
	./pgo_train $(PGO_DATA) $(PGO_INDEX) 20
	$(MAKE) clean
	$(MAKE) CFLAGS="$(CFLAGS) $(PGO_USE)" LDFLAGS="$(LDFLAGS) $(PGO_USE)" all
	rm -f pgo_train

pgo_train: src/pgo_train.c $(LIB_OBJS)
	$(CC) $(CFLAGS) -o $@ src/pgo_train.c $(LIB_OBJS) $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

server: src/server.c $(LIB_OBJS)
	$(CC) $(CFLAGS) -o $@ src/server.c $(LIB_OBJS) $(LDFLAGS)

lb: src/lb_main.c src/platform_lb.c src/platform_scm.c
	$(CC) $(CFLAGS) -o $@ src/lb_main.c src/platform_lb.c src/platform_scm.c $(LDFLAGS)

healthcheck: src/healthcheck.c
	$(CC) $(CFLAGS) -o $@ src/healthcheck.c $(LDFLAGS)

score_one: src/score_one.c $(LIB_OBJS)
	$(CC) $(CFLAGS) -o $@ src/score_one.c $(LIB_OBJS) $(LDFLAGS)

verify-tier: src/verify_tier.c $(LIB_OBJS)
	$(CC) $(CFLAGS) -o $@ src/verify_tier.c $(LIB_OBJS) $(LDFLAGS)

tier_one: src/tier_one.c src/ingest_json.o src/ingest_features.o src/time_parse.o src/decision_tree.o src/tier_score.o
	$(CC) $(CFLAGS) -o $@ src/tier_one.c src/ingest_json.o src/ingest_features.o src/time_parse.o src/decision_tree.o src/tier_score.o $(LDFLAGS)

clean:
	rm -f server lb healthcheck score_one verify-tier tier_one pgo_train $(LIB_OBJS)
