# Extracted from test-engines.R:94

# setup ------------------------------------------------------------------------
library(testthat)
test_env <- simulate_test_env(package = "warpsandbox", path = "..")
attach(test_env, warn.conflicts = FALSE)

# prequel ----------------------------------------------------------------------
agree <- function(req) {
  x <- compare_engines(req, c("rwarp", "gdal-app", "gdal7-run", "gdal-direct"), cold = FALSE)
  vapply(x$engines[-1], function(e) {
    v <- e$vs_reference
    is.null(e$error) && v$identical_values == v$compared_values &&
      v$valid_only_in_reference == 0 && v$valid_only_in_this == 0
  }, TRUE)
}

# test -------------------------------------------------------------------------
skip_on_cran()
skip_if_offline("opentopography.s3.sdsc.edu")
m <- mosaic_tiles(source_dsn("cop90"))
expect_gt(nrow(m), 20000)
expect_true(all(m$xmax > m$xmin & m$ymax > m$ymin))
req <- warp_request("cop90", crs = "EPSG:4326", extent = c(146.5, 147.5, -43, -42), dim = c(64, 64))
r <- run_engine(req, "gti")
expect_equal(dim(r$data), c(64L, 64L, 1L))
expect_lte(r$detail$tiles, 4L)
