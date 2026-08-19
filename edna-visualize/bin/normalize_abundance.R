#!/usr/bin/env Rscript


# --- Load Required Libraries ---
library(argparse)
library(data.table)
library(mia)
library(S4Vectors)


# --- Argument Parsing ---
parser <- ArgumentParser(description='Normalize agglomerated count tables to relative abundance.')

parser$add_argument('--input_asv_counts', type='character', help='Path to the ASV-level count table (TSV).', required=TRUE)
parser$add_argument('--input_phylum_counts', type='character', help='Path to the Phylum-level count table (TSV).', required=TRUE)
parser$add_argument('--input_family_counts', type='character', help='Path to the Family-level count table (TSV).', required=TRUE)
parser$add_argument('--input_genus_counts', type='character', help='Path to the Genus-level count table (TSV).', required=TRUE)
parser$add_argument('--output_dir', type='character', help='Output directory for normalized count tables.', required=TRUE)

args <- parser$parse_args()

# Create output directory if it doesn't exist
if (!dir.exists(args$output_dir)) {
    dir.create(args$output_dir, recursive = TRUE)
}

# --- Function to load, normalize, and save a count table ---
normalize_and_save_counts <- function(input_file, output_dir, level_name) {
    message(paste("Processing", level_name, "counts from:", input_file))
    
    # Load count table
    counts_df <- fread(input_file, sep="	", header=TRUE, data.table=FALSE)
    
    # The first column typically contains row names (ASV_ID, Phylum, etc.)
    # When written with write.table(col.names = NA), this column's header is empty.
    # fread often assigns "V1" as the name for such a column.
    
    # Identify the column containing row names and set them
    row_id_col_name <- names(counts_df)[1]
    
    if (is.null(row_id_col_name) || row_id_col_name == "" || row_id_col_name == "V1") {
        # If the first column name is empty or 'V1', assume it's the row ID column.
        # This is the expected behavior from write.table(col.names=NA)
        rownames(counts_df) <- counts_df[[1]] # Use the content of the first column as row names
        counts_df <- counts_df[, -1, drop=FALSE] # Remove the first column
    } else {
        # If the first column has a specific name (e.g., "ASV_ID"), use it and remove it.
        rownames(counts_df) <- counts_df[[row_id_col_name]]
        counts_df <- counts_df[, -which(names(counts_df) == row_id_col_name), drop=FALSE]
    }

    # Ensure matrix is numeric
    counts_matrix <- as.matrix(counts_df)
    mode(counts_matrix) <- "numeric"
    
    # Handle cases where all counts are zero for a feature (row sum = 0)
    # This can cause issues with relative abundance calculation (division by zero)
    # For now, transformAssay should handle it by making them 0, but it's good to be aware.

    # Create a dummy TreeSummarizedExperiment object for transformation
    # Only assays slot is strictly necessary for transformAssay
    tse_temp <- TreeSummarizedExperiment(assays = SimpleList(counts = counts_matrix))

    # Apply relative abundance transformation
    tse_normalized <- transformAssay(tse_temp, method = "relabundance")
    
    # Extract normalized counts
    normalized_matrix <- assay(tse_normalized, "relabundance")
    rel_df_save <- as.data.frame(normalized_matrix)
    
    # Determine header for first column
    first_col_name <- ifelse(level_name == "asv", "ASV_ID", "Taxon")
    
    # Add row IDs as the first column with the determined name
    rel_df_save <- cbind(setNames(data.frame(rownames(rel_df_save)), first_col_name), rel_df_save)

    # Define output file path
    output_file <- file.path(output_dir, paste0(level_name, "_relabundance.tsv"))
    
    # Save normalized counts
    write.table(rel_df_save, file = output_file, sep = "\t", quote = FALSE, row.names = FALSE)
    message(paste("Saved normalized", level_name, "counts to:", output_file))
}

# --- Process each count table ---
normalize_and_save_counts(args$input_asv_counts, args$output_dir, "asv")
normalize_and_save_counts(args$input_phylum_counts, args$output_dir, "phylum")
normalize_and_save_counts(args$input_family_counts, args$output_dir, "family")
normalize_and_save_counts(args$input_genus_counts, args$output_dir, "genus")

message("All count tables normalized to relative abundance and saved.")