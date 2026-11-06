# Speed: where the time goes

Measured 2026-11-05/06 on ecostats (32 cores, idle), GDAL 3.14.0dev
(739fcf03bf), rwarp R package from hypertidy/rwarp#56. Single-threaded on
both sides.

## 1. Fetching is the same

On GEBCO 2025 to polar stereographic (384², bilinear), rwarp's plan and
gdalwarp read **the same source window** (overview 6, `0,244 675x93`;
GDAL's kernel log says `Src=0,244,675x93`) with **the same three HTTP range
requests**. Reading that window through gdalraster takes 8 ms once the bytes
are local, and the R read function's conversions (nodata back from `NA`,
`as.integer`) about 30 ms.

## 2. Over the network, no engine is consistently faster

`engines-cold-warm.R`: three requests, 5 runs each in random order, medians.

| request | cold: fastest to slowest (s) | warm (s) |
|---|---|---|
| GEBCO 384², bilinear | gdal-app 1.56, rwarp 2.07, gdal7-run 2.47, gdal-direct 2.55 | all 0.03-0.06 |
| GHRSST 256², cubic | gdal-app 1.46, rwarp 1.61, gdal7-run 1.99, gdal-direct 2.18 | all 0.03-0.06 |
| IBCSO 1024², lanczos | gdal-direct 3.17, gdal-app 3.76, gdal7-run 4.00, rwarp 4.54 | GDAL 1.84-2.05, rwarp 2.97 |

Cold timings are network noise; the order changes from request to request.
Warm and small, rwarp is about 20 ms behind (its plan is 11 ms). The one
real gap is warm IBCSO lanczos at 1024², which is the kernel (below).

## 3. The kernels: rwarp is 1.5-5x slower, with identical output

`kernels-in-memory.R`: an uncompressed in-memory copy of IBCSO 2025 bed at
overview 2 (2400², Int16), to EPSG:3031, no network and no decompression.
Every output is identical to gdal-direct's, value for value.

| kernel | 512² | 1024² | 2048² |
|---|---|---|---|
| near | 0.032 / 0.016 (2.0x) | 0.074 / 0.026 (2.8x) | 0.205 / 0.077 (2.7x) |
| bilinear | 0.115 / 0.054 (2.1x) | 0.128 / 0.072 (1.8x) | 0.442 / 0.262 (1.7x) |
| cubic | 0.293 / 0.101 (2.9x) | 0.242 / 0.111 (2.2x) | 0.896 / 0.405 (2.2x) |
| lanczos | 0.724 / 0.133 (**5.4x**) | 1.208 / 0.246 (**4.9x**) | 2.524 / 0.708 (3.6x) |
| average | 0.094 / 0.048 (2.0x) | 0.182 / 0.118 (1.5x) | 0.509 / 0.348 (1.5x) |

(rwarp seconds / gdal-direct seconds.) rwarp's time includes its plan, the
interleave from R and building the R array; those are small next to the
kernel for the interpolating methods.

**So:** a faster read path for rwarp (GDAL in C++) would not change much. The
gap is in rwarp's kernels, largest for lanczos, which GDAL runs through a
dedicated path (`GWKResampleOptimizedLanczos` in `gdalwarpkernel.cpp`). That
is work in hypertidy/rwarp: profile the kernel loop there (a Rust bench on
this case), not in the sandbox.
