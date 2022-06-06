# 为私有NLB使用指定IP地址

## 一、背景

在一些情况下，EKS部署的服务需要使用私有的NLB即 Internal NLB + Node Port 方式对外暴露服务，例如：

- 某个纯内网的微服务，不需要外部互联网调用，只需要从VPC和其他内网调用
- 结合Gateway Load Balancer部署的多VPC的网络流量扫描方案，EKS所在的VPC为纯内网
- 其他需要固定IP地址作为入口的场景

在这些场景下创建Internal NLB即可，不需要创建Internet-facing NLB。

一般的流程是，创建NLB之后，再通过AWS控制台或者AWSCLI查询NLB所使用的VPC内的内网IP地址。为了简化管理，在使用EKS服务创建Service时候，可以手工指定希望使用的内网IP。

## 二、NLB所在子网位置和可用IP地址

### 1、NLB所在子网位置

本文的环境以“结合Gateway Load Balancer部署的多VPC的网络流量扫描方案、EKS所在的VPC为纯内网”为例，EKS所在的VPC分成多个子网，分别是TGW ENI子网、Node节点所在子网、Pod容器所在子网。其中，Pod所在子网还可以是VPC扩展IP地址即100.64网段。关于如何使用VPC扩展IP地址的说明，可以参考[这里](https://github.com/aobao32/eks-101-workshop/blob/main/08-use-seperated-subnet-for-pod.md)的文档。

在这样一个网络环境下，选择NLB落地的子网可以在TGW ENI子网和Node节点所在子网中任意选择。为了节约Node节点所在子网的IP地址，建议将NLB放到TGW ENI子网。接下来将确认这个子网的已经使用的IP地址的情况。

### 2、查询可用IP地址

进入VPC的子网页面，通过子网界面，确认要部署私有NLB的TGW ENI子网的CIDR地址范围，例如本例中是`10.2.1.0/24`和`10.2.2.0/24`两个网段。从这两个子网中人为协商确认分配IP地址，例如分配`10.2.1.194`和`10.2.2.194`这两个IP地址。接下来通过ENI网卡查询是否被使用。

进入EC2界面，从左侧菜单找到ENI网卡，然后再搜索框中搜索要使用的IP地址。为了精确查找，可以逐段输入。当输入IP地址的前三段后，如果查询结果有匹配条目，则表示IP地址已经被使用。如果没有搜索到结果，则表示地址空闲，可以被使用。如下截图是搜索出来发现地址被占用的情况。

![通过ENI查询IP地址是否被使用](https://blogimg.bitipcman.com/2022/06/06114643/eni-private-ip.png)

由此即可确定地址是否空闲，然后确认多个AZ对应多个子网各自可用的IP地址。

### 3、确认已经安装AWS Load Balancer Controller

在EKS 1.22版本上，原先的ALB Ingress已经改名为AWS Load Balancer Controller，因此不仅是使用ALB需要事先安装，使用NLB也需要提前安装好AWS Load Balancer Controller。安装方法请参考[这里](https://github.com/aobao32/eks-101-workshop/blob/main/02-deploy-alb-ingress.md)，本文不再赘述。

## 三、EKS YAML样例

编写如下yaml文件，替换其中的NLB参数和IP地址为需要使用的参数。此外，请替换其中的image镜像地址为您的ECR上的镜像地址，例如替换为`420029960748.dkr.ecr.cn-northwest-1.amazonaws.com.cn/phpdemo:4`，即可从ECR拉起镜像。

```
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
        image: public.ecr.aws/nginx/nginx:1.21.6-alpine
        ports:
        - containerPort: 80
        resources:
          limits:
            cpu: "1"
            memory: 2G
---
apiVersion: v1
kind: Service
metadata:
  name: "service-nginx"
  annotations:
        service.beta.kubernetes.io/aws-load-balancer-name: myphpdemo
        service.beta.kubernetes.io/aws-load-balancer-type: nlb-ip
        service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
        service.beta.kubernetes.io/aws-load-balancer-scheme: internal
        service.beta.kubernetes.io/aws-load-balancer-healthcheck-healthy-threshold: "2"
        service.beta.kubernetes.io/aws-load-balancer-healthcheck-unhealthy-threshold: "2"
        service.beta.kubernetes.io/aws-load-balancer-healthcheck-interval: "10"
        service.beta.kubernetes.io/aws-load-balancer-attributes: load_balancing.cross_zone.enabled=true
        service.beta.kubernetes.io/aws-load-balancer-private-ipv4-addresses: 10.2.1.194, 10.2.2.194
spec:
  selector:
    app: nginx
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

启动完毕后，进入EC2界面，查看NLB的情况，即可看到NLB分配了TGW ENI子网的静态IP地址。如下截图。

![](https://blogimg.bitipcman.com/2022/06/06120453/eni-private-ip-2.png)

## 四、其他注意事项

在VPC的子网管理中，有一项名为“CIDR预留”的功能。此功能不适用于指定NLB的内网IP分配功能。因为当标记为IP地址预留时候，此地址将不可被NLB所使用，由此会导致NLB创建失败。因此，为NLB指定IP前，查找IP地址是否被占用，通过ENI网卡界面查询即可。

## 五、参考文档

[https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.4/guide/service/annotations/#private-ipv4-addresses](https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.4/guide/service/annotations/#private-ipv4-addresses)

全文完。

