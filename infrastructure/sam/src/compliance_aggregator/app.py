"""
Compliance Aggregator Lambda.
Aggregates Trivy/Checkov/SLSA scan results and generates
immutable JSON reports stored in the S3 WORM bucket.
"""

import json
import os
import uuid
from datetime import datetime, timezone

import boto3

WORM_BUCKET = os.environ["WORM_BUCKET"]
AUDIT_TABLE = os.environ["AUDIT_TABLE"]
REGION      = os.environ.get("AWS_REGION", "us-east-1")

s3       = boto3.client("s3", region_name=REGION)
dynamodb = boto3.resource("dynamodb", region_name=REGION)
table    = dynamodb.Table(AUDIT_TABLE)


def lambda_handler(event, context):
    body = json.loads(event.get("body", "{}"))

    report_id = str(uuid.uuid4())
    timestamp = datetime.now(timezone.utc).isoformat()

    report = {
        "report_id":    report_id,
        "timestamp":    timestamp,
        "commit":       body.get("commit", "unknown"),
        "trivy":        body.get("trivy_results", {}),
        "checkov":      body.get("checkov_results", {}),
        "slsa":         body.get("slsa_provenance", {}),
        "overall_pass": (
            body.get("trivy_results", {}).get("pass", False) and
            body.get("checkov_results", {}).get("pass", False) and
            body.get("slsa_provenance", {}).get("verified", False)
        ),
    }

    s3_key = f"compliance-reports/{timestamp[:10]}/{report_id}.json"
    s3.put_object(
        Bucket=WORM_BUCKET,
        Key=s3_key,
        Body=json.dumps(report, indent=2),
        ContentType="application/json",
    )

    table.put_item(Item={
        "audit_id":   report_id,
        "timestamp":  timestamp,
        "report_s3":  f"s3://{WORM_BUCKET}/{s3_key}",
        "overall_pass": report["overall_pass"],
    })

    return {
        "statusCode": 200,
        "body": json.dumps({"report_id": report_id, "s3_key": s3_key, "pass": report["overall_pass"]}),
    }
