## The catalogue: cloud-ready raster sources the sandbox can warp.
##
## Two origins:
##  - source.coop/ausantarctic, listed through its S3 API (bedmap, gebco,
##    ibcso as single COGs; ghrsst-mur-v2 as one dated template per variable)
##  - the sds package's registry (sds::dsn_list()), the warpable kinds only
##
## catalogue_build() lists and merges them; catalogue_probe() opens each with
## GDAL (headers only) to record its grid; catalogue_write() saves JSON and
## CSV under inst/catalogue/, which catalogue() reads.

COOP_S3   <- "https://data.source.coop/ausantarctic"
COOP_HTTP <- "https://data.source.coop/ausantarctic"
GHRSST_STEM <- "{YYYY}/{MM}/{DD}/{YYYY}{MM}{DD}090000-JPL-L4_GHRSST-SSTfnd-MUR-GLOB-v02.0-fv04.1_{var}.tif"
GHRSST_VARS <- c("analysed_sst", "analysis_error", "mask", "sea_ice_fraction", "sst_anomaly")

## sds kinds GDAL opens as a raster
SDS_RASTER_KINDS <- c("cog", "vrt_url", "vrt_file", "xml_file", "wmts")

COLUMNS <- c("id", "title", "origin", "provider", "theme", "kind", "dsn",
             "dsn_template", "time_step", "time_start", "time_end", "variable",
             "crs", "license", "doi", "aliases", "notes", "size_bytes")

#' List an S3-compatible bucket (ListObjectsV2), following continuation tokens
#'
#' @param endpoint Bucket URL, e.g. "https://data.source.coop/ausantarctic".
#' @param prefix Key prefix.
#' @param delimiter "" for every key below `prefix`, "/" for one level.
#' @return A data frame of `key` and `size` (bytes), with attribute
#'   `prefixes` (the common prefixes, when `delimiter` is given).
#' @export
s3_list <- function(endpoint = COOP_S3, prefix = "", delimiter = "") {
  keys <- character(); sizes <- numeric(); prefixes <- character()
  token <- NULL
  repeat {
    q <- c(`list-type` = "2", prefix = prefix, delimiter = delimiter, `max-keys` = "1000")
    if (!is.null(token)) q <- c(q, `continuation-token` = token)
    q <- q[nzchar(q)]
    url <- paste0(endpoint, "?", paste(names(q), vapply(q, curl::curl_escape, ""), sep = "=", collapse = "&"))
    res <- curl::curl_fetch_memory(url, handle = curl::new_handle(timeout = 60))
    if (res$status_code != 200) stop(sprintf("S3 list failed (%d): %s", res$status_code, url))
    doc <- xml2::xml_ns_strip(xml2::read_xml(rawToChar(res$content)))
    keys  <- c(keys,  xml2::xml_text(xml2::xml_find_all(doc, "//Contents/Key")))
    sizes <- c(sizes, as.numeric(xml2::xml_text(xml2::xml_find_all(doc, "//Contents/Size"))))
    prefixes <- c(prefixes, xml2::xml_text(xml2::xml_find_all(doc, "//CommonPrefixes/Prefix")))
    if (xml2::xml_text(xml2::xml_find_first(doc, "//IsTruncated")) != "true") break
    token <- xml2::xml_text(xml2::xml_find_first(doc, "//NextContinuationToken"))
  }
  out <- data.frame(key = keys, size = sizes, stringsAsFactors = FALSE)
  attr(out, "prefixes") <- prefixes
  out
}

fetch_json <- function(url) {
  res <- tryCatch(curl::curl_fetch_memory(url, handle = curl::new_handle(timeout = 60)),
                  error = function(e) NULL)
  if (is.null(res) || res$status_code != 200) return(NULL)
  tryCatch(jsonlite::fromJSON(rawToChar(res$content), simplifyVector = FALSE),
           error = function(e) NULL)
}

