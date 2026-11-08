## Add the mosaic and pyramid flags (catalogue_flags()) to the existing
## catalogue without rebuilding it (a rebuild would also pick up new listings).
##   Rscript data-raw/add-flags.R
pkgload::load_all(".", quiet = TRUE)
cat1 <- catalogue()
## the date index stays as it is (catalogue_write() would rewrite it with quoted dates)
cat1 <- catalogue_flags(cat1)
catalogue_write(cat1, "inst/catalogue")
