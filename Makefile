# Project name
NAME := marin3r
# Current Operator version
VERSION ?= 0.6.0
# Default bundle image tag
BUNDLE_IMG ?= controller-bundle:$(VERSION)
# Options for 'bundle-build'
ifneq ($(origin CHANNELS), undefined)
BUNDLE_CHANNELS := --channels=$(CHANNELS)
endif
ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)

# Image URL to use all building/pushing image targets
IMG_NAME ?= quay.io/3scale/marin3r
IMG ?= $(IMG_NAME):latest
# Produce CRDs that work back to Kubernetes 1.11 (no version conversion)
CRD_OPTIONS ?= "crd:trivialVersions=true"

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

all: manager

# Run tests
ENVTEST_ASSETS_DIR = $(shell pwd)/testbin
test: generate fmt vet manifests
	mkdir -p $(ENVTEST_ASSETS_DIR)
	test -f $(ENVTEST_ASSETS_DIR)/setup-envtest.sh || curl -sSLo $(ENVTEST_ASSETS_DIR)/setup-envtest.sh https://raw.githubusercontent.com/kubernetes-sigs/controller-runtime/v0.6.3/hack/setup-envtest.sh
	source $(ENVTEST_ASSETS_DIR)/setup-envtest.sh; fetch_envtest_tools $(ENVTEST_ASSETS_DIR); setup_envtest_env $(ENVTEST_ASSETS_DIR); go test ./... -coverprofile cover.out

# Build manager binary
manager: generate fmt vet
	go build -o bin/manager main.go

# Run against the configured Kubernetes cluster in ~/.kube/config
run: generate fmt vet manifests
	go run ./main.go --debug

# Install CRDs into a cluster
install: manifests kustomize
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

# Uninstall CRDs from a cluster
uninstall: manifests kustomize
	$(KUSTOMIZE) build config/crd | kubectl delete -f -

# Deploy controller in the configured Kubernetes cluster in ~/.kube/config
deploy: manifests kustomize
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default | kubectl apply -f -

# Generate manifests e.g. CRD, RBAC etc.
manifests: controller-gen
	$(CONTROLLER_GEN) $(CRD_OPTIONS) rbac:roleName=manager-role webhook paths="./..." output:crd:artifacts:config=config/crd/bases

# Run go fmt against code
fmt:
	go fmt ./...

# Run go vet against code
vet:
	go vet ./...

# Generate code
generate: controller-gen
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

# find or download controller-gen
# download controller-gen if necessary
controller-gen:
ifeq (, $(shell which controller-gen))
	@{ \
	set -e ;\
	CONTROLLER_GEN_TMP_DIR=$$(mktemp -d) ;\
	cd $$CONTROLLER_GEN_TMP_DIR ;\
	go mod init tmp ;\
	go get sigs.k8s.io/controller-tools/cmd/controller-gen@v0.3.0 ;\
	rm -rf $$CONTROLLER_GEN_TMP_DIR ;\
	}
CONTROLLER_GEN=$(GOBIN)/controller-gen
else
CONTROLLER_GEN=$(shell which controller-gen)
endif

kustomize:
ifeq (, $(shell which kustomize))
	@{ \
	set -e ;\
	KUSTOMIZE_GEN_TMP_DIR=$$(mktemp -d) ;\
	cd $$KUSTOMIZE_GEN_TMP_DIR ;\
	go mod init tmp ;\
	go get sigs.k8s.io/kustomize/kustomize/v3@v3.5.4 ;\
	rm -rf $$KUSTOMIZE_GEN_TMP_DIR ;\
	}
KUSTOMIZE=$(GOBIN)/kustomize
else
KUSTOMIZE=$(shell which kustomize)
endif

# Generate bundle manifests and metadata, then validate generated files.
.PHONY: bundle
bundle: manifests
	operator-sdk generate kustomize manifests -q
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(IMG)
	$(KUSTOMIZE) build config/manifests | operator-sdk generate bundle -q --overwrite --version $(VERSION) $(BUNDLE_METADATA_OPTS)
	operator-sdk bundle validate ./bundle

# Build the bundle image.
.PHONY: bundle-build
bundle-build:
	docker build -f bundle.Dockerfile -t $(BUNDLE_IMG) .

#########################
#### General targets ####
#########################

.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

tmp:
	mkdir -p $@

EASYRSA_VERSION ?= v3.0.6
certs:
	hack/gen-certs.sh $(EASYRSA_VERSION)

.PHONY: clean
clean: ## remove temporary resources from the repo
	rm -rf certs build tmp bin

#######################
#### Build targets ####
#######################

CURRENT_GIT_REF := $(shell git describe --always --dirty)
RELEASE := $(CURRENT_GIT_REF)

build: ## builds $(RELEASE) or HEAD of the current branch when $(RELEASE) is unset
build: build/bin/$(NAME)_amd64_$(RELEASE)

build/bin/$(NAME)_amd64_$(RELEASE):
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -a -ldflags '-extldflags "-static"' -o build/bin/$(NAME)_amd64_$(RELEASE) main.go