fetch_text <- function(url) {
  res <- tryCatch(curl::curl_fetch_memory(url, handle = curl::new_handle(timeout = 60)),
                  error = function(e) NULL)
  if (is.null(res) || res$status_code != 200) return(NULL)
  rawToChar(res$content)
}

readme_title <- function(txt) {
  if (is.null(txt)) return(NA_character_)
  h <- grep("^# ", strsplit(txt, "\n", fixed = TRUE)[[1]], value = TRUE)
  if (length(h)) trimws(sub("^# ", "", h[1])) else NA_character_
}

row <- function(...) {
  x <- list(...)
  out <- stats::setNames(as.list(rep(NA, length(COLUMNS))), COLUMNS)
  out[names(x)] <- x
  as.data.frame(lapply(out, function(v) if (is.null(v) || length(v) == 0) NA else v),
                stringsAsFactors = FALSE)
}

## source.coop/ausantarctic --------------------------------------------------

coop_theme <- function(product) {
  switch(product, bedmap = "elevation", gebco = "bathymetry", ibcso = "bathymetry",
         `ghrsst-mur-v2` = "sst", "other")
}

coop_single_cogs <- function(product) {
  ls <- s3_list(prefix = paste0(product, "/"))
  tifs <- ls[grepl("\\.tif$", ls$key) & !grepl("/virtual/", ls$key), ]
  if (!nrow(tifs)) return(NULL)
  title0 <- readme_title(fetch_text(sprintf("%s/%s/README.md", COOP_HTTP, product)))
  ## provenance.json per folder: license and doi
  folders <- unique(dirname(tifs$key))
  prov <- lapply(folders, function(f) {
    p <- fetch_json(sprintf("%s/%s/provenance.json", COOP_HTTP, f))
    list(license = p$license %||% NA_character_,
         doi = p$source$doi %||% p$doi %||% NA_character_,
         release = p$release %||% NA_character_)
  })
  names(prov) <- folders
  rows <- lapply(seq_len(nrow(tifs)), function(i) {
    key <- tifs$key[i]
    f <- dirname(key)
    p <- prov[[f]]
    ## a STAC item next to the COG (gebco) gives license too
    if (is.na(p$license)) {
      stac <- fetch_json(sprintf("%s/%s", COOP_HTTP, sub("\\.tif$", ".stac-item.json", key)))
      if (!is.null(stac)) p$license <- stac$properties$license %||% stac$license %||% NA_character_
    }
    stem <- sub("\\.tif$", "", basename(key))
    id <- paste0("ausantarctic/", sub("/cog$", "", f), "/", stem)
    id <- sub("^ausantarctic/gebco/\\./", "ausantarctic/gebco/", id)
    row(id = gsub("/+", "/", sub("/\\.$", "", id)),
        title = paste0(title0 %|na|% product, ": ", stem),
        origin = "source.coop", provider = "ausantarctic", theme = coop_theme(product),
        kind = "cog", dsn = sprintf("/vsicurl/%s/%s", COOP_HTTP, key),
        variable = stem, license = p$license, doi = p$doi,
        size_bytes = tifs$size[i])
  })
  do.call(rbind, rows)
}

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a
`%|na|%` <- function(a, b) if (is.na(a)) b else a

#' GHRSST MUR dates on source.coop, from the repository's STAC parquet
#' @return A data frame of `date` and `status` (final, preliminary, nrt_only).
#' @noRd
ghrsst_dates <- function() {
  if (!requireNamespace("arrow", quietly = TRUE)) return(NULL)
  f <- tempfile(fileext = ".parquet")
  on.exit(unlink(f))
  curl::curl_download(sprintf("%s/ghrsst-mur-v2/ghrsst-mur-v2.parquet", COOP_HTTP), f, quiet = TRUE)
  x <- arrow::read_parquet(f)
  out <- data.frame(date = as.Date(x[["datetime"]]), status = as.character(x[["ghrsst:status"]]),
                    stringsAsFactors = FALSE)
  if (!nrow(out)) stop("the GHRSST index has no rows")
  out[order(out$date), ]
}

