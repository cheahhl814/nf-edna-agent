#!/usr/bin/env Rscript


# --- Load Required Libraries ---
library(argparse)
library(DECIPHER)
library(stringr)


# --- Argument Parsing ---
parser <- ArgumentParser(description='Train a general-purpose IDTAXA model using DECIPHER.')

parser$add_argument('--input_reference_fasta', type='character', help='Path to the reference sequences FASTA file with taxonomy in headers.', required=TRUE)
parser$add_argument('--output_model', type='character', help='Path to save the trained IDTAXA model (.RData file).', required=TRUE)
parser$add_argument('--max_group_size', type='integer', default=10, help='Maximum sequences per label group for pruning (maxGroupSize in DECIPHER).')
parser$add_argument('--max_iterations', type='integer', default=3, help='Maximum number of iterations for training (maxIterations in DECIPHER).')
parser$add_argument('--allow_group_removal', type='logical', default=FALSE, help='Allow removal of groups with problem sequences (allowGroupRemoval in DECIPHER).')
parser$add_argument('--taxo_levels', type='character', nargs='+', 
                    default=c("superkingdom", "phylum", "class", "order", "family", "genus", "species"), # Using NCBI standard ranks
                    help='Ordered list of taxonomic ranks (e.g., "superkingdom", "phylum", "class"). Must match your reference database structure.')


args <- parser$parse_args()

# --- Training Parameters from Arguments ---
file_training <- args$input_reference_fasta
file_trained <- args$output_model
maxGroupSize <- args$max_group_size
allowGroupRemoval <- args$allow_group_removal
maxIterations <- args$max_iterations
taxo_levels <- args$taxo_levels


# --- Read and Prepare Training Data ---
message(paste("Loading reference sequences from:", file_training))
seqs <- readDNAStringSet(file_training)

# DECIPHER's LearnTaxa requires names of the form:
#   "accession Root;level1;level2;..."
# OR the simpler "Root;level1;level2;..." (one taxonomy path shared across all
# accessions in the same lineage). We support BOTH formats:
#   1. QIIME2-style:   >accession;k__Bacteria;p__Firmicutes;...;s__species
#   2. DECIPHER-style: >accession Root;superkingdom;phylum;...;species
#   3. Bare taxonomy:  >Root;superkingdom;phylum;...;species
# Extract the "Root;...;species" portion and use that as the group name (the
# accession prefix is irrelevant for classification — DECIPHER only needs the
# taxonomy path).
groups <- names(seqs)
groups <- sub("^[^[:space:];]*[ ;]", "", groups, perl = FALSE)  # strip accession + space/semicolon delimiter
# Note: legacy \S+ patterns are R-incompatible; the first sub already
# handles all 3 input formats. Remove the legacy sub.
groups <- gsub("[a-z]__", "", groups)                            # strip QIIME-style prefixes (s__, p__, ...)

message(paste("Initial number of sequences:", length(seqs)))
message(paste("Initial number of unique taxonomy groups:", length(unique(groups))))


# --- Pruning group size (as found in similar tutorials for DECIPHER) ---
message("Pruning sequence groups based on maxGroupSize...")
groupCounts <- table(groups)
remove_mask <- logical(length(seqs)) # Initialize a mask for sequences to be removed

# Iterate through groups that exceed maxGroupSize
for (i in which(groupCounts > maxGroupSize)) {
  current_group_name <- names(groupCounts)[i]
  indices_in_group <- which(groups == current_group_name)
  
  # Randomly sample 'maxGroupSize' sequences to keep from this group
  keep_indices_from_group <- sample(indices_in_group, maxGroupSize)
  
  # Mark all other sequences in this group for removal
  remove_mask[indices_in_group[!indices_in_group %in% keep_indices_from_group]] <- TRUE
}
n_eliminated_initial <- sum(remove_mask)
message(paste("Number of sequences eliminated during initial pruning:", n_eliminated_initial))

# Apply the initial pruning
seqs <- seqs[!remove_mask]
groups <- groups[!remove_mask]
message(paste("Sequences remaining after initial pruning:", length(seqs)))

if (length(seqs) == 0) {
    stop("No sequences remaining after initial pruning. Adjust --max_group_size or check input data.")
}


