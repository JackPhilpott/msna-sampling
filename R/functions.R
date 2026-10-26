# Shared functions for the sampling pipeline.

suppressPackageStartupMessages({
  library(here)
  library(yaml)
})

SYNTHETIC_LABEL <- "Synthetic data – not real findings"

read_config <- function(path = here::here("config.yml")) {
  yaml::read_yaml(path)
}

# Number of clusters needed in one stratum.
#
# Standard two-stage cluster-survey formula: simple random sample size for a
# proportion, inflated by the design effect of clustering, corrected for a
# finite population, plus a buffer for attrition, then rounded up to whole
# clusters. `N_hh` is the stratum's estimated number of households.
cluster_sample_size <- function(N_hh, confidence = 0.90, proportion = 0.5,
                                margin_of_error = 0.10, icc = 0.06,
                                cluster_size = 6, buffer = 0.10) {
  z <- qnorm(1 - (1 - confidence) / 2)
  n0 <- z^2 * proportion * (1 - proportion) / margin_of_error^2
  deff <- 1 + (cluster_size - 1) * icc
  n_deff <- n0 * deff
  n_fpc <- N_hh * n_deff / (N_hh + n_deff - 1)
  n_buffered <- n_fpc * (1 + buffer)
  ceiling(n_buffered / cluster_size)
}

# Systematic probability-proportional-to-size selection with a random start.
#
# Units are taken in the order given (sort them geographically first for
# implicit stratification). Returns the index of the unit hit by each of the
# n selection points, so a unit larger than the sampling interval can be
# selected more than once (it then holds more than one cluster).
pps_systematic <- function(size, n) {
  stopifnot(all(size >= 0), n >= 0)
  if (n == 0) return(integer(0))
  total <- sum(size)
  interval <- total / n
  start <- runif(1, 0, interval)
  points <- start + (seq_len(n) - 1) * interval
  findInterval(points, c(0, cumsum(size)), left.open = TRUE)
}

# Write a CSV to data/synthetic/ without row names, with a fixed number format.
write_synthetic <- function(df, name, cfg) {
  out <- here::here(cfg$outputs$dir, name)
  dir.create(dirname(out), recursive = TRUE, showWarnings = FALSE)
  readr::write_csv(df, out, na = "")
  invisible(out)
}
