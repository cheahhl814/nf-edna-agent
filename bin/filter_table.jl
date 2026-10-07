#!/usr/bin/env julia

# This script performs prevalence-based decontamination, identifying contaminants
# by comparing ASV prevalence in negative controls versus true samples.
# It is a Julia implementation of the logic in the original R script.

# --- Automatic Environment Setup ---
import Pkg

# --- Load Required Packages ---
using ArgParse
using CSV
using DataFrames
using FASTX

function parse_commandline()
    s = ArgParseSettings(
        description = "Filter a feature table and representative sequences based on metadata."
    )

    @add_arg_table! s begin
        "--feature_table"
            help = "Feature table TSV file (ASV_ID as first column)."
            required = true
            arg_type = String
        "--rep_seqs"
            help = "Representative sequences FASTA file."
            required = true
            arg_type = String
        "--metadata"
            help = "Metadata file (sample IDs as first column)."
            required = true
            arg_type = String
        "--filter_condition"
            help = "A logical expression for filtering in the format \"column_name operator value\" (e.g., \"state == T1D\"). The string must be quoted."
            required = true
            arg_type = String
        "--output_table"
            help = "Path to the filtered output TSV file."
            required = true
            arg_type = String
        "--output_rep_seqs"
            help = "Path to the filtered output FASTA file."
            required = true
            arg_type = String
    end

    return parse_args(s)
end

# Function to read metadata, handling potential QIIME2 header on the second line.
function read_metadata_flexible(filepath::String)
    lines = readlines(filepath)
    if length(lines) > 1 && startswith(lines[2], "#q2:types")
        deleteat!(lines, 2)
    end
    return CSV.read(IOBuffer(join(lines, "\n")), DataFrame, delim="\t")
end

# Function to write a dictionary of sequences to a FASTA file
function write_fasta(sequences::Dict{String, String}, filepath::String)
    writer = FASTA.Writer(open(filepath, "w"))
    for (name, seq) in sequences
        record = FASTA.Record(name, seq)
        write(writer, record)
    end
    close(writer)
end

function main()
    args = parse_commandline()

    # --- Load Data ---
    println("Loading feature table: ", args["feature_table"])
    otu_df = CSV.read(args["feature_table"], DataFrame, delim="\t")
    rename!(otu_df, names(otu_df)[1] => "ASV_ID")

    println("Loading metadata: ", args["metadata"])
    meta_df = read_metadata_flexible(args["metadata"])
    sample_id_col = Symbol(names(meta_df)[1])

    # --- Filter Metadata ---
    println("Filtering metadata based on condition: ", args["filter_condition"])
    parts = split(args["filter_condition"], ' ', limit=3)
    if length(parts) != 3
        error("--filter_condition must be in the format: \"column_name operator value\"")
    end
    col_name, op, val_str = parts
    col_sym = Symbol(col_name)

    if !(col_name in names(meta_df))
        error("Column '$col_name' not found in metadata file.")
    end

    original_val_type = eltype(meta_df[!, col_sym])
    # If the column is Bool, accept "TRUE"/"FALSE" (R-style) in addition to
    # Julia's "true"/"false". This handles QIIME2 metadata exports where
    # boolean columns are spelled in uppercase.
    val = if original_val_type == Bool
      parsed = tryparse(Bool, val_str)
      parsed === nothing ? tryparse(Bool, uppercase(val_str) == "TRUE" ? "true" : "false") : parsed
    else
      try
        parse(original_val_type, val_str)
      catch
        val_str # Fallback to string if parsing fails
      end
    end

    op_func = Dict(
        "==" => (a, b) -> a == b,
        "!=" => (a, b) -> a != b,
        ">"  => (a, b) -> a > b,
        "<"  => (a, b) -> a < b,
        ">=" => (a, b) -> a >= b,
        "<=" => (a, b) -> a <= b
    )

    if !haskey(op_func, op)
        error("Unsupported operator: '$op'. Use one of: ", join(keys(op_func), ", "))
    end

    filtered_meta = filter(row -> op_func[op](row[col_sym], val), meta_df)
    
    samples_to_keep = filtered_meta[!, sample_id_col]
    println(length(samples_to_keep), " samples remaining after filtering.")

    # --- Filter Feature Table ---
    samples_in_otu_table = names(otu_df, Not(:ASV_ID))
    final_samples_to_keep = intersect(samples_to_keep, samples_in_otu_table)
    println(length(final_samples_to_keep), " samples from the metadata were found in the feature table.")

    filtered_otu_df = select(otu_df, "ASV_ID", final_samples_to_keep...)
    
    # Keep ASVs with total abundance > 0 after filtering
    numeric_cols = select(filtered_otu_df, Not(:ASV_ID))
    asvs_to_keep_mask = [sum(row) > 0 for row in eachrow(numeric_cols)]
    
    filtered_otu_df = filtered_otu_df[asvs_to_keep_mask, :]
    asvs_to_keep = filtered_otu_df.ASV_ID
    println(length(asvs_to_keep), " ASVs remaining after filtering.")

    # --- Filter Representative Sequences ---
    println("Loading representative sequences: ", args["rep_seqs"])
    fasta = Dict{String, String}()
    reader = FASTA.Reader(open(args["rep_seqs"]))
    for record in reader
        identifier = FASTA.identifier(record)
        # Strip off ";size=..." suffix to match the feature table ID
        asv_id = first(split(identifier, ';'))
        fasta[asv_id] = FASTA.sequence(record)
    end
    close(reader)
    
    fasta_to_keep = filter(p -> p.first in asvs_to_keep, fasta)

    # --- Write Outputs ---
    println("Writing filtered table to: ", args["output_table"])
    CSV.write(args["output_table"], filtered_otu_df, delim="\t")

    println("Writing filtered sequences to: ", args["output_rep_seqs"])
    write_fasta(fasta_to_keep, args["output_rep_seqs"])

    println("Successfully filtered files and saved outputs.")
end

main()
