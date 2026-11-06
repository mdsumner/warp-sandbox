## Engines: each takes a resolved request (warp_request()) and returns the
## destination as an array c(nrow, ncol, nbands), row 1 at the top, in the
## request's type (raw, integer or double), with timings.
##
##  rwarp       rwarp::warp_plan() + warp_exec(), reading with gdalraster
##  gdal-app    gdalwarp as a library (gdalraster::warp()) into /vsimem/
##  gdal7-run   GDAL7::gdal_run("raster reproject") into a MEM dataset
##  gdal-direct GDAL's warp API (transformer + GDALWarpOperation), C++
##
## All three read the source at the same overview level (OVERVIEW_LEVEL=k
## only, or gdalwarp's -ovr k), use gdalwarp's default error threshold
## (0.125) and take source nodata from the source.

now <- function() proc.time()[["elapsed"]]

## the largest full-resolution read (source pixels) an engine is allowed
MAX_FULL_RES_PIXELS <- 2e8

## Round doubles to the nearest Float32, as writing to a Float32 band does.
as_float32 <- function(x) readBin(writeBin(as.double(x), raw(), size = 4), "double", n = length(x), size = 4)

conv_fun <- function(type) switch(type, raw = function(v) as.raw(v), integer = as.integer, double = as.double)

## A dataset's bands into the standard array, nodata as its value (not NA),
## as rwarp writes it.
read_array <- function(ds, bands, type) {
  nc <- ds$getRasterXSize(); nr <- ds$getRasterYSize()
  conv <- conv_fun(type)
  out <- lapply(bands, function(b) {
    v <- ds$read(b, 0, 0, nc, nr, nc, nr)
    nd <- ds$getNoDataValue(b)
    if (!is.na(nd)) v[is.na(v)] <- nd
    conv(v)
  })
  pack_bands(out, nc, nr, type)
}

## A list of row-major band vectors into c(nrow, ncol, nb).
pack_bands <- function(bands, nc, nr, type) {
  a <- array(switch(type, raw = as.raw(0), integer = 0L, double = 0), c(nr, nc, length(bands)))
  for (b in seq_along(bands)) a[, , b] <- matrix(bands[[b]], nrow = nr, ncol = nc, byrow = TRUE)
  a
}

engine_rwarp <- function(req) {
  t0 <- now()
  g <- level_grid(req)
  ds <- open_level(req$dsn, req$ovr$level)
  on.exit(ds$close())
  conv <- conv_fun(req$type)
  fetch <- 0
  ## gdalraster's $read() gives nodata as NA; put the nodata value back, so
  ## rwarp sees the source as GDAL does (for integers NA would be a value,
  ## -2147483648, and for bytes it can't be represented at all)
  read_fn <- function(xoff, yoff, xsize, ysize) {
    t <- now()
    v <- unlist(lapply(req$bands, function(b) ds$read(b, xoff, yoff, xsize, ysize, xsize, ysize)))
    if (!is.na(g$nodata)) v[is.na(v)] <- g$nodata
    v <- conv(v)
    fetch <<- fetch + now() - t
    v
  }
  t1 <- now()
  plan <- rwarp::warp_plan(req$src_crs, g$gt, g$dim, req$dst_wkt, req$dst_gt,
                           dst_size = req$dim, resample = req$resample)
  t_plan <- now() - t1
  nd <- if (is.na(g$nodata)) NULL else g$nodata
  nb <- length(req$bands)
  ## an alpha band among the requested ones masks the source, as gdalwarp
  ## does (found on the full-resolution dataset; see warp_request())
  alpha <- if (is.na(req$alpha)) integer() else req$alpha
  if (is.null(plan)) {
    out <- array(switch(req$type, raw = as.raw(0), integer = if (is.null(nd)) 0L else as.integer(nd),
                        double = if (is.null(nd)) 0 else nd), c(req$dim[2], req$dim[1], nb))
  } else {
    out <- rwarp::warp_exec(plan, read_fn, req$src_crs, g$gt, req$dst_wkt, req$dst_gt,
                            nbands = nb, resample = req$resample,
                            src_nodata = nd, dst_nodata = nd,
                            mask_band = if (length(alpha)) alpha[1] else NULL)
    if (length(dim(out)) == 2) dim(out) <- c(dim(out), 1L)
    ## GDAL writes a Float32 source to Float32; rwarp returns doubles, so round
    ## to Float32 to compare like with like
    if (identical(req$dtype, "Float32")) out[] <- as_float32(out)
  }
  total <- now() - t0
  list(data = out, nodata = nd,
       seconds = c(total = total, plan = t_plan, fetch = fetch, warp = total - t_plan - fetch),
       detail = list(chunks = if (is.null(plan)) 0L else length(plan[[1]]),
                     scale = if (is.null(plan)) NA else plan[[1]][[1]]$scale_x))
}

