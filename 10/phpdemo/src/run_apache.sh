mkdir -p /var/run/apache2
mkdir -p /var/lock/apache2
/usr/sbin/php-fpm -D
/usr/sbin/httpd -D FOREGROUND
