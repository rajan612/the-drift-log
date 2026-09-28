import json
import os
import re
from datetime import datetime, timezone

import boto3


TABLE_NAME = os.environ["TABLE_NAME"]

dynamodb = boto3.client("dynamodb")

PATH_PATTERN = re.compile(r"^/[A-Za-z0-9/_\-.]*$")


def response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {
            "content-type": "application/json",
            "cache-control": "no-store, max-age=0",
            "x-content-type-options": "nosniff",
        },
        "body": json.dumps(body),
    }


def normalize_path(value):
    if not isinstance(value, str):
        raise ValueError("path must be a string")

    value = value.strip()

    if not value:
        value = "/"

    if not value.startswith("/"):
        value = f"/{value}"

    if value != "/" and value.endswith("/"):
        value = value.rstrip("/")

    if len(value) > 512:
        raise ValueError("path is too long")

    if not PATH_PATTERN.fullmatch(value):
        raise ValueError("path contains unsupported characters")

    return value


def read_counts(path):
    result = dynamodb.batch_get_item(
        RequestItems={
            TABLE_NAME: {
                "Keys": [
                    {"pk": {"S": f"PAGE#{path}"}},
                    {"pk": {"S": "SITE#TOTAL"}},
                ],
                "ConsistentRead": True,
            }
        }
    )

    page_views = 0
    site_views = 0

    for item in result.get("Responses", {}).get(TABLE_NAME, []):
        key = item["pk"]["S"]
        views = int(item.get("views", {}).get("N", "0"))

        if key == f"PAGE#{path}":
            page_views = views
        elif key == "SITE#TOTAL":
            site_views = views

    return page_views, site_views


def increment_counts(path):
    now = datetime.now(timezone.utc).isoformat()

    dynamodb.transact_write_items(
        TransactItems=[
            {
                "Update": {
                    "TableName": TABLE_NAME,
                    "Key": {
                        "pk": {"S": f"PAGE#{path}"}
                    },
                    "UpdateExpression": (
                        "SET #page_path = if_not_exists(#page_path, :path), "
                        "#updated_at = :updated_at "
                        "ADD #views :one"
                    ),
                    "ExpressionAttributeNames": {
                        "#page_path": "path",
                        "#updated_at": "updated_at",
                        "#views": "views",
                    },
                    "ExpressionAttributeValues": {
                        ":path": {"S": path},
                        ":updated_at": {"S": now},
                        ":one": {"N": "1"},
                    },
                }
            },
            {
                "Update": {
                    "TableName": TABLE_NAME,
                    "Key": {
                        "pk": {"S": "SITE#TOTAL"}
                    },
                    "UpdateExpression": (
                        "SET #updated_at = :updated_at "
                        "ADD #views :one"
                    ),
                    "ExpressionAttributeNames": {
                        "#updated_at": "updated_at",
                        "#views": "views",
                    },
                    "ExpressionAttributeValues": {
                        ":updated_at": {"S": now},
                        ":one": {"N": "1"},
                    },
                }
            },
        ]
    )

    return read_counts(path)


def handler(event, context):
    try:
        method = (
            event.get("requestContext", {})
            .get("http", {})
            .get("method", "GET")
            .upper()
        )

        if method == "POST":
            body = json.loads(event.get("body") or "{}")
            path = normalize_path(body.get("path", "/"))
            page_views, site_views = increment_counts(path)

        elif method == "GET":
            params = event.get("queryStringParameters") or {}
            path = normalize_path(params.get("path", "/"))
            page_views, site_views = read_counts(path)

        else:
            return response(
                405,
                {"error": "method not allowed"},
            )

        return response(
            200,
            {
                "path": path,
                "page_views": page_views,
                "site_views": site_views,
            },
        )

    except (ValueError, json.JSONDecodeError) as exc:
        return response(
            400,
            {"error": str(exc)},
        )

    except Exception:
        print(
            json.dumps(
                {
                    "message": "page view request failed",
                    "request_id": getattr(context, "aws_request_id", None),
                }
            )
        )

        return response(
            500,
            {"error": "internal server error"},
        )