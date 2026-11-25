"""Free-tier kill switch, run every 5 minutes by an EventBridge rule.

The Lambda always-free tier is 1,000,000 requests per month, counted across the
whole account. This adds up the account-wide Invocations metric for the current
UTC month. Once it passes KILL_THRESHOLD, it sets the chat function's reserved
concurrency to 0: the Function URL then answers 429 and nothing else gets billed.
The function stays off until you turn it back on (see README).
"""

import os
from datetime import datetime, timezone

import boto3

TARGET = os.environ["TARGET_FUNCTION"]
KILL_THRESHOLD = int(os.environ.get("KILL_THRESHOLD", "750000"))

cloudwatch = boto3.client("cloudwatch")
lambda_client = boto3.client("lambda")


def lambda_handler(event, context):
    now = datetime.now(timezone.utc)
    month_start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)

    # No dimensions = the account-wide total for every function in this region.
    # (GetMetricStatistics is in the CloudWatch free API allowance; GetMetricData is not.)
    stats = cloudwatch.get_metric_statistics(
        Namespace="AWS/Lambda",
        MetricName="Invocations",
        StartTime=month_start,
        EndTime=now,
        Period=86400,
        Statistics=["Sum"],
    )
    used = int(sum(point["Sum"] for point in stats["Datapoints"]))

    if used < KILL_THRESHOLD:
        print(f"[KILLSWITCH] ok invocations_this_month={used} threshold={KILL_THRESHOLD}")
        return {"killed": False, "invocations": used}

    lambda_client.put_function_concurrency(FunctionName=TARGET, ReservedConcurrentExecutions=0)
    print(f"[KILLSWITCH] TRIPPED invocations_this_month={used} threshold={KILL_THRESHOLD} "
          f"-> {TARGET} reserved concurrency set to 0")
    return {"killed": True, "invocations": used}
