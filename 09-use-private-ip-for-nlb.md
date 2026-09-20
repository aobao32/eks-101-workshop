# 实验九、为私有NLB使用指定的、固定的内网IP地址

> EKS 1.36 版本 @2026-09 AWS Global 区域（ap-southeast-1）实测通过，AWS Load Balancer Controller 版本为 v3.5.0。原始版本基于 EKS 1.30 @2024-07 完成。

## 一、背景

在一些情况下，EKS部署的服务需要使用私有的NLB方式对VPC内的其他应用暴露服务，但是又不需要暴露在互联网上。这些场景可能包括：

- 某个纯内网的微服务，不需要外部互联网调用，只需要从VPC和其他内网调用
- 结合Gateway Load Balancer部署的多VPC的网络流量扫描方案，EKS所在的VPC为纯内网
- 其他需要固定IP地址作为入口的场景，在这些场景下创建Internal NLB即可，不需要创建Internet-facing NLB。

一般的流程是创建NLB之后，通过AWS控制台或者AWSCLI查询NLB所使用的VPC内的内网IP地址，这个内网IP就是NLB的固定IP。在本NLB不删除的情况下，永远不会改变。在EKS服务中，创建好的NLB对应的IP地址也是不变的。如果希望在创建之初，手工指定IP，那么可以按照本文的方式配置。

## 二、确认私有NLB所在子网位置和可用IP地址

### 1、NLB所在子网位置

本文的EKS所在的VPC分成多个子网，且Node节点所在子网和Pod容器所在子网是两个独立的子网。此外，Pod所在子网还使用了VPC扩展IP地址段即100.64网段。关于如何使用VPC扩展IP地址的说明，可以参考[这里](https://github.com/aobao32/eks-101-workshop/blob/main/08-use-seperated-subnet-for-pod.md)的文档。

在这样一个网络环境下，如果希望创建一个只用于内网访问的NLB，那么可以将Pod独立放在一个网段，将NLB和Node放在一个网段。本文的实测环境中，EKS 集群位于 VPC `vpc-0a69fad178fdc8284`，三个 AZ 的私有子网 CIDR 分别为 `192.168.128.0/19`（1a）、`192.168.160.0/19`（1b）、`192.168.96.0/19`（1c），Pod 使用 100.64.0.0/16 扩展网段的三个子网。私有 NLB 将放在上述三个 192.168 私有子网中。接下来将确认这些子网的已用 IP 地址情况。

### 2、查询可用IP地址

进入VPC的子网页面，通过子网界面，确认要部署私有NLB的子网的CIDR地址范围。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/nlb-private-ip/private-ip-1.png)

从这三个子网中人为协商确认分配IP地址，例如本文实测选取的三个 IP 分别为 `192.168.159.250`（AZ 1a）、`192.168.191.250`（AZ 1b）、`192.168.127.250`（AZ 1c），每个 IP 均位于对应子网的 CIDR 范围内。接下来通过 ENI 网卡查询是否被使用。也可以使用 AWSCLI 直接列出对应子网中已被 ENI 占用的 IP，命令示例如下：

```shell
aws ec2 describe-network-interfaces \
  --region ap-southeast-1 \
  --filters "Name=subnet-id,Values=<subnet-id>" \
  --query 'NetworkInterfaces[].PrivateIpAddress' \
  --output text
```

进入EC2界面，从左侧菜单找到ENI网卡，然后再搜索框中搜索要使用的IP地址。为了精确查找，可以逐段输入。当输入IP地址的前三段后，如果查询结果有匹配条目，则表示IP地址已经被使用。如果没有搜索到结果，则表示地址空闲可以被使用。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/nlb-private-ip/private-ip-2.png)

### 3、确认已经安装AWS Load Balancer Controller

