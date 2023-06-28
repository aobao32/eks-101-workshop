FROM public.ecr.aws/amazonlinux/amazonlinux:2

# Install apache/php
RUN yum install -y which curl httpd mysql htop net-tools gd procps-ng iputils bind-utils vim \
        && amazon-linux-extras install -y php7.4 \
        && yum install -y php-gd php-pecl-imagick php-mbstring php-xml php-xmlrpc \
        && yum clean all

# Install configuration file
ADD src/httpd.conf /etc/httpd/conf/
ADD src/run_apache.sh /root/
ADD src/index.php /var/www/html/

# Configure apache
RUN chown -R apache:apache /var/www
RUN chmod +x /root/run_apache.sh
ENV APACHE_RUN_USER apache
ENV APACHE_RUN_GROUP apache
ENV APACHE_LOG_DIR /var/log/apache2

EXPOSE 80

# starting script for php-fpm and httpd
CMD ["/bin/bash", "-c", "/root/run_apache.sh"]