coop_ghrsst <- function(dates) {
  rng <- if (is.null(dates)) c(NA, NA) else as.character(range(dates$date))
  title0 <- readme_title(fetch_text(sprintf("%s/ghrsst-mur-v2/README.md", COOP_HTTP)))
  rows <- lapply(GHRSST_VARS, function(v) {
    row(id = paste0("ausantarctic/ghrsst-mur-v2/", v),
        title = paste0(title0 %|na|% "GHRSST MUR", ": ", v),
        origin = "source.coop", provider = "ausantarctic", theme = "sst", kind = "cog",
        dsn_template = sprintf("/vsicurl/%s/ghrsst-mur-v2/%s", COOP_HTTP, sub("{var}", v, GHRSST_STEM, fixed = TRUE)),
        time_step = "P1D", time_start = rng[1], time_end = rng[2], variable = v,
        license = "public domain (NASA PO.DAAC)",
        doi = "https://doi.org/10.5067/GHGMR-4FJ04",
        notes = paste("One COG per day, 36000 x 17999 at 0.01 degree, integers with scale/offset (degC).",
                      "Each day's status (final, preliminary, nrt_only) is in ghrsst-dates.csv.",
                      if (v == "sst_anomaly") "Not every day has sst_anomaly." else ""))
  })
  do.call(rbind, rows)
}

## sds ---------------------------------------------------------------------

sds_entries <- function() {
  if (!requireNamespace("sds", quietly = TRUE)) return(NULL)
  reg <- sds::dsn_list()
  reg <- reg[reg$kind %in% SDS_RASTER_KINDS & reg$status != "dead", ]
  rows <- lapply(seq_len(nrow(reg)), function(i) {
    r <- reg[i, ]
    d <- tryCatch(sds::dsn(r$name), error = function(e) NA_character_)
    row(id = r$name, title = r$name, origin = "sds", provider = r$provider,
        theme = r$theme, kind = r$kind, dsn = d, crs = r$crs, license = r$license,
        aliases = r$name,
        notes = paste0(r$notes, if (nzchar(r$needs_auth)) paste0(" Needs auth: ", r$needs_auth) else "",
                       if (r$status != "ok") paste0(" sds status: ", r$status) else ""))
  })
  do.call(rbind, rows)
}

#' Build the catalogue from source.coop/ausantarctic and the sds registry
#'
#' Network: lists the bucket, reads READMEs, provenance and the GHRSST index.
#' Entries that point at the same URL are merged, keeping the source.coop row
#' and listing the sds name in `aliases`.
#'
#' @return A data frame, one row per source, with attribute `ghrsst_dates`.
#' @export
catalogue_build <- function() {
  dates <- ghrsst_dates()
  coop <- do.call(rbind, c(lapply(c("bedmap", "gebco", "ibcso"), coop_single_cogs),
                           list(coop_ghrsst(dates))))
  s <- sds_entries()
  if (!is.null(s)) {
    url_of <- function(d) sub("^/vsicurl/", "", d)
    hit <- match(url_of(s$dsn), url_of(coop$dsn))
    for (i in which(!is.na(hit))) {
      j <- hit[i]
      coop$aliases[j] <- paste(stats::na.omit(c(coop$aliases[j], s$id[i])), collapse = ",")
      if (is.na(coop$license[j])) coop$license[j] <- s$license[i]
    }
    s <- s[is.na(hit), ]
  }
  out <- rbind(coop, s)
  out <- out[order(out$origin != "source.coop", out$theme, out$id), ]
  rownames(out) <- NULL
  stopifnot(!anyDuplicated(out$id))
  attr(out, "ghrsst_dates") <- dates
  out
}

