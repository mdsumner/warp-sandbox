# warpsandbox

A test sandbox for raster warp engines. The plan is a plumber2 service that
warps the same request with rwarp, GDAL (via gdalraster and vapour) and GDAL7,
and compares the results. This first part is **the catalogue**: what the
sandbox can warp.

## The catalogue

102 sources, built from two origins:

| origin | sources | what |
|---|---|---|
| [source.coop/ausantarctic](https://source.coop/ausantarctic) | 34 | Bedmap3 (7 layers), GEBCO 2024 to 2026, IBCSO v1, v2, annual 2024 and 2025 (bed, ice surface, RID, TID, charts), GHRSST MUR v2 (5 variables, daily from 2002-06-01) |
| the [sds](https://github.com/hypertidy/sds) registry | 68 | elevation and bathymetry VRTs and COGs (Copernicus, NASADEM, SRTM15+, REMA, older GEBCO, IBCSO, Tasmania 2 m), and 50+ WMTS / GDAL WMS imagery and basemaps |

Of the 102, GDAL opened 99 when probed (2026-11-05, GDAL 3.14.0dev). The three
it couldn't are sds WMTS entries: `esri_dark_gray` and `esri_light_gray` (Esri
renamed the layers to `Canvas_World_*_Gray_Base`) and `wa_gsd_basemap` (no
`layer=`, and two tile matrix sets both named `default`).

```r
library(warpsandbox)
x <- catalogue()                                # one row per source
catalogue(theme = "bathymetry", ok_only = TRUE)
source_dsn("ausantarctic/ibcso/annual-2025/bed")
source_dsn("gebco25")                           # sds names work as aliases
source_dsn("ausantarctic/ghrsst-mur-v2/analysed_sst", date = "2020-01-31")
```

Each row has:

- **what:** `id`, `title`, `origin`, `provider`, `theme`, `kind`, `variable`,
  `license`, `doi`, `aliases` (sds names), `notes`
- **where:** `dsn` (a `/vsicurl/` URL, a `WMTS:` string or inline GDAL XML),
  or for dated sources `dsn_template` (`{YYYY}`, `{MM}`, `{DD}`), with
  `time_step`, `time_start`, `time_end`
- **the grid, from GDAL** (headers only, so the service can plan without
  opening the source): `ncol`, `nrow`, `nbands`, `dtype`, extent and
  resolution, `n_overviews`, `block`, `nodata`, `scale`, `offset`, `crs`,
  `crs_wkt`, plus `probe_ok`, `probe_error` and `probe_seconds`

Dated sources are one row per variable, not one per day. The days, and each
day's status (`final`, `preliminary`, `nrt_only`), are in
`inst/catalogue/ghrsst-dates.csv`, taken from the repository's own STAC
parquet. `source_dsn()` refuses a date that isn't there.

Where an sds entry points at the same file as a source.coop one (GEBCO 2024 to
2026), there's one row, with the sds name in `aliases`.

### Files

- `inst/catalogue/catalogue.json`: everything, with build metadata
- `inst/catalogue/catalogue.csv`: the same without WKT (inline XML DSNs are
  marked, not inlined)
- `inst/catalogue/ghrsst-dates.csv`: GHRSST days and status

### Rebuilding

```sh
Rscript data-raw/build-catalogue.R     # about 5 minutes (listing, metadata and the GDAL probe)
```

This lists the bucket through its S3 API (`s3_list()`), reads each product's
README and `provenance.json` (or STAC item) for licence and DOI, reads the
GHRSST index, takes the warpable kinds from `sds::dsn_list()` (`cog`,
`vrt_url`, `vrt_file`, `xml_file`, `wmts`; not `dead`), merges duplicates and
probes each source.

## Next

- the service: `/catalogue`, then `/warp?engine=&source=&crs=&extent=&dim=`,
  `/plan`, `/compare` with the engines that work today (rwarp, gdalraster,
  GDAL7 `gdal_run("raster reproject")`)
- the GDAL7 direct engine (transformer + ReprojectImage into a nativeRaster)
- a policy for your own URLs
