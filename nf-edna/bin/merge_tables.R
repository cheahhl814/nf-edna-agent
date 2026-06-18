#!/usr/bin/env Rscript

# Load libraries
library(argparse)
library(data.table)

# Create a parser
parser <- ArgumentParser(description = "Merge DADA2 sequence tables")

# Add arguments
parser$add_argument("--input_files", nargs = '+', help = "List of input TSV files (one per sample)")
parser$add_argument("--output_table", help = "Path to the merged output TSV file")

# Parse the arguments
args <- parser$parse_args()

# Initialize an empty data.table to store the merged feature table
# The first column will be 'sequence' (ASV/OTU ID)
merged_feature_table <- data.table(sequence = character())

# Loop through each input file and merge it
if (length(args$input_files) > 0) {
  for (file_path in args$input_files) {
    cat(paste0("Reading file: ", file_path, "\n"))
    # Read the table using fread
    # Skip the first comment line and use the line starting with '#OTU ID' as the header.
    # The first column will be '#OTU ID' and the second column is the abundance data for the sample.
    dt <- fread(file_path, skip = "#OTU ID", sep = "\t", check.names = FALSE)

    # Extract sample ID from the file name
    sample_id <- sub("\\.table\\.tsv$", "", basename(file_path))

    # Rename '#OTU ID' column to 'sequence' for merging
    setnames(dt, old=colnames(dt)[1], new="sequence")
    # Rename the second column to the actual sample ID derived from the filename
    setnames(dt, old=colnames(dt)[2], new=sample_id)

    # Merge with the main feature table
    # Perform a full outer join on the 'sequence' column
    if (nrow(merged_feature_table) == 0) {
      merged_feature_table <- dt
    } else {
      merged_feature_table <- merge(merged_feature_table, dt, by = "sequence", all = TRUE)
    }
  }
} else {
  stop("No input files provided to merge_tables.R")
}


# Replace NA values (for sequences not present in all samples) with 0
for (col in colnames(merged_feature_table)) {
  if (is.numeric(merged_feature_table[[col]])) {
    set(merged_feature_table, i=which(is.na(merged_feature_table[[col]])), j=col, value=0)
  }
}


# Convert back to a data.frame with sequences as row names
# Ensure 'sequence' is the first column before setting as row names
setcolorder(merged_feature_table, "sequence")
final_df <- as.data.frame(merged_feature_table)
rownames(final_df) <- final_df$sequence
final_df$sequence <- NULL

# Write the final merged table
cat(paste0("Writing merged table to: ", args$output_table, "\n"))
# Convert row names (sequences) into a column
final_df_with_seq_col <- cbind(ASV_ID = rownames(final_df), final_df)
rownames(final_df_with_seq_col) <- NULL # Remove row names to prevent them from being written as first column again

# Write the header first
header_line <- paste(colnames(final_df_with_seq_col), collapse = "\t")
writeLines(header_line, con = args$output_table)

# Append the data
fwrite(final_df_with_seq_col, file = args$output_table, sep = "\t", quote = FALSE, col.names = FALSE, append = TRUE)

cat("Successfully merged", length(args$input_files), "tables into", args$output_table, "\n")