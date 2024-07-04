# 实验八、为VPC扩展IP地址并配置EKS Pod使用独立的IP地址段

EKS 1.30 版本 @2024-07 AWS Global区域测试通过

## 一、背景及网络场景选择

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

#### （2）方案二、更换Kubenetus社区的CNI并配置EKS Pod使用非VPC IP地址

如果希望EKS上的Pod完全不使用本VPC的IP地址，这可以更换EKS的CNI网络插件，官方文档[这里](https://docs.aws.amazon.com/zh_cn/eks/latest/userguide/alternate-cni-plugins.html)做了介绍。在集群创建后，可删除默认的AWS VPC CNI，然后安装WeaveNet等插件。

#### （3）方案三、为VPC扩展IP地址并配置EKS Pod使用独立的IP地址段

VPC和EKS都支持使用扩展地址段。在此方案下，继续使用EKS默认的VPC CNI，首先为现有VPC扩展IP地址，并配置EKS使用扩展IP地址。本方案影响较小，过度平滑，不需要额外创建VPC，也不需要重新部署EKS网络CNI。

要添加的IP，通常是VPC的CIDR扩展，或者是100.64的保留网段。AWS云上100.64是定义为保留网段使用。

需要注意的是，扩展IP地址存在范围限制，并不是任意IP都可以添加到VPC的扩展范围内，请注意参考[这里](https://docs.aws.amazon.com/zh_cn/vpc/latest/userguide/configure-your-vpc.html#add-cidr-block-restrictions)文档描述的限制范围。如果此IP段不可接受，则因考虑其他方案。

本文描述方案三，即为VPC扩展IP。

### 3、为VPC扩展IP地址并配置EKS Pod使用独立的IP地址段的架构图

如上文描述，为VPC扩展IP地址并配置EKS Pod使用独立的IP地址段。架构图如下。

![](https://blogimg.bitipcman.com/2022/05/04102242/eks-vpc-cidr-for-pod.png)

在这张图内，以AZ1的网络为例进行讲解，分成几个层面：

- VPC的CIDR是172.31.0.0/16，因此现有的子网都在这个范围内
- 部署NAT Gateway的公有子网，分配了是172.31.0.0/20的子网
- 部署EKS的Nodegroup的节点组是在私有子网，分配了172.31.48.0/20的子网
- 为了模拟VPC扩容，在VPC上新增了100.64.0.0/16的网段，并且分配了一个Pod专用子网100.64.0.0/17，且这个子网也是私有子网，对互联网的交互是依赖NAT Gateway的

下面开始描述配置过程。

## 二、为现有VPC扩展地址段

### 1、为VPC添加新的IP地址

首先查看当前VPC的IP范围，并查看AWS[官方文档](https://docs.aws.amazon.com/zh_cn/vpc/latest/userguide/configure-your-vpc.html#add-cidr-block-restrictions)描述的可扩充IP范围的限制。

首先进入VPC界面，选择要添加IP地址的VPC，点击右上角的操作，选择修改CIDR。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/ip/pod01.png)

进入添加IP地址段界面，添加上第二个地址段，例如`100.64.0.0/16`，然后点击右侧的分配按钮，再点击下方的保存。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/ip/pod02.png)

### 2、为新的IP地址段创建新的子网

进入创建子网界面，选择对应的VPC，创建新的子网，并使用刚才新添加的IP地址段。例如本例中`100.64.0.0/16`被添加到VPC中，那么子网可采用`100.64.1.0/24`、`100.64.2.0/24`、`100.64.3.0/24`分别对应三个AZ。

如此分别为3个AZ都创建好对应的Pod使用的子网。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/ip/pod05.png)

操作完成。

### 3、为新增加的子网配置路由表

新创建好的子网会绑定到VPC默认路由表，因此还需要将新创建的子网绑定到和Node节点同一个路由表。进入路由表界面，查看Node所在的private subnet的路由表，可以看到当前只关联了三个Node子网。点击编辑按钮。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/ip/pod06.png)

将新创建的Pod子网关联到Node所在的Private子网的路由表上。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/ip/pod07.png)

添加子网完成后，确认下Node所在的子网和Pod所在的子网，所对应的路由表的下一跳是NAT Gateway。这是因为这两个子网都是私有子网，没有Elastic IP，因此默认网关下一跳都必须是NAT Gateway。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/ip/pod08.png)

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

## 三、配置并配置EKS集群

### 1、创建一个默认EKS集群

首先构建配置文件，替换其中的子网ID为Node所在的子网ID。

```

apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: eksworkshop
  region: ap-southeast-1
  version: "1.30"

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

managedNodeGroups:
  - name: managed-ng
    labels:
      Name: managed-ng
    instanceType: t3.2xlarge
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
      nodegroup-name: managed-ng
    iam:
      withAddonPolicies:
        imageBuilder: true
        autoScaler: true
        externalDNS: true
        certManager: true
        efs: true
        ebs: true
        fsx: true
        albIngress: true
        awsLoadBalancerController: true
        xRay: true
        cloudWatch: true

cloudWatch:
  clusterLogging:
    enableTypes: ["api", "audit", "authenticator", "controllerManager", "scheduler"]
    logRetentionInDays: 30
```

