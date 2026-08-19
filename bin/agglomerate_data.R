#!/usr/bin/env Rscript


# --- Load Required Libraries ---
library(argparse)
library(data.table)
library(mia)
library(S4Vectors) # for DataFrame


# --- Argument Parsing ---
parser <- ArgumentParser(description='Perform data agglomeration at different taxonomic levels.')

parser$add_argument('--asv_counts_file', type='character', help='Path to the ASV count table (TSV).', required=TRUE)
parser$add_argument('--taxonomy_file', type='character', help='Path to the taxonomic classification table (TSV) from IDTAXA.', required=TRUE)
parser$add_argument('--metadata_file', type='character', help='Path to the sample metadata table (TSV).', required=TRUE)
parser$add_argument('--output_dir', type='character', help='Output directory for agglomerated data.', required=TRUE)
parser$add_argument('--kingdoms', type='character', default='Bacteria,Archaea', help='Comma-separated list of Kingdoms to keep (default: Bacteria,Archaea). Set to "all" to skip kingdom-level filtering.')
parser$add_argument('--ranks', type='character', default='Phylum,Family,Genus', help='Comma-separated list of taxonomic ranks to agglomerate (e.g., "Phylum,Class,Order,Family,Genus,Species").')

args <- parser$parse_args()

# Create output directory if it doesn't exist
if (!dir.exists(args$output_dir)) {
    dir.create(args$output_dir, recursive = TRUE)
}

# --- Load Data ---
message(paste("Loading ASV counts from:", args$asv_counts_file))
counts_df <- fread(args$asv_counts_file, sep="	", header=TRUE, data.table=FALSE)
# Assume first column is ASV_ID, or it's explicitly named
if (!"ASV_ID" %in% names(counts_df)) {
    if (ncol(counts_df) > 0) {
        warning("First column of ASV counts file is not named 'ASV_ID'. Using it as ASV_ID.")
        names(counts_df)[1] <- "ASV_ID"
    } else {
        stop("ASV counts file is empty or malformed.")
    }
}
rownames(counts_df) <- counts_df$ASV_ID
counts_df$ASV_ID <- NULL # Remove ASV_ID column after setting it as rownames

message(paste("Loading taxonomy from:", args$taxonomy_file))
taxonomy_df <- fread(args$taxonomy_file, sep="	", header=TRUE, data.table=FALSE)
# Assume first column is SequenceID, or it's explicitly named
if (!"SequenceID" %in% names(taxonomy_df)) {
    if (ncol(taxonomy_df) > 0) {
        warning("First column of taxonomy file is not named 'SequenceID'. Using it as SequenceID.")
        names(taxonomy_df)[1] <- "SequenceID"
    } else {
        stop("Taxonomy file is empty or malformed.")
    }
}
rownames(taxonomy_df) <- taxonomy_df$SequenceID
taxonomy_df$SequenceID <- NULL # Remove SequenceID column after setting it as rownames

message(paste("Loading metadata from:", args$metadata_file))
metadata_df <- fread(args$metadata_file, sep="	", header=TRUE, data.table=FALSE)
# Determine sample ID column name: use 'sample-id' if present, otherwise assume it's the first column
sample_id_col_name <- NULL
if ("sample-id" %in% names(metadata_df)) {
    sample_id_col_name <- "sample-id"
} else if (ncol(metadata_df) > 0) {
    warning("Column 'sample-id' not found in metadata. Using the first column as sample IDs.")
    sample_id_col_name <- names(metadata_df)[1]
} else {
    stop("Metadata file is empty or malformed.")
}
rownames(metadata_df) <- metadata_df[[sample_id_col_name]]
metadata_df[[sample_id_col_name]] <- NULL

