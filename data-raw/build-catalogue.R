## Rebuild inst/catalogue/ (network; takes a few minutes for the probe).
##   Rscript data-raw/build-catalogue.R
pkgload::load_all(".", quiet = TRUE)
cat0 <- catalogue_build()
message(nrow(cat0), " sources listed; probing with GDAL ...")
cat1 <- catalogue_probe(cat0)
message("mosaic and pyramid flags ...")
cat1 <- catalogue_flags(cat1)
attr(cat1, "ghrsst_dates") <- attr(cat0, "ghrsst_dates")
catalogue_write(cat1, "inst/catalogue")
message(sum(cat1$probe_ok, na.rm = TRUE), " of ", nrow(cat1), " opened with GDAL")
