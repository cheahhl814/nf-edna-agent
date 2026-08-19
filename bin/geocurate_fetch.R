#!/usr/bin/env Rscript

# geocurate_fetch.R
# This script fetches public occurrence records for a list of scientific names
# from GBIF and OBIS and caches them to disk.

# --- 1. Load Libraries ---
suppressPackageStartupMessages(library(optparse))
suppressPackageStartupMessages(library(readr))
suppressPackageStartupMessages(library(dplyr))
suppressPackageStartupMessages(library(stringr))
suppressPackageStartupMessages(library(purrr))
suppressPackageStartupMessages(library(rgbif))
suppressPackageStartupMessages(library(robis))
suppressPackageStartupMessages(library(future)) # For parallel processing
suppressPackageStartupMessages(library(furrr)) # For parallel map

# --- 2. Define Command-Line Options ---
option_list <- list(
  make_option("--taxa", type="character", default=NULL, help="Path to a text file containing a list of scientific names."),
  make_option("--cache_dir", type="character", default="occurrence_cache", help="Directory to store downloaded occurrence data [default= %default]."),
  make_option("--limit", type="integer", default=5000, help="Maximum number of records to fetch per taxon from GBIF [default= %default]."),
  make_option("--exclude_obis", type="logical", default=FALSE, help="Exclude querying OBIS for occurrence data [default= %default].") # New option
)

opt_parser <- OptionParser(option_list=option_list)
opt <- parse_args(opt_parser)

# --- Argument Validation ---
if (is.null(opt$taxa)) {
  print_help(opt_parser)
  stop("The --taxa argument must be supplied.", call.=FALSE)
}

# --- 3. Prepare Directories and Load Data ---
cat("Loading and preparing input data...\n")

# Create cache directory if it doesn't exist
if (!dir.exists(opt$cache_dir)) {
  cat("Creating cache directory:", opt$cache_dir, "\n")
  dir.create(opt$cache_dir, recursive = TRUE)
}

# Load taxa list
taxa_to_fetch <- readr::read_lines(opt$taxa) %>%
  str_trim() %>%
  unique()
cat(paste("Found", length(taxa_to_fetch), "unique taxa to fetch.\n"))

# Setup parallel processing
plan(multisession) # Use multiple R sessions for parallel processing

# Define function to fetch and cache data for a single taxon
fetch_single_taxon <- function(taxon, cache_dir, limit, exclude_obis) {
  cat(paste("\nFetching data for:", taxon, "...\n"))
  
  safe_filename <- gsub(" ", "_", taxon)
  cache_file <- file.path(cache_dir, paste0(safe_filename, "_occurrences.csv"))
  
  # Check cache first
  if (file.exists(cache_file)) {
    cat("  - Found cache file. Skipping API query for", taxon, "\n")
    return(NULL) # Already cached, nothing to do
  }

  gbif_df <- NULL
  obis_df <- NULL
  
  selected_cols <- c('scientificName', 'decimalLatitude', 'decimalLongitude', 'year', 'month', 'day', 'basisOfRecord', 'databaseName')
  
  # Query GBIF
  cat("    - Querying GBIF... ")
  tryCatch({
    gbif_data <- rgbif::occ_search(scientificName = taxon, hasCoordinate = TRUE, limit = limit)
    if (!is.null(gbif_data$data)) {
      gbif_df <- gbif_data$data %>%
        mutate(databaseName = "GBIF") %>%
        select(any_of(selected_cols)) %>%
        mutate(across(c(any_of(c("year", "month", "day"))), as.character)) # Ensure consistent data types
      cat(paste("Found", nrow(gbif_df), "records.\n"))
    } else { cat("Found 0 records.\n") }
  }, error = function(e) { cat("Error querying GBIF for", taxon, ":", e$message, "\n"); gbif_df <<- NULL })

  # Query OBIS (only if not excluded)
  if (!exclude_obis) { # Check the new option
    cat("    - Querying OBIS... ")
    tryCatch({
      obis_records <- robis::occurrence(scientificname = taxon)
      if (!is.null(obis_records) && nrow(obis_records) > 0) { # robis returns empty tibble if no records
        obis_df <- obis_records %>%
          mutate(databaseName = "OBIS") %>%
          select(any_of(selected_cols)) %>%
          mutate(across(c(any_of(c("year", "month", "day"))), as.character)) # Ensure consistent data types
        cat(paste("Found", nrow(obis_df), "records.\n"))
      } else { cat("Found 0 records.\n") }
    }, error = function(e) { cat("Error querying OBIS for", taxon, ":", e$message, "\n"); obis_df <<- NULL })
  } else {
    cat("    - OBIS querying excluded by option.\n")
  }

  public_occurrences <- bind_rows(gbif_df, obis_df)

  if (!is.null(public_occurrences) && nrow(public_occurrences) > 0) {
    cat("  - Saving", nrow(public_occurrences), "records to cache file:", cache_file, "\n")
    readr::write_csv(public_occurrences, cache_file)
  } else {
    cat("  - No public records found for", taxon, ". Creating empty cache file.\n")
    # Create an empty file to mark that this taxon has been processed (and has no records)
    readr::write_csv(data.frame(), cache_file)
  }
  
  return(NULL) # No need to return data, just cache files
}

# --- 4. Main Processing Loop (Parallelized) ---
cat("Starting parallel fetching of taxa occurrence data...\n")
future_map(taxa_to_fetch, ~ fetch_single_taxon(., opt$cache_dir, opt$limit, opt$exclude_obis), .options = furrr_options(seed = TRUE))

cat("\nOccurrence data fetching and caching complete.\n")