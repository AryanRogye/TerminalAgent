# This Documents How I'm Fine Tuning a MLX Model

This repo contains scripts to fine-tune for terminal command generation.

## Setup
1. Create venv: `python -m venv venv`
2. Activate: `source venv/bin/activate`
3. Install: `pip install -r requirements.txt`

## Training
Run the orchestrator with the model ID and your data folder:
`./train_and_get_output.sh [Hugging Face Model] ./fine-tune-data`

# Models Testing (Personal Research)

- mlx-community/gemma-4-e4b-it-8bit 
  - 8.96 GB 
  - 8.96 * 1.5 = 13.44 GB For Training
  - 8.96 * 1.2 = 10.752 GB For Running

- mlx-community/gemma-4-e4b-it-4bit 
  - 5.22 GB 
  - 5.22 * 1.5 = 7.83 GB For Training
  - 5.22 * 1.2 = 6.264 GB For Running
