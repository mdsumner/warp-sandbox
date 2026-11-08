# Draft upstream report: GTiff `AdviseRead()` as a prefetch for several windows

*Draft for OSGeo/gdal, not filed yet. Written 2026-11-08 against
GDAL 3.14.0dev-fa1fc3c77e. A feature request, not a bug.*

---

**Title:** GTiff: implement `AdviseRead()` so callers can prefetch several
windows over /vsicurl/ before reading them

## Background

Within one `RasterIO()` call, GTiff over `/vsicurl/` already fetches the
window's tiles in parallel: `CacheMultiRange()` hands their ranges to
`VSIFReadMultiRangeL()`, and `GDAL_HTTP_MULTIRANGE` defaults to `PARALLEL`.
We checked this against a local test server that adds a fixed 0.4 s per
request: a window spanning two rows of tiles came back in one round trip
(0.41 s), with both range requests finishing together.

Across calls, though, each `RasterIO()` waits for the one before it. A caller
that needs several separate windows of one file makes one round trip per
window, even when it knows every window in advance. A warp that splits at the
antimeridian is one such caller: a chunk on each side and two edge windows for
the gap. A tile server assembling a mosaic is another.

## What `AdviseRead()` does now

GTiff doesn't override `AdviseRead()`. The dataset-level default forwards to
the bands, and `GDALRasterBand::AdviseRead()` returns `CE_None` without doing
anything. So calling it on each window before reading them changes nothing.
That's what we measured through GDAL7's `advise_read()`.

## The request

Have GTiff's `AdviseRead()` (dataset and band) work out the tile ranges for the
region, as `CacheMultiRange()` already does, and fetch them, ideally in the
background, and **accumulating across calls**. A caller can then advise every
window and read them afterwards, and the requests overlap. The multi-threaded
read path already uses the `/vsicurl/` handle's `AdviseRead()` with a byte
limit (`GetAdviseReadTotalBytesLimit()`), so much of the machinery seems to
exist.

## Workaround, and what it gains

One dataset handle per window, each read on its own thread, all sharing the
process-wide `/vsicurl/` cache (mdsumner/warp-sandbox `inst/cpp/read_windows.cpp`).
In the antimeridian case from the companion report, at 0.4 s per request and
5 MB/s, that takes rwarp's warp from 1.79 s to 1.35 s. It works, but every
caller has to write it, and it costs a handle per thread.

## Questions

- Is there an existing route to this that we missed (an open option, or the
  `GDAL_NUM_THREADS` path, under conditions our reads didn't meet)?
- Would an accumulating `AdviseRead()` be the right shape, or something like a
  multi-window `RasterIO()`?
