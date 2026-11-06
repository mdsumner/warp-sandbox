## rwarp vs gdal-direct kernels with no network and no decompression: an
## uncompressed in-memory copy of IBCSO 2025 bed at overview 2 (2400 x 2400 Int16),
## to EPSG:3031 at 512, 1024 and 2048 square, five kernels. rwarp reads are served
## from an R matrix (their time is subtracted). Outputs are compared value for value.
##   Rscript bench/kernels-in-memory.R
## Note: gdalraster::translate() and ::warp() open the source themselves, so -oo
## is ignored; -ovr selects the overview.
suppressPackageStartupMessages(library(warpsandbox))
## the IBCSO 2025 bed at overview 2 (2400 x 2400 Int16), as an uncompressed local file
src <- "/vsimem/ibcso_l2.tif"
gdalraster::translate("/vsicurl/https://data.source.coop/ausantarctic/ibcso/annual-2025/cog/bed.tif", src,
                      cl_arg = c("-ovr", "2", "-co", "COMPRESS=NONE", "-co", "TILED=NO"), quiet = TRUE)
ds <- methods::new(gdalraster::GDALRaster, src); gt <- ds$getGeoTransform(); dimS <- c(ds$getRasterXSize(), ds$getRasterYSize()); wkt <- ds$getProjectionRef(); nd <- ds$getNoDataValue(1)
v_all <- ds$read(1, 0, 0, dimS[1], dimS[2], dimS[1], dimS[2]); v_all[is.na(v_all)] <- nd; v_all <- as.integer(v_all); ds$close()
dst_wkt <- gdalraster::srs_to_wkt("EPSG:3031"); ext <- c(-3e6, 3e6, -3e6, 3e6)
cat("source:", dimS, "\n"); invisible(warpsandbox:::gdal_direct_fun())
res <- list()
for (n in c(512L, 1024L, 2048L)) for (k in c("near", "bilinear", "cubic", "lanczos", "average")) {
  dst_gt <- c(ext[1], diff(ext[1:2]) / n, 0, ext[4], 0, -diff(ext[3:4]) / n)
  plan <- rwarp::warp_plan(wkt, gt, as.integer(dimS), dst_wkt, dst_gt, dst_size = c(n, n), resample = k)
  ## rwarp: reads served from memory (a slice of v_all), so this is plan + kernel + loop
  M <- matrix(v_all, nrow = dimS[2], byrow = TRUE); rf <- function(xoff, yoff, xsize, ysize) as.integer(t(M[yoff + seq_len(ysize), xoff + seq_len(xsize), drop = FALSE]))
  t_slice <- system.time(for (c in plan[[1]]) rf(c$src_xoff, c$src_yoff, c$src_xsize, c$src_ysize))[["elapsed"]]
  t_r <- system.time(a <- rwarp::warp_exec(plan, rf, wkt, gt, dst_wkt, dst_gt, resample = k, src_nodata = nd, dst_nodata = nd))[["elapsed"]] - t_slice
  t_d <- system.time(b <- warpsandbox:::gdal_direct_env$f(src, character(), 1L, dst_wkt, dst_gt, c(n, n), k, "integer", 0.125, 0L))[["elapsed"]]
  bm <- matrix(b$bands[[1]], n, byrow = TRUE)
  same <- mean(a == bm)
  res[[length(res) + 1]] <- data.frame(dim = n, kernel = k, rwarp_s = round(t_r, 3), gdal_direct_s = round(t_d, 3),
                                       ratio = round(t_r / t_d, 1), identical = sprintf("%.4f", same))
}
print(do.call(rbind, res), row.names = FALSE)
