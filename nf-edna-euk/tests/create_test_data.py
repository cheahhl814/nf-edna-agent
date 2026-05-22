#!/usr/bin/env python3
"""
Generate synthetic 18S V9 FASTQs for pipeline testing.
Uses real 18S V9 amplicon sequences flanked by 1391F/EukBr primers.
"""
import gzip, random, pathlib

random.seed(99)

# 1391F / EukBr primers (V9)
PRIMER_F = "GTACACACCGCCCGTC"
PRIMER_R = "TGATCCTTCTGCAGGTTCACCTAC"

# Six synthetic 18S V9 core sequences from representative eukaryote groups
CORE_SEQS = [
    "CGGAGAGGGAGCCTGAGAAACGGCTACCACATCCAAGGAAGGCAGCAGGCGCGCAAATTACCCAATCCCGACACGGGGAGGT",
    "TTTAAGTTTCAGCCTTGCGACCATACTCCCCCCGGAATACCGAGGGCATCACAGACCTGTTATTGCCTCAAACTTCCATCGG",
    "GCATGGAATAATGGAATAGGACCATCGGGGCTTTCTTGGAGAGGGAGCCTGAGAAATGGCTACCACATCCAAGGAAGGCAGC",
    "AGTTTCAGCCTTTGCGACCATACTCCCCCCGGAATACCGAGGGCATCACAGACCTGTTATCGCCTCAAACTTCCATCGGTAG",
    "CGGAGAGGGAGCCTGAGAAATGGCTACCACATCCAAGGAAGGCAGCAGGCGCGCAAATTACCCAATCCCGACACGGGGAGGT",
    "GCATGGAATAATGGAATAGGACCATCGGGGCTTTCTTGGAGAGGGAGCCTGAGAAATGGCTACCACATCCAAGGAAGGCAGG",
]

TAXA = [
    "Root;Eukaryota;Opisthokonta;Metazoa;Arthropoda;Malacostraca;Decapoda",
    "Root;Eukaryota;Opisthokonta;Metazoa;Chordata;Actinopteri;Perciformes",
    "Root;Eukaryota;Viridiplantae;Streptophyta;Embryophyta;Tracheophyta;Magnoliopsida",
    "Root;Eukaryota;Opisthokonta;Fungi;Ascomycota;Saccharomycetes;Saccharomycetales",
    "Root;Eukaryota;Alveolata;Dinoflagellata;Dinophyceae;Peridiniales;Peridiniaceae",
    "Root;Eukaryota;Stramenopiles;Bacillariophyta;Bacillariophyceae;Naviculales;Naviculaceae",
]

SAMPLES = ["euk_sample1", "euk_sample2", "euk_sample3"]
READS_PER_SAMPLE = 200
OUTPUT_DIR = pathlib.Path(__file__).parent / "fixtures"
OUTPUT_DIR.mkdir(exist_ok=True)

def make_quality(length, mean_q=34):
    return "".join(chr(min(40, max(20, int(random.gauss(mean_q, 3)))) + 33) for _ in range(length))

manifest_rows = []
for sample in SAMPLES:
    out_file = OUTPUT_DIR / f"{sample}.fastq.gz"
    with gzip.open(out_file, "wt") as fh:
        for i in range(READS_PER_SAMPLE):
            core = random.choice(CORE_SEQS)
            seq  = list(PRIMER_F + core + PRIMER_R)
            for j in range(len(seq)):
                if random.random() < 0.005:
                    seq[j] = random.choice("ACGT")
            seq = "".join(seq)
            fh.write(f"@{sample}_read{i+1}\n{seq}\n+\n{make_quality(len(seq))}\n")
    manifest_rows.append(f"{sample},{out_file.resolve()}")
    print(f"Generated {out_file}")

(OUTPUT_DIR / "manifest.csv").write_text(
    "sample-id,absolute-filepath\n" + "\n".join(manifest_rows) + "\n"
)
(OUTPUT_DIR / "metadata.tsv").write_text(
    "sample-id\thabitat\tis_negative\n"
    "euk_sample1\triffle\tFALSE\n"
    "euk_sample2\tpool\tFALSE\n"
    "euk_sample3\triffle\tFALSE\n"
)

ref_path = OUTPUT_DIR / "reference_18s.fasta"
with ref_path.open("w") as fh:
    for seq, tax in zip(CORE_SEQS, TAXA):
        fh.write(f">{tax}\n{PRIMER_F}{seq}{PRIMER_R}\n")
print(f"Reference FASTA: {ref_path}")
