mkdir -p /var/run/apache2
mkdir -p /var/lock/apache2
mkdir -p /run/php
/usr/sbin/php-fpm --daemonize
/usr/sbin/apache2 -D FOREGROUND