gdal_cl <- function(req) {
  c("-te", req$extent[c(1, 3, 2, 4)], "-ts", req$dim, "-r", req$resample,
    ## gdalraster::warp() opens the source itself, so -oo would not reach it;
    ## gdalwarp's own -ovr picks the same level (and NONE means full resolution)
    "-ovr", if (req$ovr$level >= 0) req$ovr$level else "NONE",
    unlist(lapply(req$bands, function(b) c("-srcband", b))))
}

engine_gdal_app <- function(req) {
  t0 <- now()
  out <- sprintf("/vsimem/warpsandbox-%s.tif", paste(sample(letters, 12, TRUE), collapse = ""))
  on.exit(gdalraster::vsi_unlink(out))
  gdalraster::warp(req$dsn, out, req$dst_wkt, cl_arg = gdal_cl(req), quiet = TRUE)
  t1 <- now()
  ds <- methods::new(gdalraster::GDALRaster, out)
  nd <- ds$getNoDataValue(1)
  ## with a source alpha band gdalwarp adds a destination alpha after the
  ## requested bands; keep the requested ones
  a <- read_array(ds, seq_along(req$bands), req$type)
  ds$close()
  list(data = a, nodata = if (is.na(nd)) NULL else nd,
       seconds = c(total = now() - t0, warp = t1 - t0, read = now() - t1))
}

## `gdal raster reproject` has no -ovr or -srcalpha; it reads the level through
## OVERVIEW_LEVEL=k only, and for WMS/WMTS sources those overview bands report
## no alpha band, so it warps alpha as data: pixels with alpha 0 keep their
## colour, where gdalwarp writes 0.
engine_gdal7_run <- function(req) {
  if (!requireNamespace("GDAL7", quietly = TRUE)) stop("GDAL7 is not installed", call. = FALSE)
  t0 <- now()
  args <- list(input = req$dsn, output = "", "output-format" = "MEM",
               "output-crs" = req$dst_wkt,
               bbox = req$extent[c(1, 3, 2, 4)], size = as.integer(req$dim),
               resampling = req$resample)
  if (req$ovr$level >= 0) args[["open-option"]] <- level_oo(req$ovr$level)
  o <- GDAL7::gdal_run("raster reproject", args, progress = FALSE)
  t1 <- now()
  type_arg <- if (req$type == "double") "double" else "integer"
  bands <- GDAL7::read_raster(o, bands = req$bands, type = type_arg)
  if (req$type == "raw") bands <- lapply(bands, as.raw)
  a <- pack_bands(bands, req$dim[1], req$dim[2], req$type)
  b1 <- GDAL7::get_raster_band(o, 1L)
  nd <- tryCatch(b1@nodata_value, error = function(e) NA)
  list(data = a, nodata = if (is.null(nd) || is.na(nd)) NULL else nd,
       seconds = c(total = now() - t0, warp = t1 - t0, read = now() - t1))
}

## gdal-direct is C++ (inst/cpp/gdal_direct.cpp), compiled on first use into
## a per-user cache, so the package itself stays pure R.
gdal_direct_env <- new.env()

gdal_direct_fun <- function() {
  if (!is.null(gdal_direct_env$f)) return(gdal_direct_env$f)
  if (!requireNamespace("Rcpp", quietly = TRUE)) stop("gdal-direct needs Rcpp", call. = FALSE)
  src <- system.file("cpp", "gdal_direct.cpp", package = "warpsandbox")
  if (!nzchar(src)) src <- file.path("inst", "cpp", "gdal_direct.cpp")
  cfg <- function(a) tryCatch(system2("gdal-config", a, stdout = TRUE), error = function(e) "")
  old <- Sys.getenv(c("PKG_CPPFLAGS", "PKG_LIBS"), unset = NA)
  on.exit(for (n in names(old)) if (is.na(old[[n]])) Sys.unsetenv(n) else do.call(Sys.setenv, as.list(old[n])))
  Sys.setenv(PKG_CPPFLAGS = cfg("--cflags"), PKG_LIBS = cfg("--libs"))
  cache <- tools::R_user_dir("warpsandbox", "cache")
  dir.create(cache, recursive = TRUE, showWarnings = FALSE)
  e <- new.env()
  Rcpp::sourceCpp(src, env = e, cacheDir = cache, showOutput = FALSE)
  gdal_direct_env$f <- e$gdal_direct_warp
  gdal_direct_env$f
}

has_gdal7_warp <- function() {
  requireNamespace("GDAL7", quietly = TRUE) && "warp_raster" %in% getNamespaceExports("GDAL7")
}

