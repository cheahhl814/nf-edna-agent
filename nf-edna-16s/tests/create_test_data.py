#!/usr/bin/env python3
"""
Generate synthetic 16S V3-V4 FASTQs for pipeline testing.
Produces 3 samples × 200 reads each. Sequences are real 16S V3-V4 amplicons
flanked by standard 341F/806R primers, with simulated Phred33 quality scores.
"""
import gzip, random, pathlib, textwrap

random.seed(42)

# 341F/806R primers (V3-V4)
PRIMER_F = "CCTACGGGNGGCWGCAG"
PRIMER_R = "GACTACNVGGGTWTCTAATCC"

# Six synthetic 16S V3-V4 core sequences (amplicon only, without primers)
# Derived from representative SILVA sequences
CORE_SEQS = [
    "TAGGGAATCTTCCGCAATGGACGAAAGTCTGACGGAGCAACGCCGCGTGAGTGATGAAGGTTTTCGGATCGTAAAGCTCTGTTGTAAGGGAAGAACAAGTACCGTTCGAATAGGGCGGTACCTTGACGGTACCTTATGAGAAAGCCACGGCTAACTACGTGCCAGCAGCCGCGGTAATACGTAGGTGGCAAGCGTTGTCC",
    "TACGGAGGGTGCAAGCGTTAATCGGAATTACTGGGCGTAAAGCGCACGCAGGCGGTTTGTTAAGTCAGATGTGAAATCCCCGGGCTCAACCTGGGAACTGCATTTGAAACTGGCAAGCTTGAGTCTCGTAGAGGGGGGTAGAATTCCAGGTGTAGCGGTGAAATGCGTAGAGATCTGGAGGAATACCGGTGGCGAAGG",
    "TACGTATGGAGCAAGCGTTATCCGGATTTACTGGGTGTAAAGGGAGCGCAGGCGGTACGGCAAGTCTGATGTGAAAGCCCGGGGCTCAACCCCGGAATTGCATTGGAAACTGTCGTACTTGAGTGCAGGAGAGGTAAGCGGAATTCCTAGTGTAGCGGTGAAATGCGTAGATATTAGGAGGAACACCAGTGGCGAAGGC",
    "TACGTAGGTCCCGAGCGTTGTCCGGATTTATTGGGCGTAAAGCGAGCGCAGGCGGTTTGATAAGTCTGAAGTTAAAGGCTGTGGCTTAACCATAGTACGCTTTGGAAACTGTCAAACTTGAGTGCAGAAGGGGAGAGTGGAATTCCATGTGTAGCGGTGAAATGCGTAGATATATGGAGGAACACCGGTGGCGAAAGCG",
    "TACGTATGTCACAAGCGTTGTCCGGATTTATTGGGCGTAAAGGGAGCGCAGGCGGTTTAATAAGTCTGATGTGAAAGCCCGGGGCTCAACCCCGGAATTGCATTGGAAACTGTTTAACTTGAGTGCAGAAGGGGAGAGTGGAATTCCATGTGTAGCGGTGAAATGCGTAGATATATGGAGGAACACCGGTGGCGAAAGCG",
    "TACGGAGGATCCGAGCGTTATCCGGATTTATTGGGTTTAAAGGGTGCGTAGGCGGATTATCAAGTCAGCGGTAAAATTTCGGGGCTCAACCCCGAAACTGCCGTTGATACTGATAGTCTTGAGTATGGAAGAGGTGAGTGGAATTCCGAGTGTAGAGGTGAAATTCGTAGATATTCGGAGGAACACCAGTGGCGAAGGCG",
]

SAMPLES = ["sample1", "sample2", "sample3"]
READS_PER_SAMPLE = 200
OUTPUT_DIR = pathlib.Path(__file__).parent / "fixtures"
OUTPUT_DIR.mkdir(exist_ok=True)

def make_quality(length, mean_q=35, min_q=20):
    """Simulate Phred33 quality string."""
    qs = [min(40, max(min_q, int(random.gauss(mean_q, 3)))) for _ in range(length)]
    return "".join(chr(q + 33) for q in qs)

def make_read(seq_core, sample_idx):
    full_seq = PRIMER_F + seq_core + PRIMER_R
    # Introduce ~0.5% sequencing errors
    seq = list(full_seq)
    for i in range(len(seq)):
        if random.random() < 0.005:
            seq[i] = random.choice("ACGT")
    seq = "".join(seq)
    qual = make_quality(len(seq))
    return seq, qual

manifest_rows = []
for s_idx, sample in enumerate(SAMPLES):
    out_file = OUTPUT_DIR / f"{sample}.fastq.gz"
    with gzip.open(out_file, "wt") as fh:
        for i in range(READS_PER_SAMPLE):
            core = random.choice(CORE_SEQS)
            seq, qual = make_read(core, s_idx)
            fh.write(f"@{sample}_read{i+1}\n{seq}\n+\n{qual}\n")
    manifest_rows.append(f"{sample},{out_file.resolve()}")
    print(f"Generated {out_file} ({READS_PER_SAMPLE} reads)")

# Manifest
manifest_path = OUTPUT_DIR / "manifest.csv"
manifest_path.write_text("sample-id,absolute-filepath\n" + "\n".join(manifest_rows) + "\n")
print(f"Manifest: {manifest_path}")

# Metadata
metadata_path = OUTPUT_DIR / "metadata.tsv"
metadata_path.write_text(
    "sample-id\ttreatment\tis_negative\n"
    "sample1\tcontrol\tFALSE\n"
    "sample2\ttreated\tFALSE\n"
    "sample3\tcontrol\tFALSE\n"
)
print(f"Metadata: {metadata_path}")

# Reference FASTA for IDTAXA training (same sequences, with taxonomy headers)
TAXA = [
    "Root;Bacteria;Proteobacteria;Gammaproteobacteria;Pseudomonadales;Pseudomonadaceae;Pseudomonas",
    "Root;Bacteria;Firmicutes;Bacilli;Lactobacillales;Streptococcaceae;Streptococcus",
    "Root;Bacteria;Actinobacteria;Actinobacteria;Corynebacteriales;Corynebacteriaceae;Corynebacterium",
    "Root;Bacteria;Proteobacteria;Betaproteobacteria;Burkholderiales;Burkholderiaceae;Burkholderia",
    "Root;Bacteria;Bacteroidetes;Bacteroidia;Bacteroidales;Bacteroidaceae;Bacteroides",
    "Root;Bacteria;Firmicutes;Bacilli;Bacillales;Bacillaceae;Bacillus",
]
ref_path = OUTPUT_DIR / "reference_16s.fasta"
with ref_path.open("w") as fh:
    for i, (seq, tax) in enumerate(zip(CORE_SEQS, TAXA)):
        fh.write(f">{tax}\n{PRIMER_F}{seq}{PRIMER_R}\n")
print(f"Reference FASTA: {ref_path}")
