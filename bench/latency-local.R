## Round trips at a fixed latency: GEBCO overview 3 served locally by
## bench/slow_range_server.py (a fixed delay per request), so time is
## requests on the critical path times the delay, without network noise.
##   python3 -I bench/slow_range_server.py <dir with gebco_ovr3.tif> 8765 0.4 2> server.log &
##   Rscript bench/latency-local.R <engine> <case>     (one fresh process per run)
## engine: rwarp | rwarp-noprefetch | gdal-direct | gdal-app
## case: antimeridian | pole_inside | small_oblique
suppressMessages(library(warpsandbox))
a <- commandArgs(TRUE); eng <- a[1]; case <- a[2]
Sys.setenv(GDAL_DISABLE_READDIR_ON_OPEN = "EMPTY_DIR")
gdalraster::set_config_option("GDAL_DISABLE_READDIR_ON_OPEN", "EMPTY_DIR")
invisible(warpsandbox:::read_windows_fun())
if (eng == "rwarp-noprefetch") { options(warpsandbox.prefetch = FALSE); eng <- "rwarp" }
cat0 <- catalogue()
i <- match("ausantarctic/gebco/GEBCO_2025", cat0$id)
cat0$dsn[i] <- "/vsicurl/http://127.0.0.1:8765/gebco_ovr3.tif"
cat0$ncol[i] <- 5400L; cat0$nrow[i] <- 2700L
cat0$xres[i] <- 360 / 5400; cat0$yres[i] <- 180 / 2700; cat0$n_overviews[i] <- 0L
cases <- list(antimeridian = c("+proj=laea +lat_0=-17 +lon_0=180", "-1.5e6,1.5e6,-1.5e6,1.5e6"),
              pole_inside = c("EPSG:3031", "-4e6,4e6,-4e6,4e6"),
              small_oblique = c("+proj=laea +lat_0=-42 +lon_0=147", "-1e6,1e6,-1e6,1e6"))
r <- warp_request("ausantarctic/gebco/GEBCO_2025", crs = cases[[case]][1], extent = cases[[case]][2],
                  dim = "384,384", resample = "bilinear", cat = cat0)
message("START")
s <- run_engine(r, eng)$seconds
cat(sprintf("%-13s %-17s %.2f s\n", case, a[1], s[["total"]]))
message("END")
