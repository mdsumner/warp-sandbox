## Where could rwarp win? A sweep over awkward destinations, the source type,
## and plan reuse. COG sources only (tile services have their own cache and
## fetch pattern). Writes bench/where-rwarp-wins.rds and prints tables.
##   Rscript bench/where-rwarp-wins.R        (about 15 min; run under tmux)
##
## Per case:
##  - rwarp's plan: chunks, source pixels read (sum of chunk windows), lowest fill ratio
##  - GDAL's chunks and source windows, and the kernel it picked, from
##    `gdalwarp --debug on` (same GDAL as R, same overview level)
##  - bytes and GETs per engine, each in a fresh process with GDAL's network
##    statistics, minus a process that only resolves the request
##  - cold (HTTP cache cleared, median of 3) and warm (median of 3) seconds
## Then: the same geometry as Int16, Float32 and Byte (through vrt://), warm;
## and one rwarp plan reused over 10 GHRSST dates against planning each time.
suppressPackageStartupMessages(library(warpsandbox))
ENG <- c("rwarp", "gdal-direct", "gdal-app")
GEBCO <- "ausantarctic/gebco/GEBCO_2025"
TAS <- "+proj=laea +lat_0=-42 +lon_0=147"
cases <- list(
  pole_inside    = list(GEBCO, "EPSG:3031", "-4e6,4e6,-4e6,4e6", "384,384", "bilinear"),
  pole_offcentre = list(GEBCO, "EPSG:3031", "-1e6,3e6,-1e6,3e6", "384,384", "bilinear"),
  antimeridian   = list(GEBCO, "+proj=laea +lat_0=-17 +lon_0=180", "-1.5e6,1.5e6,-1.5e6,1.5e6", "384,384", "bilinear"),
  small_oblique  = list(GEBCO, TAS, "-3e5,3e5,-3e5,3e5", "384,384", "bilinear"),
  identity       = list(GEBCO, "EPSG:4326", "140,150,-45,-40", "384,192", "bilinear"),
  big_output     = list(GEBCO, "EPSG:3031", "-4e6,4e6,-4e6,4e6", "2048,2048", "bilinear"),
  lanczos_1k     = list(GEBCO, "EPSG:3031", "-4e6,4e6,-4e6,4e6", "1024,1024", "lanczos"),
  polar_to_lonlat = list("ausantarctic/ibcso/annual-2025/bed", "EPSG:4326", "-180,180,-90,-50", "768,192", "bilinear"))

## SMOKE=1: one case, one type pair, 2 dates, to check the script end to end
SMOKE <- nzchar(Sys.getenv("SMOKE"))
if (SMOKE) cases <- cases[c("pole_inside", "lanczos_1k")]

req_of <- function(cs, vrt = NULL) warp_request(cs[[1]], crs = cs[[2]], extent = cs[[3]], dim = cs[[4]], resample = cs[[5]], vrt = vrt)

## rwarp's plan
plan_stats <- function(req) {
  g <- warpsandbox:::level_grid(req)
  p <- rwarp::warp_plan(req$src_crs, g$gt, g$dim, req$dst_wkt, req$dst_gt, dst_size = req$dim, resample = req$resample)
  ch <- if (is.null(p)) list() else p[[1]]
  data.frame(rwarp_chunks = length(ch),
             rwarp_src_px = sum(vapply(ch, function(c) c$src_xsize * c$src_ysize, 0)),
             rwarp_min_fill = if (length(ch)) min(vapply(ch, function(c) c$fill_ratio, 0)) else NA)
}

## GDAL's chunks, windows and kernel, from gdalwarp's debug output
gdal_windows <- function(req) {
  out <- tempfile(fileext = ".tif"); on.exit(unlink(out))
  e <- req$extent
  args <- c("--debug", "on", "-q", "-overwrite", "-t_srs", shQuote(req$crs),
            "-te", e[1], e[3], e[2], e[4], "-ts", req$dim, "-r", req$resample,
            "-ovr", if (req$ovr$level >= 0) req$ovr$level else "NONE", shQuote(req$dsn), out)
  log <- suppressWarnings(system2("gdalwarp", args, stdout = TRUE, stderr = TRUE))
  w <- regmatches(log, regexpr("GWK[A-Za-z0-9_]+\\(\\) Src=[0-9]+,[0-9]+,[0-9]+x[0-9]+", log))
  if (!length(w)) return(data.frame(gdal_chunks = 0L, gdal_src_px = NA, gdal_kernel = NA))
  sz <- do.call(rbind, lapply(regmatches(w, regexec("Src=[0-9]+,[0-9]+,([0-9]+)x([0-9]+)", w)), function(m) as.numeric(m[2:3])))
  data.frame(gdal_chunks = length(w), gdal_src_px = sum(sz[, 1] * sz[, 2]),
             gdal_kernel = paste(unique(sub("\\(\\).*", "", w)), collapse = ","))
}

