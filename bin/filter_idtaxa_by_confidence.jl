#!/usr/bin/env julia

# This script filters the IDTAXA classification based on confidence levels.
# If a taxonomic annotation has a corresponding confidence level below a specified threshold,
# that annotation is converted to `missing`.

using CSV
using DataFrames
using ArgParse

function parse_commandline()
    s = ArgParseSettings(description="Filter IDTAXA classification by confidence levels.")

    @add_arg_table! s begin
        "--classification_file"
            help = "Path to the IDTAXA classification TSV file."
            arg_type = String
            required = true
        "--confidence_file"
            help = "Path to the IDTAXA confidence TSV file."
            arg_type = String
            required = true
        "--output_file"
            help = "Path to the output filtered classification TSV file."
            arg_type = String
            required = true
        "--threshold"
            help = "Confidence threshold (percentage) below which classifications are converted to NA."
            arg_type = Float64
            default = 80.0
    end

    return parse_args(s)
end

function main()
    args = parse_commandline()

    classification_file = args["classification_file"]
    confidence_file = args["confidence_file"]
    output_file = args["output_file"]
    threshold = args["threshold"]

    # Read the classification and confidence files
    # `missingstrings` handles "NA" values as Julia's Missing
    # `delim='\t'` specifies tab-separated values
    # `header=1` indicates the first row is the header
    classification_df = CSV.read(classification_file, DataFrame, missingstring=["NA"], delim='\t', header=1)
    confidence_df = CSV.read(confidence_file, DataFrame, missingstring=["NA"], delim='\t', header=1)

    # Ensure SequenceID columns match and are in the same order
    if !isequal(classification_df.SequenceID, confidence_df.SequenceID)
        error("SequenceIDs in classification and confidence files do not match or are not in the same order.")
    end

    # Identify taxonomic columns (excluding SequenceID)
    # Assuming SequenceID is the first column and remaining are taxonomic ranks
    taxonomic_columns = names(classification_df)[2:end]

    # Convert taxonomic columns in classification_df to allow for missing values
    # This is necessary because CSV.read might infer a non-nullable type if no missing values are present initially.
    for col_name in taxonomic_columns
        classification_df[!, col_name] = allowmissing(classification_df[!, col_name])
    end

    # Create a copy of the dataframe for the output to preserve ASV_ID column name (SequenceID -> ASV_ID)
    final_classification_df = copy(classification_df)
    rename!(final_classification_df, :SequenceID => :ASV_ID)
    
    # Strip `;size=...` or similar suffixes from ASV_IDs to match feature table
    # We use a map to ensure this is applied to every element of the column
    final_classification_df.ASV_ID = map(x -> replace(string(x), r";.*$" => ""), final_classification_df.ASV_ID)

    # Iterate through taxonomic columns and apply the threshold
    for col_name in taxonomic_columns
        # Skip if the column doesn't exist in confidence_df (shouldn't happen if files are well-formed)
        if !(col_name in names(confidence_df))
            @warn "Column $col_name not found in confidence file. Skipping filtering for this rank."
            continue
        end

        # Get confidence scores for the current column
        confidence_scores = confidence_df[!, col_name]
        
        # Apply the threshold
        # If confidence is below threshold AND NOT already missing, set classification to missing
        for i in 1:nrow(final_classification_df)
            if !ismissing(confidence_scores[i]) && confidence_scores[i] < threshold
                final_classification_df[i, col_name] = missing
            end
        end
    end

    # Write the filtered classification to a new TSV file
    # `missingstring="NA"` ensures missing values are written as "NA" in the output file
    CSV.write(output_file, final_classification_df, delim='\t', missingstring="NA")

    println("Filtered classification saved to: $output_file")
end

main()
