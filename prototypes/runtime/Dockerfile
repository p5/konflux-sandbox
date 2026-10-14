FROM debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587
RUN apt-get update && apt-get install -y --no-install-recommends socat && rm -rf /var/lib/apt/lists/*
COPY sandboxd /usr/local/bin/sandboxd
RUN mkdir -p /workspace && chown 1000:1000 /workspace
USER 1000:1000
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/sandboxd"]
