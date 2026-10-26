# Step 2: stage 1, cluster selection.
#
# For each stratum (LGA x population type), work out how many clusters the
# design needs, then draw them by systematic PPS from the accessible PSUs in
# surveyed LGAs. A stratum with fewer households than six clusters' worth takes
# every PSU instead (a census of its PSUs).
#
# Inputs: data/synthetic/{frame_psus,lgas}.csv
# Outputs: data/synthetic/{strata,clusters}.csv

source(here::here("R", "functions.R"))
suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
})

cfg <- read_config()
set.seed(cfg$seed)
ss <- cfg$sample_size

lgas <- read_csv(here(cfg$outputs$dir, "lgas.csv"), show_col_types = FALSE) |>
  select(adm1_name, adm1_pcode, adm2_name, adm2_pcode, surveyed, partner)
frame <- read_csv(here(cfg$outputs$dir, "frame_psus.csv"), show_col_types = FALSE) |>
  left_join(lgas, by = "adm2_pcode") |>
  mutate(stratum_id = paste(pop_type, adm2_pcode, sep = "_"))
eligible <- frame |>
  filter(surveyed, accessible, size_hh > 0) |>
  arrange(stratum_id, frame_order)

strata <- eligible |>
  group_by(stratum_id, pop_type, adm1_name, adm1_pcode, adm2_name, adm2_pcode, partner) |>
  summarise(N_hh = sum(size_hh), n_psu = n(), .groups = "drop") |>
  mutate(
    census = N_hh < 6 * ss$cluster_size,
    clusters = if_else(
      census, n_psu,
      pmin(cluster_sample_size(N_hh, ss$confidence, ss$proportion, ss$margin_of_error,
                               ss$icc, ss$cluster_size, ss$buffer),
           floor(N_hh / ss$cluster_size))
    ),
    households_target = clusters * ss$cluster_size
  ) |>
  arrange(stratum_id)

drawn <- vector("list", nrow(strata))
for (i in seq_len(nrow(strata))) {
  s <- strata[i, ]
  psus <- eligible[eligible$stratum_id == s$stratum_id, ]
  idx <- if (s$census) seq_len(nrow(psus)) else pps_systematic(psus$size_hh, s$clusters)
  drawn[[i]] <- psus[idx, ] |> mutate(cluster_no = seq_len(n()))
}

clusters <- bind_rows(drawn) |>
  mutate(cluster_id = sprintf("%s_C%02d", stratum_id, cluster_no), draw = "stage1") |>
  select(cluster_id, psu_id, stratum_id, pop_type, adm1_name, adm1_pcode, adm2_name, adm2_pcode,
         partner, draw, lon, lat)

write_synthetic(strata, "strata.csv", cfg)
write_synthetic(clusters, "clusters.csv", cfg)

summary <- strata |>
  group_by(pop_type) |>
  summarise(strata = n(), census_strata = sum(census), clusters = sum(clusters),
            households = sum(households_target), .groups = "drop")
print(as.data.frame(summary), row.names = FALSE)
message(sprintf("Stage 1: %s clusters, %s households to interview, %d LGAs",
                format(sum(strata$clusters), big.mark = ","),
                format(sum(strata$households_target), big.mark = ","),
                n_distinct(strata$adm2_pcode)))
