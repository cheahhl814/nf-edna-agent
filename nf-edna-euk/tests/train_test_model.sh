#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REF_FASTA="${SCRIPT_DIR}/fixtures/reference_18s.fasta"
MODEL_OUT="${SCRIPT_DIR}/fixtures/idtaxa_model_euk.rds"
BIN_DIR="${SCRIPT_DIR}/../bin"
ENV_DIR="${SCRIPT_DIR}/../env"

if [[ ! -f "${REF_FASTA}" ]]; then
    echo "Reference FASTA not found. Run create_test_data.py first."
    exit 1
fi

pixi run --manifest-path "${ENV_DIR}/classification/pixi.toml" \
    Rscript "${BIN_DIR}/train_idtaxa_model.R" \
    --reference_fasta "${REF_FASTA}" \
    --output_model "${MODEL_OUT}" \
    --min_len 50 --max_len 300
echo "Model: ${MODEL_OUT}"
