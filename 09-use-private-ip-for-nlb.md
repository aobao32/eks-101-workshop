# 实验九、为私有NLB使用指定的、固定的内网IP地址

EKS 1.30 版本 @2024-07 AWS Global区域测试通过

## 一、背景

在一些情况下，EKS部署的服务需要使用私有的NLB方式对VPC内的其他应用暴露服务，但是又不需要暴露在互联网上。这些场景可能包括：

- 某个纯内网的微服务，不需要外部互联网调用，只需要从VPC和其他内网调用
- 结合Gateway Load Balancer部署的多VPC的网络流量扫描方案，EKS所在的VPC为纯内网
- 其他需要固定IP地址作为入口的场景，在这些场景下创建Internal NLB即可，不需要创建Internet-facing NLB。

一般的流程是创建NLB之后，通过AWS控制台或者AWSCLI查询NLB所使用的VPC内的内网IP地址，这个内网IP就是NLB的固定IP。在本NLB不删除的情况下，永远不会改变。在EKS服务中，创建好的NLB对应的IP地址也是不变的。如果希望在创建之初，手工指定IP，那么可以按照本文的方式配置。

## 二、确认私有NLB所在子网位置和可用IP地址

### 1、NLB所在子网位置

本文的EKS所在的VPC分成多个子网，且Node节点所在子网和Pod容器所在子网是两个独立的子网。此外，Pod所在子网还使用了VPC扩展IP地址段即100.64网段。关于如何使用VPC扩展IP地址的说明，可以参考[这里](https://github.com/aobao32/eks-101-workshop/blob/main/08-use-seperated-subnet-for-pod.md)的文档。

在这样一个网络环境下，如果希望创建一个只用于内网访问的NLB，那么可以将Pod独立放在一个网段，将NLB和Node放在一个网段。接下来将确认这个子网的已经使用的IP地址的情况。

### 2、查询可用IP地址

进入VPC的子网页面，通过子网界面，确认要部署私有NLB的子网的CIDR地址范围，例如本例中是`default-vpc-private`共三个网段。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/nlb-private-ip/private-ip-1.png)

从这三个子网中人为协商确认分配IP地址，例如分配`172.31.48.254`，`172.31.64.254`，`172.31.80.254`这三个IP地址。接下来通过ENI网卡查询是否被使用。

进入EC2界面，从左侧菜单找到ENI网卡，然后再搜索框中搜索要使用的IP地址。为了精确查找，可以逐段输入。当输入IP地址的前三段后，如果查询结果有匹配条目，则表示IP地址已经被使用。如果没有搜索到结果，则表示地址空闲可以被使用。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/nlb-private-ip/private-ip-2.png)

### 3、确认已经安装AWS Load Balancer Controller

安装方法请参考[这里](https://github.com/aobao32/eks-101-workshop/blob/main/02-deploy-alb-ingress.md)，本文不再赘述。

### 4、确认VPC和Subnet带有EKS的ELB所需要的标签

请确保本子网已经设置了正确的路由表，且VPC内包含NAT Gateway可以提供外网访问能力。然后接下来为其打标签。

找到当前的VPC，找到有EIP和NAT Gateway的Public Subnet，为其添加标签：

- 标签名称：kubernetes.io/role/elb，值：1

接下来进入Private subnet（本文中是Node所在的子网），为其添加标签：

- 标签名称：kubernetes.io/role/internal-elb，值：1

接下来请重复以上工作，三个AZ的子网都实施相同的配置，注意第一项标签值都是1。

## 三、启动应用部署私有NLB并指定内网IP

### 1、部署应用并创建私有NLB

编写如下yaml文件，替换其中的NLB参数和IP地址为需要使用的参数。

注意：IP地址地址的总个数必须与上一步给子网做标记的子网数量相同。例如上一步有3个子网打了tag标签，那么这里也要提交3个IP。所有IP地址是字符串格式，需要前后加双引号的提交。此外，本例仅以使用外部的容器镜像仓库`public.ecr.aws/nginx/nginx:1.24-alpine-slim`作为例子，请替换其中的image镜像地址为您的ECR上的镜像地址。

```
---
apiVersion: v1
kind: Namespace
metadata:
  name: private-nlb-fixed-ip
---
apiVersion: apps/v1
kind: Deployment
metadata:
  namespace: private-nlb-fixed-ip
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
      - image: public.ecr.aws/nginx/nginx:1.27-alpine-slim
        imagePullPolicy: Always
        name: nginx
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  namespace: private-nlb-fixed-ip
  name: "service-nginx"
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-healthy-threshold: "2"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-unhealthy-threshold: "2"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-interval: "10"
    service.beta.kubernetes.io/aws-load-balancer-attributes: load_balancing.cross_zone.enabled=true
    service.beta.kubernetes.io/aws-load-balancer-private-ipv4-addresses: "172.31.48.250, 172.31.64.250, 172.31.80.250"
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

将以上配置文件保存为`NLB-internal-with-private-ip.yaml`，然后自行如下命令拉起服务。

```
kubectl apply -f NLB-internal-with-private-ip.yaml
```

### 2、查看私有NLB的入口

执行如下命令查看NLB入口。

```
kubectl get service service-nginx -n private-nlb-fixed-ip -o wide 
```

返回结果如下：

```
NAME            TYPE           CLUSTER-IP    EXTERNAL-IP                                                                          PORT(S)        AGE     SELECTOR
service-nginx   LoadBalancer   10.50.0.184   k8s-privaten-servicen-a9a512aed8-cdd19b47e229b5ee.elb.ap-southeast-1.amazonaws.com   80:30880/TCP   2m40s   app.kubernetes.io/name=nginx
```

其中标记`EXTERNAL-IP`的字段就是Private NLB的地址，则个地址只能从VPC内访问，不可重互联网访问。

启动完毕后，进入EC2界面，查看NLB的情况，即可看到NLB分配了TGW ENI子网的静态IP地址。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/nlb-private-ip/private-ip-3.png)

### 3、测试访问

使用EC2 Connect功能，选择Session Manager登陆到EKS的Node节点。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/nlb-private-ip/private-ip-4.png)

在弹出的对话框内，选择第二个标签页`Session Manager`，点击右下角的`Connect`按钮。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/nlb-private-ip/private-ip-5.png)

登陆到Node节点后，通过curl命令访问上一步查询到的私有NLB的地址，可以看到访问正常。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/nlb-private-ip/private-ip-6.png)

## 四、其他注意事项

在VPC的子网管理中，有一项名为“CIDR预留”的功能。此功能不适用于指定NLB的内网IP分配功能。因为当标记为IP地址预留时候，此地址将不可被NLB所使用，由此会导致NLB创建失败。因此，为NLB指定IP前，查找IP地址是否被占用，通过ENI网卡界面查询即可。

## 五、删除实验环境（只删除应用Pod不删除集群）

执行如下命令删除实验环境：

```
kubectl delete -f NLB-internal-with-private-ip.yaml
```

## 六、参考文档

[https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.4/guide/service/annotations/#private-ipv4-addresses]()

全文完。