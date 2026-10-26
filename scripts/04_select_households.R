# Step 4: stage 2, household selection (synthetic buildings).
#
# The real design drew households from satellite building footprints for
# non-IDP clusters, and from a listing at the site for IDP clusters. Here the
# buildings are synthetic: for each selected hexagon piece, a few settlement
# centres are placed at random and buildings scattered around them; for each
# IDP site, dwellings are scattered around the site point (tighter for camps).
# Every active cluster then gets 6 primary and 6 reserve households, drawn at
# random without overlap between clusters in the same place.
#
# Inputs: data/synthetic/clusters_after_resampling.csv, data/interim/frame.rds
# Outputs: data/synthetic/households/households_<state>.csv
#          data/interim/stage2_example.rds (one cluster's buildings, for the maps)

source(here::here("R", "functions.R"))
suppressPackageStartupMessages({
  library(sf)
  library(dplyr)
  library(readr)
})

cfg <- read_config()
set.seed(cfg$seed)
ss <- cfg$sample_size
per_cluster <- ss$cluster_size + ss$reserves
fr <- readRDS(here("data", "interim", "frame.rds"))
crs <- cfg$area$crs

clusters <- read_csv(here(cfg$outputs$dir, "clusters_after_resampling.csv"), show_col_types = FALSE) |>
  filter(status == "active") |>
  arrange(cluster_id)

# Synthetic buildings inside a polygon: points scattered around a few settlement
# centres, kept only if they fall inside, topped up uniformly if needed.
# The loop works on geometries without a CRS: everything is in one projected CRS
# anyway, and sf otherwise asks PROJ about the CRS on every call, which was most
# of this step's run time. The CRS is put back on the outputs at the end.
points_from_xy <- function(xy) {
  st_cast(st_sfc(st_multipoint(xy[, 1:2, drop = FALSE])), "POINT")
}

buildings_in_polygon <- function(poly, n, spread_m) {
  centres <- st_coordinates(st_sample(poly, sample(1:4, 1), exact = TRUE))
  pick <- sample(nrow(centres), n * 3, replace = TRUE)
  xy <- centres[pick, 1:2, drop = FALSE] + matrix(rnorm(n * 6, 0, spread_m), ncol = 2)
  pts <- points_from_xy(xy)
  pts <- pts[lengths(st_intersects(pts, poly)) > 0]
  if (length(pts) < n) pts <- c(pts, st_sample(poly, n - length(pts), exact = TRUE))
  pts[seq_len(n)]
}

# Dwellings around an IDP site point.
dwellings_around_site <- function(site, n, spread_m) {
  xy <- st_coordinates(site)[rep(1, n), 1:2, drop = FALSE] + matrix(rnorm(n * 2, 0, spread_m), ncol = 2)
  points_from_xy(xy)
}

# Look PSUs up by position: subsetting a 22,000-row sf table inside the loop is slow
piece_id <- sprintf("%s_hex%05d", fr$pieces$adm2_pcode, fr$pieces$hex)
piece_geom <- st_set_crs(st_geometry(fr$pieces), NA)
piece_hh <- fr$pieces$households
sites <- fr$sites
site_geom <- st_set_crs(st_geometry(sites), NA)
households <- list()
example <- NULL

for (psu in unique(clusters$psu_id)) {
  cl <- clusters[clusters$psu_id == psu, ]
  need <- nrow(cl) * per_cluster
  if (cl$pop_type[1] == "non_idp") {
    i <- match(psu, piece_id)
    poly <- piece_geom[i]
    n_build <- max(need * 3, min(400, round(piece_hh[i])))
    pts <- buildings_in_polygon(poly, n_build, spread_m = 350)
    if (is.null(example) && nrow(cl) == 1) example <- list(poly = poly, buildings = pts, cluster_id = cl$cluster_id)
  } else {
    s <- match(psu, sites$site_id)
    spread <- if (sites$category[s] == "in_camp") 120 else 500
    pts <- dwellings_around_site(site_geom[s], max(need * 2, min(300, sites$households[s])), spread)
  }
  order <- sample(length(pts), need)
  xy <- st_coordinates(pts)
  role <- rep(c("primary", "reserve"), c(ss$cluster_size, ss$reserves))
  rank <- c(seq_len(ss$cluster_size), seq_len(ss$reserves))
  for (j in seq_len(nrow(cl))) {
    idx <- order[((j - 1) * per_cluster + 1):(j * per_cluster)]
    # plain coordinates here; converting to lon/lat once at the end is far faster
    households[[length(households) + 1]] <- tibble(
      household_id = sprintf("%s_%s%02d", cl$cluster_id[j], ifelse(role == "primary", "H", "R"), rank),
      cluster_id = cl$cluster_id[j], psu_id = psu, stratum_id = cl$stratum_id[j], pop_type = cl$pop_type[j],
      adm1_name = cl$adm1_name[j], adm2_name = cl$adm2_name[j], partner = cl$partner[j],
      role = role, rank = rank, x = xy[idx, 1], y = xy[idx, 2]
    )
    if (!is.null(example) && identical(example$cluster_id, cl$cluster_id[j]) && is.null(example$selected)) {
      example$selected <- st_sf(role = role, geometry = pts[idx])
    }
  }
}

hh <- bind_rows(households)
lonlat <- sf_project(st_crs(crs), st_crs(4326), cbind(hh$x, hh$y))
hh <- hh |> mutate(lon = round(lonlat[, 1], 5), lat = round(lonlat[, 2], 5)) |> select(-x, -y)

for (state in sort(unique(hh$adm1_name))) {
  write_synthetic(filter(hh, adm1_name == state),
                  file.path("households", sprintf("households_%s.csv", tolower(state))), cfg)
}
example$poly <- st_set_crs(example$poly, crs)
example$buildings <- st_set_crs(example$buildings, crs)
example$selected <- st_set_crs(example$selected, crs)
saveRDS(example, here("data", "interim", "stage2_example.rds"))
message(sprintf("Stage 2: %s households (%s primary, %s reserve) in %s clusters",
                format(nrow(hh), big.mark = ","), format(sum(hh$role == "primary"), big.mark = ","),
                format(sum(hh$role == "reserve"), big.mark = ","), format(nrow(clusters), big.mark = ",")))
