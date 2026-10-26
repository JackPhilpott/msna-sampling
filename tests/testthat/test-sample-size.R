library(testthat)
source(here::here("R", "functions.R"))

test_that("a very large stratum needs 17 clusters with the default design", {
  # z = 1.645, n0 = 67.6, deff = 1.3 -> 87.9; x 1.1 buffer = 96.7 households
  expect_equal(cluster_sample_size(1e9), 17)
})

test_that("the finite-population correction lowers the sample for small strata", {
  big <- cluster_sample_size(1e6)
  small <- cluster_sample_size(300)
  expect_lt(small, big)
  # N = 300: n_fpc = 300 * 87.9 / 386.9 = 68.2 -> 75.0 with buffer -> 13 clusters
  expect_equal(small, 13)
})

test_that("each design input moves the sample size the expected way", {
  base <- cluster_sample_size(1e6)
  expect_gt(cluster_sample_size(1e6, confidence = 0.95), base)
  expect_gt(cluster_sample_size(1e6, icc = 0.15), base)
  expect_lt(cluster_sample_size(1e6, margin_of_error = 0.15), base)
  expect_lt(cluster_sample_size(1e6, buffer = 0), base)
})
