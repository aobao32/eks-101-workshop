FROM public.ecr.aws/ubuntu/ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    apache2 \
    php-fpm \
 && a2enmod proxy_fcgi setenvif remoteip \
 && a2enconf php8.3-fpm \
 && ln -s /usr/sbin/php-fpm8.3 /usr/sbin/php-fpm \
 && rm -rf /var/lib/apt/lists/*

ARG ENABLE_PROXY_PROTOCOL=false
COPY src/index.php /var/www/html/index.php
COPY src/run_apache.sh /root/run_apache.sh
COPY src/remoteip.conf /etc/apache2/conf-available/remoteip.conf

RUN rm -f /var/www/html/index.html \
 && chown -R www-data:www-data /var/www \
 && chmod +x /root/run_apache.sh \
 && echo "ServerName localhost" >> /etc/apache2/apache2.conf \
 && if [ "$ENABLE_PROXY_PROTOCOL" = "true" ]; then a2enconf remoteip; fi

ENV APACHE_RUN_USER=www-data
ENV APACHE_RUN_GROUP=www-data
ENV APACHE_RUN_DIR=/var/run/apache2
ENV APACHE_LOCK_DIR=/var/lock/apache2
ENV APACHE_LOG_DIR=/var/log/apache2
ENV APACHE_PID_FILE=/var/run/apache2/apache2.pid

EXPOSE 80

CMD ["/bin/bash", "-c", "/root/run_apache.sh"]
