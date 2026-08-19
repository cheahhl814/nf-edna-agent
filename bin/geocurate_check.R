#!/usr/bin/env Rscript

# geocurate_check.R
# This script performs the geographic concordance check using cached occurrence data
# and classifies taxa. Map generation has been removed.

# --- 1. Load Libraries ---
suppressPackageStartupMessages(library(optparse))
suppressPackageStartupMessages(library(readr))
suppressPackageStartupMessages(library(dplyr))
suppressPackageStartupMessages(library(tidyr))
suppressPackageStartupMessages(library(stringr))
suppressPackageStartupMessages(library(sf))
suppressPackageStartupMessages(library(purrr))
suppressPackageStartupMessages(library(future)) # For parallel processing
suppressPackageStartupMessages(library(furrr)) # For parallel map

# --- 2. Define Command-Line Options ---
option_list <- list(
  # Inputs
  make_option("--taxa", type="character", default=NULL, help="Path to a text file containing a list of scientific names."),
  make_option("--locations", type="character", default=NULL, help="Path to a metadata file with study locations (must contain Latitude, Longitude)."),
  make_option("--coords", type="character", default=NULL, help="A single coordinate pair 'latitude,longitude' as an alternative to --locations.", metavar="character"),
  make_option("--cache_dir", type="character", default="occurrence_cache", help="Directory where downloaded occurrence data is stored [default= %default]."),
  
  # Parameters
  make_option("--buffer", type="numeric", default=50, help="Buffer radius in kilometers [default= %default]."),
  
  # Outputs
  make_option("--concordant", type="character", default="concordant_taxa.txt", help="Output file for taxa found within the buffer [default= %default]."),
  make_option("--discordant", type="character", default="discordant_taxa.txt", help="Output file for taxa not found within the buffer [default= %default]."),
  make_option("--norecords", type="character", default="norecords_taxa.txt", help="Output file for taxa with no public occurrence data found [default= %default].")
)

opt_parser <- OptionParser(option_list=option_list)
opt <- parse_args(opt_parser)

# --- Argument Validation ---
if (is.null(opt$taxa) || (is.null(opt$locations) && is.null(opt$coords))) {
  print_help(opt_parser)
  stop("The --taxa argument and either --locations or --coords must be supplied.", call.=FALSE)
}
if (!is.null(opt$locations) && !is.null(opt$coords)) {
  print_help(opt_parser)
  stop("Provide either --locations or --coords, not both.", call.=FALSE)
}

# --- 3. Prepare Directories and Load Data ---
cat("Loading and preparing input data...
")

# Ensure cache directory exists
if (!dir.exists(opt$cache_dir)) {
  stop(paste("Cache directory not found:", opt$cache_dir, "Please run geocurate_fetch.R first."), call.=FALSE)
}

# Load study locations
if (!is.null(opt$locations)) {
  locations <- readr::read_tsv(opt$locations, col_types = cols(.default = "c")) %>%
    rename_with(tolower, any_of(c("Latitude", "Longitude"))) %>%
    filter(!is.na(latitude), !is.na(longitude)) %>%
    select(latitude, longitude) %>%
    distinct() %>%
    sf::st_as_sf(coords = c("longitude", "latitude"), crs = 4326)
} else {
  coords_vec <- as.numeric(trimws(strsplit(opt$coords, ",")[[1]]))
  if (length(coords_vec) != 2 || any(is.na(coords_vec))) {
    stop("--coords format must be 'latitude,longitude'.", call.=FALSE)
  }
  locations <- tibble(latitude = coords_vec[1], longitude = coords_vec[2]) %>%
    sf::st_as_sf(coords = c("longitude", "latitude"), crs = 4326)
}
cat(paste("Loaded", nrow(locations), "unique study location(s).
"))

# Load taxa list
taxa_to_check <- readr::read_lines(opt$taxa) %>%
  str_trim() %>%
  unique()
cat(paste("Found", length(taxa_to_check), "unique taxa to check.
"))

# Setup parallel processing
plan(multisession)

# Define function to perform concordance check for a single taxon
check_single_taxon <- function(taxon, opt, locations_sf) {
  cat(paste("
Checking concordance for:", taxon, "...
"))
  
  safe_filename <- gsub(" ", "_", taxon)
  cache_file <- file.path(opt$cache_dir, paste0(safe_filename, "_occurrences.csv"))
  
  result <- list(
    concordant = character(),
    discordant = character(),
    norecords = character()
  )

  # Load occurrence data from cache
  if (!file.exists(cache_file)) {
      cat("  - Cache file not found for", taxon, ". Skipping concordance check.
")
      result$norecords <- taxon # Treat as no records if cache file missing
      return(result)
  }
  public_occurrences <- readr::read_csv(cache_file, col_types = cols(.default = "c"))
  
  # --- Concordance Analysis ---
  if (is.null(public_occurrences) || nrow(public_occurrences) == 0) {
    cat("  - No public records found in cache. Classifying as 'no records'.
")
    result$norecords <- taxon
    return(result)
  }

  is_concordant <- FALSE
  public_occurrences_sf <- public_occurrences %>%
    filter(!is.na(decimalLatitude), !is.na(decimalLongitude)) %>%
    sf::st_as_sf(coords = c("decimalLongitude", "decimalLatitude"), crs = 4326)
  
  if(nrow(public_occurrences_sf) > 0) {
    public_projected <- sf::st_transform(public_occurrences_sf, crs = 3857)

    for (i in 1:nrow(locations_sf)) {
        site_sf <- locations_sf[i,]
        site_projected <- sf::st_transform(site_sf, crs = 3857)
        buffer_sf_proj <- sf::st_buffer(site_projected, dist = opt$buffer * 1000)

        if (any(sf::st_intersects(buffer_sf_proj, public_projected, sparse = FALSE))) {
            is_concordant <- TRUE
            break # Found concordance for at least one site, no need to check others for this taxon
        }
    }
  }
  
  if (is_concordant) {
    cat("  - Found concordant record(s) near a study site. Classifying as 'Concordant'.
")
    result$concordant <- taxon
  } else {
    cat("  - No concordant records found. Classifying as 'Discordant'.
")
    result$discordant <- taxon
  }
  return(result)
}

# --- 4. Main Processing Loop (Parallelized) ---
cat("Starting parallel processing of taxa for concordance check...
")
processed_results <- future_map(taxa_to_check, ~ check_single_taxon(., opt, locations), .options = furrr_options(seed = TRUE))

# Combine results
concordant_taxa <- unlist(map(processed_results, ~ .$concordant))
discordant_taxa <- unlist(map(processed_results, ~ .$discordant))
norecords_taxa <- unlist(map(processed_results, ~ .$norecords))

# --- 5. Save Outputs ---
cat("
Saving results...
")

write_lines(concordant_taxa, opt$concordant)
cat(paste("  - Concordant taxa saved to:", opt$concordant, " (", length(concordant_taxa), " taxa)
"))

write_lines(discordant_taxa, opt$discordant)
cat(paste("  - Discordant taxa saved to:", opt$discordant, " (", length(discordant_taxa), " taxa)
"))

write_lines(norecords_taxa, opt$norecords)
cat(paste("  - Taxa with no public records saved to:", opt$norecords, " (", length(norecords_taxa), " taxa)
"))

cat("
Geographic concordance check complete.
")
