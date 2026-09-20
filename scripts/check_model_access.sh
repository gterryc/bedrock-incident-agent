#!/usr/bin/env bash
#
# Comprueba que el modelo de Bedrock esta realmente invocable en esta cuenta y
# region, ANTES de desplegar o de arrancar la demo.
#
# La pagina "Model access" de la consola fue retirada: los modelos serverless se
# habilitan solos en la primera invocacion. Pero para los modelos de Anthropic,
# un usuario que nunca los uso puede tener que enviar una vez los datos de caso
# de uso. Este script lo detecta sin ambiguedad: si la llamada responde, el
# modelo esta listo.
#
# Uso: ./scripts/check_model_access.sh [model-id]

set -uo pipefail

cd "$(dirname "$0")/.."

DEFAULT_MODEL="us.anthropic.claude-sonnet-4-5-20250929-v1:0"

# Prioridad: argumento > terraform.tfvars > default del modulo
MODEL_ID="${1:-}"
if [[ -z "$MODEL_ID" && -f terraform.tfvars ]]; then
  MODEL_ID="$(grep -E '^\s*bedrock_model_id' terraform.tfvars 2>/dev/null | head -1 | sed 's/.*=\s*"\(.*\)".*/\1/')"
fi
MODEL_ID="${MODEL_ID:-$DEFAULT_MODEL}"

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
if [[ -z "$REGION" && -f terraform.tfvars ]]; then
  REGION="$(grep -E '^\s*aws_region' terraform.tfvars 2>/dev/null | head -1 | sed 's/.*=\s*"\(.*\)".*/\1/')"
fi
REGION="${REGION:-us-east-1}"

echo "Modelo : $MODEL_ID"
echo "Region : $REGION"
echo

OUTPUT="$(aws bedrock-runtime converse \
  --region "$REGION" \
  --model-id "$MODEL_ID" \
  --messages '[{"role":"user","content":[{"text":"Responde unicamente: ok"}]}]' \
  2>&1)"
STATUS=$?

if [[ $STATUS -eq 0 ]]; then
  echo "✅ El modelo responde. No hace falta ningun paso manual."
  echo
  echo "$OUTPUT" | head -20
  exit 0
fi

echo "❌ La invocacion fallo:"
echo
echo "$OUTPUT" | sed 's/^/   /'
echo

case "$OUTPUT" in
  *AccessDenied*|*AccessDeniedException*)
    cat <<'MSG'
   Causa probable: es la primera vez que esta cuenta usa un modelo de Anthropic
   y falta enviar los datos de caso de uso (un formulario, una sola vez por
   cuenta), o una policy de IAM/SCP esta bloqueando bedrock:InvokeModel.

   Solucion: consola de Bedrock -> Model catalog -> elegi el modelo Claude
   Sonnet -> abrilo en el Playground. Si falta el formulario, la consola lo pide
   ahi mismo. Completalo y volve a correr este script.
MSG
    ;;
  *ValidationException*|*ResourceNotFound*)
    cat <<MSG
   Causa probable: el model id no existe o no esta disponible en $REGION.

   Mira que tenes disponible:
     aws bedrock list-inference-profiles --region $REGION \\
       --query 'inferenceProfileSummaries[?contains(inferenceProfileId,\`sonnet\`)].inferenceProfileId'

   Y ajusta bedrock_model_id en terraform.tfvars.
MSG
    ;;
  *)
    echo "   Revisa credenciales y region."
    ;;
esac
exit 1
