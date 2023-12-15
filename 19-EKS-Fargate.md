# 使用Fargate创建无服务器容器服务

## 一、背景

### 1、什么是Fargate

EKS服务使用EC2作为底层运行平台，要创建Pod，需要先指定EC2特定机型创建Nodegroup，然后在其上运行Pod。使用EC2作为Pod运行环境，需要用户管理EC2的资源使用情况，包括CPU分配、内存分配等，并辅以人工扩容或者自动扩容的方式。在此情况下，EKS除集群管理平面的计费之外，主要的计费就是EC2计费。EKS Nodegroup使用的EC2计费默认是按机型的按需计费方式，为优化成本可为对应机型购买RI预留实例，或者使用Spot竞价实例。

EKS Fargate是EKS的无服务器运行环境。使用EKS Fargate，可以直接创建对应Pod，而无需事先准备EC2 Nodegroup。由此，可简化整个技术架构的管理方式，无需考虑EC2的资源使用使用率是否充分、空闲是否足够的情况，可完全按照业务要求来定义Pod资源，直接启动Pod。使用Fargate模式时候，EKS除集群管理平面的计费之外，Fargate的资源是按照vCPU/内存的运行时长（秒计费）。

### 2、选择EC2 Nodegroup模式和Fargate模式

EKS的EC2模式和Fargate模式可同时使用。在一个EKS集群内，可同时使用EC2 Nodegroup和Fargate。当拉起一个应用环境的时候，可在Yaml中指定Namespaces或者通过Namespaces+Label的方式，指定特定Pod跑在EC2 Nodegroup上、并指定特定Pod跑在Fargate上。当然，也可以创建一个仅使用Fargate的EKS集群；也可以给之前创建的仅有EC2 Nodegroup的集群随时添加Fargate模式，这两种方式都是可行的。再操作步骤上是一致的。

从服务架构设计上，推荐使用混合EC2 Nodegroup和Fargate模式的集群。这是因为，部分EKS系统服务，包括kube-dns、aws-load-balancer-controller等组件是需要持续运行的，并非弹性的。如果创建一个仅有Fargate的集群，那么这些控制组件就必须也用Fargate模式长时间运行个，这样相对不划算。

因此，推荐在一个EKS集群内混合EC2 Nodegroup和Fargate模式，将基础服务包括kube-dns、aws-load-balancer-controller等组件创建在EC2 Nodegroup上（无需额外步骤，默认就是在EC2上），然后创建Fargate Profle和Namespaces，并手工的显式指定那些应用要跑在Fargate上，其余应用不额外指定的话则默认跑在EC2 Nodegroup上。
 
## 二、创建一个位于私有子网的EKS集群且启动2个节点的EC2 Nodegroup

### 1、集群创建

如果是为之前已经使用EC2 Nodegroup的EKS集群添加Fargate，那么可以跳过本章节。如果目前还没有任何EKS集群，那么这里可以创建一个不含EC2 Nodegroup的空白EKS集群，稍后为其配置Fargate模式。

相关工具包括eksctl、kubectl等脚本的下载和使用请参考[本篇]()博客。

定义如下配置文件：

```yaml
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
    instanceType: t3.xlarge
    minSize: 2
    desiredCapacity: 2
    maxSize: 2
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

将以上配置文件保存为`eks-private-subnet.yaml`，然后执行如下命令启动集群。

```shell
eksctl create cluster -f eks-private-subnet.yaml
```

集群启动完成。这个集群将在私有子网启动，包括2个t3.xlarge节点组成NodeGroup。

### 2、安装AWS Load Balancer Controller

详细介绍请参考[本篇](https://blog.bitipcman.com/eks-workshop-101-part2/)博客。本文以下为快速部署的简单步骤，不包含详细讲解。

#### (1) 配置EKS集群的iam-oidc-provider

```
eksctl utils associate-iam-oidc-provider --region ap-southeast-1 --cluster eksworkshop --approve
```

#### (2) IAM相关设置

如果本AWS账号下之前配置过其他EKS集群，已经具有相应的IAM Policy和IAM Role，本步骤可跳过。

```shell
curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam_policy.json
```

#### (3) 创建EKS Service Account

执行如下命令。请替换cluster、attach-policy-arn、region等参数为本次实验环境的参数。其他参数保持不变。

```shell
eksctl create iamserviceaccount \
  --cluster=eksworkshop \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn=arn:aws:iam::133129065110:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve
```

#### (4) 准备好helm并更新到最新

执行如下命令：

```shell
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks
```

#### (5) 部署AWS Load Balancer Controller

在默认的kube-system的Namespace下创建Load Balancer Controller。请替换如下命令中的集群名称，然后执行如下命令。

```shell
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=eksworkshop \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
```

#### (6) 确认部署成功

执行如下命令：

```shell
kubectl get deployment -n kube-system aws-load-balancer-controller
```

返回结果能看Load Balance Controller的Pod，则表示部署成功。例如返回结果如下。

```shell
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
aws-load-balancer-controller   2/2     2            2           89s
```

### 3、在EC2 Nodegroup上启动测试应用

现在测试AWS Load Balancer Controller工作是否正常。在如下配置文件中，分别创建：

- Namespace，指定Namespace不使用默认的Default
- Deployment，包含Pod应用，指定Namespace
- Service，包含NLB，使用Pod的IP作为Target Group的源，指定Namespace

完整配置文件：

```yaml
---
apiVersion: v1
kind: Namespace
metadata: 
  name: test1-ec2nodegroup
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-ec2nodegroup
  namespace: 	test1-ec2nodegroup
  labels:
    app: nginx-ec2nodegroup
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx-ec2nodegroup
  template:
    metadata:
      labels:
        app: nginx-ec2nodegroup
    spec:
      containers:
      - name: nginx-ec2nodegroup
        image: public.ecr.aws/nginx/nginx:1.24-alpine-slim
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-ec2nodegroup
  namespace: test1-ec2nodegroup
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
spec:
  selector:
    app: nginx-ec2nodegroup
  type: LoadBalancer
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
```

执行如下命令启动服务：

```shell
kubectl apply -f test1-ec2nodegroup.yaml
```

启动成功后，查看NLB的地址，注意添加Namespace的名称`test1-ec2nodegroup`，查询服务入口：

```shell
kubectl get services --namespace test1-ec2nodegroup
```

查询结果如下：

```shell
NAME                         TYPE           CLUSTER-IP    EXTERNAL-IP                                                                          PORT(S)        AGE
service-nginx-ec2nodegroup   LoadBalancer   10.50.0.149   k8s-nginxec2-servicen-7d894c50a4-d88e28f7253c4dc2.elb.ap-southeast-1.amazonaws.com   80:32097/TCP   15m
```

使用curl访问NLB的地址，可测试访问成功。

### 4、关于使用ELB不同模式的补充说明

上述Demo应用的Yaml文件，通过AWS Load Balance Controller，启动了一个Public的也就是Internet-facing的NLB，允许外网接入。这个NLB对接到Pod时候Targate Group使用的是IP模式。当使用EC2 Nodegroup和Fargate时候，对Targate Group的要求有所不同：

- 由于K8S的API变化，因此原先基于Node Port方式启动一个NLB的很多API已经失效，或者是被官方列入了向后兼容模式，随时可能在未来版本升级时候失效。由此，推荐EKS集群创建完毕后，立刻安装AWS Load Balance Controller控制器。应用Ingress无论是采用ALB还是NLB+Nginx自建方案，都建议先AWS Load Balance Controller控制器
- 使用EC2 Nodegroup时候，ELB的Target group模式可以是Instance模式，也可以是IP模式。
- 使用Fargate时候，ELB的Target group模式必须是指定为IP模式，不支持Instance模式。

本文ELB的Target group均使用IP模式。

## 三、配置Fargate两种使用方式

Fargate模式下，创建容器使用会调度Pod，因此需要创建Fargate所需要的IAM Role。其过程可以手动在IAM控制台上创建，也可以通过eksctl命令在创建Fargate Profile时候自动创建。以本文为例，不需要手动创建，通过eksctl命令配置Fargate即可。

指定Pod在Fargate上运行，有两种Selector模式：

- 指定某Namespace，其上所有Pod都使用Fargate 
- 指定某Namespace，带有标签的Pod都在Fargate上，此模式也成为混合模式

可任选一使用，也可以同时使用。本文分别介绍这两种模式。

## 四、选择Namespace的方式让Pod运行在Fargate上

### 1、创建EKS Fargate Profile

如下命令指定在Namespace命名空间`test2-fargate`中的所有Pod都运行于Fargate上。

```shell
eksctl create fargateprofile \
    --cluster eksworkshop \
    --name test2-fargate \
    --namespace test2-fargate
