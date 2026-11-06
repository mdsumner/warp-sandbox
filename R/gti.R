## gti: GDAL's raster tile index driver, built on the fly from a VRT mosaic.
##
## A VRT mosaic lists every tile (file and destination rectangle), so a GTI
## index can be made from the VRT's XML without opening a tile. Opening the
## index with the destination grid as open options (SRS with
## SRS_BEHAVIOR=REPROJECT, MINX/MINY/MAXX/MAXY, RESX/RESY) makes GTI warp each
## tile straight onto the grid, from that tile's own overviews. The VRT itself
## exposes none, so the other engines read a mosaic at full resolution.

gti_cache <- new.env()

## the most tiles a gti request may open
MAX_GTI_TILES <- 400

## Write a string to a /vsimem/ path (gdalraster has VSIFile, not a helper).
vsimem_write <- function(path, text) {
  f <- methods::new(gdalraster::VSIFile, path, "w")
  f$write(charToRaw(text))
  f$close()
  invisible(path)
}

#' The tiles of a VRT mosaic
#'
#' Parsed from the VRT's XML (one download), cached per DSN for the session
#' and on disk.
#'
#' @param dsn A `/vsicurl/` URL to a VRT, as in the catalogue.
#' @return A data frame of `location` (a GDAL DSN) and `xmin`, `ymin`,
#'   `xmax`, `ymax` in the VRT's CRS, with attributes `crs` (WKT),
#'   `data_type`, `band_count` and `nodata`.
#' @export
mosaic_tiles <- function(dsn) {
  if (!is.null(gti_cache[[dsn]])) return(gti_cache[[dsn]])
  if (!grepl("^/vsicurl/https?://.*\\.vrt$", dsn)) {
    stop("gti works on VRT mosaics given as a /vsicurl/ URL; this source isn't one", call. = FALSE)
  }
  disk <- file.path(tools::R_user_dir("warpsandbox", "cache"), "mosaics",
                    paste0(gsub("[^A-Za-z0-9]+", "_", sub("^/vsicurl/https?://", "", dsn)), ".rds"))
  if (file.exists(disk)) {
    x <- readRDS(disk)
    gti_cache[[dsn]] <- x
    return(x)
  }
  url <- sub("^/vsicurl/", "", dsn)
  f <- tempfile(fileext = ".vrt")
  on.exit(unlink(f))
  curl::curl_download(url, f, quiet = TRUE)
  doc <- xml2::read_xml(f)
  gt <- as.numeric(strsplit(xml2::xml_text(xml2::xml_find_first(doc, "/VRTDataset/GeoTransform")), ",")[[1]])
  if (gt[3] != 0 || gt[5] != 0) stop("rotated VRT mosaics are not supported", call. = FALSE)
  band <- xml2::xml_find_first(doc, "/VRTDataset/VRTRasterBand[1]")
  srcs <- xml2::xml_find_all(band, "./SimpleSource | ./ComplexSource")
  if (length(srcs) < 2) stop("this VRT has fewer than two sources; it isn't a mosaic", call. = FALSE)
  fn <- xml2::xml_find_first(srcs, "./SourceFilename")
  rel <- xml2::xml_attr(fn, "relativeToVRT") %in% "1"
  name <- xml2::xml_text(fn)
  base <- sub("/[^/]*$", "", url)
  location <- ifelse(rel, paste0("/vsicurl/", base, "/", name),
                     ifelse(grepl("^https?://", name), paste0("/vsicurl/", name), name))
  dr <- xml2::xml_find_first(srcs, "./DstRect")
  num <- function(a) as.numeric(xml2::xml_attr(dr, a))
  x0 <- gt[1] + num("xOff") * gt[2]
  y1 <- gt[4] + num("yOff") * gt[6]
  x1 <- x0 + num("xSize") * gt[2]
  y0 <- y1 + num("ySize") * gt[6]
  nd <- xml2::xml_text(xml2::xml_find_first(band, "./NoDataValue"))
  out <- data.frame(location = location, xmin = pmin(x0, x1), ymin = pmin(y0, y1),
                    xmax = pmax(x0, x1), ymax = pmax(y0, y1), stringsAsFactors = FALSE)
  attr(out, "crs") <- gdalraster::srs_to_wkt(xml2::xml_text(xml2::xml_find_first(doc, "/VRTDataset/SRS")))
  attr(out, "data_type") <- xml2::xml_attr(band, "dataType")
  attr(out, "band_count") <- length(xml2::xml_find_all(doc, "/VRTDataset/VRTRasterBand"))
  attr(out, "nodata") <- if (is.na(nd)) NA_real_ else as.numeric(nd)
  dir.create(dirname(disk), recursive = TRUE, showWarnings = FALSE)
  saveRDS(out, disk)
  gti_cache[[dsn]] <- out
  out
}

