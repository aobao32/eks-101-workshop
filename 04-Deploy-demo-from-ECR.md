# 实验四、在ARM架构上构建应用并使用ALB Ingress

## 一、关于多架构支持

前文的实验中，分别创建了两个Nodegroup，一个Nodegroup是使用X86_64架构Intel处理器的t3.xlarge(或m5.xlarge)机型，另一个Nodegroup是使用Graviton处理器的ARM机型t4g.xlarge或m6g.xlarge。

执行如下命令可查看Nodegroup和对应架构：

```
kubectl get nodes --label-columns=kubernetes.io/arch
```

返回结果如下，可看到最后一列就是对应的机型。

```
NAME                                                STATUS   ROLES    AGE    VERSION               ARCH
ip-192-168-0-137.ap-southeast-1.compute.internal    Ready    <none>   169m   v1.27.1-eks-2f008fe   arm64
ip-192-168-28-249.ap-southeast-1.compute.internal   Ready    <none>   3h4m   v1.27.1-eks-2f008fe   amd64
ip-192-168-39-199.ap-southeast-1.compute.internal   Ready    <none>   169m   v1.27.1-eks-2f008fe   arm64
ip-192-168-54-35.ap-southeast-1.compute.internal    Ready    <none>   3h4m   v1.27.1-eks-2f008fe   amd64
ip-192-168-76-179.ap-southeast-1.compute.internal   Ready    <none>   169m   v1.27.1-eks-2f008fe   arm64
ip-192-168-81-178.ap-southeast-1.compute.internal   Ready    <none>   3h4m   v1.27.1-eks-2f008fe   amd64
```

现在分别在这两种不同架构的集群运行应用。