```

注意：以上Profile只是指定Namespace，但是在EKS上并不会自动创建Namespace。对应的Namepsace需要手工创建，或者随着应用一起创建。

执行如下命令查看Fargate Profile创建结果：

```
eksctl get fargateprofile --cluster eksworkshop
```

### 2、应用Yaml编写实例

编写以下配置文件，在一开始的时候定义Namespace并创建。

```yaml
---
apiVersion: v1
kind: Namespace
metadata: 
  name: test2-fargate
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-fargate-pod
  namespace: test2-fargate
  labels:
    app: nginx-fargate-pod
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx-fargate-pod
  template:
    metadata:
      labels:
        app: nginx-fargate-pod
    spec:
      containers:
      - name: nginx-fargate-pod
        image: public.ecr.aws/nginx/nginx:1.24-alpine-slim
        resources:
          requests:
            cpu: "0.5"
            memory: "750M"
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-fargate-pod
  namespace: test2-fargate
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
spec:
  selector:
    app: nginx-fargate-pod
  type: LoadBalancer
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
```

将以上文件保存为`test2-fargate.yaml`，然后执行如下命令启动。

```shell
kubectl apply -f test2-fargate.yaml
```

### 3、查询Pod运行环境

Fargate创建比现有EC2上直接启动Pod要慢一些，等待2-3分钟后，再查看运行环境。

通过添加`-n`命令指定Namespace，以及添加`-o`命令输出更多参数，即可查询EC2 Nodegroup节点组和Pod运行环境：

```shell
kubectl get pods -n test2-fargate -o wide
```

返回结果如下：

```shell
NAME                                 READY   STATUS    RESTARTS   AGE   IP              NODE                                                       NOMINATED NODE   READINESS GATES
nginx-fargate-pod-75fcf896d5-2qxz9   1/1     Running   0          71s   172.31.55.250   fargate-ip-172-31-55-250.ap-southeast-1.compute.internal   <none>           <none>
nginx-fargate-pod-75fcf896d5-wpdjl   1/1     Running   0          71s   172.31.67.70    fargate-ip-172-31-67-70.ap-southeast-1.compute.internal    <none>           <none>
```

以上返回结果即可看到，Pod是运行在Fargate Node之上。

## 五、混合模式：指定某个Namespace下仅带有标签的Pod运行在Fargate上

### 1、创建EKS Fargate Profile

如下命令指定在Namespace命名空间`mix`中，只有带Label标签`runon=fargate`的Pod会运行于Fargate上，其余不带标签的Pod运行在EC2 Nodegroup上。在选择标签时候请注意，如果您定义的标签包含了yaml文件的关键字如`yes`、`true`等，那么请为其加上双引号将其定义为text字符串，否则可能会遇到提示yaml文件处理json格式错误。

```shell
eksctl create fargateprofile \
    --cluster eksworkshop \
    --name test3-mixed \
    --namespace test3-mixed \
    --labels runon=fargate
```

注意：以上Profile只是指定Namespace，但是在EKS上并不会自动创建Namespace。对应的Namepsace需要手工创建，或者随着应用一起创建。

### 2、创建Namespace

定义如下配置文件：

```yaml
---
apiVersion: v1
kind: Namespace
metadata: 
  name: test3-mixed
```

将以上内存保存为`test3-mixed-namespace.yaml`，然后创建之。

```shell
kubectl apply -f test3-mixed-namespace.yaml
```

### 3、编写Yaml文件本Namespace下不带有标签的Pod运行在EC2 Nodegroup上

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-mixed-ec2
  namespace: test3-mixed
  labels:
    app: nginx-mixed-ec2
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx-mixed-ec2
  template:
    metadata:
      labels:
        app: nginx-mixed-ec2
    spec:
      containers:
      - name: nginx-mixed-ec2
        image: public.ecr.aws/nginx/nginx:1.24-alpine-slim
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-mixed-ec2
  namespace: test3-mixed
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
spec:
  selector:
    app: nginx-mixed-ec2
  type: LoadBalancer
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
```

将以上文件保存为`test3-mixed-ec2.yaml`，然后执行如下命令启动。