## probe -------------------------------------------------------------------

probe_one <- function(dsn) {
  t0 <- proc.time()[["elapsed"]]
  r <- tryCatch({
    ds <- methods::new(gdalraster::GDALRaster, dsn, read_only = TRUE)
    on.exit(ds$close())
    gt <- ds$getGeoTransform()
    nc <- ds$getRasterXSize(); nr <- ds$getRasterYSize()
    wkt <- ds$getProjectionRef()
    epsg <- tryCatch(gdalraster::srs_find_epsg(wkt), error = function(e) NA)
    nb <- ds$getRasterCount()
    list(probe_ok = TRUE, probe_error = NA_character_,
         ncol = nc, nrow = nr, nbands = nb,
         dtype = ds$getDataTypeName(1),
         xmin = gt[1], xmax = gt[1] + nc * gt[2], ymin = gt[4] + nr * gt[6], ymax = gt[4],
         xres = gt[2], yres = -gt[6], rotated = gt[3] != 0 || gt[5] != 0,
         n_overviews = ds$getOverviewCount(1),
         block = paste(ds$getBlockSize(1), collapse = "x"),
         nodata = ds$getNoDataValue(1),
         scale = ds$getScale(1), offset = ds$getOffset(1),
         crs_probe = if (length(epsg) && !is.na(epsg[1])) paste0("EPSG:", sub("^EPSG:", "", epsg[1])) else NA_character_,
         crs_wkt = wkt)
  }, error = function(e) list(probe_ok = FALSE, probe_error = conditionMessage(e)))
  r$probe_seconds <- round(proc.time()[["elapsed"]] - t0, 2)
  r
}

#' Probe each source with GDAL: grid, bands, type, overviews, nodata
#'
#' Opens each DSN (headers only). Dated templates are probed at their latest
#' date with status "final" when the date index is known.
#'
#' @param cat A catalogue from [catalogue_build()].
#' @param timeout GDAL HTTP timeout per request, seconds.
#' @return `cat` with probe columns added.
#' @export
catalogue_probe <- function(cat, timeout = 30) {
  old <- gdalraster::get_config_option("GDAL_HTTP_TIMEOUT")
  gdalraster::set_config_option("GDAL_HTTP_TIMEOUT", as.character(timeout))
  gdalraster::set_config_option("GDAL_HTTP_MAX_RETRY", "1")
  gdalraster::set_config_option("GDAL_DISABLE_READDIR_ON_OPEN", "EMPTY_DIR")
  on.exit(gdalraster::set_config_option("GDAL_HTTP_TIMEOUT", old), add = TRUE)
  dates <- attr(cat, "ghrsst_dates")
  probe_date <- if (!is.null(dates)) max(dates$date[dates$status == "final"]) else NULL
  res <- lapply(seq_len(nrow(cat)), function(i) {
    d <- cat$dsn[i]
    if (is.na(d) && !is.na(cat$dsn_template[i])) {
      d <- fill_template(cat$dsn_template[i], probe_date %||% as.Date(cat$time_end[i]))
    }
    if (is.na(d)) return(list(probe_ok = FALSE, probe_error = "no dsn"))
    message(sprintf("[%d/%d] %s", i, nrow(cat), cat$id[i]))
    p <- probe_one(d)
    if (!is.na(cat$dsn_template[i])) p$probe_date <- as.character(probe_date)
    p
  })
  cols <- unique(unlist(lapply(res, names)))
  for (cl in cols) {
    v <- lapply(res, function(r) r[[cl]] %||% NA)
    cat[[cl]] <- if (all(vapply(v, function(x) is.numeric(x) || is.logical(x), TRUE))) unlist(v) else
      vapply(v, function(x) if (length(x) == 1 && !is.na(x)) as.character(x) else NA_character_, "")
  }
  cat$crs[is.na(cat$crs)] <- cat$crs_probe[is.na(cat$crs)]
  cat
}

