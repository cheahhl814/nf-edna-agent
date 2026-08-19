#!/usr/bin/env julia

# --- Automatic Environment Setup ---
import Pkg

# Get the directory where this script is located
const SCRIPT_DIR = @__DIR__
const PROJECT_DIR = dirname(SCRIPT_DIR)
const ENV_DIR = joinpath(PROJECT_DIR, "env") # Assuming env has required packages

# Activate the project environment
println("Activating Julia environment at: $ENV_DIR")
Pkg.activate(ENV_DIR)

# Instantiate packages (install if needed, resolve versions)
println("Checking and installing dependencies...")
Pkg.instantiate()

println("✓ All dependencies ready.\n")

# --- Load Required Packages ---
using ArgParse
using FASTX
using DataFrames # For potential future use, not strictly needed here
using DelimitedFiles # For writedlm

function parse_commandline()
    s = ArgParseSettings(
        description = "Extracts scientific names (Genus species) from DECIPHER-formatted FASTA headers."
    )

    @add_arg_table! s begin
        "--input_idtaxa_fasta"
            help = "Path to the FASTA file with DECIPHER-formatted headers (e.g., output from prepare_ncbi_fasta_for_idtaxa.R)."
            required = true
            arg_type = String
        "--output_species_list"
            help = "Path for the output text file containing scientific names (one per line)."
            required = true
            arg_type = String
    end

    return parse_args(s)
end

function main()
    args = parse_commandline()

    message = "Loading FASTA file: " * args["input_idtaxa_fasta"]
    println(message)

    scientific_names = Set{String}() # Use a Set to store unique names

    open(FASTA.Reader, args["input_idtaxa_fasta"]) do reader
        for record in reader
            header = FASTX.identifier(record)
            
            # The header is typically "Accession;s__superkingdom;p__phylum;...;g__Genus;s__species"
            # We need to split by ';' to get the taxonomic parts
            parts = split(header, ';')
            
            genus = "unassigned"
            species = "unassigned"

            for part in parts
                if startswith(part, "g__")
                    genus = strip(part[4:end]) # Remove "g__" prefix
                elseif startswith(part, "s__")
                    species = strip(part[4:end]) # Remove "s__" prefix
                end
            end

            # Combine Genus and Species
            if genus != "unassigned" && species != "unassigned"
                # If species epithet is just Genus, it means species is not resolved beyond genus
                # Example: g__Escherichia;s__Escherichia
                if species == genus
                    push!(scientific_names, genus) # Just use genus as the "scientific name" if species is identical
                else
                    push!(scientific_names, genus * " " * species)
                end
            elseif genus != "unassigned" # Only genus is available
                push!(scientific_names, genus)
            # else: if both are unassigned, we don't add anything
            end
        end
    end

    message = "Extracted " * string(length(scientific_names)) * " unique scientific names."
    println(message)

    # Convert Set to Array and sort for consistent output
    sorted_names = sort(collect(scientific_names))

    message = "Writing scientific names to: " * args["output_species_list"]
    println(message)

    # Write to file, one name per line
    open(args["output_species_list"], "w") do io
        writedlm(io, sorted_names, '
')
    end

    println("Scientific name extraction complete.")
end

main()
