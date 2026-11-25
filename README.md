# λ Global Chat — a live AWS Lambda demo

A global chat room for showing how Lambda behaves while people are using it.

```
phone/laptop ──HTTPS──▶ Lambda Function URL ──▶ lambda_function.py ──▶ DynamoDB
(web/index.html on        (no API Gateway)       (Python 3.13)          (provisioned 25/5, 24h TTL)
 Cloudflare Pages)                                      ▲
                          EventBridge (every 5 min) ──▶ killswitch.py
```

Everything is sized to stay inside the AWS **always free** tier, and a kill switch shuts the chat off before Lambda's monthly free allowance runs out. See [Cost](#cost-and-the-kill-switch).

| File | Purpose |
| --- | --- |
| `lambda_function.py` | The whole backend: `GET` returns the latest 30 messages, `POST` stores one |
| `killswitch.py` | Runs every 5 minutes and turns the chat off once this month's Lambda invocations pass 750,000 |
| `deploy.sh` | Idempotent AWS CLI deploy of everything. `./deploy.sh revive` turns the chat back on, `./deploy.sh destroy` removes it all |
| `web/index.html` | The whole frontend: one static file, no build step |

## 1. Deploy the backend

You need the AWS CLI v2 signed in (`aws sts get-caller-identity` should work). The region comes from `AWS_REGION`, or from `aws configure get region` if that's unset.

```bash
./deploy.sh
```

The last lines print the Function URL, for example:

```
Function URL: https://abc123xyz.lambda-url.eu-north-1.on.aws/
```

If you need the URL again later:

```bash
aws lambda get-function-url-config --function-name lambda-chat-demo --query FunctionUrl --output text
```

Re-running `./deploy.sh` after editing `lambda_function.py` pushes the new code. The Function URL stays the same across re-deploys, so `API_URL` only needs setting once.

## 2. Point the frontend at it

Open `web/index.html` and replace the value at the top of the `<script>`:

```js
const API_URL = "https://abc123xyz.lambda-url.eu-north-1.on.aws/";
```

Test it locally. Port 8000 is already in the CORS allow-list.

```bash
python3 -m http.server 8000 -d web
# open http://localhost:8000
```

## 3. Publish to Cloudflare Pages

Deploy only the `web/` folder, so the backend code and scripts aren't uploaded:

```bash
npx wrangler login
npx wrangler pages project create lambda-chat --production-branch main   # first time only
npx wrangler pages deploy web --project-name lambda-chat --branch main
```

Then go to **Cloudflare dashboard → Workers & Pages → lambda-chat → Custom domains → Set up a custom domain** and enter `chat.guilhermetests.com`. That exact origin is in the Function URL's CORS allow-list. The `*.pages.dev` preview URL is not, so use the custom domain. You can also add the `pages.dev` origin to `ALLOWED_ORIGINS` in `deploy.sh` and re-run it.

To deploy without the CLI, drag the `web/` folder into **Workers & Pages → Create → Pages → Upload assets**.

## During the presentation

Watch every invocation live on the projector:

```bash
./deploy.sh logs           # just stream the logs (Ctrl+C to stop)
./deploy.sh --log          # deploy, then stream the logs
./deploy.sh revive --log   # --log works after pause/revive/clear too
```

You can also open **CloudWatch → Live Tail**, pick `/aws/lambda/lambda-chat-demo` and filter on `[LAMBDA]`. You'll see:

```
[LAMBDA] cold_start instance=3f9a1c2e                       ← init phase, once per execution environment
[LAMBDA] instance=3f9a1c2e count=1 method=GET user=ana
[LAMBDA] instance=3f9a1c2e count=2 method=POST user=ana     ← same environment reused: a warm start
[LAMBDA] instance=b71d04aa count=1 method=GET user=joão     ← concurrent request → a new environment
```

Things worth showing:

- **Warm reuse:** `INSTANCE_ID` and `INVOCATION_COUNT` live outside the handler. The count keeps going up on the same instance because module state persists between invocations.
- **Scaling out:** when the whole class polls at once, Lambda adds execution environments. "instances seen" in the status bar goes up, and each new instance ID shows in orange the first time.
- **Cold starts on deploy:** re-running `./deploy.sh` (or changing any config) replaces every environment. All counts go back to 1 with new instance IDs.
- **Which environment stored a message:** each message shows the `λ <instance>` that handled its `POST`.

Guardrails: empty messages, names over 20 characters, messages over 280 characters, bodies over 4 KB and malformed JSON get a `400` response. The server collapses newlines and strips invisible characters. The page renders everything with `textContent`.

## Pause, restart and clear messages

```bash
./deploy.sh pause    # chat off: the Function URL answers 429, the page shows "paused"
./deploy.sh revive   # chat back on (also undoes a tripped kill switch)
./deploy.sh clear    # delete every message
```

Add `--log` to any of these to start streaming the logs once it finishes.

Messages also delete themselves 24 hours after they're sent. To remove a single message, take its `id` from the `GET` response and run:

```bash
aws dynamodb delete-item --table-name lambda-chat-demo-messages \
  --key '{"room":{"S":"global"},"ts":{"N":"<id>"}}'
```

## Cost and the kill switch

The account is on the paid plan with no credits, so anything outside the always-free tier is billed. The setup stays inside it:

| Service | Always free per month | This demo |
| --- | --- | --- |
| Lambda | 1M requests, 400,000 GB-seconds | ~43k requests per hour with 30 phones polling. The kill switch trips at **750k** |
| DynamoDB | 25 GB, 25 RCU + 25 WCU **provisioned** | Provisioned 25 RCU / 5 WCU. On-demand isn't free-tier, so it isn't used. Over capacity it throttles (the API returns `503`) instead of billing |
| CloudWatch | 5 GB logs, 10 alarms, 1M API calls, 1,800 min Live Tail | One short line per request, 1-day log retention. The kill switch uses `GetMetricStatistics` (free), not `GetMetricData` |
| EventBridge schedule, IAM, Function URL | free | |
| Data transfer out | 100 GB | ~6 KB per poll |

Lambda requests are the only limit a busy demo (or someone scripting the URL) could realistically hit. Every 5 minutes, `killswitch.py` adds up the **account-wide** `AWS/Lambda Invocations` metric for the current UTC month. At 750,000 it sets the chat function's reserved concurrency to **0**. From then on the URL answers `429` and throttled requests aren't billed. The page shows "paused". The account's 10-concurrent-execution limit caps how fast requests can arrive, so the 250k margin covers the 5-minute check interval plus metric delay.

It stays off until you turn it back on:

```bash
./deploy.sh revive
```

Check the kill switch's latest reading:

```bash
aws logs tail /aws/lambda/lambda-chat-demo-killswitch --since 15m
```

Limits: the check counts Lambda invocations in the deployed region only, so it doesn't see Lambda functions in other regions. Changing the reserved concurrency on another function doesn't affect it. Billing data itself lags by hours, which is why the check uses usage metrics rather than AWS Budgets.

## 4. Tear down after the presentation

```bash
./deploy.sh destroy
```

This deletes both Lambda functions, the Function URL, the 5-minute schedule, the DynamoDB table, both IAM roles and both log groups. Delete the Pages project with `npx wrangler pages project delete lambda-chat` if you no longer need it.
