/* Driver de treino para PGO (profile-guided optimization).
 * NAO faz parte do build de prod nem do alvo `all`. Exercita o caminho quente
 * (extract_json + try_fast_fraud_count + tier_fraud_count) sobre o dataset de
 * teste para gerar perfis .gcda usados na recompilacao com -fprofile-use.
 *
 * Uso (via `make pgo`): ./pgo_train <test-data.json> <index.bin> [reps] */
 #define _GNU_SOURCE
 #include "ingest.h"
 #include "tier_score.h"
 #include "fast_path.h"
 #include "index.h"
 
 #include <stdio.h>
 #include <stdlib.h>
 #include <string.h>
 
 extern int index_open(index_t *idx, const char *path);
 extern void index_init_empty(index_t *idx);
 
 #define MAXREQ 80000
 static const char *slices[MAXREQ];
 static size_t slens[MAXREQ];
 
 static int request_slice(const char *entry, const char **out, size_t *olen)
 {
     const char *k = strstr(entry, "\"request\"");
     if (!k) return 0;
     const char *obj = strchr(k, '{');
     if (!obj) return 0;
     int depth = 0;
     for (const char *p = obj; *p; p++) {
         if (*p == '{') depth++;
         else if (*p == '}') { depth--; if (depth == 0) { *out = obj; *olen = (size_t)(p - obj + 1); return 1; } }
     }
     return 0;
 }
 
 int main(int argc, char **argv)
 {
     const char *path = argc > 1 ? argv[1] : "/test/test-data.json";
     const char *index_path = argc > 2 ? argv[2] : "data/index.bin";
     int reps = argc > 3 ? atoi(argv[3]) : 10;
 
     FILE *f = fopen(path, "rb");
     if (!f) { fprintf(stderr, "pgo_train: sem dataset %s, pulando treino\n", path); return 0; }
     fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
     char *buf = malloc((size_t)sz + 1);
     if (!buf || fread(buf, 1, (size_t)sz, f) != (size_t)sz) { fclose(f); return 0; }
     buf[sz] = '\0'; fclose(f);
 
     index_t idx;
     if (index_open(&idx, index_path) != 0) { index_init_empty(&idx); idx.ready = 1; }
 
     int n = 0;
     const char *entries = strstr(buf, "\"entries\"");
     const char *p = entries ? strchr(entries, '[') : NULL;
     if (p) p++;
     while (p && *p && n < MAXREQ) {
         while (*p && (*p == ' ' || *p == ',' || *p == '\n' || *p == '\r')) p++;
         if (*p == ']' || *p != '{') break;
         const char *estart = p; int depth = 0; const char *eend = p;
         for (; *eend; eend++) { if (*eend == '{') depth++; else if (*eend == '}') { depth--; if (depth == 0) { eend++; break; } } }
         const char *req; size_t rlen;
         if (request_slice(estart, &req, &rlen)) { slices[n] = req; slens[n] = rlen; n++; }
         p = eend;
     }
 
     volatile unsigned long sink = 0;
     for (int r = 0; r < reps; r++) {
         for (int i = 0; i < n; i++) {
             raw_payload_t pl;
             if (extract_json((const uint8_t *)slices[i], slens[i], &pl)) {
                 int fast = try_fast_fraud_count(&idx, &pl);
                 sink += fast >= 0 ? (unsigned)fast : tier_fraud_count(&pl);
             }
         }
     }
     fprintf(stderr, "pgo_train: %d reqs x %d reps, sink=%lu\n", n, reps, sink);
     return 0;
 }
 