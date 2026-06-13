"""
RAG-enhanced AI logic validation Lambda.
Fetches HIPAA/FDA rules from OpenSearch, invokes Claude via Bedrock,
and logs the decision to DynamoDB.
"""

import json
import os
import uuid
from datetime import datetime, timezone

import boto3
from opensearchpy import OpenSearch, RequestsHttpConnection
from requests_aws4auth import AWS4Auth

REGION               = os.environ.get("AWS_REGION", "us-east-1")
OPENSEARCH_ENDPOINT  = os.environ["OPENSEARCH_ENDPOINT"]
AUDIT_TABLE          = os.environ["AUDIT_TABLE"]
BEDROCK_MODEL_ID     = "anthropic.claude-3-sonnet-20240229-v1:0"

bedrock   = boto3.client("bedrock-runtime", region_name=REGION)
dynamodb  = boto3.resource("dynamodb", region_name=REGION)
table     = dynamodb.Table(AUDIT_TABLE)


def get_opensearch_client():
    credentials = boto3.Session().get_credentials()
    awsauth = AWS4Auth(credentials.access_key, credentials.secret_key, REGION, "aoss",
                       session_token=credentials.token)
    return OpenSearch(
        hosts=[{"host": OPENSEARCH_ENDPOINT, "port": 443}],
        http_auth=awsauth, use_ssl=True, verify_certs=True,
        connection_class=RequestsHttpConnection,
    )


def fetch_relevant_rules(query: str) -> list[dict]:
    client = get_opensearch_client()
    response = client.search(
        index="compliance-rules",
        body={"query": {"match": {"rule": query}}, "size": 5}
    )
    return [hit["_source"] for hit in response["hits"]["hits"]]


def invoke_claude(payload: str, rules: list[dict]) -> dict:
    rules_text = "\n".join(f"- [{r['id']}] {r['title']}: {r['rule']}" for r in rules)
    prompt = f"""You are a HIPAA/FDA compliance validator. Assess the following code or logic change:

<change>
{payload}
</change>

Relevant compliance rules:
{rules_text}

Respond with a JSON object: {{"compliant": true/false, "violations": [], "recommendations": []}}"""

    response = bedrock.invoke_model(
        modelId=BEDROCK_MODEL_ID,
        body=json.dumps({"anthropic_version": "bedrock-2023-05-31",
                         "max_tokens": 1024,
                         "messages": [{"role": "user", "content": prompt}]})
    )
    return json.loads(json.loads(response["body"].read())["content"][0]["text"])


def log_audit(payload: str, rules: list, result: dict):
    table.put_item(Item={
        "audit_id":  str(uuid.uuid4()),
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "payload":   payload[:1000],
        "rules_checked": [r["id"] for r in rules],
        "compliant": result.get("compliant"),
        "violations": result.get("violations", []),
    })


def lambda_handler(event, context):
    body    = json.loads(event.get("body", "{}"))
    payload = body.get("payload", "")

    rules  = fetch_relevant_rules(payload)
    result = invoke_claude(payload, rules)
    log_audit(payload, rules, result)

    return {
        "statusCode": 200 if result.get("compliant") else 422,
        "body": json.dumps(result),
    }
