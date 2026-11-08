#' Run the sandbox API
#'
#' Binds to 127.0.0.1 by default: reach it from another machine through an
#' SSH tunnel (`ssh -L 8090:localhost:8090 <host>`), then open
#' http://localhost:8090/.
#'
#' @param port,host Where to listen.
#' @param block Block the R session (TRUE for a server).
#' @export
sandbox_run <- function(port = 8090, host = "127.0.0.1", block = TRUE) {
  ## room in GDAL's HTTP cache for a whole request, so warm timings are warm
  ## (it is read when /vsicurl/ is first used, so set it before that)
  if (!nzchar(gdalraster::get_config_option("CPL_VSIL_CURL_CACHE_SIZE"))) {
    gdalraster::set_config_option("CPL_VSIL_CURL_CACHE_SIZE", as.character(256 * 1024^2))
  }
  f <- system.file("api", "api.R", package = "warpsandbox")
  if (!nzchar(f)) f <- file.path("inst", "api", "api.R")
  plumber2::api(f) |> plumber2::api_run(host = host, port = port, block = block)
}
