ARG ZITI_VERSION=latest
FROM openziti/quickstart:${ZITI_VERSION}

USER root
COPY run-router-mgmt.sh /var/openziti/scripts/run-router-mgmt.sh
RUN chmod 755 /var/openziti/scripts/run-router-mgmt.sh
USER ziti

ENTRYPOINT ["/bin/bash", "/var/openziti/scripts/run-router-mgmt.sh"]
