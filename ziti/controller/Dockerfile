ARG ZITI_VERSION=latest
FROM openziti/quickstart:${ZITI_VERSION}

USER root
COPY run-controller-hardened.sh /var/openziti/scripts/run-controller-hardened.sh
RUN chmod 755 /var/openziti/scripts/run-controller-hardened.sh
USER ziti

ENTRYPOINT ["/var/openziti/scripts/run-controller-hardened.sh"]
