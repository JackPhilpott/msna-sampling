# Step 6: maps for the README, each in a light and a dark version.
#
# 1. The sampling frame: households per km2, synthetic IDP sites, and the
#    synthetic inaccessible area
# 2. The sample after resampling: stage-1 clusters, replacements, and the
#    clusters reported inaccessible
# 3. Stage 2 in one cluster: synthetic buildings and the 6 + 6 households drawn
#
# Colours: the sequential blue ramp for density; categorical slots 1-3 (blue,
# orange, aqua) for identity; removed clusters in neutral grey with a cross.
#
# Inputs: data/interim/{frame,stage2_example}.rds, data/synthetic/*.csv
# Outputs: docs/img/<map>_{light,dark}.png

source(here::here("R", "functions.R"))
suppressPackageStartupMessages({
  library(sf)
  library(dplyr)
  library(readr)
  library(ggplot2)
})

cfg <- read_config()
fr <- readRDS(here("data", "interim", "frame.rds"))
example <- readRDS(here("data", "interim", "stage2_example.rds"))
lgas <- read_csv(here(cfg$outputs$dir, "lgas.csv"), show_col_types = FALSE)
clusters <- read_csv(here(cfg$outputs$dir, "clusters_after_resampling.csv"), show_col_types = FALSE)
out_dir <- here(cfg$outputs$maps_dir)
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

themes <- list(
  light = list(surface = "#fcfcfb", ink = "#0b0b0b", ink2 = "#52514e", muted = "#898781",
               line = "#c3c2b7", neutral = "#f0efec", blue = "#2a78d6", orange = "#eb6834",
               aqua = "#1baf7a", ramp = c("#cde2fb", "#86b6ef", "#3987e5", "#1c5cab", "#0d366b"),
               block = "#52514e"),
  dark = list(surface = "#1a1a19", ink = "#f0efec", ink2 = "#c3c2b7", muted = "#898781",
              line = "#383835", neutral = "#2c2c2a", blue = "#3987e5", orange = "#d95926",
              aqua = "#199e70", ramp = c("#0d366b", "#1c5cab", "#3987e5", "#86b6ef", "#cde2fb"),
              block = "#c3c2b7")
)

map_theme <- function(t) {
  theme_void(base_family = "sans") +
    theme(
      plot.background = element_rect(fill = t$surface, colour = NA),
      panel.background = element_rect(fill = t$surface, colour = NA),
      plot.title = element_text(colour = t$ink, face = "bold", size = 15, margin = margin(b = 4)),
      plot.subtitle = element_text(colour = t$ink, face = "bold", size = 11, margin = margin(b = 10)),
      plot.caption = element_text(colour = t$muted, size = 8, hjust = 0, margin = margin(t = 10)),
      legend.title = element_text(colour = t$ink2, size = 9),
      legend.text = element_text(colour = t$ink2, size = 8.5),
      legend.position = "right",
      plot.margin = margin(14, 14, 10, 14)
    )
}

save_both <- function(build, name, width = 9.5, height = 7.5) {
  for (mode in names(themes)) {
    p <- build(themes[[mode]])
    ggsave(file.path(out_dir, sprintf("%s_%s.png", name, mode)), p, width = width, height = height,
           dpi = 150, bg = themes[[mode]]$surface)
  }
}

sources <- paste("Boundaries: HDX COD-AB Nigeria (OSGOF, Ehealth, UNCS), CC BY-IGO.",
                 "Population: WorldPop 2026 constrained, R2025A, CC BY 4.0.",
                 "IDP sites, access layer and sample are synthetic.")
inaccessible <- st_sf(geometry = st_sfc(fr$inaccessible, crs = cfg$area$crs))
pieces <- fr$pieces |> mutate(density = households / (as.numeric(st_area(geometry)) / 1e6))
adm2 <- fr$adm2 |> left_join(select(lgas, adm2_pcode, surveyed), by = "adm2_pcode")

