FROM docker.io/library/alpine:3.22.2@sha256:85f2b723e106c34644cd5851d7e81ee87da98ac54672b29947c052a45d31dc2f
COPY executor /usr/local/bin/executor
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/executor", "-serve"]
