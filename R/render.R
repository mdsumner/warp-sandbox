## Rendering an engine's array to a nativeRaster and PNG, and comparing
## engines.

## TRUE where a pixel holds a value (not NA, not nodata), per pixel over band 1.
valid_mask <- function(a, nodata) {
  v <- a[, , 1]
  if (is.raw(v)) v <- as.integer(v)
  ok <- !is.na(v)
  if (!is.null(nodata) && !is.na(nodata)) ok <- ok & v != nodata
  ok
}

## r, g, b, a integer matrices (0..255) -> nativeRaster (row-major ints).
pack_nara <- function(r, g, b, alpha) {
  nr <- nrow(r); nc <- ncol(r)
  v <- as.vector(t(r)) + as.vector(t(g)) * 256 + as.vector(t(b)) * 65536 + as.vector(t(alpha)) * 16777216
  v <- ifelse(v >= 2^31, v - 2^32, v)
  structure(as.integer(v), dim = c(nr, nc), class = "nativeRaster", channels = 4L)
}

#' An engine result as a nativeRaster
#'
#' Byte imagery of 3 or 4 bands is shown as RGB(A). Anything else shows band 1
#' through a colour ramp, with nodata transparent.
#'
#' @param res A result from [run_engine()].
#' @param palette A [grDevices::hcl.colors()] palette name.
#' @param range Value range for the ramp; default the data's range.
#' @export
as_nara <- function(res, palette = "viridis", range = NULL) {
  ## an engine that made its own nativeRaster (gdal7-nara): show it as is
  if (inherits(res$nara, "nativeRaster")) return(res$nara)
  a <- res$data
  nb <- dim(a)[3]
  if (is.raw(a) && nb >= 3) {
    ch <- function(b) matrix(as.integer(a[, , b]), nrow(a))
    alpha <- if (nb >= 4) ch(4) else matrix(255L, nrow(a), ncol(a))
    if (nb < 4 && !is.null(res$nodata)) {
      alpha[ch(1) == res$nodata & ch(2) == res$nodata & ch(3) == res$nodata] <- 0L
    }
    return(pack_nara(ch(1), ch(2), ch(3), alpha))
  }
  v <- a[, , 1]
  v <- matrix(if (is.raw(v)) as.integer(v) else as.numeric(v), nrow(a))
  ok <- valid_mask(a, res$nodata)
  if (is.null(range)) range <- if (any(ok)) base::range(v[ok]) else c(0, 1)
  pal <- grDevices::col2rgb(grDevices::hcl.colors(256, palette))
  idx <- if (diff(range) > 0) pmin(256L, pmax(1L, as.integer(floor((v - range[1]) / diff(range) * 255)) + 1L)) else rep(1L, length(v))
  idx[!ok | is.na(idx)] <- 1L
  m <- function(i) matrix(pal[i, idx], nrow(a))
  pack_nara(m(1), m(2), m(3), matrix(ifelse(ok, 255L, 0L), nrow(a)))
}

#' An engine result as PNG bytes
#' @inheritParams as_nara
#' @export
as_png <- function(res, palette = "viridis", range = NULL) {
  png::writePNG(as_nara(res, palette, range))
}