fill_template <- function(template, date) {
  date <- as.Date(date)
  s <- gsub("{YYYY}", format(date, "%Y"), template, fixed = TRUE)
  s <- gsub("{MM}", format(date, "%m"), s, fixed = TRUE)
  gsub("{DD}", format(date, "%d"), s, fixed = TRUE)
}

## mosaic and pyramid flags ---------------------------------------------------

## A VRT's XML: inline, a /vsicurl/ URL (one download), or a local path;
## NULL for anything that isn't a VRT.
vrt_xml <- function(dsn, kind) {
  if (is.na(dsn)) return(NULL)
  if (grepl("^\\s*<VRTDataset", dsn)) return(dsn)
  if (!kind %in% c("vrt_url", "vrt_file") || !grepl("\\.vrt$", dsn)) return(NULL)
  src <- sub("^/vsicurl/", "", dsn)
  tryCatch(paste(readLines(src, warn = FALSE), collapse = "\n"), error = function(e) NULL)
}

## Sources in the first band of a VRT (bands repeat them).
vrt_n_sources <- function(xml) {
  band <- strsplit(xml, "</VRTRasterBand>", fixed = TRUE)[[1]][1]
  m <- gregexpr("<(Simple|Complex|Averaged|Kernel)Source[ >]", band)[[1]]
  sum(m > 0)
}

#' Add mosaic and pyramid flags to a probed catalogue
#'
#' How a source serves a coarse view, which decides what a wide request
#' costs and which engines suit it:
#' - `mosaic`, `n_tiles`: a VRT of more than one source (counted in its first
#'   band). The gti engine applies to these.
#' - `pyramid`: `"internal"` (the source's own overviews, as in a COG),
#'   `"external"` (a VRT whose band carries `<Overview>` elements, as
#'   mdsumner/rema-ovr does for REMA), `"tiles"` (a tile service's zoom
#'   levels) or `"none"` (no overviews: every view reads full resolution;
#'   for a mosaic, use gti).
#' - `coarsest_factor`: full-resolution width over the coarsest overview's
#'   width (1 with no overviews).
#'
#' @param cat A catalogue from [catalogue_probe()].
#' @return `cat` with those columns.
#' @export
catalogue_flags <- function(cat) {
  gdalraster::set_config_option("GDAL_DISABLE_READDIR_ON_OPEN", "EMPTY_DIR")
  res <- lapply(seq_len(nrow(cat)), function(i) {
    out <- list(mosaic = NA, n_tiles = NA_integer_, pyramid = NA_character_, coarsest_factor = NA_real_)
    if (!isTRUE(cat$probe_ok[i])) return(out)
    message(sprintf("[%d/%d] %s", i, nrow(cat), cat$id[i]))
    d <- cat$dsn[i]
    if (is.na(d) && !is.na(cat$dsn_template[i])) {
      d <- fill_template(cat$dsn_template[i], if (!is.na(cat$probe_date[i])) cat$probe_date[i] else cat$time_end[i])
    }
    xml <- vrt_xml(d, cat$kind[i])
    out$n_tiles <- if (is.null(xml)) NA_integer_ else vrt_n_sources(xml)
    out$mosaic <- !is.na(out$n_tiles) && out$n_tiles > 1
    nov <- cat$n_overviews[i]
    out$pyramid <- if (is.na(nov) || nov == 0) "none"
      else if (cat$kind[i] %in% c("wmts", "xml_file")) "tiles"
      else if (!is.null(xml) && grepl("<Overview>", xml, fixed = TRUE)) "external"
      else "internal"
    out$coarsest_factor <- if (is.na(nov) || nov == 0) 1 else tryCatch({
      ds <- open_level(d, nov - 1L); on.exit(ds$close())
      signif(cat$ncol[i] / ds$getRasterXSize(), 4)
    }, error = function(e) NA_real_)
    out
  })
  for (cl in c("mosaic", "n_tiles", "pyramid", "coarsest_factor")) {
    cat[[cl]] <- unlist(lapply(res, `[[`, cl))
  }
  cat
}

