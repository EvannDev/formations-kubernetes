# Build and publish the training image.
#
#   make test    unit tests (inside a Go container, nothing to install)
#   make build   local images for this machine's architecture
#   make push    multi-arch images pushed to the registry
#   make list    published tags and their architectures
#
# Overridable: make push REGISTRY=ghcr.io/other/path VERSIONS="1.0"

REGISTRY   ?= ghcr.io/evanndev/formations-kubernetes/app
VERSIONS   ?= 1.0 1.1
PLATFORMS  ?= linux/amd64,linux/arm64
GO_VERSION ?= 1.27.1
BUILDER     = formations-kubernetes
SOURCE_REPO = https://github.com/EvannDev/formations-kubernetes

# Tag "1.O" (letter O) must never exist: workshop 5 relies on its absence.
ifneq ($(findstring O,$(VERSIONS)),)
$(error VERSIONS contient la lettre O : « $(VERSIONS) ». Le tag 1.O est réservé à l'atelier 5)
endif

.PHONY: help test build push builder list

help:
	@grep -E '^#   make' Makefile | sed 's/^#   //'

test:
	docker run --rm -v "$(CURDIR)":/src -w /src -e CGO_ENABLED=0 \
	  golang:$(GO_VERSION)-alpine3.24 sh -c 'gofmt -l . | (! grep .) && go vet ./... && go test -v ./...'

# Tags per version: <version> (shell) and <version>-distroless
build:
	@for v in $(VERSIONS); do \
	  docker buildx build --load --target shell      --build-arg VERSION=$$v -t $(REGISTRY):$$v . && \
	  docker buildx build --load --target distroless --build-arg VERSION=$$v -t $(REGISTRY):$$v-distroless . || exit 1; \
	done

# buildx builder able to produce several architectures
builder:
	@docker buildx inspect $(BUILDER) >/dev/null 2>&1 || \
	  docker buildx create --name $(BUILDER) --driver docker-container >/dev/null

# For multi-arch images, ghcr.io reads the source repository and description
# from the index annotations, not from the image LABELs: without them the
# package is not linked to the GitHub repository.
INDEX_ANNOTATIONS = \
  --annotation "index:org.opencontainers.image.source=$(SOURCE_REPO)" \
  --annotation "index:org.opencontainers.image.description=Application de la formation Kubernetes BDC"

push: builder
	@for v in $(VERSIONS); do \
	  docker buildx build --builder $(BUILDER) --platform $(PLATFORMS) --push $(INDEX_ANNOTATIONS) \
	    --target shell      --build-arg VERSION=$$v -t $(REGISTRY):$$v . && \
	  docker buildx build --builder $(BUILDER) --platform $(PLATFORMS) --push $(INDEX_ANNOTATIONS) \
	    --target distroless --build-arg VERSION=$$v -t $(REGISTRY):$$v-distroless . || exit 1; \
	done

list:
	@for v in $(VERSIONS); do for s in "" -distroless; do \
	  printf '%s ' "$(REGISTRY):$$v$$s"; \
	  docker buildx imagetools inspect "$(REGISTRY):$$v$$s" 2>/dev/null | grep -oE 'linux/[a-z0-9]+' | sort -u | tr '\n' ' '; \
	  echo; \
	done; done
