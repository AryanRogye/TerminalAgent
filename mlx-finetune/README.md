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

- microsoft/Phi-3-mini-4k-instruct
  - 7.64 GB
  - 7.64 * 1.5 = 11.46 GB For Training
  - 7.64 * 1.2 = 9.17 GB For Running

- mlx-community/Phi-3-mini-4k-instruct-4bit
  - 2.15 GB
  - 2.15 GB * 1.5 = 3.225 GB For Training
  - 2.15 GB * 1.2 = 2.58 GB For Running

- mlx-community/Llama-3.2-3B-Instruct-4bit
  - 1.83 GB
  - 1.83 GB * 1.5 = 2.745 GB For Training
  - 1.83 GB * 1.2 = 2.196 GB For Running

- mlx-community/gemma-4-e4b-it-8bit 
  - 8.96 GB 
  - 8.96 * 1.5 = 13.44 GB For Training
  - 8.96 * 1.2 = 10.752 GB For Running

- mlx-community/gemma-4-e4b-it-4bit 
  - 5.22 GB 
  - 5.22 * 1.5 = 7.83 GB For Training
  - 5.22 * 1.2 = 6.264 GB For Running

I think the Gemma Models wont work cuz Gemma 4 uses a different
architechure (Dual RoPE and Grouped Query Attention architecture)



