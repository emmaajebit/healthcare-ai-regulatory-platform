.PHONY: bootstrap infra serverless k8s all destroy

all: bootstrap infra serverless k8s

bootstrap:
	@echo "Installing DevOps toolchain..."
	bash scripts/install-devops-tools.sh

infra:
	@echo "Provisioning AWS infrastructure with Terraform..."
	cd infrastructure/terraform && terraform init && terraform apply -auto-approve

serverless:
	@echo "Deploying SAM serverless stack..."
	cd infrastructure/sam && sam build && sam deploy --guided

k8s:
	@echo "Deploying Kubernetes add-ons via Ansible..."
	ansible-playbook ansible/playbooks/deploy-eks-addons.yml \
	  --vault-password-file .vault_password \
	  -i ansible/inventory/hosts.yml

seed-rag:
	@echo "Seeding RAG compliance rules into OpenSearch..."
	python3 scripts/seed-compliance-rules.py

audit-report:
	@echo "Generating HIPAA/FDA audit proof..."
	bash scripts/generate-audit-proof.sh

destroy:
	@echo "Destroying infrastructure..."
	cd infrastructure/terraform && terraform destroy -auto-approve
