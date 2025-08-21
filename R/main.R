#' @title Get Routes
#' @description
#' This function enables the computation of routes.
#'
#' @param x dataframe with x_src, y_src, x_dst, y_dst in WGS84 coordinates
#' (EPSG:4326)
#' @param nc number of CPU cores
#' @param nq number of queries per chunk
#' @param server Valhalla server address
#' @param profile Valhalla profile (costing model)
#' @param costing_options list of options to use with the costing model
#' (see \url{https://valhalla.github.io/valhalla/api/turn-by-turn/api-reference/#costing-options}
#' or valh documentation)
#' @importFrom foreach foreach %dopar%
#' @export
#' @return An sf object or a data.frame is returned.
#' @examples
#' \dontrun{
#' apt <- read.csv(system.file("csv/apotheke.csv", package = "valh"))
#' x <- cbind(apt[c(1:100,1:100,1:100, 1:100), c(2:3)],
#'            apt[c(rep(1,100), rep(10,100), rep(20,100), rep(30, 100)), c(2:3)])
#' server = "http://xxxxxxx:8002/"
#' r <- routes(x, nc = 8, nq = 50, server = server)
#' library(mapsf)
#' op <- par(mfrow = c(2,2))
#' mf_map(r[1:100,], col = "red")
#' mf_map(r[101:200,], col = "blue")
#' mf_map(r[201:300,], col = "darkgreen")
#' mf_map(r[301:400,], col = "purple")
#' par(op)
#' }
routes <- function(x,
                   nc = 1,
                   nq = 100,
                   server,
                   profile = "auto",
                   costing_options = list()){
  ny <- nrow(x)
  sequence <- unique(c(seq(1, ny, nq), ny + 1))
  lseq <- length(sequence) - 1
  ml <- list()
  for  (i in 1:lseq) {
    ml[[i]] <- as.matrix.data.frame(x[(sequence[i]):(sequence[i + 1] - 1),])
  }

  cl <- parallel::makeCluster(nc, setup_strategy = "sequential")
  doParallel::registerDoParallel(cl)
  on.exit(parallel::stopCluster(cl))

  res <- foreach(x = ml, .combine = rbind, .inorder = FALSE,
                  .export = c("bq", "cpgeom")) %dopar%
    {
      do.call(rbind, lapply(apply(x, 1, bq, server = server, profile = profile, costing_options = costing_options), cpgeom))
    }
  return(res)

}

bq <- function(x, server, profile, costing_options){
  x <- round(x, 5)
  json <- list(
    costing = profile,
    locations =  list(
      list(lon = x[1], lat = x[2]),
      list(lon = x[3], lat = x[4])
    )
  )

  if (is.list(costing_options) && length(costing_options) > 0) {
    json$costing_options <- list()
    json$costing_options[[costing]] <- costing_options
  }

  utils::URLencode(paste0(server, "route?json=", jsonlite::toJSON(json, auto_unbox = TRUE)))
}

cpgeom <- function(q, req_handle){
  tryCatch(
    expr = {
      req_handle <- curl::new_handle(verbose = FALSE)
      curl::handle_setopt(req_handle, useragent = "valh_R_package")
      r <- curl::curl_fetch_memory(q, handle = req_handle)
      res <- RcppSimdJson::fparse(rawToChar(r$content))
      geodf <- do.call(rbind, lapply(res[[1]]$legs$shape, function(x) googlePolylines::decode(x)[[1]] / 10))
      rosf <- sf::st_sf(
        duration = res[[1]]$summary$time / 60,
        distance = res[[1]]$summary$length,
        geometry = sf::st_as_sfc(paste0("LINESTRING(", paste0(geodf$lon, " ", geodf$lat, collapse = ", "), ")")),
        crs = 4326
      )
    },
    error = function(cond){
      print(cond)
      sf::st_sf(duration = NA, distance = NA,
                geometry = sf::st_sfc(sf::st_linestring()), crs = "EPSG:4326")
    }
  )
}