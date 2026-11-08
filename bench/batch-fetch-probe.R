## Probe: fetch the chunk windows of an rwarp plan sequentially (one read per
## chunk) or in one RasterIO over a VRT that puts the windows side by side.
##   Rscript bench/batch-fetch-probe.R <mode> [threads]
## mode: seq | vrt | advise | fork | threads. Cold: run each in a fresh process. Prints seconds and the
## windows' checksum, so the modes can be checked against each other.
suppressMessages(library(warpsandbox))
args <- commandArgs(TRUE)
mode <- args[1]; threads <- if (length(args) > 1) args[2] else "1"
r <- warp_request("ausantarctic/gebco/GEBCO_2025", crs = "+proj=laea +lat_0=-17 +lon_0=180",
                  extent = "-1.5e6,1.5e6,-1.5e6,1.5e6", dim = "384,384", resample = "bilinear")
g <- warpsandbox:::level_grid(r)
plan <- rwarp::warp_plan(r$src_crs, g$gt, g$dim, r$dst_wkt, r$dst_gt, dst_size = r$dim, resample = r$resample)
win <- do.call(rbind, lapply(plan[[1]], function(c) c(c$src_xoff, c$src_yoff, c$src_xsize, c$src_ysize)))
gdalraster::set_config_option("GDAL_NUM_THREADS", threads)
if (mode == "threads") invisible(warpsandbox:::read_windows_fun())

t0 <- proc.time()[["elapsed"]]
if (mode == "seq") {
  ds <- warpsandbox:::open_level(r$dsn, r$ovr$level)
  vals <- lapply(seq_len(nrow(win)), function(i) ds$read(1, win[i, 1], win[i, 2], win[i, 3], win[i, 4], win[i, 3], win[i, 4]))
  ds$close()
} else if (mode == "advise") {
  ## GDAL7: AdviseRead every window first, then read them
  ds <- GDAL7::gdal_open(r$dsn, options = sprintf("OVERVIEW_LEVEL=%d only", r$ovr$level))
  for (i in seq_len(nrow(win))) GDAL7::advise_read(ds, bands = 1L, window = win[i, ])
  vals <- lapply(seq_len(nrow(win)), function(i) GDAL7::read_raster(ds, bands = 1L, window = win[i, ], type = "double")[[1]])
  GDAL7::gdal_close(ds)
} else if (mode == "threads") {
  ## inst/cpp/read_windows.cpp: every tile row of every window on its own thread
  f <- warpsandbox:::read_windows_fun()
  vals <- f(r$dsn, sprintf("OVERVIEW_LEVEL=%d only", r$ovr$level), win, 1L, 16L)
  vals <- lapply(vals, function(v) { v[v == -32767] <- NA; v })
} else if (mode == "fork") {
  ## open once (the header lands in GDAL's HTTP cache), then one forked
  ## process per window: each inherits the cache and makes one request
  ds <- warpsandbox:::open_level(r$dsn, r$ovr$level); ds$close()
  vals <- parallel::mclapply(seq_len(nrow(win)), function(i) {
    d <- warpsandbox:::open_level(r$dsn, r$ovr$level); on.exit(d$close())
    d$read(1, win[i, 1], win[i, 2], win[i, 3], win[i, 4], win[i, 3], win[i, 4])
  }, mc.cores = nrow(win))
} else {
  ## windows side by side in one VRT, read with one RasterIO
  W <- sum(win[, 3]); H <- max(win[, 4]); x0 <- c(0, cumsum(win[, 3]))[seq_len(nrow(win))]
  src <- sprintf('<SimpleSource><SourceFilename relativeToVRT="0">%s</SourceFilename><OpenOptions><OOI key="OVERVIEW_LEVEL">%d only</OOI></OpenOptions><SourceBand>1</SourceBand><SrcRect xOff="%d" yOff="%d" xSize="%d" ySize="%d"/><DstRect xOff="%d" yOff="0" xSize="%d" ySize="%d"/></SimpleSource>',
                 r$dsn, r$ovr$level, win[, 1], win[, 2], win[, 3], win[, 4], x0, win[, 3], win[, 4])
  xml <- sprintf('<VRTDataset rasterXSize="%d" rasterYSize="%d"><VRTRasterBand dataType="Int16" band="1">%s</VRTRasterBand></VRTDataset>', W, H, paste(src, collapse = ""))
  ds <- methods::new(gdalraster::GDALRaster, xml)
  all <- matrix(ds$read(1, 0, 0, W, H, W, H), nrow = H, byrow = TRUE)
  ds$close()
  vals <- lapply(seq_len(nrow(win)), function(i) as.vector(t(all[seq_len(win[i, 4]), x0[i] + seq_len(win[i, 3]), drop = FALSE])))
}
t <- proc.time()[["elapsed"]] - t0
cat(sprintf("%s threads=%s: %.2f s, %d windows, checksum %.0f\n", mode, threads, t, nrow(win), sum(as.numeric(unlist(vals)), na.rm = TRUE)))
