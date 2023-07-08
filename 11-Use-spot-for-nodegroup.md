# 实验十一、为NodeGroup使用EC2 Spot实例

## 一、规划使用Spot实例

### 1、为什么要使用Spot机型

EC2 Spot是云端当前Region和AZ内闲置的计算资源对外低价提供短期用途的一种商务模式。成本测算如下：

- 假设一个配置较高的机型采用 On-demand 按需默认的EC2实例每小时 10 元钱，那么跑满一个月则是 10元/小时 x 720小时 =7200元
- 如果购买 Reserve Instance（RI），其一整个月价格可能是 3600 元，或者更低（根据RI折扣）
- 当申请使用Spot时候，可能每小时只需要 3 元，跑满一个月 3元/小时 x 720小时 = 2160元

如果应用系统是高峰期的每天只有4个小时，那么一个月不需要按照 720 小时来计算成本，成本则是 3元/小时 x（4小时高峰/天x30天）= 3元/小时  x 120 小时 = 360元。

由此可看到使用Spot非常显著的降低了整体成本，因为负载有周期性浮动的，最佳手段不一定是新增几个RI预留实例节点，而是适当增加Spot节点混合到当前集群，实现按需缩放。

### 2、如何选择INTEL(X86_64)和Graviton(ARM)架构

ARM机型由于其比Intel机型更好的性能，更低的价格，获得了广泛用户的环境，普遍被用于EC2、EKS、RDS、Redis、OpenSearch等众多服务。

ARM机型由于相对较少的规格型号，在每个Region限制的比例也较低，而且替代机型少。例如，生产机型是m6g.2xlarge（8vCPU/32GB），那么使用Spot机型的型号一般是c6g.4xlarge（16vCPU/32GB）和r6g.2xlarge（8vCPU/64GB），可选的组合仅3个。

Intel机型由于上几代处理器机型的存在，可提供替代进行很多。以生产机型是m6g.2xlarge（8vCPU/32GB），那么替代机型可包括m4.2xlarge, m5.2xlarge。除此之外，还有AMD处理器机型，以及带有本地存储的m5d，本地存储和网络优化型m5dn等许多型号可以申请Spot。

由此可知，使用Intel的机型的Spot在选择广泛程度上更有优势。

### 3、使用ec2-instance-selector查看可选合适的机型

要查看能提供特定CPU和内存比例数量的机型，可以使用ec2-instance-selector工具，这个工具的安装使用方法参考[这篇](https://blog.bitipcman.com/ec2-instance-type-selector-cli/)文章。

假设运行EKS的Nodegroup节点希望配置最低32GB为目标，那么可按如下方式查询。

#### (1) 按机型查询

执行如下命令可以查看相似机型：

```
ec2-instance-selector --base-instance-type m6i.2xlarge --flexible
```

返回结果如下：

```
m3.2xlarge
m4.2xlarge
m5.2xlarge
m5a.2xlarge
m6a.2xlarge
t2.2xlarge
t3.2xlarge
```

#### (2) 按最低内存量进行查询

也可以手工指定vCPU和内存进行查询

```
ec2-instance-selector --vcpus 8 --memory 32
```

即可获得匹配的机型清单。

#### (3) 确认机型清单

将以上两个步骤配置清单合并。这其中：

- 增加上目标机型本身 `m6i.2xlarge`
- 去掉3系列机型（因为计算架构不是Nitro）
- 去掉t系列机型（Burst爆发型CPU算力不足）

最后可获得可用的机型清单如下：

```
m4.2xlarge
m5.2xlarge
m5a.2xlarge
m6a.2xlarge
```

### 4、基于Spot往期历史价格选择机型

Spot的目标是低成本的实现弹性扩展。因此，Spot机型的历史价格也是一个关注点。因此，使用Spot时候，有时候不是以特定机型为目标，而是以一组机型在当前一段时间内的折扣最优化为目标。

查看Spot历史的价格的方法是，进入EC2控制台，点击左侧的`Spot Requests`按钮。然后点击右侧的`Pricing history`按钮。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/spot/spot-01.png)

查询价格注意事项：

