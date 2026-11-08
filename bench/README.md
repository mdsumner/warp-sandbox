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

## 4. Where could rwarp win? (`where-rwarp-wins.R`, 2026-11-08)

Eight COG geometries (pole inside and off-centre, antimeridian, small oblique,
identity, 2048² output, lanczos 1024², polar IBCSO to lon/lat), each with
rwarp's plan, GDAL's chunks and kernel (`gdalwarp --debug on`), bytes and GETs
per engine (GDAL's network statistics, fresh process each), cold and warm.

- **Same reads, every case.** rwarp's plan and GDAL's warp chose the same single
  source window, to the pixel, and fetched the same bytes in the same 2 GETs
  (GDAL merges the ranges). So no fetch advantage today, and nothing for
  concurrent fetching to overlap at this size.
- **Warm, rwarp is 1.2-3.6x slower.** Worst on tiny work (identity 0.036 vs
  0.010 s, small oblique 0.042 vs 0.017): a fixed ~20-25 ms (plan, R
  conversions). Lanczos 1024²: 0.69 vs 0.27. Antimeridian: 0.157 vs 0.057, where
  rwarp's source read passes 2.26 M pixels through R.
- **Source type makes no difference.** Int16, Float32 and Byte (the same
  geometry through vrt://) time the same. GDAL used `GWKRealCase` for all of
  them, because GEBCO has nodata, which rules out its Byte fast paths.
- **Plan reuse saves ~10 ms per date** (GHRSST, 10 dates: 67 -> 57 ms; gdal-direct 42 ms).
- **The opportunity: the antimeridian.** Destination around 180° (laea lon_0=180,
  ±1500 km): both engines read one full-width strip of the source, 5400 × 418
  at overview 3 = 2.26 M pixels, 7.4 MB. The destination touches only two
  edges: two 234 × 416 windows = 195 k pixels, **11.6x fewer**. A planner that
  splits a chunk whose source window wraps the dateline would cut cold time on
  remote data, which is the time that dominates (cold 2-4 s vs warm 0.01-0.7 s).
