#ifndef CPKG_H
#define CPKG_H
#include <stdint.h>
typedef struct { const int32_t *data; int64_t len; } cpkg_cslice_i32;   /* const i32[:] */
typedef struct { int64_t count; int64_t sum; } cpkg_info;                /* cpkg::Info (packed, no padding: 16 bytes) */
#endif
