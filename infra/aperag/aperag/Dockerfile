ARG APERAG_BASE_IMAGE=docker.io/apecloud/aperag:v0.0.0-nightly
FROM ${APERAG_BASE_IMAGE}

COPY patches/patch_reconciler.py /tmp/liquidation-patch-reconciler.py
RUN python /tmp/liquidation-patch-reconciler.py && rm /tmp/liquidation-patch-reconciler.py

LABEL org.opencontainers.image.title="LIQUIDATION patched ApeRAG"
LABEL org.opencontainers.image.description="Project-owned ApeRAG image with document status race fix"
