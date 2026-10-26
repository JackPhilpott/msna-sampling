library(testthat)
source(here::here("R", "functions.R"))

test_that("the same seed gives the same selection", {
  size <- c(5, 40, 12, 3, 80, 25, 9)
  set.seed(1); a <- pps_systematic(size, 4)
  set.seed(1); b <- pps_systematic(size, 4)
  expect_identical(a, b)
})

test_that("selection probability is proportional to size", {
  size <- c(10, 20, 30, 40, 100)
  n <- 3
  set.seed(42)
  hits <- replicate(20000, tabulate(pps_systematic(size, n), nbins = length(size)))
  observed <- rowMeans(hits)
  expected <- n * size / sum(size)
  expect_equal(observed, expected, tolerance = 0.02)
})

test_that("a unit larger than the interval holds more than one cluster", {
  size <- c(1, 1, 98)
  set.seed(7)
  sel <- pps_systematic(size, 4)
  expect_gte(sum(sel == 3), 3)
  expect_length(sel, 4)
})

test_that("zero-size units are never selected", {
  size <- c(0, 10, 0, 10, 0)
  set.seed(3)
  sel <- unlist(lapply(1:500, function(i) pps_systematic(size, 2)))
  expect_true(all(sel %in% c(2, 4)))
})
