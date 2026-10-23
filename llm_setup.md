## LLM setup (llama.cpp + Docker)

The AI script talks to a local llama.cpp server exposing an OpenAI compatible API on port 8000.

Tested on: NVIDIA RTX 3060 12 GB, Linux, Q4_K quantization.
Model: [Huihui-gemma-4-12B-it-qat-q4_0-unquantized-abliterated-GGUF](https://huggingface.co/huihui-ai/Huihui-gemma-4-12B-it-qat-q4_0-unquantized-abliterated-GGUF/tree/main)

### 1. Install the NVIDIA Container Toolkit

Docker must already be installed, with the NVIDIA driver working (`nvidia-smi`).

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt update && sudo apt install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

### 2. Download the model

```bash
mkdir -p "$HOME/Documents/models/12B"
curl -L -o "$HOME/Documents/models/12B/Huihui-gemma-4-12B-it-qat-q4_0-unquantized-abliterated-Q4_K.gguf" \
  "https://huggingface.co/huihui-ai/Huihui-gemma-4-12B-it-qat-q4_0-unquantized-abliterated-GGUF/resolve/main/Huihui-gemma-4-12B-it-qat-q4_0-unquantized-abliterated-Q4_K.gguf"
```

### 3. Run the server

```bash
docker run --gpus all \
  -v $HOME/Documents/models:/models \
  -p 8000:8000 \
  ghcr.io/ggml-org/llama.cpp:server-cuda \
  -m /models/12B/Huihui-gemma-4-12B-it-qat-q4_0-unquantized-abliterated-Q4_K.gguf \
  --port 8000 --host 0.0.0.0 \
  -n -1 -c 16384 \
  -ngl 99 -np 1
```

| Option | Meaning |
|---|---|
| `-n -1` | Max tokens to generate. `-1` is unlimited (stops on the end token). A low value (e.g. 500) truncates answers. |
| `-c 16384` | Context size: 16K tokens. |
| `-ngl 99` | Layers offloaded to the GPU. 99 is more than the model has, so everything is on the GPU. |
| `-np 1` | One parallel slot: one request at a time. |
| `--reasoning off` | Optional. Disables thinking, for faster and shorter answers. |

Docker reference: https://github.com/ggml-org/llama.cpp/blob/master/docs/docker.md

### 4. Test

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "Say this is a test"}],
    "temperature": 0.8
  }'
```

### 5. Monitor

```bash
nvidia-smi   # GPU info and VRAM usage
nvtop        # live GPU monitor
```