# Align samples between counts and metadata
common_samples <- intersect(colnames(counts_df), rownames(metadata_df))
if (length(common_samples) == 0) {
    stop("No common samples found between counts table and metadata table. Please check sample IDs and column names.")
}
counts_df <- counts_df[, common_samples, drop=FALSE]
metadata_df <- metadata_df[common_samples, , drop=FALSE]
message(paste("Retained", length(common_samples), "common samples between count and metadata tables."))

# Align ASVs between counts and taxonomy
common_asvs <- intersect(rownames(counts_df), rownames(taxonomy_df))
if (length(common_asvs) == 0) {
    stop("No common ASVs found between counts table and taxonomy table. Please check ASV IDs and row names.")
}
counts_df <- counts_df[common_asvs, , drop=FALSE]
taxonomy_df <- taxonomy_df[common_asvs, , drop=FALSE]
message(paste("Retained", length(common_asvs), "common ASVs between count and taxonomy tables."))

# Ensure matrices are numeric if needed (for safety, though fread usually handles it)
counts_matrix <- as.matrix(counts_df)
mode(counts_matrix) <- "numeric"


# --- Create TreeSummarizedExperiment Object ---
message("Creating TreeSummarizedExperiment object at ASV level...")
tse_asv <- TreeSummarizedExperiment(
    assays = SimpleList(counts = counts_matrix),
    rowData = S4Vectors::DataFrame(taxonomy_df),
    colData = S4Vectors::DataFrame(metadata_df)
)
message(paste("Original ASV-level TreeSummarizedExperiment (tse_asv) created with dimensions:", dim(tse_asv)[1], "features and", dim(tse_asv)[2], "samples."))

# --- Cleaning the ASV-level TreeSummarizedExperiment ---
message("Cleaning ASV-level data...")

# 1. Remove ASVs with unassigned Kingdom (skipped when kingdoms="all")
if (args$kingdoms != "all") {
    initial_asvs <- nrow(tse_asv)
    tse_asv <- tse_asv[!is.na(rowData(tse_asv)$superkingdom) & rowData(tse_asv)$superkingdom != "", ]
    message(paste("Removed", initial_asvs - nrow(tse_asv), "ASVs with unassigned Kingdom. Remaining:", nrow(tse_asv), "ASVs."))
} else {
    message("Skipping Kingdom NA filter (kingdoms='all').")
}

# 2. Kingdom-level filtering
if (args$kingdoms != "all") {
    kingdoms_to_keep <- unlist(strsplit(args$kingdoms, ","))
    if ("superkingdom" %in% colnames(rowData(tse_asv))) {
        initial_asvs <- nrow(tse_asv)
        tse_asv <- tse_asv[rowData(tse_asv)$superkingdom %in% kingdoms_to_keep, ]
        message(paste("Removed", initial_asvs - nrow(tse_asv), "ASVs not classified as", paste(kingdoms_to_keep, collapse = " or "), ". Remaining:", nrow(tse_asv), "ASVs."))
    } else {
        warning("superkingdom column not found in taxonomy. Cannot filter for specified kingdoms.")
    }
} else {
    message("Keeping all superkingdoms as requested.")
}

if (nrow(tse_asv) == 0) {
    stop("No ASVs remaining after cleaning. Check your data and filters.")
}
message("ASV-level data cleaned.")
# print(tse_asv) # Optional: print summary of the cleaned object