安装方法请参考[这里](https://github.com/aobao32/eks-101-workshop/blob/main/02-deploy-alb-ingress.md)，本文不再赘述。

### 4、确认VPC和Subnet带有EKS的ELB所需要的标签

请确保本子网已经设置了正确的路由表，且VPC内包含NAT Gateway可以提供外网访问能力。然后接下来为其打标签。

找到当前的VPC，找到有EIP和NAT Gateway的Public Subnet，为其添加标签：

- 标签名称：kubernetes.io/role/elb，值：1

接下来进入 Private subnet（本文中承载私有 NLB 的三个 192.168 私有子网），为其添加标签：

- 标签名称：kubernetes.io/role/internal-elb，值：1

接下来请重复以上工作，三个AZ的子网都实施相同的配置，注意第一项标签值都是1。使用 eksctl 创建集群时，上述两个标签由 eksctl 自动写入，可通过 `aws ec2 describe-subnets` 检查是否已存在。若使用其他方式创建集群，需要手工补齐。

## 三、启动应用部署私有NLB并指定内网IP

### 1、部署应用并创建私有NLB

编写如下 yaml 文件，替换其中的 NLB 参数、私有子网 ID 和 IP 地址为您的环境所需参数。

注意：IP 地址的总个数必须与提交给 NLB 的子网数量一致，并按顺序与 `service.beta.kubernetes.io/aws-load-balancer-subnets` 中的子网 ID 一一对应；每个 IP 必须落在对应子网的 CIDR 范围内。所有 IP 地址以字符串格式提交，需前后加双引号。`service.beta.kubernetes.io/aws-load-balancer-scheme: internal` 显式指定 NLB 为内网调度，避免在同时打了 `kubernetes.io/role/elb` 与 `kubernetes.io/role/internal-elb` 标签的 VPC 中被解析为公网。本例使用外部容器镜像仓库 `public.ecr.aws/nginx/nginx:1.31-alpine-slim` 作为示例，请替换其中的 image 镜像地址为您的 ECR 上的镜像地址。

```yaml
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
      - image: public.ecr.aws/nginx/nginx:1.31-alpine-slim
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
    service.beta.kubernetes.io/aws-load-balancer-scheme: internal
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-healthy-threshold: "2"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-unhealthy-threshold: "2"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-interval: "10"
    service.beta.kubernetes.io/aws-load-balancer-attributes: load_balancing.cross_zone.enabled=true
    service.beta.kubernetes.io/aws-load-balancer-subnets: subnet-049ad8896ca32ad98, subnet-0fa9c7b38b01cd9ba, subnet-053474fb58c51db51
    service.beta.kubernetes.io/aws-load-balancer-private-ipv4-addresses: "192.168.159.250, 192.168.191.250, 192.168.127.250"
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

将以上配置文件保存为 `NLB-internal-with-private-ip.yaml`，然后执行如下命令拉起服务：

```shell
kubectl apply -f NLB-internal-with-private-ip.yaml
```

返回结果如下：

```
namespace/private-nlb-fixed-ip created
deployment.apps/nginx-deployment created
service/service-nginx created
```

### 2、查看私有NLB的入口

执行如下命令查看NLB入口。

```shell
kubectl get service service-nginx -n private-nlb-fixed-ip -o wide
```

返回结果如下：

```
NAME            TYPE           CLUSTER-IP   EXTERNAL-IP                                                                          PORT(S)        AGE   SELECTOR
service-nginx   LoadBalancer   10.50.0.41   k8s-privaten-servicen-9ba9cc7761-67abcf0a5530d29b.elb.ap-southeast-1.amazonaws.com   80:31477/TCP   35s   app.kubernetes.io/name=nginx
```

其中标记 `EXTERNAL-IP` 的字段就是 Private NLB 的地址，该地址只能从 VPC 内访问，不可以从互联网访问。

进一步执行如下 AWSCLI 命令，查看 NLB 分配到的静态私有 IP 是否与 yaml 中指定的 IP 一致：

```shell
aws elbv2 describe-load-balancers \
  --region ap-southeast-1 \
  --query "LoadBalancers[?contains(DNSName, 'k8s-privaten-servicen')].{Name:LoadBalancerName,Scheme:Scheme,State:State.Code,AZs:AvailabilityZones}" \
  --output json
```

返回结果如下（截取关键字段）：

```json
[
    {
        "Name": "k8s-privaten-servicen-9ba9cc7761",
        "Scheme": "internal",
        "State": "active",
        "AZs": [
            {"ZoneName": "ap-southeast-1c", "SubnetId": "subnet-053474fb58c51db51", "LoadBalancerAddresses": [{"PrivateIPv4Address": "192.168.127.250"}]},
            {"ZoneName": "ap-southeast-1b", "SubnetId": "subnet-0fa9c7b38b01cd9ba", "LoadBalancerAddresses": [{"PrivateIPv4Address": "192.168.191.250"}]},
            {"ZoneName": "ap-southeast-1a", "SubnetId": "subnet-049ad8896ca32ad98", "LoadBalancerAddresses": [{"PrivateIPv4Address": "192.168.159.250"}]}
        ]
    }
]
```

启动完毕后，进入 EC2 界面查看 NLB 的情况，即可看到 NLB 在三个 AZ 的私有子网上分别绑定了指定的静态 IP 地址。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/nlb-private-ip/private-ip-3.png)

### 3、测试访问

使用 EC2 Connect 功能，选择 Session Manager 登陆到 EKS 的 Node 节点。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/nlb-private-ip/private-ip-4.png)

在弹出的对话框内，选择第二个标签页 `Session Manager`，点击右下角的 `Connect` 按钮。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/nlb-private-ip/private-ip-5.png)

登陆到 Node 节点后，通过 curl 命令依次访问上一步分配的三个私有 IP：

```shell
for ip in 192.168.159.250 192.168.191.250 192.168.127.250; do
  curl -s -o /dev/null -w "HTTP=%{http_code} IP=%{remote_ip}\n" http://$ip/
done
```

返回结果如下：

```
HTTP=200 IP=192.168.159.250
HTTP=200 IP=192.168.191.250
HTTP=200 IP=192.168.127.250
```

再次执行 `curl http://192.168.159.250/` 可以看到 nginx 欢迎页正常返回，如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/nlb-private-ip/private-ip-6.png)

## 四、其他注意事项

在VPC的子网管理中，有一项名为“CIDR预留”的功能。此功能不适用于指定NLB的内网IP分配功能。因为当标记为IP地址预留时候，此地址将不可被NLB所使用，由此会导致NLB创建失败。因此，为NLB指定IP前，查找IP地址是否被占用，通过ENI网卡界面查询即可。

## 五、删除实验环境（只删除应用Pod不删除集群）

执行如下命令删除实验环境：

```
kubectl delete -f NLB-internal-with-private-ip.yaml
```

## 六、参考文档

AWS Load Balancer Controller 官方文档中关于 Service 注解的完整列表。

[https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/service/annotations/](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/service/annotations/)

其中关于 `aws-load-balancer-private-ipv4-addresses` 的说明。

[https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/service/annotations/#private-ipv4-addresses](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/service/annotations/#private-ipv4-addresses)

全文完。