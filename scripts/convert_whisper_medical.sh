#!/usr/bin/env bash

# Convert the Hugging Face model 0x456665/whisper-small-medical
# to GGML format that whisper.cpp (and whisper_flutter_new) can load.
#
# Usage:
#   scripts/convert_whisper_medical.sh [output-dir]
# Example:
#   scripts/convert_whisper_medical.sh assets/models

set -euo pipefail

MODEL_REPO_ID="0x456665/whisper-small-medical"
OUT_DIR="${1:-assets/models}"

TMP_ROOT="${TMPDIR:-/tmp}/whisper-medical-convert"
WHISPER_CPP_DIR="$TMP_ROOT/whisper.cpp"
OPENAI_WHISPER_DIR="$TMP_ROOT/openai-whisper"
HF_MODEL_DIR="$TMP_ROOT/hf-whisper-small-medical"
GGML_OUT_DIR="$TMP_ROOT/ggml-out"

echo "==> Using temporary workspace: $TMP_ROOT"
mkdir -p "$TMP_ROOT" "$GGML_OUT_DIR"

########################################
# 1) Cloner / mettre à jour whisper.cpp
########################################
if [ ! -d "$WHISPER_CPP_DIR" ]; then
  echo "==> Cloning whisper.cpp"
  git clone --depth 1 https://github.com/ggml-org/whisper.cpp "$WHISPER_CPP_DIR"
else
  echo "==> Reusing existing whisper.cpp checkout"
  (cd "$WHISPER_CPP_DIR" && git pull --ff-only || true)
fi

########################################
# 2) Cloner / mettre à jour openai/whisper
########################################
if [ ! -d "$OPENAI_WHISPER_DIR" ]; then
  echo "==> Cloning openai/whisper"
  git clone --depth 1 https://github.com/openai/whisper "$OPENAI_WHISPER_DIR"
else
  echo "==> Reusing existing openai/whisper checkout"
  (cd "$OPENAI_WHISPER_DIR" && git pull --ff-only || true)
fi

########################################
# 3) Créer / activer l'environnement Python
########################################
cd "$WHISPER_CPP_DIR"

echo "==> Creating Python virtualenv (if needed)"
python3 -m venv .venv || true
# shellcheck disable=SC1091
source .venv/bin/activate

echo "==> Installing Python dependencies for conversion"
pip install --upgrade pip
if [ -f "models/requirements-coreml.txt" ]; then
  pip install -r models/requirements-coreml.txt
else
  pip install torch transformers numpy tqdm sentencepiece safetensors
fi
pip install huggingface_hub

########################################
# 4) Télécharger le modèle HF localement
########################################
echo "==> Downloading Hugging Face model: $MODEL_REPO_ID"
python - << PY
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id="${MODEL_REPO_ID}",
    local_dir="${HF_MODEL_DIR}",
    local_dir_use_symlinks=False,
    revision="main"
)
PY

########################################
# 5) Récupérer le script convert-h5-to-ggml.py
########################################
mkdir -p "$WHISPER_CPP_DIR/models"
CONVERT_SCRIPT="$WHISPER_CPP_DIR/models/convert-h5-to-ggml.py"

if [ ! -f "$CONVERT_SCRIPT" ]; then
  echo "==> Downloading convert-h5-to-ggml.py from ggml-org/whisper.cpp"
  curl -fsSL \
    "https://raw.githubusercontent.com/ggml-org/whisper.cpp/master/models/convert-h5-to-ggml.py" \
    -o "$CONVERT_SCRIPT"
fi

if [ ! -f "$CONVERT_SCRIPT" ]; then
  echo "ERROR: convert-h5-to-ggml.py not found or failed to download." >&2
  exit 1
fi

echo "==> Using converter script: $CONVERT_SCRIPT"

########################################
# 6) Conversion HF -> GGML (float16)
########################################
echo "==> Converting HF model to GGML (float16)"
python "$CONVERT_SCRIPT" "$HF_MODEL_DIR" "$OPENAI_WHISPER_DIR" "$GGML_OUT_DIR"

echo "==> Looking for GGML model in ${GGML_OUT_DIR}"
GGML_F16_FILE=$(ls "${GGML_OUT_DIR}"/ggml-model*.bin 2>/dev/null | head -n 1 || true)

if [ -z "$GGML_F16_FILE" ]; then
  echo "ERROR: No ggml-model*.bin file found in ${GGML_OUT_DIR}" >&2
  exit 1
fi

echo "==> Found GGML model: $GGML_F16_FILE"

########################################
# 7) Build de l'outil de quantification (via CMake)
########################################
echo "==> Building whisper.cpp (with quantize tool)"
if command -v nproc >/dev/null 2>&1; then
  CORES=$(nproc)
elif command -v sysctl >/dev/null 2>&1; then
  CORES=$(sysctl -n hw.ncpu)
else
  CORES=4
fi

cmake -B build
cmake --build build -j"$CORES"


########################################
# 8) Quantification en Q5_1
########################################
BASENAME=$(basename "$GGML_F16_FILE" .bin)
OUT_Q5="${TMP_ROOT}/${BASENAME}-q5_1.bin"

echo "==> Quantizing to q5_1: $OUT_Q5"
./build/bin/quantize "$GGML_F16_FILE" "$OUT_Q5" q5_1

########################################
# 9) Copie dans le dossier de sortie Flutter
########################################
echo "==> Copying quantized model to $OUT_DIR"
mkdir -p "$OUT_DIR"
cp "$OUT_Q5" "$OUT_DIR/"

echo
echo "======================================="
echo "✅ Done."
echo "Model placed at:"
echo "  $OUT_DIR/$(basename "$OUT_Q5")"
echo "======================================="