```shell
kubectl apply -f test3-mixed-ec2.yaml
```

### 4、编写Yaml文件本Namespace下带有标签的Pod运行在Fargate上

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-mixed-fargate
  namespace: test3-mixed
  labels:
    app: nginx-mixed-fargate
    runon: fargate
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx-mixed-fargate
  template:
    metadata:
      labels:
        app: nginx-mixed-fargate
        runon: fargate
    spec:
      containers:
      - name: nginx-mixed-fargate
        image: public.ecr.aws/nginx/nginx:1.24-alpine-slim
        resources:
          requests:
            cpu: "1"
            memory: "1750M"
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-mixed-fargate
  namespace: test3-mixed
  labels:
    runon: fargate
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
spec:
  selector:
    app: nginx-mixed-fargate
  type: LoadBalancer
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
```

将以上文件保存为`test3-mixed-fargate.yaml`，然后执行如下命令启动。

```shell
kubectl apply -f test3-mixed-fargate.yaml
```

### 5、查看Pod运行环境

```shell
kubectl get pods -n test3-mixed -o wide
```

返回结果如下：

```shell
NAME                                   READY   STATUS    RESTARTS   AGE   IP              NODE                                                      NOMINATED NODE   READINESS GATES
nginx-mixed-ec2-5c68c7c8df-8fmng       1/1     Running   0          11h   172.31.85.129   ip-172-31-93-72.ap-southeast-1.compute.internal           <none>           <none>
nginx-mixed-ec2-5c68c7c8df-pz7rw       1/1     Running   0          11h   172.31.53.255   ip-172-31-53-43.ap-southeast-1.compute.internal           <none>           <none>
nginx-mixed-fargate-747577644f-9lnlt   1/1     Running   0          10h   172.31.61.98    fargate-ip-172-31-61-98.ap-southeast-1.compute.internal   <none>           <none>
nginx-mixed-fargate-747577644f-n2f2x   1/1     Running   0          10h   172.31.84.94    fargate-ip-172-31-84-94.ap-southeast-1.compute.internal   <none>           <none>
```

以上结果即可看到本Namespace下同时存在EC2节点和Fargate节点。

使用如下命令指定Label，查询配置了Label的Pod：

```shell
kubectl get pods -n test3-mixed -l runon -o wide
```

可以看到返回结果就是带有Label的两个Pod。

```shell
NAME                                   READY   STATUS    RESTARTS   AGE   IP             NODE                                                      NOMINATED NODE   READINESS GATES
nginx-mixed-fargate-747577644f-9lnlt   1/1     Running   0          10h   172.31.61.98   fargate-ip-172-31-61-98.ap-southeast-1.compute.internal   <none>           <none>
nginx-mixed-fargate-747577644f-n2f2x   1/1     Running   0          10h   172.31.84.94   fargate-ip-172-31-84-94.ap-southeast-1.compute.internal   <none>           <none>
```

### 6、测试应用

执行如下命令，获取本Namespace对应的NLB入口。

```shell
kubectl get services --namespace test3-mixed
```

返回结果如下：

```shell
NAME                  TYPE           CLUSTER-IP    EXTERNAL-IP                                                                          PORT(S)        AGE
nginx-mixed-ec2       LoadBalancer   10.50.0.17    k8s-test3mix-nginxmix-61febb02e3-ae45b4239866c787.elb.ap-southeast-1.amazonaws.com   80:31500/TCP   11h
nginx-mixed-fargate   LoadBalancer   10.50.0.113   k8s-test3mix-nginxmix-9c4bce1473-4ae758d1b8d8bc46.elb.ap-southeast-1.amazonaws.com   80:31839/TCP   10h
```

分别使用curl测试之，确认正常。

### 7、小结

回顾以上实验，我们分别使用了传统的EC2 Nodegroup（Test1），指定Namespace部署Fargate（Test），在同一个Namespace下通过Label标签区分Fargate（Test3）。

通过图形管理工具，如K9S，可以清晰的看到Pod分布和对应的Node。带有Fargate字样的是Fargate拉起的Node。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/fargate/fargate-01.png)

## 六、Fargate资源分配说明

### 1、在Yaml中定义Pod使用的资源量

指定Fargate的资源，是通过`Resource`标签的`request`或`limit`值指定。在使用Fargate的配置文件中，如果不指定申请的资源大小，则Fargate默认分配0.25vCPU和0.5GB内存。

在上述配置文件中，可看到如下定义：

```yaml
          requests:
            cpu: "1"
            memory: "1750M"
