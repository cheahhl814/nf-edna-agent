#!/usr/bin/env Rscript

# --- Load Required Libraries ---
library(argparse)
library(Biostrings)
library(DECIPHER)
library(rentrez)
library(xml2)
library(stringr)

# --- Argument Parsing ---
parser <- ArgumentParser(description='Prepare NCBI FASTA headers for DECIPHER IDTAXA training using rentrez.')

parser$add_argument('--input_ncbi_fasta',    type='character', required=TRUE,
                    help='Path to the input FASTA file downloaded from NCBI Nucleotide.')
parser$add_argument('--output_idtaxa_fasta', type='character', required=TRUE,
                    help='Path for the output FASTA file with DECIPHER-compatible headers.')
parser$add_argument('--batch_size',          type='integer', default=200,
                    help='Accessions per NCBI API request [default: 200].')
parser$add_argument('--taxo_levels',         type='character', nargs='+',
                    default=c("superkingdom", "phylum", "class", "order", "family", "genus", "species"),
                    help='Ordered taxonomic ranks to include in headers.')
parser$add_argument('--orient',              action='store_true', default=FALSE,
                    help='Orient all sequences to a consistent strand with DECIPHER::OrientNucleotides before writing.')

args <- parser$parse_args()

rank_levels <- args$taxo_levels

# --- Load FASTA ---
message("Loading FASTA: ", args$input_ncbi_fasta)
dna_seqs <- readDNAStringSet(args$input_ncbi_fasta)
original_headers <- names(dna_seqs)

# --- Extract accession IDs from headers ---
# Handles: "AF004969.1 Description..." → "AF004969.1"
accession_ids <- str_extract(original_headers, "^[A-Z]{1,2}[0-9]{5,9}(\\.?[0-9]+)?")

valid <- !is.na(accession_ids) & accession_ids != ""
if (any(!valid)) {
    message("Skipping ", sum(!valid), " sequences with unparsable headers.")
    dna_seqs      <- dna_seqs[valid]
    accession_ids <- accession_ids[valid]
}
message("Extracted ", length(accession_ids), " accession IDs.")

# Accession without version for DocSum caption matching (e.g. "AF004969.1" → "AF004969")
acc_noversion <- str_remove(accession_ids, "\\..*$")

# --- Step 1: Fetch taxids for all accessions via entrez_summary ---
message("Fetching taxids (", ceiling(length(accession_ids) / args$batch_size), " batches, ~3 req/s)...")

acc_to_taxid <- character(length(acc_noversion))
names(acc_to_taxid) <- acc_noversion

n_batches <- ceiling(length(acc_noversion) / args$batch_size)
for (i in seq_len(n_batches)) {
    idx   <- ((i - 1) * args$batch_size + 1):min(i * args$batch_size, length(acc_noversion))
    batch <- acc_noversion[idx]

    for (attempt in 1:3) {
        result <- tryCatch({
            summ <- entrez_summary(db = "nucleotide", id = batch, always_return_list = TRUE)
            for (nm in names(summ)) {
                cap <- summ[[nm]]$caption
                tid <- as.character(summ[[nm]]$taxid)
                if (!is.null(cap) && cap %in% batch) acc_to_taxid[cap] <- tid
            }
            TRUE
        }, error = function(e) { message("  Batch ", i, " attempt ", attempt, " failed: ", e$message); FALSE })
        if (result) break
        Sys.sleep(2 ^ attempt)
    }

    if (i %% 20 == 0) message("  ", i, "/", n_batches, " summary batches done")
    Sys.sleep(0.35)  # stay under 3 req/s
}

# --- Step 2: Fetch lineages for unique taxids ---
unique_taxids <- unique(acc_to_taxid[acc_to_taxid != ""])
message("Fetching lineages for ", length(unique_taxids), " unique taxids...")

taxid_to_lineage <- list()
n_tax_batches <- ceiling(length(unique_taxids) / args$batch_size)

