#!/bin/bash

set -e

# Help check
if [[ -z "$1" || -z "$2" ]]; then
  echo "Usage: ./train_and_get_output.sh <MODEL_NAME> <DATA_FOLDER>"
  echo "Example: ./train_and_get_output.sh google/gemma-4-E2B-it ./terminal-data"
  exit 1
fi

MODEL_NAME="$1"
FINE_TUNE_FOLDER="$2"