# --- Build rank data.frame from unique taxonomy paths ---
# LearnTaxa requires a `rank` data.frame describing the taxonomy hierarchy
# (Index, Name, Parent, Level, Rank). We derive this from the unique group paths
# rather than hardcoding the rank order, so the script adapts to any reference
# FASTA format.
#
# Special handling: if the species-level taxon is a binomial (e.g. "Acipenser
# gueldenstaedtii") and the genus is NOT already a separate rank level in the
# path, split it into genus + species so the genus appears as its own rank
# level (DECIPHER requires it). If the species is a single-word name (e.g. "sp."),
# or the genus is already its own level, keep it as-is.
message("Building rank table from unique taxonomy paths...")
unique_groups <- unique(groups)
split_groups <- strsplit(unique_groups, ";")
expanded_groups <- lapply(split_groups, function(parts) {
    n <- length(parts)
    if (n > 0 && grepl(" ", parts[n])) {
        binomial <- strsplit(parts[n], " ", fixed = TRUE)[[1]]
        if (length(binomial) == 2 && !is.na(binomial[1]) && !is.na(binomial[2])) {
            # Only split if the genus is not already a separate level in the path
            # (e.g. for paths that already have genus as level n-1)
            if (!(binomial[1] %in% parts[seq_len(n - 1)])) {
                return(c(parts[seq_len(n - 1)], binomial[1], binomial[2]))
            }
        }
    }
    parts
})
all_levels    <- unique(unlist(expanded_groups))
taxa_idx      <- setNames(seq_along(all_levels) - 1, all_levels)

parent_idx <- sapply(all_levels, function(tax) {
    for (parts in expanded_groups) {
        idx <- match(tax, parts)
        if (!is.na(idx) && idx > 1) {
            parent_name <- parts[idx - 1]
            return(taxa_idx[[parent_name]])
        }
    }
    return(-1L)  # Root's parent
})

level_idx <- sapply(names(taxa_idx), function(t) {
    for (parts in expanded_groups) {
        idx <- match(t, parts)
        if (!is.na(idx)) return(idx - 1L)
    }
    return(0L)
})

# Default rank names for levels 1-7 (after Root). Custom levels (e.g. strain)
# fall back to the level number.
default_rank_names <- c("superkingdom", "phylum", "class", "order", "family", "genus", "species")
rank_names <- sapply(level_idx, function(lvl) {
    if (lvl == 0L) return("rootrank")
    if (lvl <= length(default_rank_names)) return(default_rank_names[lvl])
    return(paste0("level_", lvl))
})

rank_table <- data.frame(
    Index  = unname(taxa_idx),
    Name   = names(taxa_idx),
    Parent = parent_idx,
    Level  = level_idx,
    Rank   = rank_names,
    stringsAsFactors = FALSE
)
message(paste("Rank table:", nrow(rank_table), "unique taxa across", max(level_idx) + 1, "levels"))


# --- Iteratively train classifier ---
message("Starting iterative training of IDTAXA classifier...")
probSeqsPrev <- integer() # suspected problem sequences from previous iteration
trainingSet <- NULL # Initialize trainingSet

for (i in seq_len(maxIterations)) {
  message(paste("Training iteration:", i))
  
  trainingSet <- LearnTaxa(seqs, groups, rank = rank_table, maxIterations=maxIterations)

  # Look for problem sequences. The 'problemSequences' are indices relative to the current 'seqs' object.
  # The problem sequences list might be empty if all sequences are successfully classified.
  probSeqs <- trainingSet$problemSequences$Index
  
  message(paste("Number of problem sequences identified in iteration", i, ":", length(probSeqs)))

  # Exit conditions
  if (length(probSeqs) == 0) {
    message("No problem sequences remaining. Training converged.")
    break
  } else if (length(probSeqs) == length(probSeqsPrev) && all(probSeqs == probSeqsPrev)) {
    message("Problem sequences are unchanged from previous iteration. Training converged (or stuck).")
    break
  }
  
  probSeqsPrev <- probSeqs # Update for next iteration's comparison

  # Remove problematic sequences for the next iteration
  if (length(probSeqs) > 0) {
      seqs <- seqs[-probSeqs] # Remove sequences by index from current 'seqs' object
      groups <- groups[-probSeqs] # Keep 'groups' vector aligned with 'seqs'
      
      message(paste("Removed", length(probSeqs), "problem sequences for next iteration. Remaining:", length(seqs)))
      
      if (length(seqs) == 0) {
          message("No sequences left after removing problem sequences. Training stopped.")
          break
      }
  }
}

if (is.null(trainingSet)) {
    stop("IDTAXA training failed: no trainingSet object was created.")
}

# --- Save Training Set ---
message(paste("Saving trained IDTAXA model to:", file_trained))
saveRDS(trainingSet, file = file_trained)

message("IDTAXA model training complete.")
