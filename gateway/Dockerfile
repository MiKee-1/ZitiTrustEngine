FROM python:3.12-slim

WORKDIR /app

# osquery (osqueryd daemon and osqueryi CLI): the "declared vs observed" log
# source. osqueryd runs the scheduled queries in osquery.conf (osqueryd.sh).
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates gnupg \
    && curl -fsSL -o /tmp/osquery.deb https://pkg.osquery.io/deb/osquery_5.14.1-1.linux_amd64.deb \
    && apt-get install -y /tmp/osquery.deb \
    && rm -f /tmp/osquery.deb \
    && rm -rf /var/lib/apt/lists/*

# ziti-edge-tunnel, from the official OpenZiti package repo. The tunneler is
# published only under the Ubuntu "jammy" suite (none for Debian bookworm),
# which is what OpenZiti's own docs point Debian hosts to as well. Runs inside the
# gateway container itself (not as a sidecar): process posture checks are
# evaluated by the tunneler, so it has to share the PID namespace of the
# processes it reports on - like a real gateway, one host running tunneler,
# polling script and osquery together.
ARG ZITI_TUNNEL_VERSION=1.18.7
RUN curl -fsSL https://get.openziti.io/tun/package-repos.gpg \
      | gpg --dearmor -o /usr/share/keyrings/openziti.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/openziti.gpg] https://packages.openziti.org/zitipax-openziti-deb-stable jammy main" \
      > /etc/apt/sources.list.d/openziti.list \
    && apt-get update && apt-get install -y --no-install-recommends ziti-edge-tunnel=${ZITI_TUNNEL_VERSION} \
    && rm -rf /var/lib/apt/lists/*

# Dedicated copy of the Python interpreter for the polling loop: the process
# posture check (ziti/setup/setup.sh) matches the executable path, so the
# poller must run under a path that no other Python script uses.
RUN cp /usr/local/bin/python3.12 /usr/local/bin/gateway-poller

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY test_dial.py poller.py entrypoint.sh osqueryd.sh osquery.conf osquery.flags ./

ENTRYPOINT ["bash", "/app/entrypoint.sh"]
