ARG ANGIE_VERSION=1.11.5

FROM alpine:3.21 AS build
ARG ANGIE_VERSION
RUN apk add --no-cache \
        build-base \
        linux-headers \
        pcre2-dev \
        zlib-dev \
        openssl-dev \
        curl

WORKDIR /src
RUN curl -fsSLO "https://download.angie.software/files/angie-${ANGIE_VERSION}.tar.gz" \
 && tar xzf "angie-${ANGIE_VERSION}.tar.gz" \
 && rm "angie-${ANGIE_VERSION}.tar.gz"

WORKDIR /src/angie-${ANGIE_VERSION}
RUN ./configure \
        --prefix=/usr/share/angie \
        --sbin-path=/usr/sbin/angie \
        --modules-path=/usr/lib/angie/modules \
        --conf-path=/etc/angie/angie.conf \
        --error-log-path=/var/log/angie/error.log \
        --http-log-path=/var/log/angie/access.log \
        --pid-path=/var/run/angie.pid \
        --lock-path=/var/run/angie.lock \
        --http-client-body-temp-path=/var/cache/angie/client_temp \
        --http-proxy-temp-path=/var/cache/angie/proxy_temp \
        --http-fastcgi-temp-path=/var/cache/angie/fastcgi_temp \
        --http-uwsgi-temp-path=/var/cache/angie/uwsgi_temp \
        --http-scgi-temp-path=/var/cache/angie/scgi_temp \
        --user=angie --group=angie \
        --with-pcre --with-pcre-jit \
        --with-threads \
        --with-file-aio \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_v3_module \
        --with-http_realip_module \
        --with-http_stub_status_module \
        --with-http_gzip_static_module \
        --with-http_sub_module \
        --with-http_auth_request_module \
        --with-stream \
        --with-stream_ssl_module \
 && make -j"$(nproc)" \
 && make install \
 && strip /usr/sbin/angie

FROM alpine:3.21
ARG ANGIE_VERSION
LABEL org.opencontainers.image.title="angie" \
      org.opencontainers.image.description="Angie ${ANGIE_VERSION} for linux/arm/v7" \
      org.opencontainers.image.source="https://github.com/jr551/angie-armv7"

RUN apk add --no-cache pcre2 zlib openssl tzdata ca-certificates \
 && addgroup -S angie \
 && adduser -S -D -H -G angie -s /sbin/nologin angie \
 && mkdir -p /var/log/angie /var/cache/angie /etc/angie \
 && chown -R angie:angie /var/log/angie /var/cache/angie

COPY --from=build /usr/sbin/angie /usr/sbin/angie
COPY --from=build /etc/angie/ /etc/angie/
COPY --from=build /usr/share/angie/ /usr/share/angie/

# log to stdout/stderr by default
RUN ln -sf /dev/stdout /var/log/angie/access.log \
 && ln -sf /dev/stderr /var/log/angie/error.log

EXPOSE 80 443
STOPSIGNAL SIGQUIT
CMD ["angie", "-g", "daemon off;"]
