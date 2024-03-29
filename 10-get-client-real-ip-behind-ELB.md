# 在EKS上的ELB获取最终用户的真实IP地址

EKS 1.27版本 @2023-06 AWS Global区域测试通过

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

本文实验环境构建一个Apache+PHP容器，并在其中放置一个默认页面`index.php`显示客户端IP地址。这个环境的代码在Github上[这里](https://github.com/aobao32/eks-101-workshop/tree/main/10/phpdemo)可以获得。

这个容器仓库的`src`目录中已经包含了一个默认页面`index.php`，其代码会显示访问者的客户端IP地址。文件`index.php`的内容如下。这个代码中的第一行会显示ALB、NLB直接看到的客户端IP地址，其中第二行`X_FORWARD Address`只在使用ALB时候有效，在使用NLB时候，它将与第一行`REMOTE_ADDR`输出相同的地址。

```
<h1>REMOTE_ADDR Address is: <?php printf($_SERVER["REMOTE_ADDR"]); ?></h1>

<h1>X_FORWARD Address is: <?php printf($_SERVER["REMOTE_ADDR"]); ?></h1>
```

### 4、构建测试用容器（版本1）

在一台使用Amazon Linux 2操作系统的EC2上安装Docker环境：

```
yum update -y
yum install -y docker
systemctl start docker
systemctl enable docker
usermod -a -G docker ec2-user
```

下载测试用docker容器配置文件（含PHP程序），并构建容器。此部分操作如果不熟悉，可参考[这篇](https://blog.bitipcman.com/push-docker-image-to-aws-ecr-docker-repository/)博客讲述如何构建容器镜像并上传到ECR镜像仓库。

```
git clone https://github.com/aobao32/eks-101-workshop.git
cd eks-101-workshop/10/phpdemo-amazonlinux2
docker build -t phpdemo:1 .
```

在ECR服务上，创建好名为`phpdemo`的仓库，然后从EC2上推送刚才构建好的容器到ECR。

```
aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com
docker tag phpdemo:1 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/phpdemo:1
docker push 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/phpdemo:1
```

由此即可获得构建好的容器，稍后用于EKS测试。将ECR上的容器镜像地址`133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/phpdemo:1`，复制下来，用于下一步使用。

### 5、为EKS部署AWS Load Balancer Controller

正常安装AWS Load Balancer Controller。请参考相关文档。

## 二、使用ALB Ingress获取客户端真实IP

本实验先采用ALB Ingress进行测试。

### 1、构建YAML文件（基于容器版本1）

为EKS构建一个yaml配置文件，保存为`ALB-ingress.yaml`。并替换其中ECR容器镜像地址`133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/phpdemo:1`为实际使用的地址。

```
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

```
kubectl apply -f ALB-ingress.yaml
```

### 2、查看访问ALB Ingress地址

查看ALB Ingress的入口地址。

```
kubectl get ingress -n alb-ingress
```

现在用命令行curl请求EKS生成的ALB Ingress，即可看到客户端返回的ALB入口地址。

```
NAME          CLASS   HOSTS   ADDRESS                                                                        PORTS   AGE
alb-ingress   alb     *       k8s-albingre-albingre-1f7bef2eba-1173890379.ap-southeast-1.elb.amazonaws.com   80      5m22s
```

用curl命令、或者浏览器，从互联网访问这个地址，查看其显示器的客户端真实IP地址。

```

<h1>REMOTE_ADDR Address is: 172.31.1.182</h1>

<h1>X_FORWARD Address is: 54.240.199.98</h1>

```

在以上返回的结果中可以看到，使用ALB Ingress后，容器上的应用程序看到的客户端IP地址会变为ALB的内网IP。因此如果希望获取客户端真实IP，只需要在代码中稍微修改，使用代码获取`X_FORWARD_Header`即可看到真正的客户端IP地址了。

ALB Ingress获取客户端真实IP的测试到此结束。

## 三、使用NLB+目标组IP模式获取客户端真实IP

### 1、构建NLB+IP模式的YAML文件（基于容器版本1）

为EKS构建一个yaml配置文件，保存为`NLB-ip.yaml`。并替换其中ECR容器镜像地址`133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/phpdemo:1`为实际使用的地址。

```
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

```
kubectl apply -f NLB-ip.yaml
```

返回结果如下：

```
namespace/nlb-ip-mode created
deployment.apps/nginx-deployment created
service/service-nginx created
```

创建完毕后，可使用AWS控制台，进入ELB界面，查看NLB对应的目标组，可看到Pod注册为IP模式。在NLB的属性设置页面，保留客户端IP的选项显示为`Enable`。

### 2、访问NLB入口

执行如下命令查询NLB入口地址。

```
kubectl get service service-nginx -n nlb-ip-mode -o wide 
```

返回结果如下：

```
NAME            TYPE           CLUSTER-IP   EXTERNAL-IP                                                     PORT(S)        AGE    SELECTOR
service-nginx   LoadBalancer   10.50.0.53   nlb-ip-mode-8126dfb994dbac45.elb.ap-southeast-1.amazonaws.com   80:31178/TCP   116s   app.kubernetes.io/name=nginx
```

现在用命令行curl请求EKS生成的NLB，当然也可以通过浏览器访问这个地址。即可看到客户端返回的是真实IP地址。

```
<h1>REMOTE_ADDR Address is: 54.240.199.98</h1>

<h1>X_FORWARD Address is: </h1>
```

由此表示，应用程序通过NLB+IP模式，正常的获取到了客户端的真实IP地址。注意：这里第二行`X_FORWARD Address`在本实验中是用不上的，这个Header只在使用ALB时候由ALB提供。在使用NLB时候，它将返回空白信息。

## 四、使用NLB+目标组Instance模式+Proxy V2协议获取客户端真实IP

### 1、升级现有容器、打开Proxy V2协议（构建容器版本2）

在使用ALB Ingress和NLB+IP模式时候，无需对Apache等应用做出修改。在使用NLB+Instance模式手，需要额外开始Proxy V2协议。Apache2可以通过mod_remoteip模块，一键打开对Proxy协议的支持。使用Amazon Linux 2安装的Apache，则已经内置了mod_remoteip模块。如果是使用CentOS系统自带的yum安装，也应该是内置支持的。

编辑上文构建容器镜像时候，从Github下载的代码中，找到名为`/10/phpdemo-amazonlinux2/src/httpd.conf`的配置文件。

在找到 `ServerAdmin root@localhost` 这一行。在这一行的下边，加入如下一行配置。

```
RemoteIPProxyProtocol On
```

如果这一行已经存在但是被注释掉，那么删除前边的`#`注释符号即可。此外，需要注意的是，这个配置应加载于默认网站或者VirtualHost的配置段内，不能在其他位置任意填写，否则Apache会无法启动。

修改完毕后，重新build容器，可修改构建容器时候的版本号，使之与前文的区别开。执行如下命令：

```
docker build -t phpdemo:2 .
aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com
docker tag phpdemo:2 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/phpdemo:2
docker push 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/phpdemo:2
```

构建完毕后，即可在ECR上获得名为`133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/phpdemo:2`的容器镜像。注意本容器镜像与前一个实验的版本号区别开。

### 2、构建应用和NLB的Yaml文件（基于容器版本2）

为EKS构建一个yaml配置文件，保存为`NLB-instance.yaml`。并替换其中ECR容器镜像地址`133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/phpdemo:2`为实际使用的地址。

```
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

```
kubectl apply -f NLB-instance.yaml
```

### 2、访问NLB查看IP地址

执行如下命令查询NLB入口地址。

```
kubectl get service service-nginx -n nlb-instance-mode -o wide 
```

返回结果如下：

```
NAME            TYPE           CLUSTER-IP    EXTERNAL-IP                                                           PORT(S)        AGE   SELECTOR
service-nginx   LoadBalancer   10.50.0.196   nlb-instance-mode-40281b4b20452fcf.elb.ap-southeast-1.amazonaws.com   80:32209/TCP   10m   app.kubernetes.io/name=nginx
```

现在用命令行curl请求EKS生成的NLB，当然也可以通过浏览器访问这个地址。即可看到客户端返回的是真实IP地址。

```
<h1>REMOTE_ADDR Address is: 54.240.199.98</h1>

<h1>X_FORWARD Address is: </h1>
```

由此表示，应用程序通过NLB+IP模式，正常的获取到了客户端的真实IP地址。注意：这里第二行`X_FORWARD Address`在本实验中是用不上的，这个Header只在使用ALB时候由ALB提供。在使用NLB时候，它将返回空白信息。

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

### 3、参考文档

NLB的客户端IP保留

[https://docs.aws.amazon.com/zh_cn/elasticloadbalancing/latest/network/load-balancer-target-groups.html#client-ip-preservation]()

AWS Load Balancer Controller Ingress specification 参数说明

[https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.5/guide/ingress/spec/]()