注意，如果您希望将一个应用同时运行在两种架构的节点上，则需要对同一个应用作两种架构的编译和构建。可参考[本文](https://aws.amazon.com/cn/blogs/china/how-to-easily-deploy-hybrid-architecture-nodes-on-eks/)配置。

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
      - image: public.ecr.aws/nginx/nginx:1.24-alpine-slim
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

### 1、在Amazon Linux 2023上构建容器

#### （1）创建构建容器的EC2

使用Amazon Linux 2023创建一个EC2，机型选择`t4g.medium`（2vCPU/4GB），磁盘选择`gp3`类型20GB。

通过Session Manager或者SSH登陆到EC2后，执行如下命令：

```
sudo -i
yum update -y
yum install -y docker
service docker start
usermod -a -G docker ec2-user
```

即可安装好软件包。

#### （2）编辑容器配置文件

创建`src`目录，并将如下内容保存为`run_apache.sh`脚本：

```
mkdir -p /var/run/apache2
mkdir -p /var/lock/apache2
/usr/sbin/php-fpm -D
/usr/sbin/httpd -D FOREGROUND
```

在`src`目录之外的上一层目录，构建如下的配置文件，保存文件名为`Dockerfile`。

```
FROM public.ecr.aws/amazonlinux/amazonlinux:2023
# Install dependencies
RUN yum install -y \
    httpd \
    php \
 && ln -s /usr/sbin/httpd /usr/sbin/apache2

# Install app
ADD src/run_apache.sh /root/
RUN echo "<?php phpinfo(); ?>" > /var/www/html/index.php \
 && mkdir /run/php-fpm/ \
 && chown -R apache:apache /var/www \
 && chmod +x /root/run_apache.sh

# Configure apache
ENV APACHE_RUN_USER apache
ENV APACHE_RUN_GROUP apache
ENV APACHE_LOG_DIR /var/log/apache2

EXPOSE 80

# starting script for php-fpm and httpd
CMD ["/bin/bash", "-c", "/root/run_apache.sh"]
```

由此即可创建一个使用Amazon Linux 2023操作系统，并通过Apache提供Web服务，运行PHP8.1环境。PHP将通过`run_apache.sh`脚本中的`php-fpm`服务启动。

#### （3）编译容器

执行如下命令：

```
docker build -t php .
```

构建成功。

执行`docker image ls`命令即可看到构建好的容器的信息。返回结果如下。

```
REPOSITORY                               TAG       IMAGE ID       CREATED          SIZE
php                                      latest    689411270d02   13 minutes ago   381MB
public.ecr.aws/amazonlinux/amazonlinux   2023      81f7bc2150ae   7 days ago       178MB
```

#### （4）在ECR上创建镜像仓库

进入AWS控制台，进入ECR服务，创建一个新的仓库，选择类型为私有`Private`，取名为`php`。

#### （5）在开发环境上配置AKSK并登陆ECR服务

首先在开发环境上配置AWSCLI。配置好AKSK密钥后，执行如下命令登陆到ECR：

```
aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin 383292813273.dkr.ecr.ap-southeast-1.amazonaws.com
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
docker tag php:latest 383292813273.dkr.ecr.ap-southeast-1.amazonaws.com/php
docker push 383292813273.dkr.ecr.ap-southeast-1.amazonaws.com/php:latest
```

操作成功的话返回如下：

```
docker push 383292813273.dkr.ecr.ap-southeast-1.amazonaws.com/php
Using default tag: latest
The push refers to repository [383292813273.dkr.ecr.ap-southeast-1.amazonaws.com/php]
4135e952e25c: Pushed
9b66f00047a4: Pushed
7d2cdf1e4b23: Pushed
latest: digest: sha256:ccb313d61cc92981f84ac70cc45771d3f6e5999c64de1d6b979042891c0268d6 size: 948
```

#### （7）获得ECR上镜像仓库的地址

```
383292813273.dkr.ecr.ap-southeast-1.amazonaws.com/php:latest
```

注意，不同region的名称不一样，以及最后要包含tag版本号。

### 2、编写要在EKS上使用的应用的yaml文件

格式如下。注意替换里边的ECR容器镜像的完整URI地址，包含region、名称和版本号。

```
---
apiVersion: v1
kind: Namespace
metadata:
  name: mydemo2
---
apiVersion: apps/v1
kind: Deployment
metadata:
  namespace: mydemo2
  name: php
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: php
  replicas: 3
  template:
    metadata:
      labels:
        app.kubernetes.io/name: php
    spec:
      containers:
      - image: 383292813273.dkr.ecr.ap-southeast-1.amazonaws.com/php:latest
        imagePullPolicy: Always
        name: php
        ports:
        - containerPort: 80
      nodeSelector:
        kubernetes.io/arch: arm64
---
apiVersion: v1
kind: Service
metadata:
  namespace: mydemo2
  name: php
spec:
  ports:
    - port: 80
      targetPort: 80
      protocol: TCP
  type: NodePort
  selector:
    app.kubernetes.io/name: php
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  namespace: mydemo2
  name: ingress-for-php-app
  labels:
    app: ingress-for-php-app
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
            name: php
            port:
              number: 80
```

请替换以上yaml文件中，namespace、deployment、image、service、alb ingress等可替换为自己的标识。

将以上文件保存为phpdocker.yaml，然后从本地启动部署。

### 3、启动应用

```
kubectl apply -f phpdocker.yaml
```

即可启动应用。返回结果如下：

```
namespace/mydemo2 created
deployment.apps/php created
service/php created
ingress.networking.k8s.io/ingress-for-php-app created
```

### 4、验证启动成功检查访问环境

执行如下命令检查pod运行状态：

```
kubectl get pods -n mydemo2
```

返回结果：

```
NAME                   READY   STATUS    RESTARTS   AGE
php-866cdf8bc8-47r2m   1/1     Running   0          28s
php-866cdf8bc8-kx488   1/1     Running   0          28s
php-866cdf8bc8-m74b8   1/1     Running   0          28s
```

### 5、查看ALB Ingress入口

执行如下命令查看ALB Ingress入口：

```
kubectl get ingress -n mydemo2
```

返回结果：

```
NAME                  CLASS   HOSTS   ADDRESS                                                                      PORTS   AGE
ingress-for-php-app   alb     *       k8s-mydemo2-ingressf-f7e5327d11-672345132.ap-southeast-1.elb.amazonaws.com   80      39s
```

使用浏览器访问上述ALB地址即可访问成功。

## 五、删除实验环境（可选）

执行如下命令删除刚才创建的两个应用：

```
kubectl delete -f nginx-from-public-repo-arm.yaml
kubectl delete -f phpdocker.yaml
```

实验完成。

## 六、参考文档

AWS Load Balancer Controller Ingress annotations 参数说明

[https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.5/guide/ingress/annotations/](https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.5/guide/ingress/annotations/)

AWS Load Balancer Controller Ingress specification 参数说明

[https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.5/guide/ingress/spec/](https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.5/guide/ingress/spec/)

手把手教你如何在 EKS 上轻松部署混合架构节点

[https://aws.amazon.com/cn/blogs/china/how-to-easily-deploy-hybrid-architecture-nodes-on-eks/](https://aws.amazon.com/cn/blogs/china/how-to-easily-deploy-hybrid-architecture-nodes-on-eks/)