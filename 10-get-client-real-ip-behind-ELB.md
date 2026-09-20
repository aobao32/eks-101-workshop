# 实验十、在EKS上的ELB获取最终用户的真实IP地址

> EKS 1.36 版本 @2026-09 AWS Global 区域（ap-southeast-1）实测通过，AWS Load Balancer Controller 版本为 v3.5.0。原始版本基于 EKS 1.27 @2023-06 完成。

## 一、背景

### 1、没有EKS而是使用EC2场景下获取客户端真实IP地址

在之前的文章主要是介绍ELB+EC2模式下，获取客户端真实IP，可参考AWS官方知识库[这篇](https://aws.amazon.com/cn/premiumsupport/knowledge-center/elb-capture-client-ip-addresses/)文章。也可参考过往的blog文章的[这篇](https://blog.bitipcman.com/get-real-client-ip-from-nlb-and-alb/)文章。

在这两篇中，主要讲解是ELB+EC2场景获取真实IP地址。如果用一个表格快速概括的话，汇总如下：

| 类型 | Target类型 | 是否直接透传 | 获取真实IP的方案 |
|:--------- |:---------|:---|:----------------------|
| NLB       | Instance | 是 | 无须额外配置 |
| NLB       | IP       | 否 | 启用 Proxy V2 Protocol |
| ALB       | Instance | 否 | 启用 X-Forwarded-For Header |
| ALB       | IP       | 否 | 启用 X-Forwarded-For Header |

### 2、EKS环境下获取客户端真实IP地址

在EKS环境上，ELB的选择又包括：NLB和ALB两种模式。其中，NLB注册目标组还有IP模式和Instance模式两种。

在这几种模式下，获取真实IP地址方案与ELB+EC2场景有所差别，其原因是EKS上的aws-vpc-cni和kube-proxy负责网络流量的转发，再加上AWS Load Balancer Controller负责Ingress，所以与普通ELB直接对接EC2相比有所差异。本文分别测试如下场景。

注意：本文只对NLB和EKS在同一个VPC内的场景生效。

### 3、测试容器代码说明

本文实验环境构建一个 Apache 2.4 + PHP-FPM 8.3 容器，基础镜像为 `public.ecr.aws/ubuntu/ubuntu:24.04`，并在其中放置一个默认页面 `index.php` 显示客户端 IP 地址。这个环境的代码在 GitHub 上[这里](https://github.com/aobao32/eks-101-workshop/tree/main/10/phpdemo)可以获得。

该目录 `src` 中包含的默认页面 `index.php`，其代码会显示访问者的客户端 IP 地址。文件 `index.php` 的内容如下。这个代码中的第一行会显示 ALB、NLB 直接看到的客户端 IP 地址（即 Apache 通过 `REMOTE_ADDR` 变量呈现），第二行 `X_FORWARD Address` 由 ALB 注入的 `X-Forwarded-For` 头承载，只在使用 ALB 时候有效，在使用 NLB 时候它将返回空字符串。

```php
<h1>REMOTE_ADDR Address is: <?php printf($_SERVER["REMOTE_ADDR"]); ?></h1>

<h1>X_FORWARD Address is: <?php printf($_SERVER["HTTP_X_FORWARDED_FOR"]); ?></h1>
```

### 4、构建测试用容器

从 EKS 1.36 版本起，本实验的容器改基于 `public.ecr.aws/ubuntu/ubuntu:24.04`，与实验四保持一致的镜像基线。Apache 通过 `mod_remoteip` 支持 PROXY protocol，无需再单独引入第三方模块。容器构建使用 Docker Build 命令，在一台安装了 Docker 的 EC2 上执行。

首先在 Amazon Linux 2023 上安装 Docker：

```shell
sudo dnf install -y docker
sudo systemctl enable --now docker
sudo usermod -a -G docker ec2-user
newgrp docker
```

下载代码并构建容器：

```shell
git clone https://github.com/aobao32/eks-101-workshop.git
cd eks-101-workshop/10/phpdemo
# 未开启 PROXY protocol 的版本，用于 ALB Ingress 与 NLB IP 模式
docker build --build-arg ENABLE_PROXY_PROTOCOL=false -t phpdemo:1 .
# 开启 PROXY protocol 的版本，用于 NLB Instance 模式配合 proxy_protocol_v2
docker build --build-arg ENABLE_PROXY_PROTOCOL=true  -t phpdemo:2 .
```

在 ECR 服务上创建名为 `phpdemo` 的仓库，然后推送两个 tag：

```shell
aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com
docker tag phpdemo:1 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/phpdemo:1
docker tag phpdemo:2 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/phpdemo:2
docker push 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/phpdemo:1
docker push 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/phpdemo:2
```

本次实测环境使用一台 Amazon Linux 2023 的独立 EC2（`t3.medium`，附带具有 `AmazonEC2ContainerRegistryPowerUser` 与 `AmazonSSMManagedInstanceCore` 两个托管策略的 EC2 Instance Profile）作为构建机，通过上述命令构建并推送 `phpdemo:1` 与 `phpdemo:2` 两个 tag 到 ECR。这两个 tag 分别对应 `ENABLE_PROXY_PROTOCOL=false` 与 `=true` 两种构建参数，供下文三个场景使用。构建完成后即可销毁该 EC2。

### 5、为EKS部署AWS Load Balancer Controller

正常安装 AWS Load Balancer Controller。请参考[实验二](https://github.com/aobao32/eks-101-workshop/blob/main/02-deploy-alb-ingress.md)的文档，实测环境下版本为 v3.5.0。

## 二、使用ALB Ingress获取客户端真实IP

本实验先采用ALB Ingress进行测试。

### 1、构建YAML文件（基于容器版本1）

为 EKS 构建一个 yaml 配置文件，保存为 `ALB-ingress.yaml`。并替换其中 ECR 容器镜像地址 `133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/phpdemo:1` 为实际使用的地址。

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: alb-ingress
---
apiVersion: apps/v1
kind: Deployment
metadata:
  namespace: alb-ingress
  name: alb-ingress
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: alb-ingress
  replicas: 3
  template:
    metadata:
      labels:
        app.kubernetes.io/name: alb-ingress
    spec:
      containers:
      - image: 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/phpdemo:1
        imagePullPolicy: Always
        name: alb-ingress
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  namespace:  alb-ingress
  name:  alb-ingress
spec:
  ports:
    - port: 80
      targetPort: 80
      protocol: TCP
  type: NodePort
  selector:
    app.kubernetes.io/name: alb-ingress
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  namespace: alb-ingress
  name: alb-ingress
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
              name:  alb-ingress
              port:
                number: 80
```

保存完毕后，执行如下命令启动：

```shell
kubectl apply -f ALB-ingress.yaml
```

### 2、查看访问ALB Ingress地址

查看ALB Ingress的入口地址。

```shell
kubectl get ingress -n alb-ingress
```

返回结果如下：

```
NAME          CLASS   HOSTS   ADDRESS                                                                        PORTS   AGE
alb-ingress   alb     *       k8s-albingre-albingre-1f7bef2eba-2093628417.ap-southeast-1.elb.amazonaws.com   80      3m
```

用 curl 命令、或者浏览器，从互联网访问这个地址，查看其显示的客户端真实 IP 地址：

```shell
curl -s http://k8s-albingre-albingre-1f7bef2eba-2093628417.ap-southeast-1.elb.amazonaws.com/
```

返回结果如下：

```
<h1>REMOTE_ADDR Address is: 192.168.54.252</h1>

<h1>X_FORWARD Address is: 54.240.199.97</h1>
```

在以上返回的结果中可以看到，使用 ALB Ingress 后，容器上的应用程序看到的 `REMOTE_ADDR` 是 ALB 在 VPC 内的一个内网 IP，而 `X-Forwarded-For` 头中携带的 `54.240.199.97` 才是真正的客户端公网 IP。因此如果希望获取客户端真实 IP，只需要在代码中稍微修改，使用 `HTTP_X_FORWARDED_FOR` 变量即可看到真正的客户端 IP 地址了。

ALB Ingress获取客户端真实IP的测试到此结束。

## 三、使用NLB+目标组IP模式获取客户端真实IP

### 1、构建NLB+IP模式的YAML文件（基于容器版本1）

为EKS构建一个yaml配置文件，保存为`NLB-ip.yaml`。并替换其中ECR容器镜像地址`133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/phpdemo:1`为实际使用的地址。

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: nlb-ip-mode
---
apiVersion: apps/v1
kind: Deployment
metadata:
  namespace: nlb-ip-mode
  name: nginx-deployment
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
      - image: 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/phpdemo:1
        imagePullPolicy: Always
        name: nginx
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  namespace: nlb-ip-mode
  name: "service-nginx"
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-name: nlb-ip-mode
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-healthy-threshold: "2"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-unhealthy-threshold: "2"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-interval: "10"
    service.beta.kubernetes.io/aws-load-balancer-attributes: load_balancing.cross_zone.enabled=true
    service.beta.kubernetes.io/aws-load-balancer-target-group-attributes: preserve_client_ip.enabled=true
spec:
  loadBalancerClass: service.k8s.aws/nlb
  selector:
    app.kubernetes.io/name: nginx
  type: LoadBalancer
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
```

执行如下命令启动服务：

```shell
kubectl apply -f NLB-ip.yaml
```

返回结果如下：

```
namespace/nlb-ip-mode created
deployment.apps/nginx-deployment created
service/service-nginx created
```

创建完毕后，可使用 AWS 控制台，进入 ELB 界面，查看 NLB 对应的目标组，可看到 Pod 注册为 IP 模式。在 NLB 目标组的属性页面，`Preserve client IP addresses` 显示为 `Enabled`。

### 2、访问NLB入口

执行如下命令查询NLB入口地址。

```shell
kubectl get service service-nginx -n nlb-ip-mode -o wide
```

返回结果如下：

```
NAME            TYPE           CLUSTER-IP    EXTERNAL-IP                                                     PORT(S)        AGE    SELECTOR
service-nginx   LoadBalancer   10.50.0.213   nlb-ip-mode-d4a6feb9f70bf881.elb.ap-southeast-1.amazonaws.com   80:30880/TCP   4m     app.kubernetes.io/name=nginx
```

现在用命令行 curl 请求 EKS 生成的 NLB，当然也可以通过浏览器访问这个地址。即可看到容器上的应用程序直接看到了真实客户端 IP 地址。

```shell
curl -s http://nlb-ip-mode-d4a6feb9f70bf881.elb.ap-southeast-1.amazonaws.com/
```

返回结果如下：

```
<h1>REMOTE_ADDR Address is: 54.240.199.97</h1>

<h1>X_FORWARD Address is: </h1>
```

由此表示，应用程序通过 NLB+IP 模式，正常的获取到了客户端的真实 IP 地址。注意：这里第二行 `X_FORWARD Address` 在本实验中是用不上的，这个 Header 只在使用 ALB 时候由 ALB 提供。在使用 NLB 时候，它将返回空字符串。

## 四、使用NLB+目标组Instance模式+Proxy V2协议获取客户端真实IP

### 1、升级现有容器、打开Proxy V2协议（构建容器版本2）

在使用ALB Ingress和NLB+IP模式时候，无需对Apache等应用做出修改。在使用 NLB+Instance 模式时，NLB 会在 TCP 载荷前附加一段 PROXY protocol v2 头，包含真实客户端 IP。应用容器需要能解析该头部才能取回真实 IP。Apache 2.4 通过内置的 `mod_remoteip` 模块，一键开启 PROXY 协议支持。本实验的 Ubuntu 24.04 版容器已经通过 `a2enmod remoteip` 启用了该模块，仅需通过 `ENABLE_PROXY_PROTOCOL=true` 构建参数激活其配置。

`mod_remoteip` 的具体配置见 `10/phpdemo/src/remoteip.conf`：

```apache
RemoteIPProxyProtocol On
RemoteIPTrustedProxy 10.0.0.0/8
RemoteIPTrustedProxy 100.64.0.0/10
RemoteIPTrustedProxy 172.16.0.0/12
RemoteIPTrustedProxy 192.168.0.0/16
```

其中 `RemoteIPProxyProtocol On` 打开 PROXY protocol 监听解析，`RemoteIPTrustedProxy` 声明可信来源的 NLB 网段，覆盖常见的 VPC 主网段与 EKS 扩展的 100.64/10 网段。构建命令示例见前文第一章第 4 节的 `docker build --build-arg ENABLE_PROXY_PROTOCOL=true -t phpdemo:2 .`，构建完毕后 ECR 上的 `phpdemo:2` 即为本实验所需的镜像。

注意事项：`RemoteIPProxyProtocol On` 一旦启用，Apache 会要求本监听端口上的所有连接都携带 PROXY 头。因此该镜像不能同时挂到 ALB 或 NLB IP 模式后面，只能与 `proxy_protocol_v2.enabled=true` 的 NLB Instance 目标组配合。

### 2、构建应用和NLB的Yaml文件（基于容器版本2）

为EKS构建一个yaml配置文件，保存为`NLB-instance.yaml`。并替换其中ECR容器镜像地址`133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/phpdemo:2`为实际使用的地址。

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: nlb-instance-mode
---
apiVersion: apps/v1
kind: Deployment
metadata:
  namespace: nlb-instance-mode
  name: nginx-deployment
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
      - image: 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/phpdemo:2
        imagePullPolicy: Always
        name: nginx
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  namespace: nlb-instance-mode
  name: "service-nginx"
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: instance
    service.beta.kubernetes.io/aws-load-balancer-name: nlb-instance-mode
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-healthy-threshold: "2"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-unhealthy-threshold: "2"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-interval: "10"
    service.beta.kubernetes.io/aws-load-balancer-attributes: load_balancing.cross_zone.enabled=true
    service.beta.kubernetes.io/aws-load-balancer-target-group-attributes: proxy_protocol_v2.enabled=true
spec:
  loadBalancerClass: service.k8s.aws/nlb
  selector:
    app.kubernetes.io/name: nginx
  type: LoadBalancer
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
```

执行如下命令创建环境：

```shell
kubectl apply -f NLB-instance.yaml
```

### 2、访问NLB查看IP地址

执行如下命令查询NLB入口地址。

```shell
kubectl get service service-nginx -n nlb-instance-mode -o wide
```

返回结果如下：

```
NAME            TYPE           CLUSTER-IP    EXTERNAL-IP                                                           PORT(S)        AGE   SELECTOR
service-nginx   LoadBalancer   10.50.0.246   nlb-instance-mode-8917eaa49c7aa7d1.elb.ap-southeast-1.amazonaws.com   80:31178/TCP   5m    app.kubernetes.io/name=nginx
```

现在用命令行 curl 请求 EKS 生成的 NLB，当然也可以通过浏览器访问这个地址。即可看到应用程序通过 Apache `mod_remoteip` 解析 PROXY v2 头后返回了真实客户端 IP。

```shell
curl -s http://nlb-instance-mode-8917eaa49c7aa7d1.elb.ap-southeast-1.amazonaws.com/
```

返回结果如下：

```
<h1>REMOTE_ADDR Address is: 54.240.199.97</h1>

<h1>X_FORWARD Address is: </h1>
```

由此表示，应用程序通过 NLB+Instance 模式配合 PROXY protocol v2，正常获取到了客户端的真实 IP 地址。注意：这里第二行 `X_FORWARD Address` 在本实验中是用不上的，这个 Header 只在使用 ALB 时候由 ALB 提供。在使用 NLB 时候，它将返回空字符串。

## 五、小结

### 1、测试结论汇总

通过本文测试可以看到，EKS上获取真实客户端IP的逻辑与ELB+EC2时候有所不同，汇总如下：

| 类型 | Target类型 | 是否直接透传 | EKS上Pod获取真实IP的方案 |
|:--------- |:---------|:---|:----------------------|
| ALB       | IP       | 否 | 在应用程序上获取X-Forwarded-For的HTTP Header即可获得真实IP|
| NLB       | IP | 是 | 启用NLB的目标组保留原始IP功能后，应用系统无须修改即可获得客户端真实IP|
| NLB       | Instance       | 否 | 需要应用程序支持，例如在Apache/Nginx上启用 Proxy V2 Protocol 后可获取客户端原始IP|

### 2、推荐和建议

结论：考虑如下搭配组合：

* **1、使用ALB Ingress模式**：此场景与普通ALB+EC2的方式相同，都是通过X_FORWARDED Header来获取真实IP地址。
* **2、使用NLB Target Group IP模式**：在这种打开保留客户端IP选项后，即可直接在EKS应用中获取客户端IP地址，步骤简单方便，推荐使用。
* **3、使用NLB Target Group 为Instance模式**：需要应用侧额外配置Proxy V2协议。步骤相对较多，复杂。

### 3、删除实验环境

完成上述三个场景实测后，执行如下命令删除本实验的应用和 ELB 资源：

```shell
kubectl delete -f ALB-ingress.yaml
kubectl delete -f NLB-ip.yaml
kubectl delete -f NLB-instance.yaml
```

### 4、参考文档

NLB的客户端IP保留

[https://docs.aws.amazon.com/elasticloadbalancing/latest/network/load-balancer-target-groups.html#client-ip-preservation](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/load-balancer-target-groups.html#client-ip-preservation)

AWS Load Balancer Controller Ingress specification 参数说明

[https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/spec/](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/spec/)

Apache mod_remoteip 官方文档

[https://httpd.apache.org/docs/2.4/mod/mod_remoteip.html](https://httpd.apache.org/docs/2.4/mod/mod_remoteip.html)

全文完。
