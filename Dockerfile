# syntax=docker/dockerfile:1

FROM nginxinc/nginx-unprivileged:stable-alpine

ARG APP_VERSION=dev

LABEL org.opencontainers.image.title="hello-nginx" \
      org.opencontainers.image.description="Hello World static site served by Nginx" \
      org.opencontainers.image.version="${APP_VERSION}"

COPY nginx/default.conf /etc/nginx/conf.d/default.conf
COPY app/ /usr/share/nginx/html/

USER root
RUN sed -i "s/__APP_VERSION__/${APP_VERSION}/g" /usr/share/nginx/html/index.html \
 && echo "${APP_VERSION}" > /usr/share/nginx/html/version.txt
USER 101

EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
