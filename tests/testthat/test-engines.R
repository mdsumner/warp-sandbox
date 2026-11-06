## Requests: validation needs only the catalogue (and PROJ), no network.

test_that("requests are validated with clear messages", {
  expect_error(warp_request("nope"), "no source")
  expect_error(warp_request("gebco25", crs = "EPSG:999999", ovr = "none"), "not a CRS")
  expect_error(warp_request("gebco25", dim = c(99999, 2), ovr = "none"), "dim must be")
  expect_error(warp_request("gebco25", extent = c(1, 0, 0, 1), ovr = "none"), "xmax > xmin")
  expect_error(warp_request("gebco25", resample = "sinc", ovr = "none"), "should be one of")
  expect_error(warp_request("gebco25", bands = 2, ovr = "none"), "bands must be in")
})

test_that("a request resolves extent, bbox and the destination grid", {
  r <- warp_request("gebco25", crs = "EPSG:3031", bbox = "-4e6,-3e6,4e6,3e6",
                    dim = "200,150", resample = "bilinear", ovr = "none")
  expect_equal(r$extent, c(-4e6, 4e6, -3e6, 3e6))
  expect_equal(r$dst_gt, c(-4e6, 40000, 0, 3e6, 0, -40000))
  expect_identical(r$type, "integer")
  expect_identical(r$ovr$level, -1L)
})

test_that("nativeRaster packing is R | G<<8 | B<<16 | A<<24, row-major", {
  r <- matrix(c(1L, 2L, 3L, 4L), 2, byrow = TRUE)
  n <- warpsandbox:::pack_nara(r, r * 0L, r * 0L, matrix(255L, 2, 2))
  expect_s3_class(n, "nativeRaster")
  px <- as.integer(n)
  expect_equal(bitwAnd(px, 255L), c(1L, 2L, 3L, 4L))      # row by row
  expect_equal(bitwAnd(bitwShiftR(px, 24L), 255L), rep(255L, 4))
})

test_that("single-band data renders through the ramp with nodata transparent", {
  a <- array(c(1, 2, -9999, 4), c(2, 2, 1))
  n <- as_nara(list(data = a, nodata = -9999))
  alpha <- bitwAnd(bitwShiftR(as.integer(n), 24L), 255L)
  ## -9999 is a[1, 2], the second pixel in row-major order
  expect_equal(alpha, c(255L, 0L, 255L, 255L))
})

## Engines against each other, on real sources (network).

agree <- function(req) {
  x <- compare_engines(req, c("rwarp", "gdal-app", "gdal7-run", "gdal-direct"), cold = FALSE)
  vapply(x$engines[-1], function(e) {
    v <- e$vs_reference
    is.null(e$error) && v$identical_values == v$compared_values &&
      v$valid_only_in_reference == 0 && v$valid_only_in_this == 0
  }, TRUE)
}

test_that("rwarp, gdalwarp and gdal raster reproject agree on GEBCO (bilinear, polar)", {
  skip_on_cran(); skip_if_offline("data.source.coop")
  req <- warp_request("gebco25", crs = "EPSG:3031", extent = c(-4e6, 4e6, -4e6, 4e6),
                      dim = c(128, 128), resample = "bilinear")
  expect_true(req$ovr$level >= 0)
  expect_true(all(agree(req)))
})

test_that("... and on Bedmap3 with nodata (average)", {
  skip_on_cran(); skip_if_offline("data.source.coop")
  req <- warp_request("ausantarctic/bedmap/bedmap3/bed_topography", crs = "EPSG:3031",
                      extent = c(-3e6, 3e6, -3e6, 3e6), dim = c(128, 128), resample = "average")
  expect_true(all(agree(req)))
})

test_that("rwarp and gdalwarp agree on an alpha tile cache; gdal7-run keeps colour under alpha 0", {
  skip_on_cran(); skip_if_offline("gissdi.dmp.wa.gov.au")
  req <- warp_request("wa_gsd_basemap", crs = "EPSG:28350",
                      extent = c(370000, 420000, 6440000, 6490000), dim = c(128, 128))
  expect_identical(req$alpha, 4L)
  a <- agree(req)
  expect_true(a[["gdal-app"]])
  expect_true(a[["gdal-direct"]])     # given the alpha band explicitly
  expect_false(a[["gdal7-run"]])      # WMS overview bands have no alpha (GDAL 3.14)
})

test_that("gdal-direct compiles and matches gdalwarp on GHRSST (cubic, nodata)", {
  skip_on_cran(); skip_if_offline("data.source.coop")
  skip_if(!nzchar(Sys.which("gdal-config")), "no gdal-config")
  req <- warp_request("ausantarctic/ghrsst-mur-v2/analysed_sst", date = "2024-03-01", crs = "EPSG:3031",
                      extent = c(-4e6, 4e6, -4e6, 4e6), dim = c(96, 96), resample = "cubic")
  x <- compare_engines(req, c("gdal-app", "gdal-direct"), cold = FALSE)
  v <- x$engines[["gdal-direct"]]$vs_reference
  expect_equal(v$identical_values, v$compared_values)
})

test_that("gti builds an index from a VRT mosaic's XML and warps from the tiles", {
  skip_on_cran(); skip_if_offline("opentopography.s3.sdsc.edu")
  m <- mosaic_tiles(source_dsn("cop90"))
  expect_gt(nrow(m), 20000)
  expect_true(all(m$xmax > m$xmin & m$ymax > m$ymin))
  ## one degree over Tasmania: a handful of tiles
  req <- warp_request("cop90", crs = "EPSG:4326", extent = c(146.5, 147.5, -43, -42), dim = c(64, 64))
  r <- run_engine(req, "gti")
  expect_equal(dim(r$data), c(64L, 64L, 1L))
  expect_lte(r$detail$tiles, 9L)  # footprints overhang a half pixel, so edges touch neighbours
  expect_true(any(r$data > 500, na.rm = TRUE))   # Mt Field and the Central Plateau
})

test_that("gti refuses a view that would open too many tiles", {
  skip_on_cran(); skip_if_offline("raw.githubusercontent.com")
  req <- warp_request("rema_v2", crs = "EPSG:3031", extent = c(-2.7e6, 2.8e6, -2.2e6, 2.3e6), dim = c(64, 64))
  expect_error(run_engine(req, "gti"), "pyramid")
})
