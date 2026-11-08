## The warp sandbox API (plumber2). Start it with warpsandbox::sandbox_run().
##
## Query parameters common to /warp, /plan and /compare:
##   source    catalogue id or sds alias (see /catalogue)        required
##   date      for dated sources (GHRSST), YYYY-MM-DD             default latest
##   crs       destination CRS (EPSG:n or a PROJ string)         default the source's
##   extent    xmin,xmax,ymin,ymax in crs  (or bbox=xmin,ymin,xmax,ymax)
##   dim       ncol,nrow                                          default 512,512
##   resample  near bilinear cubic cubicspline lanczos average mode min max med rms
##   bands     e.g. 1 or 1,2,3                                    default by type
##   ovr       auto | none | 0-based overview level               default auto
##   vrt       vrt:// options to read the source through, URL-encoded, e.g.
##             vrt=ot%3DByte%26scale%3D-8000%2C0%2C0%2C255 (bands, ot, scale, ...)

library(warpsandbox)

## plumber2 may split comma lists into vectors; rejoin the ones that are text
q1 <- function(x) if (is.null(x)) NULL else paste(x, collapse = ",")

req_from <- function(query) {
  tryCatch(
    warp_request(source = q1(query$source), date = q1(query$date), crs = q1(query$crs),
                 extent = q1(query$extent), bbox = q1(query$bbox),
                 dim = q1(query$dim) %||% "512,512", resample = q1(query$resample) %||% "near",
                 bands = q1(query$bands), ovr = q1(query$ovr) %||% "auto", vrt = q1(query$vrt)),
    error = function(e) reqres::abort_bad_request(conditionMessage(e)))
}

`%||%` <- function(a, b) if (is.null(a) || !length(a) || !nzchar(a[1])) b else a

#* The sandbox page
#* @get /
#* @serializer html
function() {
  paste(readLines(system.file("www", "index.html", package = "warpsandbox")), collapse = "\n")
}

#* Health and versions
#* @get /health
#* @serializer unboxedJSON
function() {
  v <- function(p) tryCatch(as.character(utils::packageVersion(p)), error = function(e) NA)
  list(status = "ok", gdal = gdalraster::gdal_version()[1],
       rwarp = v("rwarp"), gdalraster = v("gdalraster"), GDAL7 = v("GDAL7"),
       sds = v("sds"), warpsandbox = v("warpsandbox"), sources = nrow(catalogue()))
}

#* The catalogue of sources (without WKT; see /source for one source in full)
#* @get /catalogue
#* @query theme:string
#* @query origin:string
#* @query ok_only:boolean(true)
#* @serializer json
function(query) {
  x <- catalogue(theme = query$theme, origin = query$origin, ok_only = isTRUE(query$ok_only))
  x$crs_wkt <- NULL
  x$dsn[grepl("^\\s*<", x$dsn)] <- "(inline GDAL XML)"
  x
}

#* One source in full
#* @get /source
#* @query id:string*
#* @serializer unboxedJSON
function(query) {
  x <- catalogue()
  i <- match(query$id, x$id)
  if (is.na(i)) reqres::abort_not_found(sprintf("no source '%s'", query$id))
  as.list(x[i, ])
}

#* The engines
#* @get /engines
#* @serializer json
function() engines()

#* rwarp's chunk plan for a request (no pixels read)
#* @get /plan
#* @serializer unboxedJSON
function(query) {
  r <- req_from(query)
  g <- warpsandbox:::level_grid(r)
  plan <- rwarp::warp_plan(r$src_crs, g$gt, g$dim, r$dst_wkt, r$dst_gt,
                           dst_size = r$dim, resample = r$resample)
  list(request = warpsandbox:::request_summary(r),
       source_grid = list(dim = g$dim, gt = g$gt),
       chunks = if (is.null(plan)) list() else plan[[1]])
}

#* Warp with one engine: a PNG (format=png) or timings and value summary (format=json)
#* @get /warp
#* @query engine:string("rwarp")
#* @query format:string("png")
#* @query palette:string("viridis")
#* @serializer none
function(query, response) {
  r <- req_from(query)
  res <- tryCatch(run_engine(r, query$engine),
                  error = function(e) reqres::abort_bad_request(conditionMessage(e)))
  if (identical(query$format, "json")) {
    ok <- warpsandbox:::valid_mask(res$data, res$nodata)
    v <- res$data[, , 1]; if (is.raw(v)) v <- as.integer(v)
    body <- list(engine = res$engine, request = warpsandbox:::request_summary(r),
                 seconds = as.list(res$seconds), nodata = res$nodata,
                 valid_pixels = sum(ok), range = if (any(ok)) range(as.numeric(v)[ok]) else NULL)
    response$set_header("Content-Type", "application/json")
    response$body <- as.character(jsonlite::toJSON(body, auto_unbox = TRUE, digits = NA, null = "null"))
  } else {
    response$set_header("Content-Type", "image/png")
    response$set_header("X-Warp-Seconds", format(res$seconds[["total"]]))
    response$body <- as_png(res, palette = query$palette)
  }
  plumber2::Break
}

#* Compare engines on one request: timings and differences from the first (the reference)
#* @get /compare
#* @query engines:[string]
#* @query cold:boolean(true)
#* @query timing:string
#* @query images:boolean(false)
#* @query palette:string("viridis")
#* @serializer unboxedJSON{digits = NA}
function(query) {
  r <- req_from(query)
  e <- if (is.null(query$engines)) NULL else strsplit(q1(query$engines), ",", fixed = TRUE)[[1]]
  ## timing = cold | warm | shared (overrides cold)
  tm <- q1(query$timing)
  cold <- if (is.null(tm)) isTRUE(query$cold) else identical(tm, "cold")
  tryCatch(compare_engines(r, e, cold = cold, warm = identical(tm, "warm"), images = isTRUE(query$images),
                           palette = query$palette),
           error = function(err) reqres::abort_bad_request(conditionMessage(err)))
}
