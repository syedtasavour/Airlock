# Egress whitelist proxy for the airlock sandbox.
# The untrusted sandbox has NO direct internet — it can only reach this proxy,
# which forwards a request ONLY if its host matches an allow-rule in `filter`.
# Latest Alpine 3.x and tinyproxy; AIRLOCK_REFRESH (set by `airlock update`)
# forces a fresh `apk add` instead of a cached layer.
FROM alpine:3
ARG AIRLOCK_REFRESH=0
RUN apk upgrade --no-cache && apk add --no-cache tinyproxy

COPY tinyproxy.conf /etc/tinyproxy/tinyproxy.conf
COPY filter         /etc/tinyproxy/filter

EXPOSE 8888
# Run in the foreground so the container stays alive.
CMD ["tinyproxy", "-d", "-c", "/etc/tinyproxy/tinyproxy.conf"]
