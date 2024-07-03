# 实验四、在ARM架构上构建应用并使用ALB Ingress部署应用

EKS 1.30 版本 @2024-07 AWS Global区域测试通过

## 一、关于多架构支持

前文的实验中，分别创建了两个Nodegroup，一个Nodegroup是使用X86_64架构Intel处理器的t3.xlarge(或m5.xlarge/m6i.xlarge)机型，另一个Nodegroup是使用Graviton处理器的ARM机型t4g.xlarge或m6g.xlarge。由于ARM架构的容器景象和X86_64架构的容器镜像并不通用，因此本文会重新构建一个ARM版本的image，并上传到ECR镜像仓库中，再部署到节点组。

注意，如果您希望将一个应用同时运行在两种架构的节点上，则需要对同一个应用作两种架构的编译和构建。可参考[本文](https://aws.amazon.com/cn/blogs/china/how-to-easily-deploy-hybrid-architecture-nodes-on-eks/)配置。

执行如下命令可查看当前EKS集群的节点组Nodegroup所使用的处理器架构：

```
kubectl get nodes --label-columns=kubernetes.io/arch
```

返回结果如下，可看到最后一列就是对应的处理器机型，返回`amd64`表示是Intel或者AMD处理器的x86_64架构，返回`arm64`表示是Gravtion处理器的ARM架构。

```
NAME                                                STATUS   ROLES    AGE   VERSION               ARCH
ip-192-168-6-252.ap-southeast-1.compute.internal    Ready    <none>   45m   v1.30.0-eks-036c24b   arm64
ip-192-168-60-2.ap-southeast-1.compute.internal     Ready    <none>   45m   v1.30.0-eks-036c24b   arm64
ip-192-168-89-203.ap-southeast-1.compute.internal   Ready    <none>   45m   v1.30.0-eks-036c24b   arm64
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
      - image: public.ecr.aws/nginx/nginx:1.27-alpine-slim
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
yum install -y docker tmux
service docker start
systemctl enable docker
usermod -a -G docker ec2-user
```

即可安装好软件包。

#### （2）编辑容器配置文件

创建`src`目录，进入`src`目录，并将如下内容保存为`run_apache.sh`脚本：

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

注意：此步骤不可跳过。如果没有实现创建镜像仓库，那么在开发环境做`docker push`时候就会报错，不会自动创建镜像仓库。

进入AWS控制台，进入ECR服务，创建一个新的仓库，选择类型为私有`Private`，取名为`mydemo2`。在创建仓库的向导页面下方，在`Tag immutability`的开关设置为启用，在`Scan on push`的开关设置为启用。然后点击创建。

创建完毕后，在镜像仓库的`URI`位置即可看到仓库的名称类似`133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/mydemo2`的地址。

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
docker tag php:latest 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/mydemo2:latest
docker push 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/mydemo2:latest
```

操作成功的话返回如下：

```
The push refers to repository [133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/mydemo2]
38799289308e: Pushed
5aad7e0963a0: Pushed
ba317555b8f4: Pushed
e4be13cbd817: Pushed
latest: digest: sha256:9eb71521a3024da70951935d6740d3e2ea30b589c84f1e13397a16aa2577ae8c size: 1155
```

#### （7）获得ECR上镜像仓库的地址

再次进入ECR容器镜像仓库，找到刚才创建的仓库`mydemo2`，进入后可以看到URI的完整地址和版本如下：

```
133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/mydemo2:latest
```

注意，不同region的代号对应的地址不一样，并且注意最后要包含版本号。

至此，一个至此Graviton处理器的容器镜像已经上传到ECR上。

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
      - image: 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/mydemo2:latest
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

请替换以上yaml文件中的镜像仓库、镜像名称、版本，以及对应EKS部署的namespace、deployment、image、service、alb ingress等参数，可替换为实际使用的标识。

将以上文件保存为`php-arm.yaml`，然后从本地启动部署。

### 3、启动应用

```
kubectl apply -f php-arm.yaml
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
php-749c7cbbd7-clq2x   1/1     Running   0          98s
php-749c7cbbd7-hhncg   1/1     Running   0          98s
php-749c7cbbd7-slthw   1/1     Running   0          98s
```

### 5、查看ALB Ingress入口

执行如下命令查看ALB Ingress入口：

```
kubectl get ingress -n mydemo2
```

返回结果：

```
NAME                  CLASS   HOSTS   ADDRESS                                                                      PORTS   AGE
ingress-for-php-app   alb     *       k8s-mydemo2-ingressf-f7e5327d11-658637890.ap-southeast-1.elb.amazonaws.com   80      78s
```

使用浏览器访问上述ALB地址即可访问成功。

## 四、删除运行中的ARM架构的容器Pod和ALB Ingress的实验环境（可选）

执行如下命令删除刚才创建的两个应用：

```
kubectl delete -f nginx-from-public-repo-arm.yaml
kubectl delete -f php-arm.yaml
```

实验完成。

## 五、参考文档

AWS Load Balancer Controller Ingress annotations 参数说明

[https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.5/guide/ingress/annotations/](h)

AWS Load Balancer Controller Ingress specification 参数说明

[https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.5/guide/ingress/spec/]()

手把手教你如何在 EKS 上轻松部署混合架构节点

[https://aws.amazon.com/cn/blogs/china/how-to-easily-deploy-hybrid-architecture-nodes-on-eks/]()