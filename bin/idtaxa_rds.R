#!/usr/bin/env Rscript

# v1.1.1: Auto-detects three model formats via magic-byte sniffing:
#   1. Standard R RDS (DECIPHER::IdTaxa output saved via saveRDS)
#   2. DECIPHER RDX3 binary format (the SILVA trainingFile, gzip- or xz-compressed)
#   3. XZ-compressed standard RDS (uncommon but supported)
# See run/edna-run/SKILL.md Finding 7 for the full rationale.

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

# Load IDTAXA model — supports three formats:
#   1. Standard R RDS (DECIPHER::IdTaxa output saved via saveRDS)
#   2. DECIPHER RDX3 binary format (the SILVA trainingFile, gzip- or xz-compressed)
#   3. XZ-compressed standard RDS (uncommon but supported)
# Detection: peek at the first 5 bytes of the file.
#   - "RDX3\n" (0x524458330a) → DECIPHER RDX3 format; skip 5 bytes then unserialize()
#   - 0x1f 0x8d → gzip; wrap in gzfile() and readRDS()
#   - 0xfd 0x37 0x7a 0x58 0x5a → xz; decompress first then re-detect
#   - 0x78 0x01/0x5e/0x9c (zlib) → rare
#   - else → standard RDS via readRDS()
cat(paste0("Loading IDTAXA model from: ", args$idtaxa_model, "\n"))
peek <- readBin(args$idtaxa_model, "raw", n = 8)
peek_hex <- paste(format(peek, width = 2), collapse = " ")

# Helper: detect format by magic bytes
detect_format <- function(raw_bytes) {
    # RDX3: 52 44 58 33 0a
    if (length(raw_bytes) >= 5 && all(raw_bytes[1:5] == as.raw(c(0x52, 0x44, 0x58, 0x33, 0x0a)))) {
        return("rdx3")
    }
    # gzip: 1f 8b
    if (length(raw_bytes) >= 2 && all(raw_bytes[1:2] == as.raw(c(0x1f, 0x8b)))) {
        return("gzip")
    }
    # xz: fd 37 7a 58 5a
    if (length(raw_bytes) >= 6 && all(raw_bytes[1:6] == as.raw(c(0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00)))) {
        return("xz")
    }
    return("rds")
}

fmt <- detect_format(peek)
cat(paste0("Detected format: ", fmt, " (magic: ", peek_hex, ")\n"))

# Decompress to a temp file if needed (so subsequent readBin can re-open)
work_path <- args$idtaxa_model
temp_created <- FALSE
if (fmt == "xz") {
    tmp <- tempfile(fileext = ".bin")
    con_in  <- gzfile(args$idtaxa_model, "rb")
    con_out <- file(tmp, "wb")
    # xzfile() can decompress xz streams directly via a connection
    while (TRUE) {
        chunk <- readBin(con_in, "raw", n = 65536)
        if (length(chunk) == 0) break
        writeBin(chunk, con_out)
    }
    close(con_in)
    close(con_out)
    work_path <- tmp
    temp_created <- TRUE
    fmt <- "rdx3"  # assume the inner content is DECIPHER RDX3 (most common)
    cat(paste0("Decompressed XZ to: ", work_path, "\n"))
}

# Open the (possibly decompressed) file as a connection
con <- file(work_path, "rb")

if (fmt == "rdx3") {
    # DECIPHER RDX3 format: skip the 5-byte "RDX3\n" header, then unserialize()
    hdr <- readBin(con, "raw", n = 5)
    cat(paste0("Skipped RDX3 header: ", paste(rawToChar(hdr), collapse = ""), "\n"))
    obj <- unserialize(con)
    trainingSet <- obj$trainingSet
    if (is.null(trainingSet)) {
        close(con)
        stop("Failed to extract $trainingSet from RDX3 unserialize() output")
    }
    # Re-save as standard RDS for future fast loads (optional; only if not from a temp file)
    if (!temp_created) {
        tryCatch({
            rds_out <- sub("\\.(rds|rdata|RDX3|rdx3)$", ".converted.rds", args$idtaxa_model)
            saveRDS(trainingSet, rds_out)
            cat(paste0("Cached standard-RDS conversion at: ", rds_out, "\n"))
        }, error = function(e) cat("Note: failed to cache RDS conversion:", e$message, "\n"))
    }
} else if (fmt == "gzip") {
    # gzipped standard RDS
    close(con)
    gz_con <- gzfile(args$idtaxa_model, "rb")
    trainingSet <- readRDS(gz_con)
    close(gz_con)
} else {
    # Standard RDS (uncompressed or xz-compressed standard RDS)
    close(con)
    trainingSet <- readRDS(args$idtaxa_model)
}

if (temp_created) {
    unlink(work_path)
}

# Sanity check
if (!is(trainingSet, "Taxa") || !is(trainingSet, "Train")) {
    stop("Loaded object is not a DECIPHER Taxa Train; class = ",
         paste(class(trainingSet), collapse = ", "))
}
cat(paste0("Loaded trainingSet; class: ", paste(class(trainingSet), collapse = ", "), "\n"))

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
