#!/bin/bash

set -e

# Help check
if [[ -z "$1" || -z "$2" ]]; then
  echo "Usage: ./train_and_get_output.sh <MODEL_NAME> <DATA_FOLDER>"
  echo "Example: ./train_and_get_output.sh google/gemma-4-E2B-it ./terminal-data"
  exit 1
fi

# Begin Training

MODEL_NAME="$1"
FINE_TUNE_FOLDER="$2"

echo "Training $MODEL_NAME"

source ./venv/bin/activate

mlx_lm lora \
  --model "$MODEL_NAME" \
  --train \
  --data "$FINE_TUNE_FOLDER" \
  --iters 500 \
  --batch-size 1 \
  --learning-rate 1e-5 \
  --max-seq-length 1024 \
  --grad-accumulation-steps 4 \
  --save-every 50

echo "Done Training"

echo "Fusing Trained Model"

rm -rf ./output_model

mlx_lm fuse \
  --model "$MODEL_NAME" \
  --adapter-path ./adapters \
  --save-path ./output_model

deactivate
