#!/usr/bin/env bash
# Train a minimal IDTAXA model on the synthetic reference sequences.
# Run once before tests. Requires nf-emplicon env to be available.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REF_FASTA="${SCRIPT_DIR}/fixtures/reference_16s.fasta"
MODEL_OUT="${SCRIPT_DIR}/fixtures/idtaxa_model_16s.rds"
BIN_DIR="${SCRIPT_DIR}/../bin"
ENV_DIR="${SCRIPT_DIR}/../env"

if [[ ! -f "${REF_FASTA}" ]]; then
    echo "Reference FASTA not found. Run create_test_data.py first."
    exit 1
fi

pixi run --manifest-path "${ENV_DIR}/classification/pixi.toml" \
    Rscript "${BIN_DIR}/train_idtaxa_model.R" \
    --input_reference_fasta "${REF_FASTA}" \
    --output_model "${MODEL_OUT}" \
    --max_group_size 10 \
    --max_iterations 3

echo "Model written to: ${MODEL_OUT}"
