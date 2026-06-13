"""
Seeds the OpenSearch RAG database with internal HIPAA/FDA compliance rules.
Run once after infrastructure is provisioned: make seed-rag
"""

import boto3
import json
import os
from opensearchpy import OpenSearch, RequestsHttpConnection
from requests_aws4auth import AWS4Auth

OPENSEARCH_ENDPOINT = os.environ["OPENSEARCH_ENDPOINT"]
INDEX_NAME = "compliance-rules"
REGION = os.environ.get("AWS_REGION", "us-east-1")

COMPLIANCE_RULES = [
    {
        "id": "HIPAA-164.312.a.1",
        "category": "HIPAA",
        "title": "Access Control",
        "rule": "Implement technical policies and procedures for electronic information systems "
                "that maintain ePHI to allow access only to authorized persons or software programs.",
    },
    {
        "id": "HIPAA-164.312.e.1",
        "category": "HIPAA",
        "title": "Transmission Security",
        "rule": "Implement technical security measures to guard against unauthorized access to ePHI "
                "transmitted over electronic communications networks.",
    },
    {
        "id": "FDA-21CFR11.10",
        "category": "FDA",
        "title": "Electronic Records Controls",
        "rule": "Closed systems must use procedures and controls to ensure authenticity, integrity, "
                "and confidentiality of electronic records.",
    },
    {
        "id": "FDA-21CFR11.50",
        "category": "FDA",
        "title": "Signature Manifestations",
        "rule": "Signed electronic records must contain the printed name of the signer, "
                "the date and time of signing, and the meaning associated with the signature.",
    },
]


def get_opensearch_client():
    credentials = boto3.Session().get_credentials()
    awsauth = AWS4Auth(
        credentials.access_key,
        credentials.secret_key,
        REGION,
        "aoss",
        session_token=credentials.token,
    )
    return OpenSearch(
        hosts=[{"host": OPENSEARCH_ENDPOINT, "port": 443}],
        http_auth=awsauth,
        use_ssl=True,
        verify_certs=True,
        connection_class=RequestsHttpConnection,
    )


def seed():
    client = get_opensearch_client()

    if not client.indices.exists(INDEX_NAME):
        client.indices.create(
            INDEX_NAME,
            body={"mappings": {"properties": {"rule": {"type": "text"}, "category": {"type": "keyword"}}}},
        )
        print(f"Created index: {INDEX_NAME}")

    for rule in COMPLIANCE_RULES:
        client.index(index=INDEX_NAME, id=rule["id"], body=rule)
        print(f"Seeded rule: {rule['id']}")

    print(f"Done. {len(COMPLIANCE_RULES)} rules seeded into {INDEX_NAME}.")


if __name__ == "__main__":
    seed()