## A GTI description of the tiles a request needs: a GeoJSON index (with its
## CRS) in /vsimem/ and the GTI XML that points at it. Returns the XML's path.
gti_index <- function(tiles, extent_src, resample) {
  keep <- tiles$xmax > extent_src[1] & tiles$xmin < extent_src[3] &
          tiles$ymax > extent_src[2] & tiles$ymin < extent_src[4]
  t <- tiles[keep, ]
  if (!nrow(t)) stop("no tile of the mosaic intersects the request", call. = FALSE)
  if (nrow(t) > MAX_GTI_TILES) {
    stop(sprintf(paste("the request touches %d tiles (more than %d); for a view this wide,",
                       "a pyramid over the mosaic serves it better (external overviews, as",
                       "mdsumner/rema-ovr does for REMA)"), nrow(t), MAX_GTI_TILES), call. = FALSE)
  }
  crs <- attr(tiles, "crs")
  epsg <- tryCatch(gdalraster::srs_find_epsg(crs), error = function(e) NA)
  crs_name <- if (length(epsg) && !is.na(epsg[1])) sprintf("urn:ogc:def:crs:EPSG::%s", sub("^EPSG:", "", epsg[1])) else crs
  feats <- vapply(seq_len(nrow(t)), function(i) {
    sprintf('{"type":"Feature","properties":{"location":%s},"geometry":{"type":"Polygon","coordinates":[[[%.10g,%.10g],[%.10g,%.10g],[%.10g,%.10g],[%.10g,%.10g],[%.10g,%.10g]]]}}',
            jsonlite::toJSON(t$location[i], auto_unbox = TRUE),
            t$xmin[i], t$ymin[i], t$xmax[i], t$ymin[i], t$xmax[i], t$ymax[i], t$xmin[i], t$ymax[i], t$xmin[i], t$ymin[i])
  }, "")
  ## lon/lat axis order: GDAL reads a GeoJSON "crs" as given; keep x, y
  geojson <- sprintf('{"type":"FeatureCollection","crs":{"type":"name","properties":{"name":%s}},"features":[%s]}',
                     jsonlite::toJSON(crs_name, auto_unbox = TRUE), paste(feats, collapse = ","))
  id <- paste(sample(c(letters, 0:9), 12, TRUE), collapse = "")
  idx <- sprintf("/vsimem/warpsandbox-gti-%s.geojson", id)
  vsimem_write(idx, geojson)
  nd <- attr(tiles, "nodata")
  xml <- sprintf(paste0('<GDALTileIndexDataset>',
                        '<IndexDataset>%s</IndexDataset>',
                        '<LocationField>location</LocationField>',
                        '<Resampling>%s</Resampling>',
                        '<DataType>%s</DataType>',
                        '<BandCount>%d</BandCount>',
                        '%s',
                        '</GDALTileIndexDataset>'),
                 idx, resample, attr(tiles, "data_type"), attr(tiles, "band_count"),
                 if (is.na(nd)) "" else sprintf("<NoDataValue>%s</NoDataValue>", format(nd)))
  path <- sprintf("/vsimem/warpsandbox-gti-%s.gti", id)
  vsimem_write(path, xml)
  attr(path, "files") <- c(idx, path)
  attr(path, "tiles") <- nrow(t)
  path
}

engine_gti <- function(req) {
  t0 <- now()
  tiles <- mosaic_tiles(req$dsn)
  t_tiles <- now() - t0
  ## the request's extent in the mosaic's CRS (densified edges)
  e <- req$extent
  ext_src <- gdalraster::bbox_transform(c(e[1], e[3], e[2], e[4]), req$dst_wkt, attr(tiles, "crs"))
  path <- gti_index(tiles, ext_src, req$resample)
  on.exit(for (f in attr(path, "files")) gdalraster::vsi_unlink(f))
  oo <- c(paste0("SRS=", req$dst_wkt), "SRS_BEHAVIOR=REPROJECT",
          sprintf("MINX=%.17g", e[1]), sprintf("MINY=%.17g", e[3]),
          sprintf("MAXX=%.17g", e[2]), sprintf("MAXY=%.17g", e[4]),
          sprintf("RESX=%.17g", (e[2] - e[1]) / req$dim[1]),
          sprintf("RESY=%.17g", (e[4] - e[3]) / req$dim[2]))
  old <- gdalraster::get_config_option("GDAL_DISABLE_READDIR_ON_OPEN")
  gdalraster::set_config_option("GDAL_DISABLE_READDIR_ON_OPEN", "EMPTY_DIR")
  on.exit(gdalraster::set_config_option("GDAL_DISABLE_READDIR_ON_OPEN", old), add = TRUE)
  ## the XML description is opened by name ("GTI:" is for a vector index)
  ds <- methods::new(gdalraster::GDALRaster, as.character(path), TRUE, oo)
  on.exit(ds$close(), add = TRUE)
  if (ds$getRasterXSize() != req$dim[1] || ds$getRasterYSize() != req$dim[2]) {
    stop(sprintf("GTI made a %d x %d grid, not the %d x %d asked for",
                 ds$getRasterXSize(), ds$getRasterYSize(), req$dim[1], req$dim[2]), call. = FALSE)
  }
  t1 <- now()
  a <- read_array(ds, req$bands, req$type)
  nd <- ds$getNoDataValue(1)
  list(data = a, nodata = if (is.na(nd)) NULL else nd,
       seconds = c(total = now() - t0, tiles = t_tiles, read = now() - t1),
       detail = list(tiles = attr(path, "tiles"), of = nrow(tiles)))
}

is_mosaic <- function(req) {
  grepl("^/vsicurl/https?://.*\\.vrt$", req$dsn) && identical(req$kind, "vrt_url")
}
