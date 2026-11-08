# Draft upstream report: gdalwarp reads a full-width strip at the antimeridian

*Draft for OSGeo/gdal, not filed yet. Written 2026-11-08 against
GDAL 3.14.0dev-fa1fc3c77e.*

---

**Title:** gdalwarp: a target crossing the antimeridian of a global lon/lat
source reads a full-width strip of the source

## What happens

Warp a global longitude/latitude raster to a target centred on 180°. The
target needs only the two edges of the source, near -180 and near +180, but
gdalwarp reads one window spanning the whole source width.

```sh
CPL_VSIL_NETWORK_STATS_ENABLED=YES CPL_VSIL_SHOW_NETWORK_STATS=YES \
gdalwarp --debug on -q -t_srs "+proj=laea +lat_0=-17 +lon_0=180" \
  -te -1500000 -1500000 1500000 1500000 -ts 384 384 -r bilinear -ovr 3 \
  /vsicurl/https://data.source.coop/ausantarctic/gebco/GEBCO_2025.tif out.tif
```

```
WARP: dfXScale = 0.899392, dfYScale = 0.944255
GDAL: GDALWarpKernel()::GWKRealCase() Src=0,1393,5400x418 Dst=0,0,384x384
```

That's one chunk whose source window is the full 5400-pixel width of
overview 3: 2,257,200 source pixels. The network statistics show 7.6 MB
fetched from the file, 7.57 MB of it in one multi-range GET.

## What the target needs

The target's pixels map to source columns 5168-5398 (west of 180°) and 1.6-232
(east of it). Two windows, 235 × 418 at each edge, hold every source pixel it
reads: **200,600 pixels, 11.3× fewer**, about 1.2 MB (whole COG tiles).

## Why

`ComputeSourceWindow()` takes the bounding box of the transformed sample
points. Across the antimeridian those points sit at both ends of the source,
so the box spans more than 90% of the width and the 90% rule
(gdalwarpoperation.cpp) snaps it to the whole width. The fill ratio of that
window stays high, so `CollectChunkList()` has no reason to split the chunk.

## A fix, as tried in rwarp

[rwarp](https://github.com/hypertidy/rwarp), a Rust port of GDAL's warp planning
and kernels, does this (hypertidy/rwarp#57):

1. When a chunk's window snaps to full width, find the target columns where
   the source x jumps by more than half the source width, and split the chunk
   there. The two sides get compact windows.
2. The few columns at the jump map to *both* edges, but each pixel needs only
   one. Those columns become two chunks on the same target window, one source
   window at each edge. GDAL's kernel already skips a target pixel whose
   source falls outside the chunk's window, so each pass fills its own pixels.
   They're combined by writing only the pixels each pass produced.
3. Keep the split only if it reads under half of the full-width window. Around
   a pole every longitude is needed and splitting saves nothing, so EPSG:3031
   targets keep the plan they have now.

With an exact transformer the output is identical to the unsplit warp, for
nearest, bilinear and cubic, and for Int16, Float32 and Byte. With the default
`-et 0.125` it differs within that tolerance, as any change of chunking does,
because the approximate transformer interpolates between different nodes.

## Why it matters

Cold reads from object storage. Against a local server with a fixed 0.4 s per
request and 5 MB/s per connection (harness in mdsumner/warp-sandbox,
`bench/latency-local.R` and `bench/slow_range_server.py`), the case above takes
3.06 s through GDAL's warp API. rwarp takes 1.35 s with the split and the
chunks' windows fetched at once (1.79 s with the split alone). The difference
is the 7.4 MB strip at 5 MB/s.

Any Pacific-centred view of a global lon/lat product pays this: Fiji, Tonga, the
Ross Sea, an EPSG:3832 map.

## Questions

- Is there an existing option for this that we missed? We didn't find one
  among the warp options.
- Would a split like this be welcome in `CollectChunkList()`, perhaps behind a
  warp option at first?
