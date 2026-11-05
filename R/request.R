## A warp request, resolved once and handed to every engine unchanged, so the
## engines differ only in how they warp: same DSN, same overview level, same
## bands, same destination grid, same kernel.

MAX_DIM <- 4096L

RESAMPLE <- c("near", "bilinear", "cubic", "cubicspline", "lanczos", "average",
              "mode", "min", "max", "med", "rms")

parse_num <- function(x, n, what) {
  if (is.null(x)) return(NULL)
  if (is.character(x)) x <- unlist(strsplit(x, ",", fixed = TRUE))
  v <- suppressWarnings(as.numeric(x))
  if (length(v) != n || anyNA(v)) {
    stop(sprintf("%s must be %d comma-separated numbers", what, n), call. = FALSE)
  }
  v
}

## GDAL type name -> the R type an engine reads it as
r_type <- function(dtype) {
  if (dtype %in% c("Byte", "UInt8")) "raw"
  else if (dtype %in% c("Int8", "Int16", "UInt16", "Int32")) "integer"
  else "double"
}

#' Resolve a warp request
#'
#' @param source A catalogue id (or an sds alias).
#' @param date For dated sources, a date (default the latest).
#' @param crs Destination CRS (anything PROJ accepts). Default: the source's.
#' @param extent Destination extent `c(xmin, xmax, ymin, ymax)` in `crs`, or a
#'   comma-separated string. Give `extent` or `bbox`; default: the source's
#'   extent, when `crs` is the source's.
#' @param bbox The same as `c(xmin, ymin, xmax, ymax)` (OGC order).
#' @param dim Destination `c(ncol, nrow)`. Default `c(512, 512)`.
#' @param resample A gdalwarp kernel name.
#' @param bands Band numbers. Default: band 1, or 1:3 / 1:4 for byte imagery.
#' @param ovr Overview level: `"auto"` (the coarsest overview that is still at
#'   least as fine as the destination; the same level is used by every
#'   engine), `"none"` (full resolution) or a 0-based level.
#' @param cat The catalogue.
#' @return A list with the resolved request.
#' @export
warp_request <- function(source, date = NULL, crs = NULL, extent = NULL, bbox = NULL,
                         dim = c(512L, 512L), resample = "near", bands = NULL,
                         ovr = "auto", cat = catalogue()) {
  if (is.null(source) || !nzchar(source)) stop("source is required", call. = FALSE)
  i <- match(source, cat$id)
  if (is.na(i)) {
    al <- strsplit(ifelse(is.na(cat$aliases), "", cat$aliases), ",", fixed = TRUE)
    i <- which(vapply(al, function(a) source %in% a, TRUE))[1]
  }
  if (is.na(i)) stop(sprintf("no source '%s' in the catalogue", source), call. = FALSE)
  row <- cat[i, ]
  if (!isTRUE(row$probe_ok)) stop(sprintf("source '%s' did not open when the catalogue was probed", row$id), call. = FALSE)
  dsn <- source_dsn(row$id, date = date, cat = cat)

  resample <- match.arg(resample, RESAMPLE)
  dim <- as.integer(parse_num(dim, 2, "dim"))
  if (any(dim < 1L) || any(dim > MAX_DIM)) stop(sprintf("dim must be between 1 and %d", MAX_DIM), call. = FALSE)

  src_crs <- row$crs_wkt
  if (is.null(crs) || !nzchar(crs)) crs <- row$crs
  dst_wkt <- tryCatch(gdalraster::srs_to_wkt(crs), error = function(e) "")
  if (!nzchar(dst_wkt)) stop(sprintf("crs '%s' is not a CRS PROJ understands", crs), call. = FALSE)

  if (!is.null(bbox)) {
    b <- parse_num(bbox, 4, "bbox"); extent <- b[c(1, 3, 2, 4)]
  } else if (!is.null(extent)) {
    extent <- parse_num(extent, 4, "extent")
  } else if (gdalraster::srs_is_same(dst_wkt, src_crs)) {
    extent <- c(row$xmin, row$xmax, row$ymin, row$ymax)
  } else {
    extent <- gdalraster::bbox_transform(c(row$xmin, row$ymin, row$xmax, row$ymax), src_crs, dst_wkt)[c(1, 3, 2, 4)]
  }
  if (!(extent[2] > extent[1] && extent[4] > extent[3])) {
    stop("extent must have xmax > xmin and ymax > ymin", call. = FALSE)
  }
  dst_gt <- c(extent[1], (extent[2] - extent[1]) / dim[1], 0,
              extent[4], 0, -(extent[4] - extent[3]) / dim[2])

  type <- r_type(row$dtype)
  if (is.null(bands)) {
    bands <- if (type == "raw" && row$nbands >= 4) 1:4 else if (type == "raw" && row$nbands == 3) 1:3 else 1L
  }
  if (is.character(bands)) bands <- strsplit(bands, ",", fixed = TRUE)[[1]]
  bands <- suppressWarnings(as.integer(bands))
  if (!length(bands) || anyNA(bands)) stop("bands must be band numbers, e.g. 1 or 1,2,3", call. = FALSE)
  if (any(bands < 1L | bands > row$nbands)) stop(sprintf("bands must be in 1..%d", row$nbands), call. = FALSE)

  req <- list(id = row$id, title = row$title, dsn = dsn, date = date,
              src_crs = src_crs, src_dim = as.integer(c(row$ncol, row$nrow)),
              src_gt = c(row$xmin, row$xres, 0, row$ymax, 0, -row$yres),
              dtype = row$dtype, type = type, nodata = row$nodata,
              crs = crs, dst_wkt = dst_wkt, extent = extent, dim = dim, dst_gt = dst_gt,
              resample = resample, bands = bands, n_overviews = row$n_overviews)
  ## the alpha band, from the full-resolution dataset: WMS and WMTS overview
  ## bands report no colour interpretation (GDAL 3.14), so a tile service
  ## opened at an overview with OVERVIEW_LEVEL has no alpha band
  if (type == "raw" && length(bands) > 1) {
    ds <- open_level(dsn, -1L)
    ci <- vapply(bands, function(b) ds$getRasterColorInterp(b), "")
    ds$close()
    req$alpha <- which(ci == "Alpha")[1]
  } else {
    req$alpha <- NA_integer_
  }
  req$ovr <- choose_overview(req, ovr)
  req
}

