ARG BUILD_FROM
FROM $BUILD_FROM
RUN apk add --no-cache libusb libftdi1 mosquitto-clients jq
# ectool: Chromium OS EC tool, chrultrabook musl build
# https://files.tree123.org/utils/x86_64/musl/ectool (see ectool.LICENSE)
COPY ectool /usr/bin/ectool
COPY run.sh /run.sh
RUN echo "0d6b4902066c28a2baff497f3abf760690b0c1e1f3d94d49c70e78a2c7e5b3ca  /usr/bin/ectool" | sha256sum -c - \
    && chmod 755 /run.sh /usr/bin/ectool
CMD [ "/run.sh" ]
