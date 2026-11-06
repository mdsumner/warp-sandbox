# warpsandbox

A test sandbox for raster warp engines: a plumber2 service that warps the
same request with several engines and compares the results, over a catalogue
of 102 cloud-ready sources.

## Run it

```sh
Rscript -e 'warpsandbox::sandbox_run()'          # 127.0.0.1:8090; under tmux on a server
ssh -L 8090:localhost:8090 <server>              # from your machine
```

then open <http://localhost:8090/>: pick a source and a destination, tick
engines, and see each one's image, timings and differences from the first.

## Engines

| engine | what |
|---|---|
| `rwarp` | [rwarp](https://github.com/hypertidy/rwarp) (Rust): `warp_plan()` + `warp_exec()`, reading with gdalraster |
| `gdal-app` | gdalwarp as a library, `gdalraster::warp()` |
| `gdal7-run` | `gdal raster reproject` through `GDAL7::gdal_run()` |
| `gdal-direct` | GDAL's warp API with no utility layer (transformer + `GDALWarpOperation::ChunkAndWarpImage`), through `GDAL7::warp_raster()` (rgdal-dev/GDAL7, branch `warp-raster`); without that, the prototype in `inst/cpp/gdal_direct.cpp`, compiled on first use with Rcpp |

A request is resolved once and every engine gets it unchanged: the same DSN,
the same destination grid, kernel and bands, and the **same overview level**
(`ovr=auto` picks the coarsest overview that is still at least as fine as the
destination). rwarp, gdal7-run and gdal-direct open the source with `OVERVIEW_LEVEL=k
only` (`only`, so GDAL can't pick a further overview by itself); gdal-app uses
gdalwarp's `-ovr k`, because `gdalraster::warp()` opens the source itself.
`/compare` clears GDAL's HTTP cache before each engine (`cold=true`), so
timings are comparable.

### What agrees (2026-11-05, GDAL 3.14.0dev)

All four engines give **identical values** on: GEBCO 2025 (bilinear, to
polar stereographic), GHRSST SST (cubic), IBCSO 2025 in EPSG:9354 (lanczos),
Bedmap3 with nodata (average), and Esri World Imagery over WMTS (4-band, to a
Lambert projection). On the WA tile cache (an alpha band), rwarp, gdalwarp
and gdal-direct are identical; gdal7-run differs, see below.

Speed: see [bench/README.md](bench/README.md). In short, rwarp and gdalwarp
read the same windows with the same HTTP requests, cold timings are network
noise, and with the data in memory rwarp's kernels are 1.5-3x slower than
GDAL's (lanczos up to 5x), with identical output.

### Findings

- **WMS and WMTS overview bands report no colour interpretation**
  (`Undefined` for every band; R/G/B/Alpha at full resolution; GeoTIFF is
  fine). So a tile service opened at an overview with `OVERVIEW_LEVEL=k` has
  no alpha band. gdalwarp with `-ovr k` still finds the alpha band on the full
  dataset and masks with it; `gdal raster reproject` (no `-ovr`, no
  `-srcalpha`) can only pin a level by opening the overview, so it warps
  alpha as data: fully transparent pixels keep their colour where gdalwarp
  writes 0. The sandbox takes the alpha band from the full-resolution dataset
  for rwarp. Parked upstream in mdsumner/osgeo-upstream
  (`notes/2026-11-05-overview-colour-interp.md`): a one-line cause in each
  driver.
- gdalraster's `$read()` returns nodata as `NA`. For integers that is
  -2147483648, which a warp reads as a value; the rwarp engine puts the
  nodata value back before warping.

## Mosaics: gti, and external overviews

Several catalogue sources are VRT mosaics of thousands of COG tiles (COP30,
COP90, NASADEM, SRTM15+, USGS seamless, REMA v2). Such a VRT exposes no
overviews of its own, so a coarse view through it reads full-resolution
tiles. Two ways round that:

- **`gti`** builds a GDAL raster tile index from the VRT's XML (tile files
  and footprints, `mosaic_tiles()`, cached; no tile is opened), keeps the
  tiles the request needs, and opens it with the request's grid as open
  options (`SRS` with **`SRS_BEHAVIOR=REPROJECT`**, `MINX/MINY/MAXX/MAXY`,
  `RESX/RESY`). GTI then warps each tile onto the grid from that tile's own
  overviews. `GDAL_DISABLE_READDIR_ON_OPEN=EMPTY_DIR` matters: without it,
  opening each tile lists a 26,000-file directory (200 s rather than 17 s).
  Refused above 400 tiles.
- **External overviews**, as [mdsumner/rema-ovr](https://github.com/mdsumner/rema-ovr)
  does for REMA: the VRT's band carries `<Overview>` elements pointing at
  coarser mosaics and COGs, which every engine uses as ordinary overviews.
  The catalogue's `rema_v2` is that VRT. (A GTI description accepts
  `<Overview>` too.)

What they give (2026-11-06):

| request | engines on the VRT | gti |
|---|---|---|
| COP90, Tasmania, 560² at 800 m (no pyramid) | full resolution: rwarp 23 s, gdalwarp 31 s, 49 MB | **17 s, 2.9 MB**, from tile overviews; values differ (overviews vs a wide kernel at full resolution: median 0 m, max 1279 m) |
| REMA v2, Antarctica, 512² (rema-ovr pyramid) | overview 4: 2-4 s, all four identical | refused: 5774 tiles |
| REMA v2, Davis, 20 km at 512² | overview 1 (10 m): ~4-5 s, identical to 2e-6 | 5 s, from the 2 m tiles' overviews: a different answer (max 25 m) |

So: gti for a regional view of a mosaic without a pyramid; a pyramid for wide
views.

The COP90 case is also the first request big enough for gdalwarp to split
into chunks, and there it differs from rwarp by up to 2.37 m; with `-wm 4G`
(one chunk) by 6e-5 (Float32 rounding). That is GDAL's kernel scale estimate
ignoring the chunk's offset, parked in mdsumner/osgeo-upstream.

## Endpoints

| | |
|---|---|
| `GET /` | the page |
| `GET /health` | versions |
| `GET /catalogue?theme=&origin=&ok_only=true` | sources |
| `GET /source?id=` | one source in full |
| `GET /engines` | engines and availability |
| `GET /plan?…` | rwarp's chunk plan (no pixels read) |
| `GET /warp?engine=&format=png\|json&palette=&…` | one engine |
| `GET /compare?engines=a,b,c&cold=true&images=false&…` | timings and differences from the first engine |

Request parameters: `source` (id or sds alias), `date` (dated sources),
`crs`, `extent=xmin,xmax,ymin,ymax` or `bbox=xmin,ymin,xmax,ymax`,
`dim=ncol,nrow` (up to 4096), `resample` (gdalwarp's kernels), `bands`, `ovr`
(`auto`, `none` or a level). Bad requests get a 400 with a message.

From R the same is `warp_request()`, `run_engine()`, `compare_engines()`,
`as_nara()` and `as_png()`.

## The catalogue

102 sources, built from two origins:

| origin | sources | what |
|---|---|---|
| [source.coop/ausantarctic](https://source.coop/ausantarctic) | 34 | Bedmap3 (7 layers), GEBCO 2024 to 2026, IBCSO v1, v2, annual 2024 and 2025 (bed, ice surface, RID, TID, charts), GHRSST MUR v2 (5 variables, daily from 2002-06-01) |
| the [sds](https://github.com/hypertidy/sds) registry | 68 | elevation and bathymetry VRTs and COGs (Copernicus, NASADEM, SRTM15+, REMA, older GEBCO, IBCSO, Tasmania 2 m), and 50+ WMTS / GDAL WMS imagery and basemaps |

All 102 open with GDAL (probed 2026-11-05, GDAL 3.14.0dev). Three sds entries
needed fixes first (sds branch `fix/wmts-esri-wa`): `esri_dark_gray` and
`esri_light_gray` (Esri renamed the layers to `Canvas_World_*_Gray_Base`), and
`wa_gsd_basemap`, whose WMTS tile matrix origin is written in the wrong axis
order for EPSG:7844 (now a GDAL_WMS TMS description of its tile cache).

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

- GDAL7 `warp_raster(nara = TRUE)` warps straight into a nativeRaster (MEM
  bands viewing its bytes); the page could use it for byte imagery instead of
  packing in R
- rwarp kernel speed (hypertidy/rwarp), lanczos first: see bench/
- a policy for your own URLs, before it runs anywhere public
