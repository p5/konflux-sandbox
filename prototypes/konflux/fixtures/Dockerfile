FROM docker.io/library/alpine:3.22.2@sha256:85f2b723e106c34644cd5851d7e81ee87da98ac54672b29947c052a45d31dc2f
COPY ec /usr/local/bin/ec
COPY kubectl /usr/local/bin/kubectl
COPY chains-public.pem /public/chains.pem
COPY policy /policy
USER 65532:65532
