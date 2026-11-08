# Notes

Drafts of upstream reports from what the sandbox found. Nothing here has been
filed; they're written so they can be pasted into an issue as they are.

- [`upstream-gdal-warp-antimeridian.md`](upstream-gdal-warp-antimeridian.md):
  gdalwarp reads a full-width strip of a global lon/lat source when the target
  crosses the antimeridian. The target needs two edge windows, 11.3× fewer
  pixels. rwarp's fix: hypertidy/rwarp#57.
- [`upstream-gdal-gtiff-adviseread.md`](upstream-gdal-gtiff-adviseread.md):
  GTiff fetches a window's tiles in parallel, but separate windows queue, and
  `AdviseRead()` is a no-op. A request for a prefetch across several windows.

The evidence for both is in [`../bench/README.md`](../bench/README.md),
sections 4 and 5, and the scripts beside it.
