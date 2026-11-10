FROM ubuntu:latest
# Optional: a closer Ubuntu mirror, e.g. http://azure.archive.ubuntu.com/ubuntu
ARG UBUNTU_MIRROR=
RUN if [ -n "$UBUNTU_MIRROR" ]; then \
      sed -i "s#http://archive.ubuntu.com/ubuntu#$UBUNTU_MIRROR#g; s#http://security.ubuntu.com/ubuntu#$UBUNTU_MIRROR#g" \
        /etc/apt/sources.list.d/ubuntu.sources; \
    fi
RUN apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=30 update \
 && DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=5 install -y --no-install-recommends tgt iproute2 \
 && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 3260
ENTRYPOINT ["/entrypoint.sh"]
