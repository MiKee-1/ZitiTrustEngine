FROM python:3.12-slim

WORKDIR /app

# osquery CLI, used to produce the "declared posture vs observed" log source.
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
RUN curl -fsSL https://get.openziti.io/tun/package-repos.gpg \
      | gpg --dearmor -o /usr/share/keyrings/openziti.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/openziti.gpg] https://packages.openziti.org/zitipax-openziti-deb-stable jammy main" \
      > /etc/apt/sources.list.d/openziti.list \
    && apt-get update && apt-get install -y --no-install-recommends ziti-edge-tunnel \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY test_dial.py entrypoint.sh ./

ENTRYPOINT ["bash", "/app/entrypoint.sh"]
