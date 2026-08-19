#!/usr/bin/env Rscript

# Load libraries
library(argparse)
library(ape)
library(phytools) # Use phytools for midpoint.root

# Create a parser
parser <- ArgumentParser(description = "Midpoint root a phylogenetic tree")

# Add arguments
parser$add_argument("--input_tree", help = "Input Newick tree file")
parser$add_argument("--output_tree", help = "Output Newick tree file for the rooted tree")

# Parse the arguments
args <- parser$parse_args()

# Read the tree
tree <- read.tree(args$input_tree)

# Perform midpoint rooting using phytools' midpoint.root function
rooted_tree <- phytools::midpoint.root(tree)

# Write the rooted tree
write.tree(rooted_tree, file = args$output_tree)

cat("Successfully rooted the tree and saved to", args$output_tree, "\n")
