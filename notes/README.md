# Notes

Drafts: upstream reports from what the sandbox found (nothing filed yet;
written to paste into an issue as they are), and design notes.

- [`upstream-gdal-warp-antimeridian.md`](upstream-gdal-warp-antimeridian.md):
  gdalwarp reads a full-width strip of a global lon/lat source when the target
  crosses the antimeridian. The target needs two edge windows, 11.3× fewer
  pixels. rwarp's fix: hypertidy/rwarp#57.
- [`upstream-gdal-gtiff-adviseread.md`](upstream-gdal-gtiff-adviseread.md):
  GTiff fetches a window's tiles in parallel, but separate windows queue, and
  `AdviseRead()` is a no-op. A request for a prefetch across several windows.

- [`own-url-policy.md`](own-url-policy.md): a draft policy for warping URLs the
  catalogue doesn't list: the risks, rules every tier keeps, tiers from "just
  you through the tunnel" to shared, and the decisions it needs.

The evidence for the upstream reports is in [`../bench/README.md`](../bench/README.md),
sections 4 and 5, and the scripts beside it.
