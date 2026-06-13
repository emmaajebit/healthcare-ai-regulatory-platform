#!/usr/bin/env bash
set -euo pipefail

# Extracts SLSA provenance, WORM reports, and AI audit logs
# for external HIPAA/FDA auditors and stores them in S3 WORM bucket.

WORM_BUCKET="${WORM_BUCKET:-healthcare-worm-audit}"
TIMESTAMP=$(date -u +"%Y%m%dT%H%M%SZ")
REPORT_DIR="/tmp/audit-report-${TIMESTAMP}"
mkdir -p "$REPORT_DIR"

echo "Collecting SLSA provenance..."
aws s3 cp "s3://${WORM_BUCKET}/slsa/" "${REPORT_DIR}/slsa/" --recursive

echo "Collecting AI validation logs from DynamoDB..."
aws dynamodb scan \
  --table-name bedrock-audit-log \
  --output json > "${REPORT_DIR}/ai-validation-log.json"

echo "Collecting Trivy/Checkov scan results..."
aws s3 cp "s3://${WORM_BUCKET}/scan-results/" "${REPORT_DIR}/scan-results/" --recursive

echo "Packaging audit report..."
tar -czf "/tmp/audit-proof-${TIMESTAMP}.tar.gz" -C /tmp "audit-report-${TIMESTAMP}"

echo "Uploading final report to WORM bucket..."
aws s3 cp "/tmp/audit-proof-${TIMESTAMP}.tar.gz" \
  "s3://${WORM_BUCKET}/audit-proofs/audit-proof-${TIMESTAMP}.tar.gz"

echo "Audit proof generated: s3://${WORM_BUCKET}/audit-proofs/audit-proof-${TIMESTAMP}.tar.gz"
