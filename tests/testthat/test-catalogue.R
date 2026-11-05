## Offline: these read the catalogue written by data-raw/build-catalogue.R.

test_that("the catalogue loads, with unique ids and the expected columns", {
  x <- catalogue()
  expect_gt(nrow(x), 50)
  expect_false(anyDuplicated(x$id) > 0)
  expect_true(all(c("id", "origin", "kind", "dsn", "dsn_template", "crs",
                    "probe_ok", "ncol", "nrow", "dtype") %in% names(x)))
  expect_setequal(unique(x$origin), c("source.coop", "sds"))
})

test_that("every entry has a DSN or a dated template", {
  x <- catalogue()
  expect_true(all(!is.na(x$dsn) | !is.na(x$dsn_template)))
})

test_that("source.coop/ausantarctic is all there", {
  x <- catalogue(origin = "source.coop")
  for (p in c("bedmap", "gebco", "ibcso", "ghrsst-mur-v2")) {
    expect_true(any(startsWith(x$id, paste0("ausantarctic/", p, "/"))), label = p)
  }
  expect_setequal(x$variable[grepl("ghrsst", x$id)],
                  c("analysed_sst", "analysis_error", "mask", "sea_ice_fraction", "sst_anomaly"))
})

test_that("sds names that point at source.coop are aliases, not duplicates", {
  x <- catalogue()
  expect_false("gebco25" %in% x$id)
  expect_identical(source_dsn("gebco25"),
                   "/vsicurl/https://data.source.coop/ausantarctic/gebco/GEBCO_2025.tif")
})

test_that("dated sources fill their template, and refuse unknown dates", {
  d <- source_dsn("ausantarctic/ghrsst-mur-v2/analysed_sst", date = "2020-01-31")
  expect_match(d, "ghrsst-mur-v2/2020/01/31/20200131090000-JPL-L4_GHRSST-SSTfnd-MUR-GLOB-v02.0-fv04.1_analysed_sst.tif$")
  expect_match(source_dsn("ausantarctic/ghrsst-mur-v2/mask"), "^/vsicurl/https://data.source.coop/")
  expect_error(source_dsn("ausantarctic/ghrsst-mur-v2/analysed_sst", date = "1999-01-01"), "no data")
  expect_error(source_dsn("no-such-source"), "no source")
})

test_that("the probe recorded grids for the source.coop COGs", {
  x <- catalogue(origin = "source.coop")
  ok <- x[x$probe_ok %in% TRUE, ]
  expect_gt(nrow(ok), 30)
  g <- ok[ok$id == "ausantarctic/gebco/GEBCO_2025", ]
  expect_equal(c(g$ncol, g$nrow), c(86400, 43200))
  expect_equal(g$crs, "EPSG:4326")
})

test_that("s3_list pages through a real bucket", {
  skip_on_cran()
  skip_if_offline("data.source.coop")
  top <- s3_list(prefix = "", delimiter = "/")
  expect_true("gebco/" %in% attr(top, "prefixes"))
})