#' Compare engines on one request
#'
#' Runs each engine on the same request. The first engine is the reference;
#' each other one is compared with it over every band, where both have a
#' value.
#'
#' @param req A request from [warp_request()].
#' @param engines Engine names; the first is the reference. Default: every
#'   available engine, rwarp first.
#' @param cold Clear GDAL's HTTP cache before each engine, and turn off the
#'   WMS/WMTS disk cache (~/.cache/gdalwmscache), so the timings are
#'   comparable (otherwise later engines reuse what earlier ones fetched).
#'   Ignored when `warm` is `TRUE`.
#' @param warm Time each engine with its own reads already cached: one
#'   untimed run, then `warm_runs` timed runs, reporting the median of each
#'   timing. That leaves out the network, so it shows the plan and kernel
#'   costs (cold timings are mostly network).
#' @param warm_runs Timed runs per engine when `warm`.
#' @param images Also return each engine's PNG (and a difference image) as
#'   data URIs.
#' @param palette,range For the images.
#' @return A list: the request summary, per-engine timings, and per-engine
#'   differences from the reference.
#' @export
compare_engines <- function(req, engines = NULL,
                            cold = TRUE, warm = FALSE, warm_runs = 3L,
                            images = FALSE, palette = "viridis", range = NULL) {
  if (is.null(engines)) {
    av <- warpsandbox::engines()
    engines <- av$engine[av$available]
    if (!is_mosaic(req)) engines <- setdiff(engines, "gti")
    if (req$type != "raw") engines <- setdiff(engines, "gdal7-nara")
  }
  ## Cold also means no WMS/WMTS disk cache: tile sources with <Cache/> keep
  ## their tiles in ~/.cache/gdalwmscache across runs and processes, which
  ## vsi_curl_clear_cache() doesn't touch. Warm keeps it: that's their cache.
  if (cold && !warm) {
    old_wms <- gdalraster::get_config_option("GDAL_ENABLE_WMS_CACHE")
    gdalraster::set_config_option("GDAL_ENABLE_WMS_CACHE", "NO")
    on.exit(gdalraster::set_config_option("GDAL_ENABLE_WMS_CACHE", old_wms), add = TRUE)
  }
  one <- function(e) tryCatch(run_engine(req, e), error = function(err) list(engine = e, error = conditionMessage(err)))
  res <- lapply(engines, function(e) {
    if (!warm) {
      if (cold) gdalraster::vsi_curl_clear_cache()
      return(one(e))
    }
    ## each engine fills the cache for itself right before it is timed, so one
    ## engine's reads can't evict another's
    r <- one(e)
    if (!is.null(r$error)) return(r)
    runs <- lapply(seq_len(warm_runs), function(i) one(e))
    if (any(vapply(runs, function(x) !is.null(x$error), TRUE))) return(runs[[1]])
    r <- runs[[warm_runs]]
    r$seconds <- apply(do.call(rbind, lapply(runs, `[[`, "seconds")), 2, stats::median)
    r
  })
  names(res) <- engines
  ref <- res[[1]]
  if (!is.null(ref$error)) stop(sprintf("reference engine %s failed: %s", engines[1], ref$error), call. = FALSE)
  ## one colour range for every image, from the reference
  if (is.null(range) && !(is.raw(ref$data) && dim(ref$data)[3] >= 3)) {
    ok <- valid_mask(ref$data, ref$nodata)
    v <- ref$data[, , 1]; if (is.raw(v)) v <- as.integer(v)
    if (any(ok)) range <- base::range(as.numeric(v)[ok])
  }
  out <- list(request = request_summary(req), reference = engines[1],
              timing = if (warm) sprintf("warm: median of %d runs after one untimed run", warm_runs)
                       else if (cold) "cold: HTTP cache cleared before each engine" else "shared cache, in engine order",
              engines = list())
  for (e in engines) {
    r <- res[[e]]
    about <- ENGINES[[e]]$about
    if (!is.null(r$error)) {
      out$engines[[e]] <- list(about = about, error = r$error)
      next
    }
    entry <- list(about = about, seconds = as.list(round(r$seconds, 4)))
    if (length(r$detail)) entry$detail <- lapply(r$detail, function(x) if (is.numeric(x)) signif(x, 6) else x)
    if (e != engines[1]) entry$vs_reference <- diff_stats(ref, r)
    if (images) {
      entry$png <- data_uri(as_png(r, palette, range))
      if (e != engines[1] && is.null(entry$vs_reference$error)) entry$diff_png <- data_uri(diff_png(ref, r))
    }
    out$engines[[e]] <- entry
  }
  out
}

diff_stats <- function(ref, r) {
  a <- ref$data; b <- r$data
  if (!identical(dim(a), dim(b))) return(list(error = sprintf("dims differ: %s vs %s", paste(dim(a), collapse = "x"), paste(dim(b), collapse = "x"))))
  okA <- valid_mask(a, ref$nodata); okB <- valid_mask(b, r$nodata)
  both <- okA & okB
  num <- function(x) if (is.raw(x)) as.integer(x) else as.numeric(x)
  d <- abs(num(a) - num(b))
  both3 <- rep(as.vector(both), dim(a)[3])
  dd <- d[both3]
  list(pixels = length(okA),
       both_valid = sum(both),
       valid_only_in_reference = sum(okA & !okB),
       valid_only_in_this = sum(okB & !okA),
       identical_values = sum(dd == 0),
       compared_values = length(dd),
       max_abs = if (length(dd)) max(dd) else NA,
       mean_abs = if (length(dd)) mean(dd) else NA)
}

## |reference - other| over band 1 (white is equal, darker is larger), with
## pixels valid in only one of them in magenta.
diff_png <- function(ref, r) {
  num <- function(x) if (is.raw(x)) as.integer(x) else as.numeric(x)
  a <- matrix(num(ref$data[, , 1]), nrow(ref$data)); b <- matrix(num(r$data[, , 1]), nrow(r$data))
  okA <- valid_mask(ref$data, ref$nodata); okB <- valid_mask(r$data, r$nodata)
  d <- abs(a - b); d[!(okA & okB)] <- 0
  mx <- max(d, na.rm = TRUE)
  g <- if (mx > 0) 255L - as.integer(round(255 * sqrt(d / mx))) else matrix(255L, nrow(d), ncol(d))
  g <- matrix(g, nrow(d))
  rr <- g; gg <- g; bb <- g
  one <- xor(okA, okB)
  rr[one] <- 255L; gg[one] <- 0L; bb[one] <- 255L
  alpha <- matrix(ifelse(okA | okB, 255L, 0L), nrow(d))
  png::writePNG(pack_nara(rr, gg, bb, alpha))
}

data_uri <- function(png) paste0("data:image/png;base64,", jsonlite::base64_enc(png))

request_summary <- function(req) {
  list(source = req$id, title = req$title, date = req$date, vrt = req$vrt, dsn = if (startsWith(req$dsn, "<")) "(inline GDAL XML)" else req$dsn,
       crs = req$crs, extent = req$extent, dim = req$dim, resample = req$resample,
       bands = req$bands, type = req$type, overview = req$ovr,
       mosaic = isTRUE(req$mosaic), pyramid = req$pyramid)
}