# 1. Sampling frame ------------------------------------------------------------
save_both(function(t) {
  ggplot() +
    geom_sf(data = pieces, aes(fill = density), colour = NA) +
    scale_fill_gradientn(colours = t$ramp, trans = "log10", limits = c(1, 2000), oob = scales::squish,
                         breaks = c(1, 10, 100, 1000), labels = scales::label_comma(),
                         name = "Households per km²") +
    geom_sf(data = inaccessible, aes(alpha = "Inaccessible area"), fill = t$block, colour = NA) +
    scale_alpha_manual(values = 0.45, name = NULL) +
    geom_sf(data = fr$adm1, fill = NA, colour = t$surface, linewidth = 0.5) +
    # a slightly larger point in the surface colour underneath gives each site a ring
    geom_sf(data = fr$sites, aes(shape = category), colour = t$surface, size = 3.1, show.legend = FALSE) +
    geom_sf(data = fr$sites, aes(shape = category, colour = category), size = 2.1) +
    scale_shape_manual(values = c(in_camp = 17, host_community = 16), name = "IDP sites",
                       breaks = c("in_camp", "host_community"),
                       labels = c("In camp", "Host community")) +
    scale_colour_manual(values = c(in_camp = t$orange, host_community = t$aqua), name = "IDP sites",
                        breaks = c("in_camp", "host_community"),
                        labels = c("In camp", "Host community")) +
    labs(title = sprintf("Sampling frame: %d states, %s hexagon pieces, %d IDP sites",
                         nrow(fr$adm1), format(nrow(pieces), big.mark = ","), nrow(fr$sites)),
         subtitle = SYNTHETIC_LABEL, caption = sources) +
    map_theme(t)
}, "map_frame")

# 2. Sample after resampling ----------------------------------------------------
cl <- clusters |>
  mutate(group = case_when(status == "inaccessible" ~ "Reported inaccessible",
                           round_added > 0 ~ "Replacement",
                           TRUE ~ "Stage 1 draw"),
         group = factor(group, levels = c("Stage 1 draw", "Replacement", "Reported inaccessible"))) |>
  st_as_sf(coords = c("lon", "lat"), crs = 4326) |>
  st_transform(cfg$area$crs) |>
  arrange(desc(group))
group_labels <- sprintf("%s (%s)", levels(cl$group), scales::comma(as.integer(table(cl$group))))
save_both(function(t) {
  ggplot() +
    geom_sf(data = adm2, aes(fill = surveyed), colour = t$line, linewidth = 0.15) +
    scale_fill_manual(values = c(`TRUE` = t$neutral, `FALSE` = t$line), name = NULL,
                      labels = c(`TRUE` = "LGA surveyed", `FALSE` = "LGA not surveyed")) +
    geom_sf(data = fr$adm1, fill = NA, colour = t$ink2, linewidth = 0.4) +
    geom_sf(data = cl, aes(colour = group, shape = group), size = 1.1, stroke = 0.6) +
    scale_colour_manual(values = c(`Stage 1 draw` = t$blue, Replacement = t$orange,
                                   `Reported inaccessible` = t$muted), name = "Clusters",
                        labels = group_labels) +
    scale_shape_manual(values = c(`Stage 1 draw` = 16, Replacement = 16, `Reported inaccessible` = 4),
                       name = "Clusters", labels = group_labels) +
    guides(colour = guide_legend(override.aes = list(size = 2.5))) +
    labs(title = sprintf("Sample after two rounds of resampling: %s active clusters",
                         format(sum(cl$status == "active"), big.mark = ",")),
         subtitle = SYNTHETIC_LABEL, caption = sources) +
    map_theme(t)
}, "map_sample")

# 3. Stage 2 in one cluster -----------------------------------------------------
sel <- example$selected |> mutate(role = factor(role, levels = c("primary", "reserve")))
save_both(function(t) {
  ggplot() +
    geom_sf(data = st_sf(geometry = example$poly), fill = t$neutral, colour = t$ink2, linewidth = 0.6) +
    geom_sf(data = st_sf(geometry = example$buildings), aes(colour = "Synthetic building"), size = 0.9) +
    geom_sf(data = sel, aes(colour = role, shape = role), size = 3.2, stroke = 1.1) +
    scale_colour_manual(values = c(`Synthetic building` = t$muted, primary = t$blue, reserve = t$orange),
                        breaks = c("primary", "reserve", "Synthetic building"),
                        labels = c("Primary household (6)", "Reserve household (6)", "Synthetic building"),
                        name = NULL) +
    scale_shape_manual(values = c(primary = 16, reserve = 1), guide = "none") +
    guides(colour = guide_legend(override.aes = list(shape = c(16, 1, 16), size = c(3, 3, 1.5)))) +
    labs(title = "Stage 2 in one cluster: 6 primary and 6 reserve households",
         subtitle = SYNTHETIC_LABEL,
         caption = sprintf("Cluster %s. Buildings are synthetic, standing in for satellite building footprints.",
                           example$cluster_id)) +
    map_theme(t)
}, "stage2_example", width = 8, height = 7)

message("Maps written to ", cfg$outputs$maps_dir)
