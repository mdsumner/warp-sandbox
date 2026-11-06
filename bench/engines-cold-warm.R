## Each engine on three requests, 5 runs each in random order, with GDAL's HTTP
## cache cleared before every run (cold) and warm. Medians.
##   Rscript bench/engines-cold-warm.R
suppressPackageStartupMessages(library(warpsandbox))
eng <- c("rwarp", "gdal-app", "gdal7-run", "gdal-direct")
cases <- list(
  gebco_bilinear = list("gebco25", NULL, "bilinear", c(-4e6, 4e6, -4e6, 4e6), c(384L, 384L)),
  ghrsst_cubic   = list("ausantarctic/ghrsst-mur-v2/analysed_sst", "2024-03-01", "cubic", c(-4e6, 4e6, -4e6, 4e6), c(256L, 256L)),
  ibcso_lanczos_1k = list("ausantarctic/ibcso/annual-2025/bed", NULL, "lanczos", c(-3e6, 3e6, -3e6, 3e6), c(1024L, 1024L)))
invisible(warpsandbox:::gdal_direct_fun())
set.seed(1)
rows <- list()
for (nm in names(cases)) {
  cs <- cases[[nm]]
  req <- warp_request(cs[[1]], date = cs[[2]], crs = "EPSG:3031", extent = cs[[4]], dim = cs[[5]], resample = cs[[3]])
  for (mode in c("cold", "warm")) {
    if (mode == "warm") for (e in eng) run_engine(req, e)       # fill the cache
    for (rep in 1:5) for (e in sample(eng)) {
      if (mode == "cold") gdalraster::vsi_curl_clear_cache()
      r <- run_engine(req, e)
      s <- r$seconds
      rows[[length(rows) + 1]] <- data.frame(case = nm, mode = mode, engine = e, total = s[["total"]],
        fetch = if ("fetch" %in% names(s)) s[["fetch"]] else NA, plan = if ("plan" %in% names(s)) s[["plan"]] else NA)
    }
  }
}
x <- do.call(rbind, rows)
agg <- aggregate(cbind(total, fetch, plan) ~ case + mode + engine, x, median, na.action = na.pass)
agg <- agg[order(agg$case, agg$mode, agg$total), ]
agg[, 4:6] <- round(agg[, 4:6], 3)
print(agg, row.names = FALSE)
saveRDS(x, "engines-cold-warm.rds")