将以上内容保存为`eks-in-private-subnet.yaml`，然后运行如下命令启动集群。

```
eksctl create cluster -f eks-in-private-subnet.yaml
```

### 2、部署AWS Load Balancer Controller

有关详细部署Load Balancer Controllerd的说明请参考[前文的实验](https://github.com/aobao32/eks-101-workshop/blob/main/02-deploy-alb-ingress.md)。

### 3、部署CloudWatch Container Insight

部署CloudWatch Container Insight的方法与此前方法相同。可参考[这篇](https://github.com/aobao32/eks-101-workshop/blob/main/03-monitor-update-node-group.md)文档。

## 四、修改EKS的网络参数为Pod指定单独子网

注意：在修改本参数之后，必须重新创建新的Nodegroup才可以生效

### 1、调整aws-vpc-cni的参数分别设置Node子网和Pod子网

允许EKS自定义CNI网络插件的参数，执行如下命令：

``` 
kubectl set env daemonset aws-node -n kube-system AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG=true
```

返回如下信息表示配置成功。

```
daemonset.apps/aws-node env updated
```

进入AWS控制台，从子网界面查看子网信息，确定Pod所在子网，获得可用区ID和子网ID。将三个Pod子网的信息分别复制下来。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/ip/pod09.png)

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

执行命令`kubectl get ENIConfigs`验证配置是否成功。返回结果如下则表示设置成功。

```
NAME              AGE
ap-southeast-1a   91s
ap-southeast-1b   91s
ap-southeast-1c   90s
```

接下来为EKS设置标签，允许Node使用对应子网。执行如下命令：

```
kubectl set env daemonset aws-node -n kube-system ENI_CONFIG_LABEL_DEF=topology.kubernetes.io/zone
```

返回如下结果表示设置成功。

```
daemonset.apps/aws-node env updated
```

为了查询上述配置是否生效，可以自行如下命令：

```
kubectl describe daemonset aws-node -n kube-system | grep ENI_CONFIG_LABEL_DEF
```

返回如下结果表示设置成功。

```
      ENI_CONFIG_LABEL_DEF:                topology.kubernetes.io/zone
      ENI_CONFIG_LABEL_DEF:                topology.kubernetes.io/zone
      ENI_CONFIG_LABEL_DEF:                topology.kubernetes.io/zone
```

### 2、使用Node子网创建新的Nodegroup节点组

注意：修改了EKS网络参数后，必须重新创建新的Nodegroup节点组，原先的节点组不会发生过变化、原先的Pod也不会自动迁移到新分配的子网。另外如果EKS版本低于1.28版本，那么建议执行如下命令确认插件为最新。如果已经1.28版本可以暂时不用升级。

升级命令如下（会对现有pod造成短暂网络影响）。

构建如下内容，保存为`new-subnet-for-pod`文件。注意这里建议使用相同处理器架构的Nodegroup，这样便于Pod可以自动漂移过去。

```
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: eksworkshop
  region: ap-southeast-1
  version: "1.30"

managedNodeGroups:
  - name: newng
    labels:
      Name: newng
    instanceType: t3.2xlarge
    minSize: 3
    desiredCapacity: 3
    maxSize: 6
    volumeType: gp3
    volumeSize: 100
    volumeIOPS: 3000
    volumeThroughput: 125
    tags:
      nodegroup-name: new-subnet-for-pod
    iam:
      withAddonPolicies:
        imageBuilder: true
        autoScaler: true
        externalDNS: true
        certManager: true
        efs: true
        ebs: true
        fsx: true
        albIngress: true
        awsLoadBalancerController: true
        xRay: true
        cloudWatch: true
```

保存配置完毕后，执行如下命令生效：

```
eksctl create nodegroup -f new-subnet-for-pod.yaml
```
### 3、把旧的Nodegroup删除

如果新创建的Nodegroup是采用相同处理器架构的EC2，那么删除旧的Nodegroup时候，原有的Pod会自动漂移到新的Nodegroup上。反之，则要看本应用对应的镜像仓库上是否有分别提供X86_64版本和ARM版本的容器镜像，如果有对应版本的话原有的Pod会自动漂移到新的Nodegroup上，如果没有的话应用Pod会启动失败。

执行如下命令：

```
eksctl delete nodegroup --name managed-ng --cluster eksworkshop 
```

删除完毕后，即可在新的节点上用新的网络配置启动应用，这时候应用Pod网段将会与Node网段独立开。

## 五、测试多种ELB部署场景

### 1、在公有子网部署ALB Ingress并测试从互联网访问

#### （1）部署应用

构建应用配置文件。

```
---
apiVersion: v1
kind: Namespace
metadata:
  name: public-alb
---
apiVersion: apps/v1
kind: Deployment
metadata:
  namespace: public-alb
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
---
apiVersion: v1
kind: Service
metadata:
  namespace: public-alb
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
  namespace: public-alb
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

将上述配置文件保存为`public-alb.yaml`。然后执行如下命令启动：

```
kubectl apply -f public-alb.yaml
```

返回结果：

```
namespace/public-alb created
deployment.apps/nginx created
service/nginx created
ingress.networking.k8s.io/ingress-for-nginx-app created
```

#### （2）查看ALB Ingress入口地址并测试

执行如下命令可查看：

```
kubectl get ingress -n public-alb
```

返回结果：

```
NAME                    CLASS   HOSTS   ADDRESS                                                                        PORTS   AGE
ingress-for-nginx-app   alb     *       k8s-publical-ingressf-e3bf1572ab-1992535472.ap-southeast-1.elb.amazonaws.com   80      14s
```

#### （3）测试ALB访问

使用浏览器访问上一步获得的ALB的地址，即可看到应用部署成功。

### 2、在公有子网创建NLB并通过互联网访问

如果需求方式是网络流量发布而非HTTP请求发布，那么可不使用ALB Ingress，而是使用NLB发布四层端口。前文在创建子网部分已经描述了如何在Subnet上打上EKS的tag，由此EKS会自动找到对应子网。

####  （1）部署测试应用

构建如下测试应用：

```
---
apiVersion: v1
kind: Namespace
metadata:
  name: public-nlb
---
apiVersion: apps/v1
kind: Deployment
metadata:
  namespace: public-nlb
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
  namespace: public-nlb
  name: "service-nginx"
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
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

将以上配置文件保存为`public-nlb.yaml`，然后执行如下命令启动：

```
kubectl apply -f public-nlb.yaml
```

返回结果：

```
namespace/public-nlb created
deployment.apps/nginx-deployment created
service/service-nginx created
```

#### （2）查看Public NLB的入口地址

查看NLB入口。

```
kubectl get service service-nginx -n public-nlb -o wide 
``` 

返回结果如下。

```
NAME            TYPE           CLUSTER-IP    EXTERNAL-IP                                                                          PORT(S)        AGE    SELECTOR
service-nginx   LoadBalancer   10.50.0.224   k8s-publicnl-servicen-112bd18a54-a628f86f0217bffa.elb.ap-southeast-1.amazonaws.com   80:31011/TCP   118s   app.kubernetes.io/name=nginx
```

即可获得NLB的入口地址。

#### （3）测试公有NLB

从互联网访问上一步查询出来的NLB入口，可看到访问正常。

### 3、在私有子网部署只能从内网访问的私有NLB

#### （1）构建应用和私有NLB配置

在某些模式下，我们只需要对VPC内网或者其他VPC、专线等另一侧暴露内网NLB。因此这时候就不需要构建基于Internet-facing的公网NLB了，而是将NLB配置为私有NLB，其访问入口也只能通过VPC访问。构建如下一段配置：

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
    service.beta.kubernetes.io/aws-load-balancer-name: myphpdemo
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-healthy-threshold: "2"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-unhealthy-threshold: "2"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-interval: "10"
    service.beta.kubernetes.io/aws-load-balancer-attributes: load_balancing.cross_zone.enabled=true
    service.beta.kubernetes.io/aws-load-balancer-private-ipv4-addresses: 172.31.48.254, 172.31.64.254, 172.31.80.254
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

将以上配置文件保存为`private-nlb.yaml`，然后执行如下命令启动：

```
kubectl apply -f private-nlb.yaml
```

返回结果：

```
namespace/private-nlb-fixed-ip created
deployment.apps/nginx-deployment created
service/service-nginx created
```

#### （2）查看Private NLB入口地址并测试

查看NLB入口。

```
kubectl get service service-nginx -n private-nlb -o wide
``` 

```
NAME            TYPE           CLUSTER-IP   EXTERNAL-IP                                                                          PORT(S)        AGE    SELECTOR
service-nginx   LoadBalancer   10.50.0.34   k8s-privaten-servicen-3fe387f3ed-3b1e7aef54125420.elb.ap-southeast-1.amazonaws.com   80:32631/TCP   118s   app.kubernetes.io/name=nginx
```

这个地址将会解析为内网IP。

#### （3）测试从VPC内访问私有NLB

从VPC内访问以上的NLB入口地址，即可看到应用加载正常。

## 六、确认Pod运行在和Node相互独立的网段

上述几个场景的实验完整后，EKS集群上分别有了可从外网访问的ALB Ingress、Public NLB和Private NLB，以及他们背后的应用pod。

现在查看所有pod的IP，可发现除默认负责网络转发的kube-proxy和aws-node（VPC CNI）还运行在Node所在的Subnet上之外，新创建的应用都会运行在新的子网和IP地址段上。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/ip/pod11.png)

## 七、参考文档

Github上的AWS VPC CNI代码和文档：

[https://github.com/aws/amazon-vpc-cni-k8s]()

使用CNI自定义网络：

[https://docs.aws.amazon.com/eks/latest/userguide/cni-custom-network.html]()

EKS的NLB参数说明：

[https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.5/guide/service/nlb/]()