library(testthat)
# Integrity checks on the pipeline's outputs. Skipped until the pipeline has run.
source(here::here("R", "functions.R"))
suppressPackageStartupMessages({
  library(sf)
  library(dplyr)
  library(readr)
})

cfg <- read_config()
out <- function(...) here::here(cfg$outputs$dir, ...)
have_outputs <- file.exists(out("clusters_after_resampling.csv")) &&
  file.exists(here::here("data", "interim", "frame.rds"))

test_that("every frame unit sits inside its own LGA", {
  skip_if_not(have_outputs, "run the pipeline first")
  fr <- readRDS(here::here("data", "interim", "frame.rds"))
  psus <- read_csv(out("frame_psus.csv"), show_col_types = FALSE) |>
    st_as_sf(coords = c("lon", "lat"), crs = 4326) |>
    st_transform(cfg$area$crs)
  # a 50 m margin absorbs the rounding of coordinates at LGA edges
  hits <- st_intersects(psus, st_buffer(fr$adm2, 50))
  inside <- mapply(function(i, code) code %in% fr$adm2$adm2_pcode[i], hits, psus$adm2_pcode)
  expect_true(all(inside))
})

test_that("the accessible flag agrees with the access layer", {
  skip_if_not(have_outputs, "run the pipeline first")
  layer <- st_read(out("access_layer_synthetic.geojson"), quiet = TRUE)
  psus <- read_csv(out("frame_psus.csv"), show_col_types = FALSE) |>
    st_as_sf(coords = c("lon", "lat"), crs = 4326)
  in_layer <- lengths(st_intersects(psus, layer)) > 0
  # accessible should mean "outside the layer"; a unit both inside and flagged
  # accessible (or the reverse) is a mismatch. Coordinates are rounded to 4
  # decimals (about 10 m), so allow a handful right at the edge.
  mismatch <- in_layer == psus$accessible
  expect_lt(mean(mismatch), 0.002)
})

test_that("stage 1 draws exactly the clusters each stratum needs", {
  skip_if_not(have_outputs, "run the pipeline first")
  strata <- read_csv(out("strata.csv"), show_col_types = FALSE)
  clusters <- read_csv(out("clusters.csv"), show_col_types = FALSE)
  drawn <- count(clusters, stratum_id, name = "drawn")
  check <- inner_join(strata, drawn, by = "stratum_id")
  expect_equal(nrow(check), nrow(strata))
  expect_equal(check$drawn, check$clusters)
})

test_that("every active cluster has 6 primary and 6 reserve households", {
  skip_if_not(have_outputs, "run the pipeline first")
  active <- read_csv(out("clusters_after_resampling.csv"), show_col_types = FALSE) |>
    filter(status == "active")
  hh <- bind_rows(lapply(list.files(out("households"), full.names = TRUE), read_csv,
                         show_col_types = FALSE))
  per <- count(hh, cluster_id, role) |> tidyr::pivot_wider(names_from = role, values_from = n)
  expect_setequal(per$cluster_id, active$cluster_id)
  expect_true(all(per$primary == cfg$sample_size$cluster_size))
  expect_true(all(per$reserve == cfg$sample_size$reserves))
  expect_false(anyDuplicated(hh$household_id) > 0)
})

test_that("replacements stay in the stratum of the cluster they replace", {
  skip_if_not(have_outputs, "run the pipeline first")
  cl <- read_csv(out("clusters_after_resampling.csv"), show_col_types = FALSE)
  repl <- cl |> filter(!is.na(replaces)) |>
    left_join(select(cl, cluster_id, old_stratum = stratum_id), by = c("replaces" = "cluster_id"))
  expect_true(all(repl$stratum_id == repl$old_stratum))
  # a replacement drawn in round r never lands on a PSU reported inaccessible in
  # rounds 1..r (it can itself be reported inaccessible in a later round)
  lost <- cl |> filter(status == "inaccessible")
  bad <- mapply(function(psu, r) psu %in% lost$psu_id[lost$round_removed <= r],
                repl$psu_id, repl$round_added)
  expect_false(any(bad))
})
