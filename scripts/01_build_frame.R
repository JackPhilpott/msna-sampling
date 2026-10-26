# Step 1: build the sampling frame.
#
# - a hexagon grid over the 11 states, cut at LGA boundaries, with households
#   estimated from WorldPop (non-IDP primary sampling units)
# - synthetic IDP sites (IDP primary sampling units)
# - a synthetic access layer: a band along the international border plus
#   randomly placed inaccessible zones
# - LGAs kept for data collection, and synthetic partner assignment
#
# Inputs: data/raw/ (open data, see 00_download_open_data.py)
# Outputs: data/synthetic/{frame_psus,idp_sites_synthetic,lgas}.csv,
#          data/synthetic/access_layer_synthetic.geojson, and
#          data/interim/frame.rds (geometry for later steps, not committed)

source(here::here("R", "functions.R"))
suppressPackageStartupMessages({
  library(sf)
  library(terra)
  library(exactextractr)
  library(dplyr)
  library(readr)
})

cfg <- read_config()
set.seed(cfg$seed)
crs <- cfg$area$crs
hh_size <- cfg$households$persons_per_household

# --- Boundaries ----------------------------------------------------------------
read_admin <- function(level) {
  files <- list.files(here(cfg$open_data$boundaries$dir), recursive = TRUE, full.names = TRUE,
                      pattern = sprintf("admin%d\\.shp$", level))
  st_read(files[1], quiet = TRUE) |> st_transform(crs)
}
adm0 <- read_admin(0)
adm1 <- read_admin(1) |> filter(adm1_name %in% cfg$area$states)
stopifnot(setequal(adm1$adm1_name, cfg$area$states))
adm2 <- read_admin(2) |>
  filter(adm1_name %in% cfg$area$states) |>
  select(adm1_name, adm1_pcode, adm2_name, adm2_pcode)
area <- st_union(adm1)
message(sprintf("Area: %d states, %d LGAs, %s km2", nrow(adm1), nrow(adm2),
                format(round(as.numeric(st_area(area)) / 1e6), big.mark = ",")))

# --- Hexagon grid cut at LGA boundaries, with households from WorldPop -----------
# This step is slow and has no randomness, so it is cached in data/interim/.
cache <- here("data", "interim", "pieces_population.rds")
cache_key <- list(cfg$area$states, cfg$area$hex_cellsize_m, crs, cfg$open_data$population$file)
if (file.exists(cache) && identical(readRDS(cache)$key, cache_key)) {
  pieces <- readRDS(cache)$pieces
} else {
  grid <- st_make_grid(area, cellsize = cfg$area$hex_cellsize_m, square = FALSE)
  grid <- st_sf(hex = seq_along(grid), geometry = grid)
  grid <- grid[lengths(st_intersects(grid, area)) > 0, ]
  pieces <- suppressWarnings(st_intersection(grid, adm2)) |>
    st_collection_extract("POLYGON", warn = FALSE) |>
    group_by(hex, adm1_name, adm1_pcode, adm2_name, adm2_pcode) |>
    summarise(.groups = "drop")
  pop <- rast(here(cfg$open_data$population$file))
  pop <- crop(pop, vect(st_transform(area, crs(pop))))
  pieces$population <- exact_extract(pop, st_transform(pieces, crs(pop)), "sum", progress = FALSE)
  dir.create(dirname(cache), showWarnings = FALSE)
  saveRDS(list(key = cache_key, pieces = pieces), cache)
}
pieces$households <- pieces$population / hh_size
non_idp <- pieces |>
  filter(households >= cfg$area$min_hex_households) |>
  mutate(pop_type = "non_idp",
         psu_id = sprintf("%s_hex%05d", adm2_pcode, hex),
         frame_order = hex)
message(sprintf("Non-IDP frame: %s hexagon pieces, %s households",
                format(nrow(non_idp), big.mark = ","),
                format(round(sum(non_idp$households)), big.mark = ",")))

# --- Synthetic IDP sites ---------------------------------------------------------
sites <- lapply(names(cfg$idp_sites$per_state), function(state) {
  n <- cfg$idp_sites$per_state[[state]]
  pool <- non_idp[non_idp$adm1_name == state, ]
  host <- pool[sample(nrow(pool), n, replace = TRUE, prob = pool$households), ]
  pts <- st_sample(st_geometry(host), size = rep(1L, n), exact = TRUE)
  in_camp <- runif(n) < cfg$idp_sites$in_camp_share
  st_sf(adm1_name = host$adm1_name, adm1_pcode = host$adm1_pcode,
        adm2_name = host$adm2_name, adm2_pcode = host$adm2_pcode,
        category = ifelse(in_camp, "in_camp", "host_community"),
        households = pmax(15, round(rlnorm(n, cfg$idp_sites$households_meanlog + 0.6 * in_camp,
                                           cfg$idp_sites$households_sdlog))),
        geometry = pts)
})
sites <- do.call(rbind, sites)
sites <- sites[order(sites$adm2_pcode, st_coordinates(sites)[, 1]), ]
sites$site_id <- sprintf("S%03d", seq_len(nrow(sites)))
sites$site_name <- sprintf("Site %03d", seq_len(nrow(sites)))
message(sprintf("Synthetic IDP sites: %d (%d in camps), %s households",
                nrow(sites), sum(sites$category == "in_camp"),
                format(sum(sites$households), big.mark = ",")))

