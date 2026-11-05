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
  f <- system.file("api", "api.R", package = "warpsandbox")
  if (!nzchar(f)) f <- file.path("inst", "api", "api.R")
  plumber2::api(f) |> plumber2::api_run(host = host, port = port, block = block)
}
