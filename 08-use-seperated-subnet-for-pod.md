# 为VPC扩展IP地址并配置EKS Pod使用独立的IP地址段

## 一、背景

### 1、关于EKS的默认CNI

AWS EKS默认使用AWS VPC CNI（了解更多点[这里](https://github.com/aws/amazon-vpc-cni-k8s)），所有的Pod都将自动获得一个本VPC内的IP地址，从外部网络看Pod，它们的表现就如同一个普通EC2。这是AWS EKS默认的网络模式，也是强烈推荐的使用模式。

### 2、需要额外IP的解决方案（三选一）

某些场景下，可能当前创建VPC时候预留IP地址过少，要大规模启动容器会遇到VPC内可用IP地址不足。此时有几个办法：

#### （1）方案一、创建全新的VPC运行EKS

由于云上可以随时创建多个VPC，并可通过多种方式实现VPC和应用之间的互通，因此创建一个独立的VPC运行新的应用是最快捷的解决地址不足的办法。EKS的命令行管理工具eksctl默认的参数就是创建一个全新VPC。当创建全新VPC后，一般可通过如下方式让两个VPC之间的服务互通：

- 路由模式。如果两个VPC IP地址段不重叠且可路由，可通过VPC Peering或Transit Gateway打通两个VPC网络，实现三层和四层协议的全面互通；
- 通过公网方式。在一个VPC上的应用前配置好ELB并对外发布服务，然后对ELB可限制来源IP白名单，仅允许另一个VPC访问；
- 通过内网方式。在一个VPC上配置PrivateLink映射Endpoint Service，并在另一个VPC内提供Endpoint服务。

除此以外，可能还有其他方式用于实现跨VPC的应用互访，再次不逐个罗列。

#### （2）方案二、为VPC扩展IP地址并配置EKS Pod使用独立的IP地址段

VPC和EKS都支持使用扩展地址段。在此方案下，继续使用EKS默认的VPC CNI，首先为现有VPC扩展IP地址，并配置EKS使用扩展IP地址。本方案影响较小，过度平滑，不需要额外创建VPC，也不需要重新部署EKS网络CNI。需要注意的是，扩展IP地址存在范围限制，并不是任意IP都可以添加到VPC的扩展范围内，请注意参考[这里](https://docs.aws.amazon.com/zh_cn/vpc/latest/userguide/configure-your-vpc.html#add-cidr-block-restrictions)文档描述的限制范围。如果此IP段不可接受，则因考虑其他方案。

#### （3）方案三、更换Kubenetus社区的CNI并配置EKS Pod使用非VPC IP地址

如果希望EKS上的Pod完全不使用本VPC的IP地址，这可以更换EKS的CNI网络插件，官方文档[这里](https://docs.aws.amazon.com/zh_cn/eks/latest/userguide/alternate-cni-plugins.html)做了介绍。在集群创建后，可删除默认的AWS VPC CNI，然后安装WeaveNet等插件。

本文描述方案二，即为VPC扩展IP。

### 3、为VPC扩展IP地址并配置EKS Pod使用独立的IP地址段的架构图

如上文描述，本文使用方式2，也就是为VPC扩展IP地址并配置EKS Pod使用独立的IP地址段。架构图如下。

![](https://blogimg.bitipcman.com/2022/05/04102242/eks-vpc-cidr-for-pod.png)

下面开始描述配置过程。注：文档描述的IP地址段与上边的架构图地址段有出入，以实际配置为准。

## 二、为VPC添加第二IP地址段

### 1、为VPC添加IP地址

首先查看当前VPC的IP范围，并查看AWS[官方文档](https://docs.aws.amazon.com/zh_cn/vpc/latest/userguide/configure-your-vpc.html#add-cidr-block-restrictions)描述的可扩充IP范围的限制。

首先进入VPC界面，选择要添加IP地址的VPC，点击右上角的操作，选择修改CIDR。如下截图。

![](https://myworkshop.bitipcman.com/eks101/ip/pod01.png)

进入添加IP地址段界面，添加上第二个地址段，例如`100.64.0.0/16`，然后点击右侧的分配按钮，再点击下方的保存。如下截图。

![](https://myworkshop.bitipcman.com/eks101/ip/pod02.png)

### 2、为第二IP地址段创建子网

进入创建子网界面，选择对应的VPC，创建新的子网，并使用刚才新添加的IP地址段。例如本例中`100.64.0.0/16`被添加到VPC中，那么子网可采用`100.64.1.0/24`、`100.64.2.0/24`、`100.64.3.0/24`分别对应三个AZ。

如此分别为3个AZ都创建好对应的Pod使用的子网。如下截图。

![](https://myworkshop.bitipcman.com/eks101/ip/pod05.png)

操作完成。

### 3、为新增加的子网配置路由表

新创建好的子网会绑定到VPC默认路由表，因此还需要将新创建的子网绑定到和Node节点同一个路由表。进入路由表界面，查看Node所在的private subnet的路由表，可以看到当前只关联了三个Node子网。点击编辑按钮。如下截图。

![](https://myworkshop.bitipcman.com/eks101/ip/pod06.png)

将新创建的Pod子网关联到Node所在的Private子网的路由表上。如下截图。

![](https://myworkshop.bitipcman.com/eks101/ip/pod07.png)

添加子网完成后，确认下Node所在的子网和Pod所在的子网，所对应的路由表的下一跳是NAT Gateway。这是因为这两个子网都是私有子网，没有Elastic IP，因此默认网关下一跳都必须是NAT Gateway。如下截图。

![](https://myworkshop.bitipcman.com/eks101/ip/pod08.png)

备注：如果您使用了Gateway Load Balancer做的集中网络流量检测方案，那么这里的默认网关下一跳应该是TGW。如果您没有使用Gateway Load Balancer，默认下一跳都是NAT Gateway。

### 4、为要使用ELB的子网打标签

#### （1）使用Internet-facing ELB，面向公网提供服务

找到当前的VPC，找到有EIP和NAT Gateway的Public Subnet，为其添加标签（多个AZ需要同时添加）：

- 标签名称：`kubernetes.io/role/elb`，值：`1`

如果之前标签已经存在，请跳过这一步。

#### （2）使用Internal ELB，面向Private内部子网提供服务

在创建私有ELB时候，可选的任意子网创建，可以选择一个独立的私有子网部署ELB，也可以选择Node所在子网，也可以选择Pod所在子网。

本文以使用Node所在子网为例。在VPC界面上，找到Node使用的私有子网，为其添加标签（多个AZ需要同时添加）：

- 标签名称：`kubernetes.io/role/internal-elb`，值：`1`

接下来请重复以上工作，每个AZ的子网都实施相同的配置，注意第一项标签值都是1。至此VPC配置完毕。

## 三、配置EKS集群

### 1、创建一个不包含Node节点的空白EKS集群（设置Node所在子网）

首先构建配置文件，替换其中的子网ID为Node所在的子网ID。

```
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: eksworkshop
  region: ap-southeast-1
  version: "1.27"

vpc:
  clusterEndpoints:
    publicAccess:  true
    privateAccess: true
  subnets:
    private:
      ap-southeast-1a: { id: subnet-04a7c6e7e1589c953 }
      ap-southeast-1b: { id: subnet-031022a6aab9b9e70 }
      ap-southeast-1c: { id: subnet-0eaf9054aa6daa68e }

kubernetesNetworkConfig:
  serviceIPv4CIDR: 10.50.0.0/24

cloudWatch:
  clusterLogging:
    enableTypes: ["api", "audit", "authenticator", "controllerManager", "scheduler"]
    logRetentionInDays: 30
```

将以上内容保存为`eks-without-nodegroup.yaml`，然后运行如下命令启动集群。

```
eksctl create cluster -f eks-without-nodegroup.yaml
```

### 2、调整aws-vpc-cni的参数分别设置Node子网和Pod子网

允许EKS自定义CNI网络插件的参数，执行如下命令：

``` 
kubectl set env daemonset aws-node -n kube-system AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG=true
```

进入AWS控制台，从子网界面查看子网信息，确定Pod所在子网，获得可用区ID和子网ID。将三个Pod子网的信息分别复制下来。如下截图。

![](https://myworkshop.bitipcman.com/eks101/ip/pod09.png)

用文本编辑器编辑如下文件，替换其中的可用区ID和子网ID为Pod所在子网的ID，然后保存为`eniconfig.yaml`文件。

```
apiVersion: crd.k8s.amazonaws.com/v1alpha1
kind: ENIConfig
metadata: 
  name: ap-southeast-1a
spec: 
  subnet: subnet-0691037d70aac39da
---
apiVersion: crd.k8s.amazonaws.com/v1alpha1
kind: ENIConfig
metadata: 
  name: ap-southeast-1b
spec: 
  subnet: subnet-096d7481a653e3f47
---
apiVersion: crd.k8s.amazonaws.com/v1alpha1
kind: ENIConfig
metadata: 
  name: ap-southeast-1c
spec: 
  subnet: subnet-0db55d7fb02249825
```

将以上配置文件保存为`eniconfig.yaml`文件。然后执行如下命令：

```
kubectl apply -f eniconfig.yaml
```

接下来为EKS设置标签，允许Node使用对应子网。执行如下命令：

```
kubectl set env daemonset aws-node -n kube-system ENI_CONFIG_LABEL_DEF=topology.kubernetes.io/zone
```

为了查询上述配置是否生效，可以自行如下命令：

```
kubectl describe daemonset aws-node --namespace kube-system
```

通过输出结果即可确认配置生效。

### 3、使用Node子网创建新的Nodegroup节点组

注意：本实验采用的是创建全新集群，并修改网络配置，然后创建节点组。如果是现有集群，修改网络配置后也要重新创建Node才可以生效。

如果上述配置文件启动的Nodegroup是Graviton处理器的ARM机型，则需要额外执行如下命令确认插件为最新：

```
eksctl utils update-coredns --cluster eksworkshop --approve
eksctl utils update-kube-proxy --cluster eksworkshop --approve
eksctl utils update-aws-node --cluster eksworkshop --approve
```

构建如下内容，保存为`newnodegroup.yaml`文件。

```
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: eksworkshop
  region: ap-southeast-1
  version: "1.27"

managedNodeGroups:
  - name: newng1
    labels:
      Name: newng1
    instanceType: t4g.xlarge
    minSize: 3
    desiredCapacity: 3
    maxSize: 6
    privateNetworking: true
    subnets:
      - subnet-04a7c6e7e1589c953
      - subnet-031022a6aab9b9e70
      - subnet-0eaf9054aa6daa68e
    volumeType: gp3
    volumeSize: 100
    tags:
      nodegroup-name: newng1
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
```

保存配置完毕后，执行如下命令生效：

```
eksctl create nodegroup -f newnodegroup.yaml
```

## 四、部署AWS Load Balancer Controller

在EKS 1.21以上版本，由于API的变化，创建NLB和ALB Ingress都被整合到了Load Balancer Controller中。所以如果不部署Load Balancer Controller，NLB也是无法创建成功的。在部署Load Balancer Controller完成后，可以根据需要只部署NLB或者只部署ALB Ingress，或者同时部署两种负载均衡。

有关详细部署Load Balancer Controllerd的说明请参考[前文的实验](https://github.com/aobao32/eks-101-workshop/blob/main/02-deploy-alb-ingress.md)。

## 五、测试多种ELB部署方式

### 1、在公有子网部署ALB Ingress



### 2、在公有子网创建NLB并使用NodePort方式暴露应用

如果需求方式是使用Node节点的高位端口暴露应用，那么可不使用ALB Ingress，只是使用简单的NodePort方式暴露应用。前文在创建子网部分已经描述了如何在Subnet上打上EKS的tag，由此EKS会自动找到对应子网。

构建如下测试应用（Nginx）：

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
---
apiVersion: v1
kind: Service
metadata:
  name: "service-nginx"
  annotations:
        service.beta.kubernetes.io/aws-load-balancer-type: external
        service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
        service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
spec:
  selector:
    app: nginx
  type: LoadBalancer
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
```

将以上配置文件保存为`nginx-nlb.yaml`，然后执行如下命令启动：

```
kubectl apply -f nginx-nlb.yaml
```

查看NLB入口。

```
kubectl get service service-nginx -o wide 
``` 

启动完成后，查看所有pod的IP，可发现除默认负责网络转发的kube-proxy和aws-node（VPC CNI）还运行在Node所在的Subnet上之外，新创建的应用都会运行在新的子网和IP地址段上。如下截图。

![](https://myworkshop.bitipcman.com/eks101/ip/pod10.png)

### 3、在私有子网部署内网的NLB

在某些模式下，我们只需要对VPC内网或者其他VPC、专线等另一侧暴露内网NLB。因此这时候就不需要构建基于Internet-facing的公网NLB了。这种场景下，构建如下一段配置：

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
---
apiVersion: v1
kind: Service
metadata:
  name: "service-nginx"
  annotations:
        service.beta.kubernetes.io/aws-load-balancer-type: nlb-ip
        service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
        service.beta.kubernetes.io/aws-load-balancer-scheme: internal
        service.beta.kubernetes.io/aws-load-balancer-attributes: load_balancing.cross_zone.enabled=true
spec:
  selector:
    app: nginx
  type: LoadBalancer
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
```

## 七、部署CloudWatch Container Insight

部署CloudWatch Container Insight的方法与此前方法相同。可参考[这篇](https://github.com/aobao32/eks-101-workshop/blob/main/03-monitor-update-node-group.md)文档。

## 八、参考文档

Github上的AWS VPC CNI代码和文档：

[https://github.com/aws/amazon-vpc-cni-k8s](https://github.com/aws/amazon-vpc-cni-k8s)

使用CNI自定义网络：

[https://docs.aws.amazon.com/zh_cn/eks/latest/userguide/cni-custom-network.html](https://docs.aws.amazon.com/zh_cn/eks/latest/userguide/cni-custom-network.html)

EKS的NLB参数说明：

[https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.4/guide/service/annotations/#lb-scheme](https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.4/guide/service/annotations/#lb-scheme)