# --- Synthetic access layer ------------------------------------------------------
border_band <- st_buffer(st_boundary(st_union(adm0)), cfg$access$border_buffer_km * 1000)
centres <- st_sample(area, cfg$access$n_zones)
radii <- runif(cfg$access$n_zones, cfg$access$zone_radius_km[1], cfg$access$zone_radius_km[2]) * 1000
zones <- st_union(st_buffer(centres, radii))
inaccessible <- st_intersection(st_union(border_band, zones), area)

psus <- bind_rows(
  non_idp |> select(psu_id, pop_type, adm1_name, adm1_pcode, adm2_name, adm2_pcode,
                    size_hh = households, frame_order) |>
    mutate(geometry = st_point_on_surface(geometry)),
  sites |> transmute(psu_id = site_id, pop_type = "idp", adm1_name, adm1_pcode, adm2_name,
                     adm2_pcode, size_hh = households, frame_order = seq_len(n()))
) |> st_as_sf()
psus$accessible <- lengths(st_intersects(psus, inaccessible)) == 0
psus$near_zone <- psus$accessible &
  lengths(st_is_within_distance(psus, zones, cfg$resampling$near_zone_km * 1000)) > 0

# --- LGAs kept for data collection -----------------------------------------------
lgas <- psus |>
  st_drop_geometry() |>
  group_by(adm1_name, adm1_pcode, adm2_name, adm2_pcode) |>
  summarise(households = sum(size_hh), accessible_share = sum(size_hh[accessible]) / sum(size_hh),
            .groups = "drop") |>
  mutate(surveyed = accessible_share >= cfg$access$min_lga_accessible_share)
message(sprintf("LGAs kept for data collection: %d of %d", sum(lgas$surveyed), nrow(lgas)))

# --- Synthetic partner assignment ------------------------------------------------
# Partners are shared out between states in proportion to their surveyed LGAs
# (at least one each), then each state's LGAs are split west to east.
centroid_x <- st_coordinates(st_centroid(st_geometry(adm2)))[, 1]
lgas$x <- centroid_x[match(lgas$adm2_pcode, adm2$adm2_pcode)]
by_state <- lgas |> filter(surveyed) |> count(adm1_name)
quota <- by_state$n / sum(by_state$n) * cfg$partners$count
k <- pmax(1, floor(quota))
while (sum(k) < cfg$partners$count) {
  i <- which.max(quota - k)
  k[i] <- k[i] + 1
}
partner_names <- paste("Partner", LETTERS[seq_len(cfg$partners$count)])
by_state$first <- cumsum(c(0, head(k, -1))) + 1
by_state$k <- k
lgas$partner <- NA_character_
for (i in seq_len(nrow(by_state))) {
  rows <- which(lgas$adm1_name == by_state$adm1_name[i] & lgas$surveyed)
  rows <- rows[order(lgas$x[rows])]
  group <- ceiling(seq_along(rows) / length(rows) * by_state$k[i])
  lgas$partner[rows] <- partner_names[by_state$first[i] + group - 1]
}
psus <- psus |>
  left_join(select(lgas, adm2_pcode, surveyed, partner), by = "adm2_pcode") |>
  mutate(stratum_id = paste(pop_type, adm2_pcode, sep = "_"))

# --- Outputs ---------------------------------------------------------------------
# Kept lean to stay under 2 MB: LGA names, partner and the surveyed flag live in
# lgas.csv (join on adm2_pcode), and the stratum is pop_type + "_" + adm2_pcode.
# Coordinates are attached before sorting so each row keeps its own point.
lonlat <- st_coordinates(st_transform(psus, 4326))
frame_out <- psus |>
  mutate(lon = round(lonlat[, 1], 4), lat = round(lonlat[, 2], 4), size_hh = round(size_hh)) |>
  st_drop_geometry() |>
  arrange(stratum_id, frame_order) |>
  select(psu_id, pop_type, adm2_pcode, accessible, near_zone, size_hh, frame_order, lon, lat)
write_synthetic(frame_out, "frame_psus.csv", cfg)

site_xy <- st_coordinates(st_transform(sites, 4326))
write_synthetic(sites |> st_drop_geometry() |>
                  mutate(lon = round(site_xy[, 1], 4), lat = round(site_xy[, 2], 4)) |>
                  select(site_id, site_name, category, adm1_name, adm1_pcode, adm2_name, adm2_pcode,
                         households, lon, lat),
                "idp_sites_synthetic.csv", cfg)
write_synthetic(lgas |> select(-x) |> mutate(households = round(households),
                                             accessible_share = round(accessible_share, 3)),
                "lgas.csv", cfg)

dir.create(here("data", "interim"), showWarnings = FALSE)
saveRDS(list(adm0 = adm0, adm1 = adm1, adm2 = adm2, pieces = non_idp, sites = sites,
             inaccessible = inaccessible, zones = zones, border_band = border_band),
        here("data", "interim", "frame.rds"))
# GeoJSON rather than GeoPackage: plain text, identical on every run, and GitHub shows it as a map.
# Simplifying in metres first keeps vertices apart, so rounding the coordinates cannot create
# duplicate vertices (which spherical tools such as s2 reject).
layer_out <- st_simplify(st_sfc(inaccessible), preserveTopology = TRUE, dTolerance = 25) |>
  st_transform(4326)
st_write(st_sf(layer = "inaccessible", geometry = layer_out),
         here(cfg$outputs$dir, "access_layer_synthetic.geojson"), delete_dsn = TRUE, quiet = TRUE,
         layer_options = c("COORDINATE_PRECISION=6", "RFC7946=YES"))
message("Frame written to ", cfg$outputs$dir)