for (i in seq_len(n_tax_batches)) {
    idx   <- ((i - 1) * args$batch_size + 1):min(i * args$batch_size, length(unique_taxids))
    batch <- unique_taxids[idx]

    for (attempt in 1:3) {
        result <- tryCatch({
            xml_str  <- entrez_fetch(db = "taxonomy", id = batch, rettype = "xml")
            tax_xml  <- read_xml(xml_str)
            top_taxa <- xml_find_all(tax_xml, "/TaxaSet/Taxon")

            for (node in top_taxa) {
                taxid      <- xml_text(xml_find_first(node, "TaxId"))
                sci_name   <- xml_text(xml_find_first(node, "ScientificName"))
                taxon_rank <- xml_text(xml_find_first(node, "Rank"))

                lineage <- list()
                for (ln in xml_find_all(node, "LineageEx/Taxon")) {
                    r <- xml_text(xml_find_first(ln, "Rank"))
                    n <- xml_text(xml_find_first(ln, "ScientificName"))
                    if (r %in% rank_levels) lineage[[r]] <- n
                }
                if (taxon_rank == "species") lineage[["species"]] <- sci_name

                taxid_to_lineage[[taxid]] <- lineage
            }
            TRUE
        }, error = function(e) { message("  Tax batch ", i, " attempt ", attempt, " failed: ", e$message); FALSE })
        if (result) break
        Sys.sleep(2 ^ attempt)
    }

    if (i %% 20 == 0) message("  ", i, "/", n_tax_batches, " taxonomy batches done")
    Sys.sleep(0.35)
}

# --- Step 3: Build DECIPHER-compatible headers ---
# Format: "accession Root;Kingdom;Phylum;Class;Order;Family;Genus;Species"
# - Taxonomy starts with "Root" and uses full taxon names, no rank-prefix abbreviations.
# - Missing ranks are filled with "unassigned" so every sequence has the same number
#   of levels; LearnTaxa then receives a consistent hierarchy.
# - The rank names (rootrank, superkingdom, phylum, ...) must be passed to LearnTaxa
#   via its `rank` parameter at training time:
#     ranks <- c("rootrank", rank_levels)
#     taxa  <- LearnTaxa(seqs, taxonomy, rank = ranks)
format_lineage <- function(taxid) {
    lin        <- taxid_to_lineage[[taxid]]
    taxa_parts <- sapply(rank_levels, function(r) {
        val <- lin[[r]]
        if (!is.null(val) && nzchar(val)) val else "unassigned"
    })
    paste(c("Root", taxa_parts), collapse = ";")
}

unassigned_lineage <- paste(c("Root", rep("unassigned", length(rank_levels))), collapse = ";")

new_headers <- mapply(function(acc_nv, acc_full) {
    tid <- acc_to_taxid[acc_nv]
    lineage_str <- if (!is.na(tid) && tid != "" && !is.null(taxid_to_lineage[[tid]])) {
        format_lineage(tid)
    } else {
        unassigned_lineage
    }
    paste0(acc_full, " ", lineage_str)
}, acc_noversion, accession_ids)

names(dna_seqs) <- new_headers

n_assigned   <- sum(!str_detect(new_headers, "unassigned$"))
n_unassigned <- sum( str_detect(new_headers, "unassigned$"))
message("Headers assigned: ", n_assigned, " | unassigned: ", n_unassigned)

# --- Step 4 (optional): Orient sequences to a consistent strand ---
# Mixed-strand reference databases cause IdTaxa(strand="top") to miss half the
# queries. OrientNucleotides aligns every sequence to the same strand as the
# majority of the input set, making strand="top" reliable at classification time.
if (args$orient) {
    message("Orienting sequences to a consistent strand...")
    dna_seqs <- OrientNucleotides(dna_seqs, processors = NULL, verbose = TRUE)
    message("Orientation complete.")
}

# --- Write output ---
message("Writing: ", args$output_idtaxa_fasta)
writeXStringSet(dna_seqs, args$output_idtaxa_fasta)
message("Done.")
