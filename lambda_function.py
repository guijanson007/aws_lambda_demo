"""Global chat backend: one Lambda function behind a Function URL, backed by DynamoDB.

GET  /            -> latest 30 messages, oldest first
GET  /?user=name  -> same; the name only shows up in the log line
POST / {"user": "...", "text": "..."} -> store a message
"""

import base64
import json
import os
import re
import time
import uuid

import boto3
from botocore.exceptions import ClientError
from boto3.dynamodb.conditions import Key

# ---------------------------------------------------------------------------
# INIT PHASE: everything at module level runs once per execution environment
# (a "cold start"). Warm invocations reuse these objects, so INVOCATION_COUNT
# keeps climbing until Lambda recycles this environment.
# ---------------------------------------------------------------------------
INSTANCE_ID = str(uuid.uuid4())[:8]
INVOCATION_COUNT = 0

TABLE = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
ROOM = "global"
HISTORY = 30
MAX_USER = 20
MAX_TEXT = 280
MAX_BODY_BYTES = 4096
TTL_SECONDS = 24 * 60 * 60

_WHITESPACE = re.compile(r"\s+")
_CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f​-‏ -‮⁦-⁩]")

print(f"[LAMBDA] cold_start instance={INSTANCE_ID}")


def lambda_handler(event, context):
    global INVOCATION_COUNT
    INVOCATION_COUNT += 1

    method = event.get("requestContext", {}).get("http", {}).get("method", "?")
    user = "-"
    try:
        if method == "GET":
            params = event.get("queryStringParameters") or {}
            user = clean(params.get("user", ""))[:MAX_USER] or "-"
            return respond(200, {"messages": latest_messages()})

        if method == "POST":
            data, error = parse_body(event)
            if error:
                return respond(400, {"error": error})
            raw_user, raw_text = data.get("user"), data.get("text")
            if not isinstance(raw_user, str) or not isinstance(raw_text, str):
                return respond(400, {"error": "'user' and 'text' must be strings"})
            name, text = clean(raw_user), clean(raw_text)
            user = name[:MAX_USER] or "-"
            if not name:
                return respond(400, {"error": "Username is required"})
            if len(name) > MAX_USER:
                return respond(400, {"error": f"Username must be at most {MAX_USER} characters"})
            if not text:
                return respond(400, {"error": "Message cannot be empty"})
            if len(text) > MAX_TEXT:
                return respond(400, {"error": f"Message must be at most {MAX_TEXT} characters"})
            store_message(name, text)
            return respond(201, {"ok": True})

        if method == "OPTIONS":  # The Function URL answers CORS preflight itself; this is a fallback.
            return respond(204, None)

        return respond(405, {"error": "Method not allowed"})
    except ClientError as err:
        # Provisioned (free-tier) capacity exhausted, or another DynamoDB error: fail soft.
        code = err.response.get("Error", {}).get("Code", "ClientError")
        print(f"[LAMBDA] dynamodb_error={code}")
        return respond(503, {"error": "Chat is busy, try again in a moment"})
    finally:
        # One line per invocation, easy to read in CloudWatch Logs Live Tail.
        print(f"[LAMBDA] instance={INSTANCE_ID} count={INVOCATION_COUNT} method={method} user={user}")


def latest_messages():
    result = TABLE.query(
        KeyConditionExpression=Key("room").eq(ROOM),
        ScanIndexForward=False,  # newest first, so Limit keeps the latest 30
        Limit=HISTORY,
    )
    items = reversed(result.get("Items", []))  # back to chronological order
    return [
        {
            "id": str(item["ts"]),
            "ts": int(item["ts"]) // 1_000_000,  # nanoseconds -> milliseconds
            "user": item["user"],
            "text": item["text"],
            "instance_id": item.get("instance_id", ""),
        }
        for item in items
    ]


def store_message(user, text):
    TABLE.put_item(
        Item={
            "room": ROOM,
            "ts": time.time_ns(),  # sort key; nanoseconds make collisions practically impossible
            "user": user,
            "text": text,
            "instance_id": INSTANCE_ID,
            "expires_at": int(time.time()) + TTL_SECONDS,  # DynamoDB TTL attribute
        }
    )


def parse_body(event):
    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        try:
            body = base64.b64decode(body).decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            return None, "Body is not valid UTF-8"
    if len(body.encode("utf-8")) > MAX_BODY_BYTES:
        return None, "Body too large"
    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        return None, "Body must be valid JSON"
    if not isinstance(data, dict):
        return None, "Body must be a JSON object"
    return data, None


def clean(value):
    """Drop control/invisible characters and collapse whitespace (no newline spam on the projector)."""
    return _WHITESPACE.sub(" ", _CONTROL.sub(" ", value)).strip()


def respond(status, payload):
    # CORS headers are added by the Function URL's CORS config, so none are set here.
    body = dict(payload or {})
    body["meta"] = {"instance_id": INSTANCE_ID, "invocation_count": INVOCATION_COUNT}
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json", "Cache-Control": "no-store"},
        "body": "" if status == 204 else json.dumps(body),
    }