- 多个AZ可用区空余容量不一样，因此Spot价格可能不一样
- 查询价格页面右上角的选项`Display normalized prices`按钮不要打开，这个按钮是显示vCPU等单位价格，请确保这个按钮不要打开。当这个按钮没有打开时候，显示的On-Demand标准价格与AWS EC2官网Pricing页面的价格是一致的。

现在开始查询几个机型，例如`m6g.2xlarge`，`m5.2xlarge`，`m5a.2xlarge`三个机型。

在弹出的对话框中，在`Instance Type`位置输入要查询价格的目标机型，例如输入`m6g.2xlarge`（使用Graviton2处理器的ARM机型），可获得信息是按需机型（On-Demand）价格是`0.384`美元每小时，而Spot的折扣为`31.51%`，由此当前价格约为`0.2632`美元每小时。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/spot/spot-02.png)

接下来调查其他机型。在`Instance Type`位置输入`m5.2xlarge`（使用Intel Xeon处理器），可获得信息是按需机型（On-Demand）价格是`0.48`美元每小时，而Spot的折扣为`60.40%`，由此当前价格约为`0.1896`美元每小时。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/spot/spot-03.png)

接下来调查其他机型。在`Instance Type`位置输入`m5a.2xlarge`（使用AMD EPYC处理器），可获得信息是按需机型（On-Demand）价格是`0.432`美元每小时，而Spot的折扣为`35.05%`，由此当前价格约为`0.2867`美元每小时。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/spot/spot-04-2.png)

几个价格对比下来，Graviton2处理器虽然单价便宜，但总体容量不如之前的Intel机型，因此选择上一代Intel机型的Spot是价格最便宜的。本文为了方便代码编写和测试，将继续使用Graviton2的Spot机型。虽然价格没有Intel机型低，但是与本机型按需使用的On-Demand相比，依然有很大折扣，而且之前本文构建的ECR容器镜像，都是按照ARM架构构建的。因此本文的实验，将使用`m6g.2xlarge`的Spot机型进行构建。

## 二、新建使用Spot的Nodegroup

