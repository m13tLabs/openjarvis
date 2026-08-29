# OpenJarvis server, installed from the published PyPI release.
#
# The pinned version lives in JARVIS_VERSION so Renovate's Dockerfile _VERSION
# custom manager (github>m13tLabs/renovate-config) can bump it automatically.
FROM python:3.12-slim AS builder

# renovate: datasource=pypi depName=openjarvis versioning=pep440
ENV JARVIS_VERSION=1.0.3

RUN pip install --no-cache-dir uv && \
    uv pip install --system "openjarvis[server]==${JARVIS_VERSION}"

FROM python:3.12-slim

ARG BUILD_DATE
ARG APP_VERSION

LABEL org.opencontainers.image.authors='Martin Reinhardt (martin@m13t.de)' \
    org.opencontainers.image.created=$BUILD_DATE \
    org.opencontainers.image.version=$APP_VERSION \
    org.opencontainers.image.url='https://hub.docker.com/r/m13t/openjarvis' \
    org.opencontainers.image.documentation='https://github.com/m13tLabs/openjarvis' \
    org.opencontainers.image.source='https://github.com/m13tLabs/openjarvis.git' \
    org.opencontainers.image.licenses='MIT'

COPY --from=builder /usr/local /usr/local
WORKDIR /app

EXPOSE 8000

ENTRYPOINT ["jarvis"]
CMD ["serve", "--host", "0.0.0.0", "--port", "8000"]
