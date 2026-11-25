#!/usr/bin/env bash
# Idempotent deploy of the Lambda chat demo using only the AWS CLI.
# Everything stays inside the AWS *always free* tier (see README "Cost").
#   ./deploy.sh           create or update everything, print the Function URL
#   ./deploy.sh pause     turn the chat off (the Function URL answers 429)
#   ./deploy.sh revive    turn the chat back on (after pause, or after the kill switch tripped)
#   ./deploy.sh clear     delete every chat message
#   ./deploy.sh logs      only stream the live logs (same as --log without deploying)
#   ./deploy.sh destroy   delete every AWS resource this script creates
# Add --log to any command except destroy to stream the chat function's logs
# (CloudWatch Logs Live Tail) when it finishes, e.g. ./deploy.sh --log
set -euo pipefail
cd "$(dirname "$0")"

COMMAND="" LOG=false
for arg in "$@"; do
  case "$arg" in
    --log) LOG=true ;;
    -*) echo "Unknown option: $arg" >&2; exit 1 ;;
    *) COMMAND="$arg" ;;
  esac
done

APP="lambda-chat-demo"
TABLE="$APP-messages"
FUNCTION="$APP"
KILL_FUNCTION="$APP-killswitch"
KILL_RULE="$APP-killswitch-every-5-min"
KILL_THRESHOLD=750000          # Lambda always-free = 1,000,000 requests/month; trip well before it
READ_CAPACITY=25               # DynamoDB always-free = 25 RCU + 25 WCU of *provisioned* capacity
WRITE_CAPACITY=5
RUNTIME="python3.13"
ALLOWED_ORIGINS='["https://chat.guilhermetests.com","http://localhost:8000"]'

export AWS_REGION="${AWS_REGION:-$(aws configure get region || echo us-east-1)}"
export AWS_PAGER=""
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
TABLE_ARN="arn:aws:dynamodb:$AWS_REGION:$ACCOUNT:table/$TABLE"
FUNCTION_ARN="arn:aws:lambda:$AWS_REGION:$ACCOUNT:function:$FUNCTION"
log_arn() { echo "arn:aws:logs:$AWS_REGION:$ACCOUNT:log-group:/aws/lambda/$1"; }

# Stream the "[LAMBDA]" lines live until Ctrl+C (with --log), then exit.
finish() {
  if $LOG; then
    echo
    echo "Streaming live logs from /aws/lambda/$FUNCTION (Ctrl+C to stop)..."
    exec aws logs start-live-tail --log-group-identifiers "$(log_arn "$FUNCTION")" \
      --log-event-filter-pattern '"[LAMBDA]"'
  fi
  exit 0
}

destroy() {
  echo "Deleting $APP resources in $AWS_REGION..."
  aws events remove-targets --rule "$KILL_RULE" --ids 1 >/dev/null 2>&1 || true
  aws events delete-rule --name "$KILL_RULE" 2>/dev/null && echo "  schedule deleted" || true
  for fn in "$FUNCTION" "$KILL_FUNCTION"; do
    aws lambda delete-function --function-name "$fn" 2>/dev/null && echo "  function $fn deleted" || true
    aws iam delete-role-policy --role-name "$fn-role" --policy-name policy 2>/dev/null || true
    aws iam delete-role --role-name "$fn-role" 2>/dev/null && echo "  role $fn-role deleted" || true
    aws logs delete-log-group --log-group-name "/aws/lambda/$fn" 2>/dev/null && echo "  log group /aws/lambda/$fn deleted" || true
  done
  aws dynamodb delete-table --table-name "$TABLE" >/dev/null 2>&1 && echo "  table deleted" || true
  echo "Done."
}

case "$COMMAND" in
  destroy) destroy; exit 0 ;;
  logs) LOG=true; finish ;;
  pause)
    aws lambda put-function-concurrency --function-name "$FUNCTION" --reserved-concurrent-executions 0 >/dev/null
    echo "Chat paused: the Function URL now answers 429. Turn it back on with ./deploy.sh revive"
    finish ;;
  revive)
    aws lambda delete-function-concurrency --function-name "$FUNCTION"
    echo "Chat function re-enabled. The kill switch trips again if this month's invocations pass $KILL_THRESHOLD."
    finish ;;
  clear)
    # Uses your own CLI credentials: the chat function itself is not allowed to delete anything.
    COUNT=0
    for ts in $(aws dynamodb query --table-name "$TABLE" \
        --key-condition-expression "#r = :room" --expression-attribute-names '{"#r":"room"}' \
        --expression-attribute-values '{":room":{"S":"global"}}' \
        --projection-expression ts --query 'Items[].ts.N' --output text); do
      aws dynamodb delete-item --table-name "$TABLE" \
        --key "{\"room\":{\"S\":\"global\"},\"ts\":{\"N\":\"$ts\"}}"
      COUNT=$((COUNT + 1))
    done
    echo "Deleted $COUNT message(s)."
    finish ;;
  "") ;;
  *) echo "Unknown command: $COMMAND (use logs, pause, revive, clear or destroy)" >&2; exit 1 ;;
