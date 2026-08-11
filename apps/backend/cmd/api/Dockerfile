# Build context is apps/backend. That is the reason the backend keeps its own
# deployments/ directory instead of sharing one at the repo root: the iOS app,
# the probe harness and 55MB of Xcode output never enter the build context.
FROM golang:1.26-alpine AS build

WORKDIR /src

# Copied first and cached separately, so a source-only change doesn't re-download
# the module graph.
COPY go.mod go.sum ./
RUN go mod download && go mod verify

COPY . .
RUN CGO_ENABLED=0 \
    go build -trimpath -ldflags="-s -w" \
    -o /out/app ./cmd/api

# scratch, not alpine: the binary is static and there is no shell to exec into,
# which is the point. Debugging goes through logs.
FROM scratch

# Needed to verify Prelude's TLS certificate; without it every verification send
# fails with an opaque x509 error.
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /out/app /usr/local/bin/app
# The server runs goose at boot, so the migrations ship in the image and the
# schema can never be older than the code that expects it.
COPY --from=build /src/deployments/migrations /deployments/migrations

USER 65532:65532
ENTRYPOINT ["/usr/local/bin/app"]