## Destination pixels per source pixel at full resolution, from rwarp's plan
## (no I/O). The smaller of x and y, over the chunks.
full_res_scale <- function(req) {
  plan <- rwarp::warp_plan(req$src_crs, req$src_gt, req$src_dim, req$dst_wkt, req$dst_gt,
                           dst_size = req$dim, resample = "near")
  if (is.null(plan)) return(NA_real_)
  ch <- plan[[1]]
  min(vapply(ch, function(c) min(c$scale_x, c$scale_y), 0))
}

## The open option for an overview level (-1 is full resolution). " only"
## hides the coarser levels, so no engine can pick a further overview itself.
level_oo <- function(level) if (level >= 0) sprintf("OVERVIEW_LEVEL=%d only", level) else character()

## Open a source at an overview level (-1 is full resolution).
open_level <- function(dsn, level) {
  oo <- level_oo(level)
  methods::new(gdalraster::GDALRaster, dsn, TRUE, oo)
}

choose_overview <- function(req, ovr) {
  n <- req$n_overviews
  if (is.na(n)) n <- 0L
  if (identical(ovr, "none") || n == 0) return(list(level = -1L, factor = 1, rule = if (identical(ovr, "none")) "none" else "no overviews"))
  if (!identical(ovr, "auto")) {
    k <- suppressWarnings(as.integer(ovr))
    if (is.na(k) || k < -1L || k >= n) stop(sprintf("ovr must be auto, none, or 0..%d", n - 1), call. = FALSE)
    ds <- open_level(req$dsn, k); on.exit(ds$close())
    return(list(level = k, factor = req$src_dim[1] / ds$getRasterXSize(), rule = "given"))
  }
  s <- full_res_scale(req)
  if (is.na(s) || s >= 1) return(list(level = -1L, factor = 1, rule = "auto", scale = s))
  need <- 1 / s
  ## overviews are usually powers of two; start from the guess and confirm
  k <- min(n - 1L, max(-1L, floor(log2(need)) - 1L))
  repeat {
    if (k < 0) return(list(level = -1L, factor = 1, rule = "auto", scale = s))
    ds <- open_level(req$dsn, k)
    f <- req$src_dim[1] / ds$getRasterXSize()
    ds$close()
    if (f <= need * 1.0001) return(list(level = k, factor = f, rule = "auto", scale = s))
    k <- k - 1L
  }
}

## The source grid at the request's overview level.
level_grid <- function(req) {
  ds <- open_level(req$dsn, req$ovr$level)
  on.exit(ds$close())
  list(gt = ds$getGeoTransform(), dim = as.integer(c(ds$getRasterXSize(), ds$getRasterYSize())),
       nodata = ds$getNoDataValue(1))
}
