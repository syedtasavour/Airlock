# Egress whitelist proxy for the airlock sandbox.
# The untrusted sandbox has NO direct internet — it can only reach this proxy,
# which forwards a request ONLY if its host matches an allow-rule in `filter`.
FROM alpine:3.20

RUN apk add --no-cache tinyproxy

COPY tinyproxy.conf /etc/tinyproxy/tinyproxy.conf
COPY filter         /etc/tinyproxy/filter

EXPOSE 8888
# Run in the foreground so the container stays alive.
CMD ["tinyproxy", "-d", "-c", "/etc/tinyproxy/tinyproxy.conf"]
