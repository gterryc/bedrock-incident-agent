#!/usr/bin/env bash
#
# Muestra el estado de los targets y de la alarma. Util para proyectar en la
# charla mientras el ambiente se cae.
#
# Usa la region del perfil de AWS CLI; exporta AWS_REGION si desplegaste en otra.

set -euo pipefail

cd "$(dirname "$0")/.."

TG_ARN="$(terraform output -raw target_group_arn)"
ALARM_NAME="$(terraform output -raw alarm_name)"

echo "== Estado de los targets =="
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{Target:Target.Id,Estado:TargetHealth.State,Motivo:TargetHealth.Reason}' \
  --output table

echo
echo "== Estado de la alarma =="
aws cloudwatch describe-alarms \
  --alarm-names "$ALARM_NAME" \
  --query 'MetricAlarms[].{Alarma:AlarmName,Estado:StateValue,Desde:StateUpdatedTimestamp}' \
  --output table
