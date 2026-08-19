#!/usr/bin/env Rscript


# --- Load Required Libraries ---
library(argparse)
library(DECIPHER)

parser <- ArgumentParser(description='Perform IDTAXA classification on query sequences.')

parser$add_argument('--query_sequences', type='character', help='Path to the query sequences FASTA file.')
parser$add_argument('--idtaxa_model', type='character', help='Path to the IDTAXA model RDS file.')
parser$add_argument('--output_classification', type='character', help='Path for the output classification TSV file.')
parser$add_argument('--output_confidence', type='character', help='Path for the output confidence TSV file.')

args <- parser$parse_args()

# Load query sequences
cat(paste0("Loading query sequences from: ", args$query_sequences, "\n"))
dna <- readDNAStringSet(args$query_sequences)

# Load IDTAXA model
cat(paste0("Loading IDTAXA model from: ", args$idtaxa_model, "\n"))
trainingSet <- readRDS(args$idtaxa_model)

# Perform classification
cat("Performing IDTAXA classification...\n")
ids <- IdTaxa(dna, trainingSet, strand="both", processors=NULL)

# Format classification results robustly
cat("Formatting classification results...\n")
# Define the desired rank levels and their order, matching NCBI standard ranks
rank_levels <- c("superkingdom", "phylum", "class", "order", "family", "genus", "species")
n_ranks <- length(rank_levels)

# Positional rank hierarchy for rank-less IDTAXA models (e.g. 12S fish).
# These models omit the $rank field entirely; ranks are inferred by position.
RANKLESS_HIERARCHY <- c("rootrank", "superkingdom", "phylum", "class", "order", "family", "genus", "species")

# Function to map IdTaxa output to fixed rank levels
process_idtaxa_result <- function(x) {
  # Initialize vectors for this row with NAs
  final_taxon_row <- rep(NA_character_, n_ranks)
  names(final_taxon_row) <- rank_levels
  final_confidence_row <- rep(NA_real_, n_ranks)
  names(final_confidence_row) <- rank_levels

  # For rank-less models (e.g. 12S), $rank is absent; synthesize from positional hierarchy
  ranks_vec <- x$rank
  if (length(ranks_vec) == 0) {
    n_t <- length(x$taxon)
    ranks_vec <- if (n_t <= length(RANKLESS_HIERARCHY)) {
      RANKLESS_HIERARCHY[seq_len(n_t)]
    } else {
      c(RANKLESS_HIERARCHY, rep("unknown", n_t - length(RANKLESS_HIERARCHY)))
    }
  }

  # Iterate through ranks and taxa
  for (i in seq_along(ranks_vec)) {
    idtaxa_actual_rank <- ranks_vec[i]
    idtaxa_taxon_value <- x$taxon[i]
    idtaxa_confidence_value <- x$confidence[i]

    # Skip root/unclassified/unassigned/empty taxa
    if (is.na(idtaxa_taxon_value) || idtaxa_taxon_value == "" ||
        grepl("unclassified_|^Incertae Sedis_|^Root$|^unassigned$", idtaxa_taxon_value)) next

    target_rank_name <- NULL
    if (idtaxa_actual_rank %in% c("rootrank", "root")) {
      next  # skip root level
    } else if (idtaxa_actual_rank == "domain") {
      target_rank_name <- "superkingdom"
    } else {
      matched_idx <- match(tolower(idtaxa_actual_rank), tolower(rank_levels))
      if (!is.na(matched_idx)) {
        target_rank_name <- rank_levels[matched_idx]
      }
    }

    if (!is.null(target_rank_name) && target_rank_name %in% rank_levels) {
      final_taxon_row[target_rank_name]      <- idtaxa_taxon_value
      final_confidence_row[target_rank_name] <- idtaxa_confidence_value
    }
  }

  return(list(taxon = final_taxon_row, confidence = final_confidence_row))
}

# Process all IdTaxa results
taxa_results_list <- lapply(ids, process_idtaxa_result)

# Prepare classification data frame with SequenceID header
classification_df <- as.data.frame(do.call(rbind, lapply(taxa_results_list, `[[`, "taxon")))
classification_df <- cbind(SequenceID = names(ids), classification_df)

# Write classification results to TSV
cat(paste0("Writing classification results to: ", args$output_classification, "\n"))
write.table(classification_df, file = args$output_classification, sep = "\t", quote = FALSE, row.names = FALSE, col.names = TRUE)

# Prepare confidence data frame with SequenceID header
confidence_df <- as.data.frame(do.call(rbind, lapply(taxa_results_list, `[[`, "confidence")))
confidence_df <- cbind(SequenceID = names(ids), confidence_df)

# Write confidence results to TSV
cat(paste0("Writing confidence results to: ", args$output_confidence, "\n"))
write.table(confidence_df, file = args$output_confidence, sep = "\t", quote = FALSE, row.names = FALSE, col.names = TRUE)

cat("IDTAXA classification complete.\n")
