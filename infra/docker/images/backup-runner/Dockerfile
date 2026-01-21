FROM alpine:3.20

RUN apk add --no-cache ca-certificates curl bash postgresql-client coreutils tar gzip
RUN curl -fsSL -o /usr/local/bin/kubectl https://dl.k8s.io/release/v1.30.0/bin/linux/amd64/kubectl \
  && chmod +x /usr/local/bin/kubectl

WORKDIR /work
ENTRYPOINT ["/bin/sh","-lc"]
