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
# Input headers are "accession;x__level1;x__level2;..." so we reformat here.
groups <- names(seqs)
groups <- sub("^(\\S+);", "\\1 Root;", groups)   # first ; → " Root;"
groups <- gsub("[a-z]__", "", groups)             # strip QIIME-style prefixes (s__, p__, ...)

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


# --- Iteratively train classifier ---
message("Starting iterative training of IDTAXA classifier...")
probSeqsPrev <- integer() # suspected problem sequences from previous iteration
trainingSet <- NULL # Initialize trainingSet

for (i in seq_len(maxIterations)) {
  message(paste("Training iteration:", i))
  
  trainingSet <- LearnTaxa(seqs, groups, maxIterations=maxIterations)

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
