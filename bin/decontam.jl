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
using HypothesisTests
using Statistics

# --- Argument Parsing ---
function parse_commandline()
    s = ArgParseSettings(
        description = "Performs prevalence-based decontamination on ASV data (Julia implementation).",
        usage = "julia run_decontam.jl [options]"
    )

    @add_arg_table! s begin
        "--feature_table", "-f"
            help = "Path to the feature table (TSV format)."
            required = true
            arg_type = String
        "--rep_seqs", "-r"
            help = "Path to the representative sequences (FASTA format)."
            required = true
            arg_type = String
        "--metadata", "-m"
            help = "Path to the sample metadata (TSV format)."
            required = true
            arg_type = String
        "--neg_control_column", "-n"
            help = "Column name in metadata indicating negative controls (e.g., 'is_negative')."
            required = true
            arg_type = String
        "--threshold", "-t"
            help = "P-value threshold for identifying contaminants (e.g., 0.1)."
            required = true
            arg_type = Float64
        "--output_cleaned_table", "-c"
            help = "Output path for the cleaned feature table (TSV format)."
            required = true
            arg_type = String
        "--output_cleaned_rep_seqs", "-s"
            help = "Output path for the cleaned representative sequences (FASTA format)."
            required = true
            arg_type = String
        "--output_contaminants_summary", "-o"
            help = "Output path for the contaminants summary (TSV format)."
            required = true
            arg_type = String
    end

    return parse_args(s)
end

# --- Utility Functions ---

# Function to read FASTA file into a dictionary
function read_fasta(filepath::String)
    sequences = Dict{String, String}()
    reader = FASTA.Reader(open(filepath))
    for record in reader
        sequences[FASTA.identifier(record)] = FASTA.sequence(record)
    end
    close(reader)
    return sequences
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

# --- Main Script Logic ---
function main()
    args = parse_commandline()

    println("Loading feature table: ", args["feature_table"])
    feature_table_df = CSV.read(args["feature_table"], DataFrame, delim='\t')
    
    # The first column should be the ASV identifier. Let's rename it for clarity if needed.
    rename!(feature_table_df, names(feature_table_df)[1] => "ASV_ID")

    # Replace missing values with 0 and ensure counts are numeric
    for col in names(feature_table_df, Not(:ASV_ID))
        feature_table_df[!, col] = coalesce.(feature_table_df[!, col], 0)
        if !(eltype(feature_table_df[!, col]) <: Number)
            feature_table_df[!, col] = parse.(Float64, string.(feature_table_df[!, col]))
        end
    end

    println("Loading metadata: ", args["metadata"])
    metadata_df = CSV.read(args["metadata"], DataFrame, delim='\t')
    sample_id_col = names(metadata_df)[1]

    # Ensure sample IDs match and are in the same order
    feature_table_samples = names(feature_table_df, Not(:ASV_ID))
    metadata_samples = metadata_df[!, sample_id_col]

    common_samples = intersect(feature_table_samples, metadata_samples)
    if isempty(common_samples)
        error("No common sample IDs found between feature table and metadata.")
    end

    metadata_df = filter(row -> row[sample_id_col] in common_samples, metadata_df)
    feature_table_df = feature_table_df[!, vcat("ASV_ID", common_samples)]

    println("Identifying negative control samples using column: ", args["neg_control_column"])
    neg_col = args["neg_control_column"]
    if !hasproperty(metadata_df, Symbol(neg_col))
        error("Negative control column '$neg_col' not found in metadata.")
    end

    # Parse boolean-like values from the negative control column
    vals = lowercase.(string.(metadata_df[!, neg_col]))
    is_neg_control_mask = (vals .== "true") .| (vals .== "t") .| (vals .== "1")

    neg_control_samples = metadata_df[is_neg_control_mask, sample_id_col]
    true_samples = metadata_df[.!is_neg_control_mask, sample_id_col]

    if isempty(neg_control_samples)
        error("No negative control samples identified.")
    end
    if isempty(true_samples)
        error("No true (non-negative control) samples identified. Cannot perform decontamination.")
    end

    println("Performing prevalence-based decontamination with threshold: ", args["threshold"])
    
    contaminant_results = DataFrame(
        ASV_ID = String[],
        P_Value = Float64[],
        Prevalence_in_NegControls = Float64[],
        Prevalence_in_TrueSamples = Float64[],
        Contaminant_Status = String[]
    )
    num_neg_controls = length(neg_control_samples)
    num_true_samples = length(true_samples)
    identified_contaminants = String[]

    for asv_row in eachrow(feature_table_df)
        asv_id = asv_row.ASV_ID

        neg_present = sum(asv_row[s] > 0 for s in neg_control_samples)
        true_present = sum(asv_row[s] > 0 for s in true_samples)
        
        neg_absent = num_neg_controls - neg_present
        true_absent = num_true_samples - true_present

        prevalence_neg = isempty(neg_control_samples) ? 0.0 : neg_present / num_neg_controls
        prevalence_true = isempty(true_samples) ? 0.0 : true_present / num_true_samples
        
        p_value = 1.0
        is_contaminant = "No"

        # Construct contingency table and run Fisher's exact test
        contingency_matrix = [neg_present true_present; neg_absent true_absent]
        if sum(contingency_matrix) > 0 && (neg_present > 0 || true_present > 0)
            test = FisherExactTest(neg_present, true_present, neg_absent, true_absent)
            p_value = pvalue(test, tail=:right) # alternative = "greater"
            
            if p_value < args["threshold"] && prevalence_neg > prevalence_true
                is_contaminant = "Yes"
                push!(identified_contaminants, asv_id)
            end
        elseif prevalence_neg > 0 && prevalence_true == 0
            is_contaminant = "Yes"
            push!(identified_contaminants, asv_id)
            p_value = 0.0
        end

        push!(contaminant_results, (asv_id, p_value, prevalence_neg, prevalence_true, is_contaminant))
    end
    
    println("Identified ", length(identified_contaminants), " contaminants.")

    # --- Output Cleaned Feature Table ---
    # Filter contaminant ASV rows, then drop negative control sample columns
    cleaned_feature_table_df = filter(row -> row.ASV_ID ∉ identified_contaminants, feature_table_df)
    cleaned_feature_table_df = select(cleaned_feature_table_df, Not(Symbol.(neg_control_samples)))
    println("Writing cleaned feature table to: ", args["output_cleaned_table"])
    CSV.write(args["output_cleaned_table"], cleaned_feature_table_df, delim='\t')
    
    # --- Output Cleaned Representative Sequences ---
    println("Loading representative sequences: ", args["rep_seqs"])
    rep_seqs = read_fasta(args["rep_seqs"])
    cleaned_rep_seqs = filter(pair -> pair.first ∉ identified_contaminants, rep_seqs)
    println("Writing cleaned representative sequences to: ", args["output_cleaned_rep_seqs"])
    write_fasta(cleaned_rep_seqs, args["output_cleaned_rep_seqs"])
    
    # --- Output Contaminants Summary ---
    println("Writing contaminants summary to: ", args["output_contaminants_summary"])
    CSV.write(args["output_contaminants_summary"], contaminant_results, delim='\t')
    
    println("Decontamination script finished successfully.")
end

# Run the main function
main()
