# Build the soft_limit_req dynamic module against the nginx source, then run
# nginx with the produced .so. Version is pinned via the NGINX_VERSION build ARG.
FROM ubuntu:24.04

# Pinned nginx source version. 1.31.1 is the current mainline release and matches
# the tmp/nginx reference tree the module was forked against. Override at build
# time: --build-arg NGINX_VERSION=...
ARG NGINX_VERSION=1.31.1

RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl gcc make libc-dev \
        libpcre2-dev zlib1g-dev libssl-dev; \
    rm -rf /var/lib/apt/lists/*

# Module sources are copied into /src (the addon dir referenced by `config`).
COPY config /src/config
COPY src /src/src

# Fetch and unpack the pinned nginx source.
RUN set -eux; \
    mkdir -p /usr/src/nginx; \
    curl -fsSL "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" \
        -o /tmp/nginx.tar.gz; \
    tar -xzf /tmp/nginx.tar.gz -C /usr/src/nginx --strip-components=1; \
    rm /tmp/nginx.tar.gz

# Configure as a dynamic module build and produce the .so, then install nginx.
WORKDIR /usr/src/nginx
RUN set -eux; \
    ./configure \
        --prefix=/etc/nginx \
        --sbin-path=/usr/sbin/nginx \
        --conf-path=/etc/nginx/nginx.conf \
        --pid-path=/run/nginx.pid \
        --error-log-path=/var/log/nginx/error.log \
        --http-log-path=/var/log/nginx/access.log \
        --modules-path=/usr/lib/nginx/modules \
        --with-compat \
        --with-http_ssl_module \
        --with-http_realip_module \
        --add-dynamic-module=/src; \
    make modules; \
    make; \
    make install; \
    mkdir -p /usr/lib/nginx/modules; \
    cp objs/ngx_http_soft_limit_req_module.so /usr/lib/nginx/modules/; \
    mkdir -p /var/log/nginx

# Static content root for the soft-limited locations. Serving a real file makes
# requests reach the content phase (after PREACCESS) so the soft_limit_req
# handler actually runs — a `return 200` would finalize in the rewrite phase
# and skip PREACCESS entirely.
RUN set -eux; \
    mkdir -p /usr/share/test-html; \
    printf 'ok\n' > /usr/share/test-html/ok.txt

# Test config carrying load_module + a trivial server{} returning 200.
COPY test/conf/nginx.conf /etc/nginx/nginx.conf

EXPOSE 80
STOPSIGNAL SIGQUIT
CMD ["nginx", "-g", "daemon off;"]
