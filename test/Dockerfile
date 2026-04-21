# Build context: project root (`docker build -f test/Dockerfile .`).
#
# Bakes the static parts of a DevVMSetup test container: debian:trixie,
# sudo + ca-certificates, a passwordless-sudo `tester` user, and an
# entrypoint that handles runtime bits (host-docker-GID match, copying
# the bind-mounted project into the tester's home). Used by both
# `test.sh --e2e` and `test2.sh`.

FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        sudo \
        ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m -s /bin/bash tester \
 && echo 'tester ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tester \
 && chmod 0440 /etc/sudoers.d/tester

COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

USER tester
WORKDIR /home/tester
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