clean-dirty-builds:
	rm -rf build/bin/*-dirty

docker-build: ## builds the docker image for $(RELEASE) or for HEAD of the current branch when $(RELEASE) is unset
docker-build: build/bin/$(NAME)_amd64_$(RELEASE)
	docker build . -t ${IMG_NAME}:$(RELEASE)
	docker tag ${IMG_NAME}:$(RELEASE) ${IMG_NAME}:test

#######################
#### kuttl targets ####
#######################

KUTTL_VERSION := 0.7.0
KUTTL := bin/kuttl
$(KUTTL):
	mkdir -p $$(dirname $@)
	curl -sLo $(KUTTL) https://github.com/kudobuilder/kuttl/releases/download/v$(KUTTL_VERSION)/kubectl-kuttl_$(KUTTL_VERSION)_$$(uname)_x86_64
	chmod +x $(KUTTL)

TEST_OPERATOR_MANIFEST ?= tmp/deploy
$(TEST_OPERATOR_MANIFEST): .FORCE
	mkdir -p $(TEST_OPERATOR_MANIFEST)
	$(KUSTOMIZE) build config/test > $(TEST_OPERATOR_MANIFEST)/operator.yaml

TETS_ARTIFACTS_DIR ?= tmp/test
$(TETS_ARTIFACTS_DIR):
	mkdir -p $(TETS_ARTIFACTS_DIR)

e2e: $(KUTTL) tmp manifests docker-build $(TEST_OPERATOR_MANIFEST)
	$(KUTTL) test

#########################3333333333#########
#### Targets to manually test with Kind ####
############################################

KIND_VERSION ?= v0.9.0
KIND ?= bin/kind
export KUBECONFIG = ${PWD}/kubeconfig

$(KIND):
	mkdir -p $$(dirname $@)
	curl -sLo $(KIND) https://github.com/kubernetes-sigs/kind/releases/download/$(KIND_VERSION)/kind-$$(uname)-amd64
	chmod +x $(KIND)

kind-create: ## runs a k8s kind cluster with a local registry in "localhost:5000" and ports 1080 and 1443 exposed to the host
kind-create: tmp $(KIND)
	$(KIND) create cluster --config test/kind.yaml
	$(KIND) load docker-image quay.io/3scale/marin3r:test --name kind

kind-deploy: manifests kustomize
	$(KUSTOMIZE) build config/test | kubectl apply -f -

kind-refresh-discoveryservice: ## rebuilds the marin3r image, pushes it to the kind registry and recycles the marin3r pod
kind-refresh-discoveryservice: docker-build
	$(KIND) load docker-image quay.io/3scale/marin3r:test --name kind
	kubectl delete pods -A -l app.kubernetes.io/name=marin3r --force --grace-period=0

kind-delete: ## deletes the kind cluster and the registry
kind-delete: $(KIND)
	$(KIND) delete cluster

###########################################
#### Targets to run components locally ####
###########################################

ENVOY_VERSION ?= v1.14.1

run-ds: ## locally starts marin3r's discovery service
run-ds: certs
	WATCH_NAMESPACE="" go run main.go \
		--discovery-service \
		--server-certificate-path certs/server \
		--ca-certificate-path certs/ca \
		--debug

run-envoy: ## executes an envoy process in a container that will try to connect to the local marin3r's discovery service
run-envoy: certs
	docker run -ti --rm \
		--network=host \
		--add-host marin3r.default.svc:127.0.0.1 \
		-v $$(pwd)/certs:/etc/envoy/tls \
		-v $$(pwd)/examples/local:/config \
		envoyproxy/envoy:$(ENVOY_VERSION) \
		envoy -c /config/envoy-client-bootstrap.yaml $(ARGS)



test-envoy-config: ## Run a local envoy container with the configuration passed in var CONFIG: "make test-envoy-config CONFIG=example/config.yaml". To debug problems with configs, increase envoy components log levels: make test-envoy-config CONFIG=example/envoy-ratelimit.yaml ARGS="--component-log-level http:debug"
test-envoy-config:
	docker run -ti --rm \
		--network=host \
		-v $$(pwd)/$(CONFIG):/config.yaml \
		envoyproxy/envoy:$(ENVOY_VERSION) \
		envoy -c /config.yaml $(ARGS)

grpc-proxy: ## executes an envoy process in a container that will try to connect to a local marin3r control plane
grpc-proxy: certs
	docker run -ti --rm \
		--network=host \
		--add-host marin3r.default.svc:127.0.0.1 \
		-v $$(pwd)/certs:/etc/envoy/tls \
		-v $$(pwd)/examples/local:/config \
		envoyproxy/envoy:$(ENVOY_VERSION) \
		envoy -c /config/discovery-service-proxy.yaml $(ARGS)

############################
#### refdocs generation ####
############################

CRD_REFDOCS_VERSION := v0.0.5
CRD_REFDOCS := bin/crd-ref-docs
$(CRD_REFDOCS):
		mkdir -p $$(dirname $@)
		curl -sLo $(CRD_REFDOCS) https://github.com/elastic/crd-ref-docs/releases/download/$(CRD_REFDOCS_VERSION)/crd-ref-docs
		chmod +x $(CRD_REFDOCS)

refdocs: $(CRD_REFDOCS) ## Generates api reference documentation from code
	crd-ref-docs \
		--source-path=apis \
		--config=docs/api-reference/config.yaml \
		--templates-dir=docs/api-reference/templates/asciidoctor \
		--renderer=asciidoctor \
		--output-path=docs/api-reference/reference.asciidoc

.FORCE:
