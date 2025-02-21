MAKEFLAGS += --warn-undefined-variables
SHELL := bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := all

IMG ?= cnmcavoy/harbor-container-webhook
TAG ?= dev
ARCH ?= $(shell go env GOARCH)

RUN_GO_GROUPS := go run oss.indeed.com/go/go-groups@v1.1.3
RUN_GOLANGCI_LINT := go run github.com/golangci/golangci-lint/cmd/golangci-lint@v1.52.2

.PHONY: deps
deps: ## download go modules
	go mod download

.PHONY: fmt
fmt: ## ensure consistent code style
	$(RUN_GO_GROUPS) -w .
	$(RUN_GOLANGCI_LINT) run --fix > /dev/null 2>&1 || true
	go mod tidy

.PHONY: lint
lint: ## run golangci-lint
	$(RUN_GOLANGCI_LINT) run
	@if [ -n "$$($(RUN_GO_GROUPS) -l .)" ]; then \
		echo -e "\033[0;33mdetected fmt problems: run \`\033[0;32mmake fmt\033[0m\033[0;33m\`\033[0m"; \
		exit 1; \
	fi

.PHONY: test
test: lint ## run go tests
	go test ./... -race

.PHONY: gen
gen:
	go generate ./...

.PHONY: build
build: ## build harbor-container-webhook binary
	go build -o bin/harbor-container-webhook main.go

.PHONY: docker-build
docker-build: test ## build the docker image
	docker buildx rm harbor-container-webhook-builder || true
	docker buildx create --name harbor-container-webhook-builder --driver-opt network=host
	docker buildx build --builder=harbor-container-webhook-builder --platform=linux/amd64,linux/arm64 -t $(IMG):$(TAG) .

.PHONY: docker-push
docker-push: ## push the docker image
	docker buildx rm harbor-container-webhook-builder || true
	docker buildx create --name harbor-container-webhook-builder --driver-opt network=host
	docker buildx build --builder=harbor-container-webhook-builder --platform=linux/amd64,linux/arm64 --push -t $(IMG):$(TAG) .

hack/certs/tls.crt hack/certs/tls.key:
	hack/gencerts.sh

.PHONY: hack
hack: build hack/certs/tls.crt hack/certs/tls.key ## build and run the webhook w/hack config
	bin/harbor-container-webhook --config hack/config.yaml --kube-client-qps=5 --kube-client-burst=10 --kube-client-lazy-remap

.PHONY: hack-test
hack-test: ## curl the admission and no-op json bodies to the webhook
	curl -X POST 'https://localhost:9443/webhook-v1-pod' --data-binary @hack/test/admission.json -H "Content-Type: application/json" --cert hack/certs/tls.crt --key hack/certs/tls.key --cacert hack/certs/caCert.pem
	curl -X POST 'https://localhost:9443/webhook-v1-pod' --data-binary @hack/test/no-op.json -H "Content-Type: application/json" --cert hack/certs/tls.crt --key hack/certs/tls.key --cacert hack/certs/caCert.pem

.PHONY: all
all: test gen build

.PHONY: help
help: ## displays this help message
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_\/-]+:.*?## / {printf "\033[34m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST) | \
		sort | \
		grep -v '#'