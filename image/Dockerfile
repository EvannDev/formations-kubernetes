# syntax=docker/dockerfile:1
#
# Training image formations-kubernetes/app — two variants, selected with --target:
#   shell       Alpine: sh, wget, nslookup available (F1, F2)
#   distroless  no shell, no tools (F3)
# See the Makefile for building and publishing.

ARG GO_VERSION=1.27.1

# --- Build (on the host architecture, cross-compiled binary) -------------------
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine3.24 AS build
ARG TARGETOS
ARG TARGETARCH
ARG VERSION=dev
# Static binary: no dependency on the final image libc
ENV CGO_ENABLED=0
WORKDIR /src
COPY go.mod ./
COPY *.go ./
# No image if a test fails
RUN go vet ./... && go test ./...
RUN GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /app .

# --- distroless variant (F3) -----------------------------------------------------
FROM gcr.io/distroless/static-debian13:nonroot AS distroless
LABEL org.opencontainers.image.source="https://github.com/EvannDev/formations-kubernetes"
LABEL org.opencontainers.image.description="Application de la formation Kubernetes BDC (variante distroless)"
COPY --from=build /app /app
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/app"]

# --- shell variant (F1, F2) — default target -------------------------------------
FROM alpine:3.24.2 AS shell
LABEL org.opencontainers.image.source="https://github.com/EvannDev/formations-kubernetes"
LABEL org.opencontainers.image.description="Application de la formation Kubernetes BDC (variante shell)"
# Non-root user, same UID as the distroless variant
RUN addgroup -S -g 65532 app && adduser -S -D -H -u 65532 -G app app
COPY --from=build /app /usr/local/bin/app
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/app"]
