# 实验四、在ARM架构上构建应用并使用ALB Ingress部署应用

EKS 1.36版本 @2026 AWS Global区域测试通过

## 一、关于多架构支持

前文的实验中，分别创建了两个Nodegroup，一个Nodegroup是使用X86_64架构Intel处理器的t3.xlarge(或m5.xlarge/m6i.xlarge)机型，另一个Nodegroup是使用Graviton处理器的ARM机型t4g.xlarge或m6g.xlarge。由于ARM架构的容器镜像和X86_64架构的容器镜像并不通用，因此本文会重新构建一个ARM版本的image，并上传到ECR镜像仓库中，再部署到节点组。

注意，如果您希望将一个应用同时运行在两种架构的节点上，则需要对同一个应用作两种架构的编译和构建。可参考[本文](https://aws.amazon.com/cn/blogs/china/how-to-easily-deploy-hybrid-architecture-nodes-on-eks/)配置。

执行如下命令可查看当前EKS集群的节点组Nodegroup所使用的处理器架构：

```
kubectl get nodes --label-columns=kubernetes.io/arch
```

返回结果如下，可看到最后一列就是对应的处理器机型，返回`amd64`表示是Intel或者AMD处理器的x86_64架构，返回`arm64`表示是Gravtion处理器的ARM架构。

```
NAME                                                STATUS   ROLES    AGE   VERSION               ARCH
ip-192-168-6-252.ap-southeast-1.compute.internal    Ready    <none>   45m   v1.36.1-eks-xxxxxxx   arm64
ip-192-168-60-2.ap-southeast-1.compute.internal     Ready    <none>   45m   v1.36.1-eks-xxxxxxx   arm64
ip-192-168-89-203.ap-southeast-1.compute.internal   Ready    <none>   45m   v1.36.1-eks-xxxxxxx   arm64
```

接下来为ARM架构构建镜像并上传到ECR。

## 二、使用外部镜像仓库上ARM架构的镜像拉起应用并使用ALB Ingress

### 1、确认外部镜像仓库的镜像支持ARM架构

使用外部镜像仓库时候，需要查询镜像仓库中的镜像是否支持多架构。例如访问：

[https://gallery.ecr.aws/nginx/nginx](https://gallery.ecr.aws/nginx/nginx)

在这个镜像中，可以看到说明信息是：`OS/Arch: Linux, x86-64, ARM 64`。这表示这个镜像支持两种架构。

### 2、构建应用配置文件并使用ALB做Ingress

构建如下一个配置文件，格式如下。注意替换里边的ECR容器镜像的完整URI地址，包含region、名称和版本号。这里可以看到`nodeSelector`是指定了使用ARM架构的Nodegroup来运行应用的。

```
---
apiVersion: v1
kind: Namespace
metadata:
  name: mydemo1
---
apiVersion: apps/v1
kind: Deployment
metadata:
  namespace: mydemo1
  name: nginx
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: nginx
  replicas: 3
  template:
    metadata:
      labels:
        app.kubernetes.io/name: nginx
    spec:
      containers:
      - image: public.ecr.aws/nginx/nginx:1.31-alpine-slim
        imagePullPolicy: Always
        name: nginx
        ports:
        - containerPort: 80
      nodeSelector:
        kubernetes.io/arch: arm64
---
apiVersion: v1
kind: Service
metadata:
  namespace: mydemo1
  name: nginx
spec:
  ports:
    - port: 80
      targetPort: 80
      protocol: TCP
  type: NodePort
  selector:
    app.kubernetes.io/name: nginx
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  namespace: mydemo1
  name: ingress-for-nginx-app
  labels:
    app: ingress-for-nginx-app
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
spec:
  ingressClassName: alb
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nginx
            port:
              number: 80
```

请替换以上yaml文件中，namespace、deployment、image、service、alb ingress等可替换为自己的标识。

将以上文件保存为`nginx-from-public-repo-arm.yaml`，然后从本地启动部署。

### 3、启动应用

```
kubectl apply -f nginx-from-public-repo-arm.yaml
```

即可启动应用。

### 4、验证启动成功检查访问环境

执行如下命令检查pod运行状态：

```
kubectl get pods -n mydemo1
```

返回结果：

```
NAME                    READY   STATUS    RESTARTS   AGE
nginx-f97c98cd5-9zxm6   1/1     Running   0          3m47s
nginx-f97c98cd5-tmxr6   1/1     Running   0          3m47s
nginx-f97c98cd5-z9spm   1/1     Running   0          3m47s
```

### 5、查看ALB Ingress入口

执行如下命令查看ALB Ingress入口：

```
kubectl get ingress -n mydemo1
```

返回结果：

```
NAME                    CLASS   HOSTS   ADDRESS                                                                       PORTS   AGE
ingress-for-nginx-app   alb     *       k8s-mydemo1-ingressf-7d07591635-1180464861.ap-southeast-1.elb.amazonaws.com   80      4m
```

使用浏览器访问上述ALB地址即可访问成功。

## 三、在ARM架构上构建应用并使用AWS ECR镜像仓库

### 1、基于Ubuntu 24.04构建容器

本节所构建的容器镜像以Canonical在ECR Public上发布的Ubuntu 24.04官方镜像为基础。选择该版本的依据是24.04属于长期支持版本（LTS，Long Term Support），其软件仓库内的Apache与PHP版本在整个支持周期内保持稳定，不会因为基础镜像的例行更新而发生主版本漂移，便于实验结果的复现。镜像地址为`public.ecr.aws/ubuntu/ubuntu:24.04`，该标签指向24.04系列的最新更新版本，当前实测解析到Ubuntu 24.04.5 LTS。

需要注意，同一仓库下另有指向更新发行版的标签以及`latest`标签，本实验必须显式指定`24.04`，不能使用`latest`，否则基础镜像会随Ubuntu发行节奏切换到新的发行版，导致后续的软件包名称与路径与本文不一致。

#### （1）创建构建容器的EC2

使用Amazon Linux 2023创建一个EC2作为构建机，机型选择`t4g.medium`（2vCPU/4GB），磁盘选择`gp3`类型20GB。构建机必须使用Graviton处理器的ARM机型，因为本文采用的是宿主机架构直接构建，构建产物的架构由构建机决定。

通过Session Manager或者SSH登陆到EC2后，执行如下命令：

```
sudo -i
yum update -y
yum install -y docker tmux
service docker start
systemctl enable docker
usermod -a -G docker ec2-user
```

即可安装好软件包。执行`docker version`可确认服务端版本与架构，实测返回Docker 25.0.16、架构`arm64`。

#### （2）编辑容器配置文件

创建`src`目录，进入`src`目录，并将如下内容保存为`run_apache.sh`脚本：

```
mkdir -p /var/run/apache2
mkdir -p /var/lock/apache2
mkdir -p /run/php
/usr/sbin/php-fpm --daemonize
/usr/sbin/apache2 -D FOREGROUND
```

脚本中的`/run/php`目录用于存放PHP-FPM的PID文件与Unix Socket文件，该目录位于`/run`之下，在容器每次启动时均为空，因此必须在启动脚本中创建而不能依赖镜像构建阶段。`--daemonize`参数使PHP-FPM以后台方式驻留，随后由前台运行的Apache进程作为容器主进程，保证容器的生命周期与Web服务一致。

在`src`目录之外的上一层目录，构建如下的配置文件，保存文件名为`Dockerfile`。

```
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
```

由此即可创建一个使用Ubuntu 24.04操作系统，并通过Apache提供Web服务，运行PHP 8.3环境的容器镜像。PHP将通过`run_apache.sh`脚本中的`php-fpm`服务启动。

上述`Dockerfile`中有若干处与Ubuntu的软件包组织方式直接相关，需要逐项说明。

`DEBIAN_FRONTEND=noninteractive`用于关闭APT的交互式提示。若不设置该变量，安装`apache2`时会因为时区配置向终端请求输入，导致构建过程挂起。

`php-fpm`是一个元包，在Ubuntu 24.04上会解析到`php8.3-fpm`，实测版本为8.3.6。`--no-install-recommends`用于跳过推荐依赖，可显著减小镜像体积。

`a2enmod proxy_fcgi setenvif`与`a2enconf php8.3-fpm`用于建立Apache与PHP-FPM之间的连接，这两条命令不可省略。Ubuntu的Apache不使用进程内的PHP模块，而是由`proxy_fcgi`模块把`.php`请求通过FastCGI协议转发给PHP-FPM监听的Unix Socket，该Socket路径为`/run/php/php8.3-fpm.sock`。安装`php-fpm`软件包时，其安装脚本仅以`NOTICE`形式提示需要执行上述两条命令，并不会自动执行。实测省略这两条命令的后果如下：`/etc/apache2/mods-enabled`下不存在`proxy_fcgi`，`/etc/apache2/conf-enabled`下不存在`php8.3-fpm.conf`，Apache不会把`.php`请求交给PHP-FPM，此时访问站点仍然返回`HTTP 200`，但响应体是`index.php`的源代码文本`<?php phpinfo(); ?>`而非渲染后的信息页。由于HTTP状态码正常，这类故障容易被误判为应用正常，排查时应以响应体内容而非状态码为依据。其中`setenvif`模块在Ubuntu的Apache中默认已处于启用状态，执行时会返回`Module setenvif already enabled`的提示，属于正常输出。

`ln -s /usr/sbin/php-fpm8.3 /usr/sbin/php-fpm`用于建立一个不含版本号的符号链接。Ubuntu安装的PHP-FPM可执行文件名为`/usr/sbin/php-fpm8.3`，带有版本号后缀，通过符号链接可使启动脚本不必绑定具体的PHP版本。

`rm -f /var/www/html/index.html`用于删除Apache的默认欢迎页。Ubuntu的Apache默认`DirectoryIndex`顺序中`index.html`优先于`index.php`，若不删除该文件，访问站点根路径时返回的将是Apache默认页而不是`phpinfo()`的输出。

六个`APACHE_`开头的环境变量在Ubuntu上是必需的。Ubuntu将这些变量定义在`/etc/apache2/envvars`中，该文件仅在通过`apache2ctl`启动时才会被加载，而本文的启动脚本直接调用`/usr/sbin/apache2`，因此必须在镜像中以环境变量形式提供。若缺少这些变量，Apache会因为无法解析`${APACHE_RUN_USER}`等占位符而拒绝启动。

追加`ServerName localhost`用于消除Apache启动时的`AH00558`告警。该告警本身不影响服务可用性，但会使容器日志出现无效信息，显式设置后容器日志为空。

#### （3）编译容器

执行如下命令：

```
docker build -t php-ubuntu .
```

构建成功。构建过程中会输出Apache模块与配置的启用信息，返回结果如下。

```
#5 26.22 Enabling module proxy.
#5 26.22 Enabling module proxy_fcgi.
#5 26.23 Module setenvif already enabled
#5 26.26 Enabling conf php8.3-fpm.
#9 exporting to image
#9 writing image sha256:40ff47430f33ebe6f3b4941a4c7c0923f9c096e4d744c77e5a46563e193eedfe done
#9 naming to docker.io/library/php-ubuntu done
```

执行`docker image ls`命令即可看到构建好的容器的信息。返回结果如下。

```
REPOSITORY                     TAG       IMAGE ID       CREATED        SIZE
php-ubuntu                     latest    40ff47430f33   1 second ago   270MB
public.ecr.aws/ubuntu/ubuntu   24.04     8494c74ca40f   7 days ago     101MB
```

在推送到镜像仓库之前，建议先在构建机上做一次本地验证，确认Apache与PHP-FPM均已正常启动。执行如下命令：

```
docker run -d --name utest -p 8080:80 php-ubuntu
curl -s http://127.0.0.1:8080/ | grep -oE '<title>[^<]*</title>'
```

返回结果如下，表示PHP解析正常：

```
<title>PHP 8.3.6 - phpinfo()</title>
```

执行`docker logs utest`应无任何输出，表示Apache启动过程中没有产生告警。验证完毕后执行`docker rm -f utest`删除测试容器。

#### （4）在ECR上创建镜像仓库

注意：此步骤不可跳过。如果没有实现创建镜像仓库，那么在开发环境做`docker push`时候就会报错，不会自动创建镜像仓库。

进入AWS控制台，进入ECR服务，创建一个新的仓库，选择类型为私有`Private`，取名为`mydemo3`。在创建仓库的向导页面下方，在`Tag immutability`的开关设置为启用，在`Scan on push`的开关设置为启用。然后点击创建。

创建完毕后，在镜像仓库的`URI`位置即可看到仓库的名称类似`133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/mydemo3`的地址。

注意：启用`Tag immutability`后，同一个标签不允许被内容不同的镜像覆盖。若在后续调试中修改了`Dockerfile`并重新构建，再次向`latest`标签推送会被拒绝，返回`tag invalid: The image tag 'latest' already exists in the 'mydemo3' repository and cannot be overwritten because the tag is immutable.`。需要迭代镜像时，应改用带版本号的标签（例如`v1`、`v2`），或者在创建仓库时关闭该开关。

#### （5）在开发环境上配置AKSK并登陆ECR容器镜像仓库

首先在开发环境上配置AWSCLI。配置好AKSK密钥后，执行如下命令登陆到ECR容器镜像仓库。注意替换对应的region代号。

```
aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com
```

请替换对应的AWS Account ID（12位数字账号）和操作的Region为当前环境的真实值。

返回如下结果表示登陆成功。

```
WARNING! Your password will be stored unencrypted in /root/.docker/config.json.
Configure a credential helper to remove this warning. See
https://docs.docker.com/engine/reference/commandline/login/#credentials-store

Login Succeeded
```

#### （6）从开发环境上推送构建好的容器到ECR镜像仓库

请替换如下命令中的容器名称、ECR地址为实际名称和地址。

```
docker tag php-ubuntu:latest 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/mydemo3:latest
docker push 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/mydemo3:latest
```

操作成功的话返回如下：

```
The push refers to repository [133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/mydemo3]
5c6c39ff4dbf: Pushed
148bd1e943ba: Pushed
b8a2ab024093: Pushed
8edaba054542: Pushed
375f9ca9fee5: Pushed
latest: digest: sha256:899c8182a986615c7092185c95b6fe06ded518e3d405d036bf4c0b2374e5d5bc size: 1363
```

#### （7）获得ECR上镜像仓库的地址

再次进入ECR容器镜像仓库，找到刚才创建的仓库`mydemo3`，进入后可以看到URI的完整地址和版本如下：

```
133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/mydemo3:latest
```

注意，不同region的代号对应的地址不一样，并且注意最后要包含版本号。

至此，一个面向Graviton处理器的容器镜像已经上传到ECR上。下面转向在EKS上部署该镜像。

### 2、编写要在EKS上使用的应用的yaml文件

格式如下。注意替换里边的ECR容器镜像的完整URI地址，包含region、名称和版本号。

```
---
apiVersion: v1
kind: Namespace
metadata:
  name: mydemo3
---
apiVersion: apps/v1
kind: Deployment
metadata:
  namespace: mydemo3
  name: php-ubuntu
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: php-ubuntu
  replicas: 3
  template:
    metadata:
      labels:
        app.kubernetes.io/name: php-ubuntu
    spec:
      containers:
      - image: 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/mydemo3:latest
        imagePullPolicy: Always
        name: php-ubuntu
        ports:
        - containerPort: 80
      nodeSelector:
        kubernetes.io/arch: arm64
---
apiVersion: v1
kind: Service
metadata:
  namespace: mydemo3
  name: php-ubuntu
spec:
  ports:
    - port: 80
      targetPort: 80
      protocol: TCP
  type: NodePort
  selector:
    app.kubernetes.io/name: php-ubuntu
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  namespace: mydemo3
  name: ingress-for-php-ubuntu-app
  labels:
    app: ingress-for-php-ubuntu-app
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
spec:
  ingressClassName: alb
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: php-ubuntu
            port:
              number: 80
```

请替换以上yaml文件中的镜像仓库、镜像名称、版本，以及对应EKS部署的namespace、deployment、image、service、alb ingress等参数，可替换为实际使用的标识。

将以上文件保存为`php-ubuntu-arm.yaml`，然后从本地启动部署。

### 3、启动应用

```
kubectl apply -f php-ubuntu-arm.yaml
```

即可启动应用。返回结果如下：

```
namespace/mydemo3 created
deployment.apps/php-ubuntu created
service/php-ubuntu created
ingress.networking.k8s.io/ingress-for-php-ubuntu-app created
```

### 4、验证启动成功检查访问环境

执行如下命令检查pod运行状态：

```
kubectl get pods -n mydemo3
```

返回结果：

```
NAME                          READY   STATUS    RESTARTS   AGE
php-ubuntu-64df754cd6-g4bsb   1/1     Running   0          23s
php-ubuntu-64df754cd6-pb6mk   1/1     Running   0          23s
php-ubuntu-64df754cd6-xlsm9   1/1     Running   0          23s
```

### 5、查看ALB Ingress入口

执行如下命令查看ALB Ingress入口：

```
kubectl get ingress -n mydemo3
```

返回结果：

```
NAME                         CLASS   HOSTS   ADDRESS                                                                      PORTS   AGE
ingress-for-php-ubuntu-app   alb     *       k8s-mydemo3-ingressf-8025f36a7b-686691352.ap-southeast-1.elb.amazonaws.com   80      23s
```

使用浏览器访问上述ALB地址即可访问成功。

注意：`ADDRESS`列中的ALB域名在执行`kubectl apply`后约二十秒即会出现，但此时ALB仍处于`provisioning`状态，直接访问会因为DNS尚未生效而连接失败。实测需要再等待约一分钟，待ALB转为`active`且目标组健康检查通过后才能访问成功。

访问成功后页面显示的是`phpinfo()`的输出。可通过如下命令从命令行确认关键信息：

```
curl -sI http://上文获取到的ALB入口地址
```

返回结果如下，`Server`字段表明Web服务由Ubuntu发行版的Apache提供：

```
HTTP/1.1 200 OK
Content-Type: text/html; charset=UTF-8
Server: Apache/2.4.58 (Ubuntu)
```

在`phpinfo()`页面中，`System`行包含`aarch64`，表明应用运行在Graviton处理器的节点上；`Server API`行为`FPM/FastCGI`，表明PHP请求确实由PHP-FPM处理而非Apache进程内模块。

## 四、删除运行中的ARM架构的容器Pod和ALB Ingress的实验环境（可选）

执行如下命令删除刚才创建的两个应用：

```
kubectl delete -f nginx-from-public-repo-arm.yaml
kubectl delete -f php-ubuntu-arm.yaml
```

删除Service与Ingress后，AWS Load Balancer Controller会自动回收对应的两个ALB。此外，本实验中作为构建机创建的EC2在镜像推送完成后即可终止，ECR上的`mydemo3`仓库如不再使用也可一并删除。

实验完成。

## 五、参考文档

AWS Load Balancer Controller Ingress annotations 参数说明

[https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.13/guide/ingress/annotations/]()

AWS Load Balancer Controller Ingress specification 参数说明

[https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.13/guide/ingress/spec/]()

手把手教你如何在 EKS 上轻松部署混合架构节点

[https://aws.amazon.com/cn/blogs/china/how-to-easily-deploy-hybrid-architecture-nodes-on-eks/]()

Canonical在ECR Public上发布的Ubuntu官方容器镜像，可查看各标签所支持的处理器架构

[https://gallery.ecr.aws/ubuntu/ubuntu](https://gallery.ecr.aws/ubuntu/ubuntu)

Ubuntu 24.04 LTS（Noble Numbat）官方发布说明

[https://discourse.ubuntu.com/t/noble-numbat-release-notes/39890](https://discourse.ubuntu.com/t/noble-numbat-release-notes/39890)

Ubuntu发行版生命周期，用于确认LTS版本的支持截止时间

[https://ubuntu.com/about/release-cycle](https://ubuntu.com/about/release-cycle)

Apache HTTP Server的mod_proxy_fcgi模块说明，即Apache向PHP-FPM转发请求所依赖的模块

[https://httpd.apache.org/docs/2.4/mod/mod_proxy_fcgi.html](https://httpd.apache.org/docs/2.4/mod/mod_proxy_fcgi.html)

Amazon ECR关于防止镜像标签被覆盖的官方文档

[https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-tag-mutability.html](https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-tag-mutability.html)