esac

# Log group with 1-day retention, created here so roles don't need logs:CreateLogGroup.
ensure_log_group() {
  aws logs create-log-group --log-group-name "/aws/lambda/$1" 2>/dev/null || true
  aws logs put-retention-policy --log-group-name "/aws/lambda/$1" --retention-in-days 1
}

# ensure_role <function> <extra policy statements JSON>; prints the role ARN.
ensure_role() {
  local role="$1-role"
  if ! aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    echo "- creating role $role" >&2
    aws iam create-role --role-name "$role" --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{"Effect": "Allow", "Principal": {"Service": "lambda.amazonaws.com"}, "Action": "sts:AssumeRole"}]
    }' >/dev/null
  fi
  aws iam put-role-policy --role-name "$role" --policy-name policy --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {\"Effect\": \"Allow\", \"Action\": [\"logs:CreateLogStream\", \"logs:PutLogEvents\"], \"Resource\": \"$(log_arn "$1"):*\"},
      $2
    ]
  }"
  aws iam get-role --role-name "$role" --query Role.Arn --output text
}

# deploy_function <name> <source.py> <role arn> <memory MB> <env vars>
deploy_function() {
  local name="$1" src="$2" role_arn="$3" memory="$4" env="$5" dir
  dir="$(mktemp -d)"
  cp "$src" "$dir/$src"
  (cd "$dir" && zip -q function.zip "$src")
  if aws lambda get-function --function-name "$name" >/dev/null 2>&1; then
    echo "- updating $name (running environments are replaced: expect cold starts)"
    aws lambda update-function-code --function-name "$name" --zip-file "fileb://$dir/function.zip" >/dev/null
    aws lambda wait function-updated-v2 --function-name "$name"
    aws lambda update-function-configuration --function-name "$name" \
      --runtime "$RUNTIME" --handler "${src%.py}.lambda_handler" --role "$role_arn" \
      --memory-size "$memory" --timeout 10 --environment "Variables={$env}" >/dev/null
    aws lambda wait function-updated-v2 --function-name "$name"
  else
    echo "- creating function $name"
    # A brand-new IAM role takes a few seconds before Lambda can assume it, so retry.
    for attempt in $(seq 1 15); do
      if aws lambda create-function --function-name "$name" \
          --runtime "$RUNTIME" --handler "${src%.py}.lambda_handler" \
          --role "$role_arn" --zip-file "fileb://$dir/function.zip" \
          --memory-size "$memory" --timeout 10 \
          --environment "Variables={$env}" >/dev/null 2>&1; then
        break
      fi
      [[ $attempt -eq 15 ]] && { echo "create-function $name kept failing" >&2; exit 1; }
      sleep 4
    done
    aws lambda wait function-active-v2 --function-name "$name"
  fi
  rm -rf "$dir"
}

echo "Deploying $APP to $AWS_REGION (account $ACCOUNT)"

# 1. DynamoDB table: PROVISIONED capacity (on-demand is not covered by the always-free tier).
#    Over capacity, DynamoDB throttles instead of billing more.
if ! aws dynamodb describe-table --table-name "$TABLE" >/dev/null 2>&1; then
  echo "- creating table $TABLE"
  aws dynamodb create-table --table-name "$TABLE" \
    --billing-mode PROVISIONED \
    --provisioned-throughput "ReadCapacityUnits=$READ_CAPACITY,WriteCapacityUnits=$WRITE_CAPACITY" \
    --attribute-definitions AttributeName=room,AttributeType=S AttributeName=ts,AttributeType=N \
    --key-schema AttributeName=room,KeyType=HASH AttributeName=ts,KeyType=RANGE >/dev/null
  aws dynamodb wait table-exists --table-name "$TABLE"
else
  read -r MODE RCU WCU < <(aws dynamodb describe-table --table-name "$TABLE" --output text \
    --query '[Table.BillingModeSummary.BillingMode, Table.ProvisionedThroughput.ReadCapacityUnits, Table.ProvisionedThroughput.WriteCapacityUnits]')
  if [[ "$MODE" == "PAY_PER_REQUEST" || "$RCU" != "$READ_CAPACITY" || "$WCU" != "$WRITE_CAPACITY" ]]; then
    echo "- setting table to provisioned $READ_CAPACITY RCU / $WRITE_CAPACITY WCU"
    aws dynamodb update-table --table-name "$TABLE" --billing-mode PROVISIONED \
      --provisioned-throughput "ReadCapacityUnits=$READ_CAPACITY,WriteCapacityUnits=$WRITE_CAPACITY" >/dev/null
    aws dynamodb wait table-exists --table-name "$TABLE"
  fi
