# Package related
BINARY_NAME=ib-kubernetes
PACKAGE=ib-kubernetes
ORG_PATH=github.com/Mellanox
REPO_PATH=$(ORG_PATH)/$(PACKAGE)
GOPATH=$(CURDIR)/.gopath
GOBIN =$(CURDIR)/bin
BUILDDIR=$(CURDIR)/build
BASE=$(GOPATH)/src/$(REPO_PATH)
GOFILES=$(shell find . -name *.go | grep -vE "(\/vendor\/)|(_test.go)")
PKGS=$(or $(PKG),$(shell cd $(BASE) && env GOPATH=$(GOPATH) $(GO) list ./... | grep -v "^$(PACKAGE)/vendor/"))
TESTPKGS = $(shell env GOPATH=$(GOPATH) $(GO) list -f '{{ if or .TestGoFiles .XTestGoFiles }}{{ .ImportPath }}{{ end }}' $(PKGS))

export GOPATH
export GOBIN

# Docker
IMAGE_BUILDER?=@docker
IMAGEDIR=$(BASE)/images
DOCKERFILE?=$(CURDIR)/Dockerfile
TAG?=mellanox/ib-kubernetes
IMAGE_BUILD_OPTS?=
# Accept proxy settings for docker
# To pass proxy for Docker invoke it as 'make image HTTP_POXY=http://192.168.0.1:8080'
DOCKERARGS=
ifdef HTTP_PROXY
	DOCKERARGS += --build-arg http_proxy=$(HTTP_PROXY)
endif
ifdef HTTPS_PROXY
	DOCKERARGS += --build-arg https_proxy=$(HTTPS_PROXY)
endif
IMAGE_BUILD_OPTS += $(DOCKERARGS)

# Go tools
GO      = go
GOFMT   = gofmt
GOLINT = $(GOBIN)/golangci-lint
TIMEOUT = 15
V = 0
Q = $(if $(filter 1,$V),,@)

.PHONY: all
all: fmt lint build plugins

$(BASE): ; $(info  setting GOPATH...)
	@mkdir -p $(dir $@)
	@ln -sf $(CURDIR) $@

$(GOBIN):
	@mkdir -p $@

$(BUILDDIR): | $(BASE) ; $(info Creating build directory...)
	@cd $(BASE) && mkdir -p $@

build: $(BUILDDIR)/$(BINARY_NAME) ; $(info Building $(BINARY_NAME)...) ## Build executable file
	$(info Done!)

$(BUILDDIR)/$(BINARY_NAME): $(GOFILES) | $(BUILDDIR)
	@cd $(BASE)/cmd/$(BINARY_NAME) && CGO_ENABLED=0 $(GO) build -o $(BUILDDIR)/$(BINARY_NAME) -tags no_openssl -v

# Tools

.PHONY: fmt
fmt: ; $(info  running gofmt...) @ ## Run gofmt on all source files
	@ret=0 && for d in $$($(GO) list -f '{{.Dir}}' ./... | grep -v /vendor/); do \
		$(GOFMT) -l -w $$d/*.go || ret=$$? ; \
	 done ; exit $$ret

$(GOLINT): | $(BASE) ; $(info  building golangci-lint...)
	$Q go get -u github.com/golangci/golangci-lint/cmd/golangci-lint

GOVERALLS = $(GOBIN)/goveralls
$(GOBIN)/goveralls: | $(BASE) ; $(info  building goveralls...)
	$Q go get github.com/mattn/goveralls

# Tests

.PHONY: lint
lint: | $(BASE) $(GOLINT) ; $(info  running golint...) @ ## Run golint
	$Q cd $(BASE) && ret=0 && \
		test -z "$$($(GOLINT) run --timeout 10m0s | tee /dev/stderr)" || ret=1 ; \
	 exit $$ret

plugins: test-plugin

TEST_TARGETS := test-default test-bench test-short test-verbose test-race
.PHONY: $(TEST_TARGETS) test-xml check test tests
test-bench:   ARGS=-run=__absolutelynothing__ -bench=. ## Run benchmarks
test-short:   ARGS=-short        ## Run only short tests
test-verbose: ARGS=-v            ## Run tests in verbose mode with coverage reporting
test-race:    ARGS=-race         ## Run tests with race detector
$(TEST_TARGETS): NAME=$(MAKECMDGOALS:test-%=%)
$(TEST_TARGETS): test
test-plugin: | $(BASE) ; $(info Buidling test go plugins)
	$Q mkdir -p $(CURDIR)/test/plugin
	$Q  $(GO) build -o $(CURDIR)/test/plugin/noop_plugin.so -buildmode=plugin -i $(REPO_PATH)/pkg/sm/plugins/noop

	$Q for plugin in $(NO_PLUGIN_SYMBOL) $(NOT_VALID_PLUGIN_SYMBOL); do cd $$plugin && $(GO) build -buildmode=plugin main.go; done

check test tests: | $(BASE) ; $(info  running $(NAME:%=% )tests...) @ ## Run tests
	$Q cd $(BASE) && $(GO) test -timeout $(TIMEOUT)s $(ARGS) $(TESTPKGS)

test-xml: | $(BASE) $(GO2XUNIT) ; $(info  running $(NAME:%=% )tests...) @ ## Run tests with xUnit output
	$Q cd $(BASE) && 2>&1 $(GO) test -timeout 20s -v $(TESTPKGS) | tee test/tests.output
	$(GO2XUNIT) -fail -input test/tests.output -output test/tests.xml

COVERAGE_MODE = count
.PHONY: test-coverage test-coverage-tools
test-coverage-tools: | $(GOVERALLS)
test-coverage: COVERAGE_DIR := $(CURDIR)/test
test-coverage: test-coverage-tools | $(BASE) ; $(info  running coverage tests...) @ ## Run coverage tests
	$Q mkdir -p $(COVERAGE_DIR)/coverage
	$Q cd $(BASE) && for pkg in $(TESTPKGS); do \
		$(GO) test \
			-coverpkg=$$($(GO) list -f '{{ join .Deps "\n" }}' $$pkg | \
					grep '^$(PACKAGE)/' | grep -v '^$(PACKAGE)/vendor/' | \
					tr '\n' ',')$$pkg \
			-covermode=$(COVERAGE_MODE) \
			-coverprofile="$(COVERAGE_DIR)/coverage/`echo $$pkg | tr "/" "-"`.cover" $$pkg ;\
	 done

# Container image
.PHONY: image
image: | $(BASE) ; $(info Building Docker image...)  ## Build conatiner image
	$(IMAGE_BUILDER) build -t $(TAG) -f $(DOCKERFILE)  $(CURDIR) $(IMAGE_BUILD_OPTS)


# Misc

.PHONY: clean
clean: ; $(info  Cleaning...)	 ## Cleanup everything
	@rm -rf $(GOPATH)
	@rm -rf $(BUILDDIR)
	@rm -rf  test

.PHONY: help
help: ## Show this message
	@grep -E '^[ a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'