# --- Define Agglomeration Function and Save ---
# Uses manual row grouping to avoid mia tree-update issues (no phylogenetic tree in euk pipeline)
agglomerate_and_save <- function(tse_obj, rank_level, output_dir) {
    message(paste("Agglomerating data to", rank_level, "level..."))

    if (!rank_level %in% colnames(rowData(tse_obj))) {
        warning(paste("Rank '", rank_level, "' not found in taxonomy data. Skipping agglomeration for this level."))
        return(NULL)
    }

    counts_mat <- assay(tse_obj, "counts")
    tax_df     <- as.data.frame(rowData(tse_obj))
    rank_vals  <- tax_df[[rank_level]]

    # Drop rows without a rank assignment
    valid      <- !is.na(rank_vals) & nzchar(rank_vals)
    counts_mat <- counts_mat[valid, , drop = FALSE]
    tax_df     <- tax_df[valid,     , drop = FALSE]
    rank_vals  <- rank_vals[valid]

    unique_taxa <- unique(rank_vals)
    message(paste(rank_level, "-level agglomeration:", length(unique_taxa), "features."))

    if (length(unique_taxa) == 0) {
        warning(paste("No non-NA values found for rank '", rank_level, "'. Skipping."))
        return(invisible(NULL))
    }

    # Sum counts per taxon
    agg_counts <- do.call(rbind, lapply(unique_taxa, function(tx) {
        colSums(counts_mat[rank_vals == tx, , drop = FALSE])
    }))
    rownames(agg_counts) <- unique_taxa

    # First-occurrence taxonomy row per taxon
    agg_tax <- do.call(rbind, lapply(unique_taxa, function(tx) {
        tax_df[rank_vals == tx, , drop = FALSE][1L, , drop = FALSE]
    }))
    rownames(agg_tax) <- unique_taxa

    counts_outfile   <- file.path(output_dir, paste0(tolower(rank_level), "_counts.tsv"))
    taxonomy_outfile <- file.path(output_dir, paste0(tolower(rank_level), "_taxonomy.tsv"))

    counts_df_save <- cbind(Taxon = rownames(agg_counts), as.data.frame(agg_counts))
    write.table(counts_df_save, file = counts_outfile, sep = "\t", quote = FALSE, row.names = FALSE)
    message(paste("Saved", rank_level, "counts to:", counts_outfile))

    tax_df_save <- cbind(Taxon = rownames(agg_tax), agg_tax)
    write.table(tax_df_save, file = taxonomy_outfile, sep = "\t", quote = FALSE, row.names = FALSE)
    message(paste("Saved", rank_level, "taxonomy to:", taxonomy_outfile))

    return(invisible(NULL))
}

# --- Agglomerate and Save for desired levels ---
# ASV Level (original, also save its components for consistency)
message("Saving ASV-level counts and taxonomy...")
asv_counts_outfile <- file.path(args$output_dir, "asv_counts.tsv")
asv_taxonomy_outfile <- file.path(args$output_dir, "asv_taxonomy.tsv")

asv_counts_df_save <- as.data.frame(assay(tse_asv, "counts"))
asv_counts_df_save <- cbind(ASV_ID = rownames(asv_counts_df_save), asv_counts_df_save)
write.table(asv_counts_df_save, file = asv_counts_outfile, sep = "\t", quote = FALSE, row.names = FALSE)
message(paste("Saved ASV counts to:", asv_counts_outfile))

asv_tax_df_save <- S4Vectors::as.data.frame(rowData(tse_asv))
asv_tax_df_save <- cbind(ASV_ID = rownames(asv_tax_df_save), asv_tax_df_save)
write.table(asv_tax_df_save, file = asv_taxonomy_outfile, sep = "\t", quote = FALSE, row.names = FALSE)
message(paste("Saved ASV taxonomy to:", asv_taxonomy_outfile))

# Loop through specified ranks
target_ranks <- unlist(strsplit(args$ranks, ","))
target_ranks <- trimws(target_ranks) # Remove any whitespace

available_ranks <- colnames(rowData(tse_asv))

for (rank in target_ranks) {
    if (tolower(rank) != "asv") {
        # Case-insensitive match to find the actual column name
        match_idx <- match(tolower(rank), tolower(available_ranks))
        if (!is.na(match_idx)) {
            real_rank <- available_ranks[match_idx]
            agglomerate_and_save(tse_asv, real_rank, args$output_dir)
        } else {
            warning(paste("Rank '", rank, "' not found in taxonomy data. Available columns:", paste(available_ranks, collapse = ", ")))
        }
    }
}


message("Data agglomeration script finished successfully.")