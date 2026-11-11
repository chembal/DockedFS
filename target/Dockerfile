FROM ubuntu:latest
# Optional: a closer Ubuntu mirror, e.g. http://azure.archive.ubuntu.com/ubuntu
ARG UBUNTU_MIRROR=
RUN if [ -n "$UBUNTU_MIRROR" ]; then \
      sed -i -E "s#https?://(archive|security)\.ubuntu\.com/ubuntu/?#$UBUNTU_MIRROR/#g" \
        /etc/apt/sources.list.d/ubuntu.sources; \
    fi; grep URIs /etc/apt/sources.list.d/ubuntu.sources
# apt-get update exits 0 even when every index fails; --error-on=any plus a retry
# loop turns a flaky mirror into a slower build instead of a broken one.
RUN for i in 1 2 3 4 5; do \
      apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 --error-on=any update && break; \
      echo "apt-get update failed (attempt $i), retrying"; sleep 15; \
    done \
 && DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=5 install -y --no-install-recommends tgt iproute2 iptables util-linux \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --no-create-home --shell /usr/sbin/nologin tgt
COPY entrypoint.sh firewall.sh /
RUN chmod +x /entrypoint.sh /firewall.sh
EXPOSE 3260
ENTRYPOINT ["/entrypoint.sh"]
