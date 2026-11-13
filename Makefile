.PHONY: bootstrap state-bucket infra secrets serverless ansible-inventory k8s k8s-check k8s-enforce seed-rag audit-report destroy all

TF_DIR     := infrastructure/terraform
VAULT_FLAG := $(if $(wildcard .vault_password),--vault-password-file .vault_password,)
PLAYBOOK   := ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/deploy-eks-addons.yml $(VAULT_FLAG)

# WORM audit resources are protected by prevent_destroy and Object Lock
# COMPLIANCE. `make destroy` drops them from state first so the rest of the
# platform can be destroyed; the bucket and its evidence stay in AWS.
WORM_STATE := aws_s3_bucket.worm_audit \
              aws_s3_bucket_versioning.worm \
              aws_s3_bucket_public_access_block.worm \
              aws_s3_bucket_lifecycle_configuration.worm \
              aws_s3_bucket_object_lock_configuration.worm \
              aws_s3_bucket_server_side_encryption_configuration.worm

all: bootstrap infra secrets serverless ansible-inventory k8s

bootstrap:
	@echo "Installing DevOps toolchain..."
	bash scripts/install-devops-tools.sh

state-bucket infra:
	@echo "Bootstrapping state bucket (KMS, versioning, public-access block) + terraform apply..."
	bash scripts/bootstrap-aws.sh

secrets:
	@echo "Populating real values in Secrets Manager (run BEFORE k8s)..."
	bash scripts/populate-secrets.sh

serverless:
	@echo "Deploying SAM serverless stack..."
	cd infrastructure/sam && sam build && sam deploy --guided

ansible-inventory:
	bash scripts/terraform-to-ansible.sh

k8s: ansible-inventory
	@echo "Deploying Kubernetes add-ons via Ansible (Kyverno policies in Audit mode)..."
	$(PLAYBOOK)

k8s-check: ansible-inventory
	$(PLAYBOOK) --check --diff

k8s-enforce: ansible-inventory
	@echo "Switching Kyverno policies to Enforce..."
	$(PLAYBOOK) -e kyverno_policy_mode=Enforce

seed-rag:
	@echo "Seeding RAG compliance rules into OpenSearch..."
	python3 scripts/seed-compliance-rules.py

audit-report:
	@echo "Generating HIPAA/FDA audit proof..."
	bash scripts/generate-audit-proof.sh

destroy:
	@echo "Destroying infrastructure (WORM audit bucket is retained)..."
	cd $(TF_DIR) && for r in $(WORM_STATE); do \
	  terraform state list | grep -qx "$$r" && terraform state rm "$$r" || true; \
	done
	cd $(TF_DIR) && terraform destroy
	@echo "WORM bucket retained in AWS. Re-adopt later with: terraform import aws_s3_bucket.worm_audit <bucket-name>"