## read and write -----------------------------------------------------------

#' Write the catalogue as JSON and CSV (and the GHRSST date index)
#' @param cat A probed catalogue.
#' @param dir Output folder.
#' @export
catalogue_write <- function(cat, dir = "inst/catalogue") {
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)
  dates <- attr(cat, "ghrsst_dates")
  attr(cat, "ghrsst_dates") <- NULL
  meta <- list(built = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
               gdal = tryCatch(gdalraster::gdal_version()[1], error = function(e) NA),
               sds = tryCatch(as.character(utils::packageVersion("sds")), error = function(e) NA),
               n = nrow(cat))
  jsonlite::write_json(list(meta = meta, sources = cat), file.path(dir, "catalogue.json"),
                       pretty = TRUE, auto_unbox = TRUE, na = "null", digits = NA)
  csv <- cat
  csv$crs_wkt <- NULL
  csv$dsn[grepl("^\\s*<", csv$dsn)] <- "(inline GDAL XML; see catalogue.json)"
  utils::write.csv(csv, file.path(dir, "catalogue.csv"), row.names = FALSE, na = "")
  if (!is.null(dates)) utils::write.csv(dates, file.path(dir, "ghrsst-dates.csv"), row.names = FALSE)
  invisible(dir)
}

catalogue_dir <- function() {
  d <- system.file("catalogue", package = "warpsandbox")
  if (!nzchar(d)) d <- file.path("inst", "catalogue")
  d
}

#' The catalogue of sources the sandbox can warp
#'
#' @param theme,origin,kind Optional filters.
#' @param ok_only Only sources GDAL opened when the catalogue was probed.
#' @return A data frame, one row per source.
#' @export
catalogue <- function(theme = NULL, origin = NULL, kind = NULL, ok_only = FALSE) {
  x <- jsonlite::fromJSON(file.path(catalogue_dir(), "catalogue.json"))$sources
  if (!is.null(theme))  x <- x[x$theme %in% theme, ]
  if (!is.null(origin)) x <- x[x$origin %in% origin, ]
  if (!is.null(kind))   x <- x[x$kind %in% kind, ]
  if (ok_only && "probe_ok" %in% names(x)) x <- x[x$probe_ok %in% TRUE, ]
  rownames(x) <- NULL
  x
}

#' The GDAL DSN for a catalogue source
#'
#' @param id A catalogue id, or an sds name listed in `aliases`.
#' @param date For dated sources (GHRSST): a date; default the latest.
#' @param cat The catalogue.
#' @return A GDAL DSN (a path, a /vsicurl/ URL, a WMTS: string or inline XML).
#' @export
source_dsn <- function(id, date = NULL, cat = catalogue()) {
  i <- match(id, cat$id)
  if (is.na(i)) {
    al <- strsplit(ifelse(is.na(cat$aliases), "", cat$aliases), ",", fixed = TRUE)
    i <- which(vapply(al, function(a) id %in% a, TRUE))[1]
  }
  if (is.na(i)) stop(sprintf("no source '%s' in the catalogue", id))
  if (is.na(cat$dsn_template[i])) {
    if (!is.null(date)) warning(sprintf("'%s' is not dated; date ignored", id))
    return(cat$dsn[i])
  }
  if (is.null(date)) date <- cat$time_end[i]
  date <- as.Date(date)
  f <- file.path(catalogue_dir(), "ghrsst-dates.csv")
  if (file.exists(f)) {
    known <- as.Date(utils::read.csv(f)$date)
    if (!date %in% known) stop(sprintf("'%s' has no data for %s (range %s to %s)",
                                       id, date, min(known), max(known)))
  }
  fill_template(cat$dsn_template[i], date)
}