engine_gdal_direct <- function(req) {
  if (has_gdal7_warp()) return(engine_gdal_direct_gdal7(req))
  f <- gdal_direct_fun()
  t0 <- now()
  r <- f(req$dsn, level_oo(req$ovr$level), as.integer(req$bands), req$dst_wkt,
         as.numeric(req$dst_gt), as.integer(req$dim), req$resample, req$type, 0.125,
         if (is.na(req$alpha)) 0L else as.integer(req$alpha))
  t1 <- now()
  a <- pack_bands(r$bands, req$dim[1], req$dim[2], req$type)
  list(data = a, nodata = r$nodata,
       seconds = c(total = now() - t0, warp = t1 - t0, read = now() - t1),
       detail = list(backend = "inst/cpp prototype"))
}

## The same through GDAL7::warp_raster() (rgdal-dev/GDAL7 branch warp-raster),
## which is where the prototype went.
engine_gdal_direct_gdal7 <- function(req) {
  t0 <- now()
  ds <- GDAL7::gdal_open(req$dsn, options = if (req$ovr$level >= 0) level_oo(req$ovr$level) else NULL)
  on.exit(GDAL7::gdal_close(ds))
  ## extent as GDAL7 orders it: xmin, ymin, xmax, ymax
  bands <- GDAL7::warp_raster(ds, req$dst_wkt, req$extent[c(1, 3, 2, 4)], size = req$dim,
                              resample = req$resample, bands = req$bands, type = req$type,
                              alpha_band = if (is.na(req$alpha)) 0L else req$alpha)
  t1 <- now()
  a <- pack_bands(bands, req$dim[1], req$dim[2], req$type)
  b1 <- GDAL7::get_raster_band(ds, req$bands[1])
  nd <- tryCatch(b1@nodata_value, error = function(e) NA)
  list(data = a, nodata = if (is.null(nd) || is.na(nd)) NULL else nd,
       seconds = c(total = now() - t0, warp = t1 - t0, read = now() - t1),
       detail = list(backend = "GDAL7::warp_raster()"))
}

ENGINES <- list(
  "rwarp"     = list(fun = engine_rwarp, about = "rwarp (Rust): warp_plan() + warp_exec(), reading with gdalraster"),
  "gdal-app"  = list(fun = engine_gdal_app, about = "gdalwarp as a library, via gdalraster::warp()"),
  "gdal7-run" = list(fun = engine_gdal7_run, about = "GDAL's `gdal raster reproject`, via GDAL7::gdal_run()"),
  "gti"       = list(fun = function(req) engine_gti(req), about = "GDAL's GTI driver over an index made from a VRT mosaic's XML: each tile warped onto the grid from its own overviews (mosaics only)"),
  "gdal-direct" = list(fun = engine_gdal_direct, about = "GDAL's warp API directly: transformer + GDALWarpOperation (GDAL7::warp_raster(), or the inst/cpp prototype)")
)

#' The engines and whether each is available here
#' @export
engines <- function() {
  data.frame(engine = names(ENGINES),
             about = vapply(ENGINES, `[[`, "", "about"),
             available = c(requireNamespace("rwarp", quietly = TRUE),
                           requireNamespace("gdalraster", quietly = TRUE),
                           requireNamespace("GDAL7", quietly = TRUE),
                           TRUE,
                           has_gdal7_warp() || (requireNamespace("Rcpp", quietly = TRUE) && nzchar(Sys.which("gdal-config")))),
             row.names = NULL, stringsAsFactors = FALSE)
}

#' Warp a request with one engine
#'
#' @param req A request from [warp_request()].
#' @param engine One of [engines()].
#' @return A list: `data` (array c(nrow, ncol, nbands)), `nodata`, `seconds`,
#'   and the `engine` name.
#' @export
run_engine <- function(req, engine = "rwarp") {
  e <- ENGINES[[engine]]
  if (is.null(e)) stop(sprintf("no engine '%s'; one of %s", engine, paste(names(ENGINES), collapse = ", ")), call. = FALSE)
  ## a source with no overviews (a VRT mosaic) is read at full resolution by
  ## every engine but gti; refuse what would be an enormous read
  px <- req$ovr$src_pixels
  if (engine != "gti" && !is.null(px) && !is.na(px) && px > MAX_FULL_RES_PIXELS) {
    stop(sprintf("%s would read about %.0f million source pixels at full resolution (no overviews)%s",
                 engine, px / 1e6, if (is_mosaic(req)) "; use gti, or a smaller extent" else "; use a smaller extent"),
         call. = FALSE)
  }
  ## public data only: unsigned requests for /vsis3/ sources (REMA's PGC
  ## tiles, reached through rema-ovr's overview VRTs)
  old <- gdalraster::get_config_option("AWS_NO_SIGN_REQUEST")
  gdalraster::set_config_option("AWS_NO_SIGN_REQUEST", "YES")
  on.exit(gdalraster::set_config_option("AWS_NO_SIGN_REQUEST", old))
  r <- e$fun(req)
  r$engine <- engine
  r
}
