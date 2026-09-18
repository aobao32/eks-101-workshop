FROM public.ecr.aws/ubuntu/ubuntu:24.04

# Install dependencies
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    apache2 \
    php-fpm \
 && a2enmod proxy_fcgi setenvif \
 && a2enconf php8.3-fpm \
 && ln -s /usr/sbin/php-fpm8.3 /usr/sbin/php-fpm \
 && rm -rf /var/lib/apt/lists/*

# Install app
COPY src/run_apache.sh /root/
RUN echo "<?php phpinfo(); ?>" > /var/www/html/index.php \
 && rm -f /var/www/html/index.html \
 && chown -R www-data:www-data /var/www \
 && chmod +x /root/run_apache.sh

# Configure apache
ENV APACHE_RUN_USER=www-data
ENV APACHE_RUN_GROUP=www-data
ENV APACHE_RUN_DIR=/var/run/apache2
ENV APACHE_LOCK_DIR=/var/lock/apache2
ENV APACHE_LOG_DIR=/var/log/apache2
ENV APACHE_PID_FILE=/var/run/apache2/apache2.pid
RUN echo "ServerName localhost" >> /etc/apache2/apache2.conf

EXPOSE 80

# starting script for php-fpm and apache2
CMD ["/bin/bash", "-c", "/root/run_apache.sh"]