## GETs and bytes of one engine in a fresh process ("baseline": the request only)
net <- function(cs, engine, vrt = NULL) {
  code <- sprintf('suppressMessages(library(warpsandbox)); r <- warp_request(%s, crs = %s, extent = %s, dim = %s, resample = %s%s); %s',
                  deparse(cs[[1]]), deparse(cs[[2]]), deparse(cs[[3]]), deparse(cs[[4]]), deparse(cs[[5]]),
                  if (is.null(vrt)) "" else sprintf(", vrt = %s", deparse(vrt)),
                  if (engine == "baseline") "" else sprintf("invisible(run_engine(r, %s))", deparse(engine)))
  txt <- paste(suppressWarnings(system2("Rscript", c("-e", shQuote(code)), stdout = TRUE, stderr = TRUE,
              env = c("CPL_VSIL_NETWORK_STATS_ENABLED=YES", "CPL_VSIL_SHOW_NETWORK_STATS=YES"))), collapse = "\n")
  i <- regexpr("Network statistics:", txt, fixed = TRUE)
  if (i < 0) return(c(gets = NA, bytes = NA))
  g <- jsonlite::fromJSON(substring(txt, i + nchar("Network statistics:")))$methods$GET
  c(gets = g$count %||% 0, bytes = g$downloaded_bytes %||% 0)
}
`%||%` <- function(a, b) if (is.null(a)) b else a

secs <- function(req, warm) {
  if (warm) {
    x <- compare_engines(req, ENG, warm = TRUE)$engines
  } else {
    ## three cold rounds, engine order shuffled each time, median per engine
    r <- lapply(1:3, function(i) compare_engines(req, sample(ENG), cold = TRUE)$engines)
    x <- setNames(lapply(ENG, function(e) list(seconds = list(total = stats::median(vapply(r, function(z) z[[e]]$seconds$total %||% NA_real_, 0))))), ENG)
  }
  vapply(ENG, function(e) x[[e]]$seconds$total %||% NA_real_, 0)
}

set.seed(1)
rows <- list()
for (nm in names(cases)) {
  cs <- cases[[nm]]
  message(format(Sys.time(), "%T"), "  ", nm)
  req <- req_of(cs)
  base <- net(cs, "baseline")
  nets <- lapply(ENG, function(e) net(cs, e) - base)
  cold <- secs(req, FALSE); warm <- secs(req, TRUE)
  row <- data.frame(case = nm, ovr = req$ovr$level, plan_stats(req), gdal_windows(req))
  for (k in seq_along(ENG)) {
    e <- sub("-", "_", ENG[k])
    row[[paste0("kb_", e)]] <- round(nets[[k]][["bytes"]] / 1024)
    row[[paste0("gets_", e)]] <- nets[[k]][["gets"]]
    row[[paste0("cold_", e)]] <- round(cold[[k]], 3)
    row[[paste0("warm_", e)]] <- round(warm[[k]], 3)
  }
  rows[[nm]] <- row
}
sweep <- do.call(rbind, rows); rownames(sweep) <- NULL

## Source type: the same geometry and bytes, Int16 vs Float32 vs Byte (warm)
message(format(Sys.time(), "%T"), "  types")
types <- list(Int16 = NULL, Float32 = "ot=Float32", Byte = "ot=Byte&scale=-8000,0,0,255")
tt <- do.call(rbind, lapply(c("pole_inside", "lanczos_1k"), function(nm) do.call(rbind, lapply(names(types), function(ty) {
  req <- req_of(cases[[nm]], types[[ty]])
  w <- secs(req, TRUE)
  data.frame(case = nm, type = ty, t(round(w, 3)), gdal_kernel = gdal_windows(req)$gdal_kernel, check.names = FALSE)
}))))

## Plan reuse: GHRSST over 10 dates, warm (each date fetched once first)
message(format(Sys.time(), "%T"), "  plan reuse")
dates <- format(as.Date("2024-03-01") + 0:(if (SMOKE) 1 else 9))
gh <- list("ausantarctic/ghrsst-mur-v2/analysed_sst", "EPSG:3031", "-4e6,4e6,-4e6,4e6", "384,384", "bilinear")
reqs <- lapply(dates, function(d) warp_request(gh[[1]], date = d, crs = gh[[2]], extent = gh[[3]], dim = gh[[4]], resample = gh[[5]]))
for (r in reqs) for (e in c("rwarp", "gdal-direct")) invisible(run_engine(r, e))
g0 <- warpsandbox:::level_grid(reqs[[1]])
t_plan <- system.time(plan0 <- rwarp::warp_plan(reqs[[1]]$src_crs, g0$gt, g0$dim, reqs[[1]]$dst_wkt, reqs[[1]]$dst_gt,
                                                 dst_size = reqs[[1]]$dim, resample = reqs[[1]]$resample))[["elapsed"]]
tm <- function(f) { t <- proc.time()[["elapsed"]]; f(); proc.time()[["elapsed"]] - t }
reuse <- data.frame(
  approach = c("rwarp, plan each date", "rwarp, one plan reused", "gdal-direct, each date"),
  seconds_10_dates = round(c(tm(function() for (r in reqs) run_engine(r, "rwarp")),
                             t_plan + tm(function() for (r in reqs) { r$plan <- plan0; run_engine(r, "rwarp") }),
                             tm(function() for (r in reqs) run_engine(r, "gdal-direct"))), 3))
reuse$per_date <- round(reuse$seconds_10_dates / length(dates), 4)

saveRDS(list(sweep = sweep, types = tt, reuse = reuse, when = Sys.time(),
             gdal = gdalraster::gdal_version()[1], rwarp = as.character(packageVersion("rwarp"))),
        if (SMOKE) file.path(tempdir(), "smoke.rds") else "bench/where-rwarp-wins.rds")
options(width = 200)
cat("\n## Sweep\n"); print(sweep, row.names = FALSE)
cat("\n## Source type (warm seconds)\n"); print(tt, row.names = FALSE)
cat("\n## Plan reuse, GHRSST 10 dates (warm)\n"); print(reuse, row.names = FALSE)