fi
TTL_STATUS="$(aws dynamodb describe-time-to-live --table-name "$TABLE" \
  --query TimeToLiveDescription.TimeToLiveStatus --output text)"
if [[ "$TTL_STATUS" != "ENABLED" && "$TTL_STATUS" != "ENABLING" ]]; then
  echo "- enabling TTL on expires_at"
  aws dynamodb update-time-to-live --table-name "$TABLE" \
    --time-to-live-specification Enabled=true,AttributeName=expires_at >/dev/null
fi

# 2. Chat function: may only PutItem + Query this table and write its own logs.
ensure_log_group "$FUNCTION"
ROLE_ARN="$(ensure_role "$FUNCTION" \
  "{\"Effect\": \"Allow\", \"Action\": [\"dynamodb:PutItem\", \"dynamodb:Query\"], \"Resource\": \"$TABLE_ARN\"}")"
deploy_function "$FUNCTION" lambda_function.py "$ROLE_ARN" 256 "TABLE_NAME=$TABLE"

# 3. Function URL (public, CORS locked to the demo origins)
CORS="{\"AllowOrigins\":$ALLOWED_ORIGINS,\"AllowMethods\":[\"GET\",\"POST\"],\"AllowHeaders\":[\"content-type\"],\"MaxAge\":300}"
if aws lambda get-function-url-config --function-name "$FUNCTION" >/dev/null 2>&1; then
  aws lambda update-function-url-config --function-name "$FUNCTION" --auth-type NONE --cors "$CORS" >/dev/null
else
  echo "- creating Function URL"
  aws lambda create-function-url-config --function-name "$FUNCTION" --auth-type NONE --cors "$CORS" >/dev/null
fi
# A public Function URL needs BOTH permissions, or every request gets 403.
POLICY="$(aws lambda get-policy --function-name "$FUNCTION" --query Policy --output text 2>/dev/null || true)"
if [[ "$POLICY" != *'"FunctionURLAllowPublicAccess"'* ]]; then
  aws lambda add-permission --function-name "$FUNCTION" --statement-id FunctionURLAllowPublicAccess \
    --action lambda:InvokeFunctionUrl --principal '*' --function-url-auth-type NONE >/dev/null
fi
if [[ "$POLICY" != *'"FunctionURLInvokeAllowPublicAccess"'* ]]; then
  aws lambda add-permission --function-name "$FUNCTION" --statement-id FunctionURLInvokeAllowPublicAccess \
    --action lambda:InvokeFunction --principal '*' --invoked-via-function-url >/dev/null
fi

# 4. Kill switch: every 5 minutes, check this month's Lambda invocations and
#    throttle the chat function to 0 concurrency once they pass KILL_THRESHOLD.
ensure_log_group "$KILL_FUNCTION"
KILL_ROLE_ARN="$(ensure_role "$KILL_FUNCTION" \
  "{\"Effect\": \"Allow\", \"Action\": \"lambda:PutFunctionConcurrency\", \"Resource\": \"$FUNCTION_ARN\"},
   {\"Effect\": \"Allow\", \"Action\": \"cloudwatch:GetMetricStatistics\", \"Resource\": \"*\"}")"
deploy_function "$KILL_FUNCTION" killswitch.py "$KILL_ROLE_ARN" 128 \
  "TARGET_FUNCTION=$FUNCTION,KILL_THRESHOLD=$KILL_THRESHOLD"
RULE_ARN="$(aws events put-rule --name "$KILL_RULE" --schedule-expression "rate(5 minutes)" \
  --query RuleArn --output text)"
KILL_POLICY="$(aws lambda get-policy --function-name "$KILL_FUNCTION" --query Policy --output text 2>/dev/null || true)"
if [[ "$KILL_POLICY" != *'"AllowEventBridgeSchedule"'* ]]; then
  aws lambda add-permission --function-name "$KILL_FUNCTION" --statement-id AllowEventBridgeSchedule \
    --action lambda:InvokeFunction --principal events.amazonaws.com --source-arn "$RULE_ARN" >/dev/null
fi
aws events put-targets --rule "$KILL_RULE" \
  --targets "Id=1,Arn=arn:aws:lambda:$AWS_REGION:$ACCOUNT:function:$KILL_FUNCTION" >/dev/null
KILL_OUT="$(mktemp)"
aws lambda invoke --function-name "$KILL_FUNCTION" "$KILL_OUT" >/dev/null
echo "- kill switch armed, trips at $KILL_THRESHOLD invocations this month. First check: $(cat "$KILL_OUT")"
rm -f "$KILL_OUT"

URL="$(aws lambda get-function-url-config --function-name "$FUNCTION" --query FunctionUrl --output text)"
echo
echo "Function URL: $URL"
echo "Paste it into API_URL at the top of the <script> in web/index.html."
$LOG || echo "Live logs:    ./deploy.sh logs"
finish
