FROM alpine:3.18.3

ARG ALPINE_PACKAGES="php82-iconv php82-pdo_mysql php82-pdo_pgsql php82-openssl php82-simplexml"
ARG COMPOSER_PACKAGES="aws/aws-sdk-php google/cloud-storage"
ARG PBURL=https://github.com/PrivateBin/PrivateBin/
ARG RELEASE=1.5.2
ARG UID=65534
ARG GID=82

ENV CONFIG_PATH=/srv/cfg
ENV PATH=$PATH:/srv/bin

LABEL org.opencontainers.image.authors=support@privatebin.org \
      org.opencontainers.image.vendor=PrivateBin \
      org.opencontainers.image.documentation=https://github.com/PrivateBin/docker-nginx-fpm-alpine/blob/master/README.md \
      org.opencontainers.image.source=https://github.com/PrivateBin/docker-nginx-fpm-alpine \
      org.opencontainers.image.licenses=zlib-acknowledgement \
      org.opencontainers.image.version=${RELEASE}

COPY release.asc /tmp/

RUN \
# Prepare composer dependencies
    ALPINE_PACKAGES="$(echo ${ALPINE_PACKAGES} | sed 's/,/ /g')" ;\
    ALPINE_COMPOSER_PACKAGES="" ;\
    if [ -n "${COMPOSER_PACKAGES}" ] ; then \
        ALPINE_COMPOSER_PACKAGES="php82-phar" ;\
        if [ -n "${ALPINE_PACKAGES##*php82-curl*}" ] ; then \
            ALPINE_COMPOSER_PACKAGES="php82-curl ${ALPINE_COMPOSER_PACKAGES}" ;\
        fi ;\
        if [ -n "${ALPINE_PACKAGES##*php82-mbstring*}" ] ; then \
            ALPINE_COMPOSER_PACKAGES="php82-mbstring ${ALPINE_COMPOSER_PACKAGES}" ;\
        fi ;\
        RAWURL="$(echo ${PBURL} | sed s/github.com/raw.githubusercontent.com/)" ;\
    fi \
# Install dependencies
    && apk upgrade --no-cache \
    && apk add --no-cache gnupg git nginx php82 php82-fpm php82-gd php82-opcache \
        s6 tzdata ${ALPINE_PACKAGES} ${ALPINE_COMPOSER_PACKAGES} \
# Stabilize php config location
    && mv /etc/php82 /etc/php \
    && ln -s /etc/php /etc/php82 \
    && ln -s $(which php82) /usr/local/bin/php \
# Remove (some of the) default nginx & php config
    && rm -f /etc/nginx.conf /etc/nginx/http.d/default.conf /etc/php/php-fpm.d/www.conf \
    && rm -rf /etc/nginx/sites-* \
# Ensure nginx logs, even if the config has errors, are written to stderr
    && ln -s /dev/stderr /var/log/nginx/error.log \
# Install PrivateBin
    && cd /tmp \
    && export GNUPGHOME="$(mktemp -d -p /tmp)" \
    && gpg2 --list-public-keys || /bin/true \
    && gpg2 --import /tmp/release.asc \
    && rm -rf /var/www/* \
    && if expr "${RELEASE}" : '[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}$' >/dev/null ; then \
         echo "getting release ${RELEASE}"; \
         wget -qO ${RELEASE}.tar.gz.asc ${PBURL}releases/download/${RELEASE}/PrivateBin-${RELEASE}.tar.gz.asc \
         && wget -q ${PBURL}archive/${RELEASE}.tar.gz \
         && gpg2 --verify ${RELEASE}.tar.gz.asc ; \
       else \
         echo "getting tarball for ${RELEASE}"; \
         git clone ${PBURL%%/}.git -b ${RELEASE}; \
         (cd $(basename ${PBURL}) && git archive --prefix ${RELEASE}/ --format tgz ${RELEASE} > /tmp/${RELEASE}.tar.gz); \
       fi \
    && if [ -n "${COMPOSER_PACKAGES}" ] ; then \
        wget -qO composer-installer.php https://getcomposer.org/installer \
        && php composer-installer.php --install-dir=/usr/local/bin --filename=composer ;\
    fi \
    && cd /var/www \
    && tar -xzf /tmp/${RELEASE}.tar.gz --strip 1 \
    && if [ -n "${COMPOSER_PACKAGES}" ] ; then \
        wget -q ${RAWURL}${RELEASE}/composer.json \
        && wget -q ${RAWURL}${RELEASE}/composer.lock \
        && composer remove --dev --no-update phpunit/phpunit \
        && composer require --no-update ${COMPOSER_PACKAGES} \
        && composer update --no-dev --optimize-autoloader \
        rm composer.* /usr/local/bin/* ;\
    fi \
    && rm *.md cfg/conf.sample.php \
    && mv bin cfg lib tpl vendor /srv \
    && mkdir -p /srv/data \
    && sed -i "s#define('PATH', '');#define('PATH', '/srv/');#" index.php \
# Support running s6 under a non-root user
    && mkdir -p /etc/s6/services/nginx/supervise /etc/s6/services/php-fpm82/supervise \
    && mkfifo \
        /etc/s6/services/nginx/supervise/control \
        /etc/s6/services/php-fpm82/supervise/control \
    && chown -R ${UID}:${GID} /etc/s6 /run /srv/* /var/lib/nginx /var/www \
    && chmod o+rwx /run /var/lib/nginx /var/lib/nginx/tmp \
# Clean up
    && gpgconf --kill gpg-agent \
    && rm -rf /tmp/* \
    && apk del --no-cache gnupg git ${ALPINE_COMPOSER_PACKAGES}

COPY etc/ /etc/

WORKDIR /var/www
# user nobody, group www-data
USER ${UID}:${GID}

# mark dirs as volumes that need to be writable, allows running the container --read-only
VOLUME /run /srv/data /tmp /var/lib/nginx/tmp

EXPOSE 8080

ENTRYPOINT ["/etc/init.d/rc.local"]
