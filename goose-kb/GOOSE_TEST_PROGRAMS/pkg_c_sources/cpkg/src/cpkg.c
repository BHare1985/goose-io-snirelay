#include "cpkg.h"
#include "goose.h"   /* the compiler puts this on the include path of every native part */
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>

int64_t cpkg_sum(cpkg_cslice_i32 xs) { int64_t t = 0; for (int64_t i = 0; i < xs.len; i++) t += xs.data[i]; return t; }
void cpkg_fill(cpkg_cslice_i32 xs, cpkg_info *out) { out->count = xs.len; out->sum = cpkg_sum(xs); }
void cpkg_describe(gs_rref out, int64_t n) { char b[64]; int k = snprintf(b, sizeof b, "n=%ld sqrt=%.3f", (long)n, sqrt((double)n)); gs_bld_append(out, b, k); }
typedef struct { int64_t state; } cpkg_gen;
int64_t cpkg_open(int64_t seed) { cpkg_gen *g = malloc(sizeof *g); if (!g) return 0; g->state = seed; return (int64_t)(intptr_t)g; }
int64_t cpkg_next(int64_t h) { cpkg_gen *g = (cpkg_gen *)(intptr_t)h; g->state = g->state * 6364136223846793005LL + 1442695040888963407LL; return g->state >> 33; }
void cpkg_close(int64_t h) { free((void *)(intptr_t)h); }
