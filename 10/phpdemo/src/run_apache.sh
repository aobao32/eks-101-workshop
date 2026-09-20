#!/bin/bash
mkdir -p /var/run/apache2 /var/lock/apache2 /run/php
/usr/sbin/php-fpm --daemonize
exec /usr/sbin/apache2 -D FOREGROUND