```

这就是申请的Fargate Pod资源。但是请注意，Fargate计费是按照实际创建的资源计费，二者之间有一个Gap，请看如下分析。

### 2、EKS Fargate支持的Pod资源量组合

EKS Fargate可以使用的资源组合范围如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/fargate/fargate-02.png)

### 3、关于系统预留资源和Pod资源量规划

在EC2 Nodegroup上，每个EC2节点都会预留一定的资源，用于Kube-proxy/kube-dns等后台服务。

在Fargate上，每个Pod运行在一个Fargate环境中，这个Fargate也需要预留256MB内存用于系统进程。因此，申请Pod时候，EKS实际生成的Fargate都会自动添加256MB内存，并且向上凑整进位，才是真实的资源量。

这里举例如下：

- 在Yaml文件中申请`0.25vCPU/512MB`内存，Fargate将自动添加256MB内存等于768MB，根据上表规格清单中查询，向上进一位将真实分配`0.25vCPU/1GB`资源；
- 在Yaml文件中申请`0.5vCPU/1GB`内存，Fargate将自动添加256MB内存等于1280MB，根据上表规格清单中查询，向上进一位将真实分配`0.5vCPU/2GB`资源；
- 在Yaml文件中申请`1vCPU/1750MB`内存，Fargate将自动添加256MB内存等于2006MB（2GB是2048MB），根据上表规格清单中查询，向上进一位将真实分配`1vCPU/2GB`资源；
- 在Yaml文件中申请`1vCPU/4GB`内存，Fargate将自动添加256MB内存等于4352MB，根据上表规格清单中查询，向上进一位将真实分配`1vCPU/5GB`内存
- 在Yaml文件中申请`1vCPU/8GB`内存，Fargate将自动添加256MB内存等于8448MB，根据上表规格清单中查询，向上进一位将真实分配9GB内存；又因为1vCPU最大支持8GB内存，因此vCPU也会向上进位取整，最终真实分配是`2vCPU/9GB`内存；

其他情况以此类推。

### 4、查询现有Fargate Pod分配的资源

执行如下命令，请替换其中的Namespace和Pod名称为真实值。

```shell
kubectl describe pod --namespace test3-mixed nginx-mixed-fargate-7d67455886-chwzg
```

在输出结果中，可以看到如下一条：

```shell
Annotations:          CapacityProvisioned: 1vCPU 2GB
```

则表示本Pod分配的资源是1vCPU/2GB，实际计费也按照这个资源计费。

### 5、关于登录到Pod后使用Shell查询的系统资源

官方文档中的说法，Fargate Pod和实际分配的Farget环境是不一样的，一般实际分配的规格会更大，但是二者没有直接关系。

    There is no correlation between the size of the Pod 
    running on Fargate and the node size reported by 
    Kubernetes with kubectl get nodes. The reported node 
    size is often larger than the Pod's capacity. 

举例来说，Yaml中申请的`1vCPU/3750MB`，实际分配的是`1vCPU/4GB`，使用上文的`kubectl describe pod`命令查看其`Annotations`中，也是显示`1vCPU/4GB`，这时候账单也是按照`1vCPU/4GB`计费的。但是，登录到Pod的Shell中，执行`free -m`命令查看内存，查看到的内存值可能大于4GB，有可能是6GB或者8GB。这是正常的。Fargate将只按照`Annotations`中显示的计费。

## 七、参考资料

手工创建Fargate所需的Pod运行IAM Role

[https://docs.aws.amazon.com/zh_cn/eks/latest/userguide/pod-execution-role.html]()

EKS Mixed Mode Deployment Fargate Serverless & EC2 Worker Nodes - 3 Apps ¶

[https://www.stacksimplify.com/aws-eks/aws-fargate/learn-to-run-kubernetes-workloads-on-aws-eks-and-aws-fargate-serverless-part-2/#create-fargate-profile-manifest]()

eksctl - EKS Fargate Support¶

[https://eksctl.io/usage/fargate-support/]()

Fargate Pod configuration 机型和计费

[https://docs.aws.amazon.com/eks/latest/userguide/fargate-pod-configuration.html]()