首先本文假设集群已经创建好，并且有Nodegroup存在，同时部署了AWS Load Balancer Controller等必要的逐渐。搭建本文实验环境可参考[这篇](https://blog.bitipcman.com/use-dedicate-subnet-for-eks-node-with-aws-vpc-cni/)文档完成。下面开始部署Spot节点。

### 1、为现有的EKS集群创建新的使用Spot的Nodegroup

本文假设

编辑如下内容，并保存为`spot-nodegroup.yaml`文件。需要注意的是，如果新创建的Nodegroup在Public Subnet内，这直接使用如下内容即可。如果新创建的Nodegroup在Private Subnet内，那么请增加如下一行`privateNetworking: true`到配置文件中。添加的位置在`volumeSize`的下一行即可。

```
apiVersion: eksctl.io/v1alpha5

kind: ClusterConfig

metadata:
  name: eksworkshop
  region: ap-southeast-1
  version: "1.23"

managedNodeGroups:
  - name: spot1
    labels:
      Name: spot1
    instanceTypes: ["m4.2xlarge","m5.2xlarge","m5d.2xlarge"]
    spot: true
    minSize: 3
    desiredCapacity: 3
    maxSize: 6
    volumeType: gp3
    volumeSize: 100
    tags:
      nodegroup-name: spot1
    iam:
      withAddonPolicies:
        imageBuilder: true
        autoScaler: true
        certManager: true
        efs: true
        albIngress: true
        xRay: true
        cloudWatch: true
```

编辑完毕后保存退出。执行如下命令创建：

```
eksctl create nodegroup -f spot-nodegroup.yaml
```

执行如下命令查看nodegroup是否正常。请注意修改cluster名称与当前集群名称要匹配。

```
eksctl get nodegroup --cluster eksworkshop
```

返回结果可以看到原来的和新创建的两个nodegroup如下。

```
CLUSTER		NODEGROUP	STATUS	CREATED			MIN SIZE	MAX SIZE	DESIRED CAPACITY	INSTANCE TYPE				IMAGE ID	ASG NAME						TYPE
eksworkshop	managed-ng	ACTIVE	2022-10-14T08:25:52Z	3		6		3			m5.2xlarge				AL2_x86_64	eks-managed-ng-32c1eacc-bd74-6172-37c3-d9a66afa8512	managed
eksworkshop	spot1		ACTIVE	2022-10-14T09:39:29Z	3		6		3			m4.2xlarge,m5.2xlarge,m5d.2xlarge	AL2_x86_64	eks-spot1-88c1eaee-6f0f-0da3-a6a4-3b2792ee447a		managed
```

查看节点的创建时间：

```
kubectl get nodes --sort-by=.metadata.creationTimestamp
```

返回信息类似如下：

```
NAME                                               STATUS   ROLES    AGE     VERSION
ip-192-168-73-49.ap-southeast-1.compute.internal   Ready    <none>   3h30m   v1.23.9-eks-ba74326
ip-192-168-3-225.ap-southeast-1.compute.internal   Ready    <none>   3h30m   v1.23.9-eks-ba74326
ip-192-168-53-33.ap-southeast-1.compute.internal   Ready    <none>   3h30m   v1.23.9-eks-ba74326
ip-192-168-27-19.ap-southeast-1.compute.internal   Ready    <none>   136m    v1.23.9-eks-ba74326
ip-192-168-46-69.ap-southeast-1.compute.internal   Ready    <none>   136m    v1.23.9-eks-ba74326
ip-192-168-65-14.ap-southeast-1.compute.internal   Ready    <none>   136m    v1.23.9-eks-ba74326
```

### 3、查看当前集群的On-Demand节点

执行如下命令：

```
kubectl get nodes \
  --label-columns=eks.amazonaws.com/capacityType \
  --selector=eks.amazonaws.com/capacityType=ON_DEMAND
```

输出结果类似如下：

```
NAME                                               STATUS   ROLES    AGE   VERSION               CAPACITYTYPE
ip-192-168-3-225.ap-southeast-1.compute.internal   Ready    <none>   68m   v1.23.9-eks-ba74326   ON_DEMAND
ip-192-168-53-33.ap-southeast-1.compute.internal   Ready    <none>   68m   v1.23.9-eks-ba74326   ON_DEMAND
ip-192-168-73-49.ap-southeast-1.compute.internal   Ready    <none>   68m   v1.23.9-eks-ba74326   ON_DEMAND
```

### 4、查看当前集群的Spot节点

查看节点类型是Spot的Node：

```
kubectl get nodes \
  --label-columns=eks.amazonaws.com/capacityType \
  --selector=eks.amazonaws.com/capacityType=SPOT
```

返回结果如下：

```
NAME                                               STATUS   ROLES    AGE    VERSION               CAPACITYTYPE
ip-192-168-27-19.ap-southeast-1.compute.internal   Ready    <none>   141m   v1.23.9-eks-ba74326   SPOT
ip-192-168-46-69.ap-southeast-1.compute.internal   Ready    <none>   141m   v1.23.9-eks-ba74326   SPOT
ip-192-168-65-14.ap-southeast-1.compute.internal   Ready    <none>   141m   v1.23.9-eks-ba74326   SPOT
```

## 三、部署应用分别运行在Spot和On-demand机型上

### 1、使用Spot的yaml配置文件

在和Container配置平级的位置，增加如下一段配置，表示优先使用Spot节点运行服务：

```
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 1
            preference:
              matchExpressions:
              - key: eks.amazonaws.com/capacityType
                operator: In
                values:
                - SPOT
      tolerations:
      - key: "spotInstance"
        operator: "Equal"
        value: "true"
        effect: "PreferNoSchedule"
```

在和Container配置平级的位置，增加如下一段配置，表示强制使用On-demand节点运行服务：

```
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: eks.amazonaws.com/capacityType
                operator: In
                values:
                - ON_DEMAND
```

### 2、使用Spot的yaml文件示例

```
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-nginx-od
  labels:
    app: demo-nginx-od
spec:
  replicas: 3
  selector:
    matchLabels:
      app: demo-nginx-od
  template:
    metadata:
      labels:
        app: demo-nginx-od
    spec:
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 1
            preference:
              matchExpressions:
              - key: eks.amazonaws.com/capacityType
                operator: In
                values:
                - SPOT
      tolerations:
      - key: "spotInstance"
        operator: "Equal"
        value: "true"
        effect: "PreferNoSchedule"
      containers:
      - name: demo-nginx-od
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
  name: "demo-nginx-od"
  annotations:
        service.beta.kubernetes.io/aws-load-balancer-type: nlb
spec:
  selector:
    app: demo-nginx-od
  type: LoadBalancer
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
```

### 3、使用On-demand的yaml文件示例

```
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-nginx-spot
  labels:
    app: demo-nginx-spot
spec:
  replicas: 3
  selector:
    matchLabels:
      app: demo-nginx-spot
  template:
    metadata:
      labels:
        app: demo-nginx-spot
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: eks.amazonaws.com/capacityType
                operator: In
                values:
                - ON_DEMAND
      containers:
      - name: demo-nginx-spot
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
  name: "demo-nginx-spot"
  annotations:
        service.beta.kubernetes.io/aws-load-balancer-type: nlb
spec:
  selector:
    app: demo-nginx-spot
  type: LoadBalancer
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
```

## 三、查看在On-demand和Spot节点上的Pod

### 1、查看Spot节点上的Pod

执行如下命令：

```
 for n in $(kubectl get nodes -l eks.amazonaws.com/capacityType=SPOT --no-headers | cut -d " " -f1); do echo "Pods on instance ${n}:";kubectl get pods --all-namespaces  --no-headers --field-selector spec.nodeName=${n} ; echo ; done
```

返回信息如下：

```
Pods on instance ip-192-168-27-19.ap-southeast-1.compute.internal:
default       demo-nginx-spot-79676dcc79-2mlv8   1/1   Running   0             117s
kube-system   aws-node-pdcx2                     1/1   Running   1 (11h ago)   2d3h
kube-system   kube-proxy-j5xdm                   1/1   Running   1 (11h ago)   2d3h

Pods on instance ip-192-168-46-69.ap-southeast-1.compute.internal:
default       demo-nginx-spot-79676dcc79-gpk4z   1/1   Running   0             118s
kube-system   aws-node-nmz6k                     1/1   Running   1 (11h ago)   2d3h
kube-system   kube-proxy-qpb6f                   1/1   Running   1 (11h ago)   2d3h

Pods on instance ip-192-168-65-14.ap-southeast-1.compute.internal:
default       demo-nginx-spot-79676dcc79-bllnb   1/1   Running   0             119s
kube-system   aws-node-vbl6f                     1/1   Running   1 (11h ago)   2d3h
kube-system   kube-proxy-45jfj                   1/1   Running   1 (11h ago)   2d3h
```

### 2、查看On-demand节点上的Pod

执行如下命令：

```
 for n in $(kubectl get nodes -l eks.amazonaws.com/capacityType=ON_DEMAND --no-headers | cut -d " " -f1); do echo "Pods on instance ${n}:";kubectl get pods --all-namespaces  --no-headers --field-selector spec.nodeName=${n} ; echo ; done
```

返回信息如下：

```
Pods on instance ip-192-168-3-225.ap-southeast-1.compute.internal:
default       demo-nginx-on-demand-5549798b4c-ftwq2   1/1   Running   0             3m5s
kube-system   aws-node-lgwn5                          1/1   Running   1 (11h ago)   2d4h
kube-system   kube-proxy-kvqd9                        1/1   Running   1 (11h ago)   2d4h

Pods on instance ip-192-168-53-33.ap-southeast-1.compute.internal:
default       demo-nginx-on-demand-5549798b4c-zkns8   1/1   Running   0             3m6s
kube-system   aws-node-jw6t2                          1/1   Running   1 (11h ago)   2d4h
kube-system   kube-proxy-6ncrr                        1/1   Running   1 (11h ago)   2d4h

Pods on instance ip-192-168-73-49.ap-southeast-1.compute.internal:
default       demo-nginx-on-demand-5549798b4c-nbxf8   1/1   Running   0             3m7s
kube-system   aws-node-7wh29                          1/1   Running   1 (11h ago)   2d4h
kube-system   coredns-6d8cc4bb5d-bfmmb                1/1   Running   1 (11h ago)   2d5h
kube-system   coredns-6d8cc4bb5d-fhj8p                1/1   Running   1 (11h ago)   2d5h
kube-system   kube-proxy-2wm22                        1/1   Running   1 (11h ago)   2d4h
```

## 参考文档

Spot最佳实践：

[https://docs.aws.amazon.com/zh_cn/AWSEC2/latest/UserGuide/spot-best-practices.html]()