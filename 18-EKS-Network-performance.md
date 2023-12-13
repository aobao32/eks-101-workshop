# 测试EKS服务上Pod使用VPC CNI对网络吞吐性能的影响

## 一、背景

在EC2的网络优化机型上，例如c6in.8xlarge(32vCPU/64GB)，其网络带宽达到50Gbps。在没有容器环境下，使用iperf2测试，其带宽可以49.7Gbps的吞吐，相当于标称值的99.4%，考虑统计差异，这个速度可认为几乎没有损耗。测试过程和方法参考[这篇](https://blog.bitipcman.com/ec2-ena-iperf-networking-performance/)博客。

那么当场景来到EKS上，Pod的所有流量都是通过Node节点上的VPC CNI进行转发，此时压力测试的其中一端是非容器化的EC2，另一端是Pod容器，会发生什么情况？

## 二、实验环境

基础环境：

- Time: UTC 8:00-9:00, Dec 09, 2023
- Region: ap-southeast-1, AZ1

EC2一侧：

- EC2: c6in.8xlarge
- OS: Amazon Linux 2023 
- Kernel: 6.1.61-85.141.amzn2023.x86_64
- ENA Driver: 2.10.0g, /lib/modules/6.1.61-85.141.amzn2023.x86_64/kernel/drivers/amazon/net/ena/ena.ko (系统自带)
- iperf2: iperf version 2.1.9 (14 March 2023) pthreads

EKS容器一侧的Node节点：

- EKS版本：1.28
- Node类型：Managed node group
- EC2: c6in.8xlarge
- OS: Amazon Linux 2
- Kernel: 5.10.199-190.747.amzn2.x86_64
- ENA Driver: 2.10.0g, /lib/modules/5.10.199-190.747.amzn2.x86_64/kernel/drivers/amazon/net/ena/ena.ko (系统自带)
- CNI: AWS VPC CNI，分别测试了`v1.14.1-eksbuild.1`、`v1.15.4-eksbuild.1`两个版本

EKS上Pod：

- OS: Amazon Linux 2023
- iperf2: iperf version 2.1.9 (14 March 2023) pthreads

## 三、环境搭建

### 1、创建EKS集群

准备如下配置文件。

```
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: eksworkshop
  region: ap-southeast-1
  version: "1.28"

vpc:
  clusterEndpoints:
    publicAccess:  true
    privateAccess: true

kubernetesNetworkConfig:
  serviceIPv4CIDR: 10.50.0.0/24

managedNodeGroups:
  - name: managed-ng
    labels:
      Name: managed-ng
    instanceType: c6in.8xlarge
    minSize: 2
    desiredCapacity: 2
    maxSize: 2
    volumeType: gp3
    volumeSize: 100
    tags:
      nodegroup-name: managed-ng
    iam:
      withAddonPolicies:
        imageBuilder: true
        autoScaler: true
        certManager: true
        efs: true
        ebs: true
        albIngress: true
        xRay: true
        cloudWatch: true

cloudWatch:
  clusterLogging:
    enableTypes: ["api", "audit", "authenticator", "controllerManager", "scheduler"]
    logRetentionInDays: 30
```

在以上配置文件中，指定了两台`c6in.8xlarge`作为Nodegroup启动集群。

执行如下命令创建EKS集群。

```
eksctl create cluster -f newvpc.yaml
```

EKS集群会在一个新的VPC中创建好，与现有VPC无冲突。

### 2、压力测试用EC2

按本文测试环境要求，正常创建EC2，创建时候注意选择上文新生成的VPC。

在标称内网规格是50Gbps的场景下，不需要Placement group即可达到50Gbps的性能。如果需要更高，建议考虑使用EC2 Placement group以到达聚合EC2地理位置从而实现更高性能。

### 3、设置EC2和EKS Node使用同一个安全组且允许互相访问

关于安全规则组，确保服务器和客户端二者互相授权，允许客户端访问服务器端的TCP和UDP协议的所有端口。这是由于iperf调用的端口较多，虽然可以通过`-p`参数指定端口，但是相对麻烦。

这里推荐将EC2和EKS的Node节点绑定同一个安全规则组，然后在这个安全规则组中加入一条规则，允许所有流量访问并限定来源是本安全组。这样即可允许绑定这个安全组的两个机器之间完全互信。

### 4、构建容器并拉起容器

准备如下Dockerfile文件。

```yaml
FROM public.ecr.aws/amazonlinux/amazonlinux:2023

# Install dependencies
RUN yum install -y \
    httpd \
    php8.2 \
    php-pear \
    php8.2-bcmath \
    php8.2-devel \
    php8.2-gd \
    php8.2-intl \
    php8.2-mbstring \
    php8.2-odbc \
    php8.2-xml \
    php8.2-mysqlnd \
    tmux wget htop \
 && ln -s /usr/sbin/httpd /usr/sbin/apache2

# Install app
ADD src/run_apache.sh /root/
ADD src/index.php /var/www/html/
RUN mkdir /run/php-fpm/ \
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

本Docker中使用的启动服务脚本`/root/run_apache.sh`内容如下：

```shell
mkdir -p /var/run/apache2
mkdir -p /var/lock/apache2
/usr/sbin/php-fpm -D
/usr/sbin/httpd -D FOREGROUND
```

构建好容器、登录ECR、并推送Docker镜像到ECR。

```shell
docker build -t demo .
docker tag demo:latest 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/amzn2023:1
aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com
docker push 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/amzn2023:1
```

构件容器应用配置文件

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
  labels:
    app: nginx
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/amzn2023:1
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: "service-nginx"
  annotations:
        service.beta.kubernetes.io/aws-load-balancer-type: nlb
spec:
  selector:
    app: nginx
  type: LoadBalancer
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
```

拉起应用，获得测试用容器。

```shell
kubectl apply -f test.yaml
```

## 五、测试流程

### 1、iperf2工具使用方法

压力测试iperf工具命令和方法参考[这篇](https://blog.bitipcman.com/ec2-ena-iperf-networking-performance/)博客博客。

服务器端：

```shell
iperf -s
```

客户端：

```shell
iperf -c 172.31.51.45 --parallel 32 -i 1
```

### 2、登录到pod内的shell发起交互式命令

可使用kubelctl命令登录到Pod上shell环境来执行命令。

首先查看所有Pod：

```Shell
kubectl get pods -A
```

实验环境构建的Pod位于默认的Namespaces下，名字叫做`nginx-deployment-579885f88d-5k6ht`。复制下来名字。拼接如下命令：

```shell
kubectl exec --stdin --tty nginx-deployment-579885f88d-5k6ht -- /bin/bash
```

即可登录到容器。

这个过程也可以使用其他容器管理工具例如`k9s`完成，在`k9s`中对这pod按`s`键表示进入shell。

### 3、客户端和服务器端调换位置的测试

发起测试后，记录结果。例如效果如下：

```
# 此处省略若干行...

[  4] 0.00-10.02 sec   714 MBytes   597 Mbits/sec
[ 29] 0.00-10.02 sec  2.69 GBytes  2.30 Gbits/sec
[ 16] 0.00-10.03 sec  1.51 GBytes  1.30 Gbits/sec
[ 27] 0.00-10.03 sec  1.05 GBytes   903 Mbits/sec
[ 12] 0.00-10.02 sec   992 MBytes   830 Mbits/sec
[ 19] 0.00-10.03 sec  1006 MBytes   842 Mbits/sec
[ 17] 0.00-10.03 sec  1.09 GBytes   930 Mbits/sec
[  7] 0.00-10.03 sec  1.58 GBytes  1.35 Gbits/sec
[ 31] 0.00-10.02 sec   980 MBytes   820 Mbits/sec
[ 22] 0.00-10.03 sec   995 MBytes   832 Mbits/sec
[ 20] 0.00-10.03 sec  1.00 GBytes   860 Mbits/sec
[  6] 0.00-10.02 sec  1.25 GBytes  1.07 Gbits/sec
[ 13] 0.00-10.02 sec  3.02 GBytes  2.59 Gbits/sec
[SUM] 0.00-10.00 sec  57.8 GBytes  49.7 Gbits/sec
```

测试结果如下截图：

![](https://blogimg.bitipcman.com/workshop/EC2-iperf2/iperf-07.png)

然后将服务器端和客户端的位置兑换，再次执行测试。

### 4、升级EKS的VPC CNI到最新版本再进行测试

前边测试完成后，升级EKS的AWS VPC CNI版本，重复测试。升级CNI的方法可以参考[这篇](https://blog.bitipcman.com/eks-console-addon-upgrade/)博客。

首先查看当前版本：

```shell
kubectl describe daemonset aws-node --namespace kube-system | grep amazon-k8s-cni: | cut -d : -f 3
```

返回结果即可看到`v1.14.1-eksbuild.1`的。升级版本可以通过EKS控制台，进入集群，进入Addons插件界面，选中新版本的`v1.15.4-eksbuild.1`，然后在可选设置的最下方，选中Override，这表示将强制升级现有插件。如果没有选中Override，那么会提示插件已经存在。

升级完毕，再次进行测试，并观察测试结果。

## 六、测试数据和小结

|对比|CNI版本<br>v1.14.1-eksbuild.1|CNI版本<br>v1.15.4-eksbuild.1|
|---|---|---|
|EC2发起压力<br>Pod承接|49.7Gbps|49.7Gbps|
|Pod发起压力<br>EC2承接|49.7Gbps|49.7Gbps|

多次重复执行测试，测试均结果在49.7Gbps和49.6Gbps之间抖动。

结论：与之前[这篇](https://blog.bitipcman.com/ec2-ena-iperf-networking-performance/)博客中进行的两端都是EC2之间测试相比，压力测试的一端放到EKS上的Pod并通过aws-vpc-cni提供网络接入，并没有明显的性能衰减，可放心使用。
