# 使用Fargate创建无服务器容器服务

> EKS 1.36 版本 @2026-09 AWS Global 区域（ap-southeast-1）实测通过，AWS Load Balancer Controller 版本为 v3.5.0，Fargate 节点 kubelet 版本为 `v1.36.3-eks-cb19647`。

## 一、背景

### 1、什么是Fargate

EKS服务使用EC2作为底层运行平台，要创建Pod，需要先指定EC2特定机型创建Nodegroup，然后在其上运行Pod。使用EC2作为Pod运行环境，需要用户管理EC2的资源使用情况，包括CPU分配、内存分配等，并辅以人工扩容或者自动扩容的方式。在此情况下，EKS除集群管理平面的计费之外，主要的计费就是EC2计费。EKS Nodegroup使用的EC2计费默认是按机型的按需计费方式，为优化成本可为对应机型购买RI预留实例，或者使用Spot竞价实例。

EKS Fargate是EKS的无服务器运行环境。使用EKS Fargate，可以直接创建对应Pod，而无需事先准备EC2 Nodegroup。由此，可简化整个技术架构的管理方式，无需考虑EC2的资源使用率是否充分、空闲是否足够的情况，可完全按照业务要求来定义Pod资源，直接启动Pod。使用Fargate模式时候，EKS除集群管理平面的计费之外，Fargate的资源是按照vCPU/内存的运行时长（秒计费）。

每个运行在Fargate上的Pod拥有独立的计算边界，不与其他Pod共享内核、CPU、内存和弹性网卡。与此相对应，Fargate也存在如下约束：不支持DaemonSet、不支持特权容器、不能使用`HostPort`与`HostNetwork`、不支持GPU，并且Fargate Pod只能运行在私有子网中（通过NAT Gateway访问外部，而不能直接路由到Internet Gateway）。

### 2、选择EC2 Nodegroup模式和Fargate模式

EKS的EC2模式和Fargate模式可同时使用。在一个EKS集群内，可同时使用EC2 Nodegroup和Fargate。当拉起一个应用环境的时候，可在Yaml中指定Namespaces或者通过Namespaces+Label的方式，指定特定Pod跑在EC2 Nodegroup上、并指定特定Pod跑在Fargate上。当然，也可以创建一个仅使用Fargate的EKS集群；也可以给之前创建的仅有EC2 Nodegroup的集群随时添加Fargate模式，这两种方式都是可行的，在操作步骤上是一致的。

从服务架构设计上，推荐使用混合EC2 Nodegroup和Fargate模式的集群。这是因为，部分EKS系统服务，包括CoreDNS、aws-load-balancer-controller等组件是需要持续运行的，并非弹性的。如果创建一个仅有Fargate的集群，那么这些控制组件就必须也用Fargate模式长时间运行，这样相对不划算。此外，CloudWatch Agent、Fluent Bit等以DaemonSet形式部署的组件无法运行在Fargate上，混合集群可以让这类组件继续运行在EC2节点上。

因此，推荐在一个EKS集群内混合EC2 Nodegroup和Fargate模式，将基础服务包括CoreDNS、aws-load-balancer-controller等组件创建在EC2 Nodegroup上（无需额外步骤，默认就是在EC2上），然后创建Fargate Profile和Namespaces，并手工显式指定哪些应用要跑在Fargate上，其余应用不额外指定的话则默认跑在EC2 Nodegroup上。

下面开始创建实验集群。

## 二、创建一个位于私有子网的EKS集群且启动2个节点的EC2 Nodegroup

### 1、集群创建

现在创建一个EKS集群，使用两台EC2 Nodegroup节点，稍后为其配置Fargate模式。相关工具包括eksctl、kubectl等脚本的下载和使用请参考[本篇](https://blog.bitipcman.com/eks-workshop-101-part1/)博客。

如果已经按照实验一创建了名为`eksworkshop`的集群，则可以跳过本节，直接使用该集群。实验一由eksctl新建的VPC同时包含公有子网和带NAT Gateway的私有子网，满足Fargate对私有子网的要求。本文的实测即在实验一集群上完成。

本节配置文件使用现有VPC中的私有子网创建集群。定义如下配置文件，并将其中的三个子网ID替换为实际环境中位于三个可用区的私有子网ID。这些私有子网必须具备通往NAT Gateway的默认路由，否则节点与Fargate Pod将无法拉取镜像。

```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: eksworkshop
  region: ap-southeast-1
  version: "1.36"

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
    volumeIOPS: 3000
    volumeThroughput: 125
    tags:
      nodegroup-name: managed-ng
    iam:
      withAddonPolicies:
        imageBuilder: true
        autoScaler: true
        certManager: true
        efs: true
        ebs: true
        awsLoadBalancerController: true
        xRay: true
        cloudWatch: true

cloudWatch:
  clusterLogging:
    enableTypes: ["api", "audit", "authenticator", "controllerManager", "scheduler"]
    logRetentionInDays: 30
```

将以上配置文件保存为`eks-private-subnet.yaml`。创建前先执行如下命令进行只读校验，该命令不会创建任何资源，可提前发现子网ID错误等配置问题：

```shell
eksctl create cluster -f eks-private-subnet.yaml --dry-run
```

校验通过后，执行如下命令启动集群。

```shell
eksctl create cluster -f eks-private-subnet.yaml
```

集群启动完成。这个集群将在私有子网启动，包括2个t3.xlarge节点组成NodeGroup。

### 2、安装AWS Load Balancer Controller

详细介绍请参考[本篇](https://blog.bitipcman.com/eks-workshop-101-part2/)博客以及本仓库的[实验二](https://github.com/aobao32/eks-101-workshop/blob/main/02-deploy-alb-ingress.md)。本文以下为快速部署的简单步骤，不包含详细讲解。如果集群已经按照实验二部署了AWS Load Balancer Controller，本节可直接跳到第（6）步确认部署状态。

#### (1) 配置EKS集群的iam-oidc-provider

```shell
eksctl utils associate-iam-oidc-provider --region ap-southeast-1 --cluster eksworkshop --approve
```

#### (2) IAM相关设置

如果本AWS账号下之前配置过其他EKS集群，已经具有相应的IAM Policy和IAM Role，本步骤可跳过。但需要确认已有的IAM Policy与上游最新版本一致，策略陈旧会导致控制器报`AccessDenied`且负载均衡器无法创建，更新方法请参考实验二。

```shell
curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam_policy.json
```

#### (3) 创建EKS Service Account

执行如下命令。请替换cluster、region、attach-policy-arn等参数为本次实验环境的参数。其他参数保持不变。注意`--region`参数不可省略，否则eksctl会使用AWS CLI配置文件中的默认区域，在默认区域与集群区域不一致时会因找不到集群而中止。

```shell
eksctl create iamserviceaccount \
  --cluster=eksworkshop \
  --region=ap-southeast-1 \
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

本文的控制器运行在EC2 Nodegroup上，可通过实例元数据服务（IMDS，Instance Metadata Service）自动获取区域与VPC ID。如果集群中没有EC2节点、控制器本身也需要运行在Fargate上，由于Fargate Pod无法访问IMDS，需要在以上命令中追加`--set region=ap-southeast-1`与`--set vpcId=<vpc-id>`两个参数。

#### (6) 确认部署成功

执行如下命令：

```shell
kubectl get deployment -n kube-system aws-load-balancer-controller
```

返回结果能看Load Balance Controller的Pod，则表示部署成功。例如返回结果如下。

```shell
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
aws-load-balancer-controller   2/2     2            2           6d4h
```

### 3、在EC2 Nodegroup上启动测试应用

现在测试AWS Load Balancer Controller工作是否正常。在如下配置文件中，分别创建：

- Namespace，指定Namespace不使用默认的Default
- Deployment，包含Pod应用，指定Namespace
- Service，包含NLB，使用Pod的IP作为Target Group的源，指定Namespace

其中Service的`spec.loadBalancerClass`设置为`service.k8s.aws/nlb`，表示该Service由AWS Load Balancer Controller负责创建NLB；`aws-load-balancer-nlb-target-type: ip`表示Target Group使用IP模式。

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
  namespace: test1-ec2nodegroup
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
        image: public.ecr.aws/nginx/nginx:1.31-alpine-slim
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
  loadBalancerClass: service.k8s.aws/nlb
  selector:
    app: nginx-ec2nodegroup
  type: LoadBalancer
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
```

将以上文件保存为`test1-ec2nodegroup.yaml`，执行如下命令启动服务：

```shell
kubectl apply -f test1-ec2nodegroup.yaml
```

启动成功后，查看NLB的地址，注意添加Namespace的名称`test1-ec2nodegroup`，查询服务入口：

```shell
kubectl get services --namespace test1-ec2nodegroup
```

查询结果如下：

```shell
NAME                 TYPE           CLUSTER-IP    EXTERNAL-IP                                                                          PORT(S)        AGE
nginx-ec2nodegroup   LoadBalancer   10.50.0.115   k8s-test1ec2-nginxec2-d03f888d05-503c38ea92569b60.elb.ap-southeast-1.amazonaws.com   80:30297/TCP   47s
```

NLB从创建到状态变为`active`约需2至3分钟，此后其DNS名称还需要一段时间才能在客户端解析成功。在此期间curl会返回连接失败，这是正常现象，稍候重试即可。执行如下命令测试访问：

```shell
curl -s -o /dev/null -w '%{http_code}\n' http://k8s-test1ec2-nginxec2-d03f888d05-503c38ea92569b60.elb.ap-southeast-1.amazonaws.com
```

返回结果如下，表示访问成功：

```
200
```

### 4、关于使用ELB不同模式的补充说明

上述Demo应用的Yaml文件，通过AWS Load Balance Controller，启动了一个Public的也就是Internet-facing的NLB，允许外网接入。这个NLB对接到Pod时候Target Group使用的是IP模式。当使用EC2 Nodegroup和Fargate时候，对Target Group的要求有所不同：

- 推荐EKS集群创建完毕后，立刻安装AWS Load Balance Controller控制器，并在Service中通过`loadBalancerClass: service.k8s.aws/nlb`显式指定由该控制器创建NLB。应用Ingress无论是采用ALB还是NLB+Nginx自建方案，都建议先部署AWS Load Balance Controller控制器。
- 使用EC2 Nodegroup时候，ELB的Target group模式可以是Instance模式，也可以是IP模式。
- 使用Fargate时候，ELB的Target group模式必须是指定为IP模式，不支持Instance模式。

本文ELB的Target group均使用IP模式。下面进入Fargate的配置。

## 三、配置Fargate两种使用方式

Fargate模式下，Fargate需要以Pod执行角色（Pod execution role）的身份拉取镜像、向集群注册节点，因此需要创建Fargate所需要的IAM Role。其过程可以手动在IAM控制台上创建，也可以通过eksctl命令在创建Fargate Profile时候自动创建。以本文为例，不需要手动创建，通过eksctl命令配置Fargate即可。eksctl首次为集群创建Fargate Profile时，会先部署名为`eksctl-<集群名>-fargate`的CloudFormation栈，其中包含名称形如`eksctl-eksworkshop-fargate-FargatePodExecutionRole-<随机字符>`的IAM Role，后续创建的Fargate Profile复用该角色。

Fargate Profile未指定子网时，eksctl默认使用集群的全部私有子网，Fargate Pod的IP地址从这些子网中分配。

指定Pod在Fargate上运行，有两种Selector模式：

- 指定某Namespace，其上所有Pod都使用Fargate 
- 指定某Namespace，带有标签的Pod都在Fargate上，此模式也称为混合模式

可任选一使用，也可以同时使用。本文分别介绍这两种模式。

## 四、选择Namespace的方式让Pod运行在Fargate上

### 1、创建EKS Fargate Profile

如下命令指定在Namespace命名空间`test2-fargate`中的所有Pod都运行于Fargate上。

```shell
eksctl create fargateprofile \
    --cluster eksworkshop \
    --region ap-southeast-1 \
    --name test2-fargate \
    --namespace test2-fargate
```

返回结果如下（节选）。首次创建时会先部署Pod执行角色的CloudFormation栈，整个过程约3分钟：

```
2026-09-24 20:09:35 [ℹ]  deploying stack "eksctl-eksworkshop-fargate"
2026-09-24 20:09:35 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-fargate"
2026-09-24 20:10:06 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-fargate"
2026-09-24 20:10:09 [ℹ]  creating Fargate profile "test2-fargate" on EKS cluster "eksworkshop"
2026-09-24 20:12:20 [ℹ]  created Fargate profile "test2-fargate" on EKS cluster "eksworkshop"
```

注意：以上Profile只是指定Namespace，但是在EKS上并不会自动创建Namespace。对应的Namespace需要手工创建，或者随着应用一起创建。

执行如下命令查看Fargate Profile创建结果：

```shell
eksctl get fargateprofile --cluster eksworkshop --region ap-southeast-1
```

返回结果如下：

```
NAME		SELECTOR_NAMESPACE	SELECTOR_LABELS	POD_EXECUTION_ROLE_ARN										SUBNETS										TAGS	STATUS
test2-fargate	test2-fargate		<none>		arn:aws:iam::133129065110:role/eksctl-eksworkshop-fargate-FargatePodExecutionRole-6UZdN3VEYTMT	subnet-049ad8896ca32ad98,subnet-0fa9c7b38b01cd9ba,subnet-053474fb58c51db51	<none>	ACTIVE
```

返回结果中`SUBNETS`列即为集群的三个私有子网。

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
        image: public.ecr.aws/nginx/nginx:1.31-alpine-slim
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
  loadBalancerClass: service.k8s.aws/nlb
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

Fargate创建比现有EC2上直接启动Pod要慢一些。Pod创建后首先处于`Pending`状态，此时`NOMINATED NODE`列显示的是Fargate调度器分配的任务标识，而不是节点名称。实测约1分钟后Pod转为`Running`，建议等待1至2分钟后再查看运行环境。

通过添加`-n`命令指定Namespace，以及添加`-o`命令输出更多参数，即可查询EC2 Nodegroup节点组和Pod运行环境：

```shell
kubectl get pods -n test2-fargate -o wide
```

返回结果如下：

```shell
NAME                                 READY   STATUS    RESTARTS   AGE   IP                NODE                                                         NOMINATED NODE   READINESS GATES
nginx-fargate-pod-5cfd56b8c4-bfn9t   1/1     Running   0          91s   192.168.163.175   fargate-ip-192-168-163-175.ap-southeast-1.compute.internal   <none>           <none>
nginx-fargate-pod-5cfd56b8c4-dbldw   1/1     Running   0          91s   192.168.133.236   fargate-ip-192-168-133-236.ap-southeast-1.compute.internal   <none>           <none>
```

以上返回结果即可看到，Pod是运行在Fargate Node之上。每个Fargate Pod独占一个Fargate节点，节点名称以`fargate-`开头，Pod IP与节点IP相同，均来自Fargate Profile指定的私有子网。本文实测集群沿用了实验八的VPC CNI自定义网络，EC2节点上的Pod地址位于`100.64.0.0/16`辅助网段，而Fargate Pod不受ENIConfig影响，地址仍来自私有子网。

执行如下命令查看Fargate节点：

```shell
kubectl get node -o wide | grep fargate
```

返回结果如下：

```
fargate-ip-192-168-133-236.ap-southeast-1.compute.internal   Ready    <none>   50s     v1.36.3-eks-cb19647   192.168.133.236   <none>           Minimal                         6.1.182 (amd64)                           containerd://2.2.5+unknown
fargate-ip-192-168-163-175.ap-southeast-1.compute.internal   Ready    <none>   54s     v1.36.3-eks-cb19647   192.168.163.175   <none>           Minimal                         6.1.182 (amd64)                           containerd://2.2.5+unknown
```

可见Fargate节点的kubelet版本与集群的1.36版本一致，操作系统与内核由AWS托管维护。

此外，执行`kubectl describe pod`时，Fargate Pod的事件中会出现一条`Warning LoggingDisabled`，内容为`Disabled logging because aws-logging configmap was not found`。这表示集群中未配置Fargate内置的Fluent Bit日志路由，不影响Pod运行。如需将Fargate Pod日志发送到CloudWatch Logs，需在`aws-observability`命名空间中创建名为`aws-logging`的ConfigMap，详见参考资料中的官方文档。

执行如下命令查询NLB入口并测试访问：

```shell
kubectl get services --namespace test2-fargate
```

返回结果如下：

```
NAME                TYPE           CLUSTER-IP    EXTERNAL-IP                                                                          PORT(S)        AGE
nginx-fargate-pod   LoadBalancer   10.50.0.182   k8s-test2far-nginxfar-e308b6366f-495cc5ebabcc0e54.elb.ap-southeast-1.amazonaws.com   80:31950/TCP   92s
```

使用curl访问该地址，返回HTTP 200即表示Fargate上的应用访问正常。接下来测试混合模式。

## 五、混合模式：指定某个Namespace下仅带有标签的Pod运行在Fargate上

### 1、创建EKS Fargate Profile

如下命令指定在Namespace命名空间`test3-mixed`中，只有带Label标签`runon=fargate`的Pod会运行于Fargate上，其余不带标签的Pod运行在EC2 Nodegroup上。在选择标签时候请注意，如果您定义的标签包含了yaml文件的关键字如`yes`、`true`等，那么请为其加上双引号将其定义为text字符串，否则可能会遇到提示yaml文件处理json格式错误。

```shell
eksctl create fargateprofile \
    --cluster eksworkshop \
    --region ap-southeast-1 \
    --name test3-mixed \
    --namespace test3-mixed \
    --labels runon=fargate
```

返回结果如下。由于Pod执行角色已经存在，本次只创建Fargate Profile，耗时约半分钟：

```
2026-09-24 20:13:14 [ℹ]  creating Fargate profile "test3-mixed" on EKS cluster "eksworkshop"
2026-09-24 20:13:48 [ℹ]  created Fargate profile "test3-mixed" on EKS cluster "eksworkshop"
```

注意：以上Profile只是指定Namespace，但是在EKS上并不会自动创建Namespace。对应的Namespace需要手工创建，或者随着应用一起创建。

执行如下命令查看两个Fargate Profile：

```shell
eksctl get fargateprofile --cluster eksworkshop --region ap-southeast-1
```

返回结果如下，可见`test3-mixed`的`SELECTOR_LABELS`列为`runon=fargate`：

```
NAME		SELECTOR_NAMESPACE	SELECTOR_LABELS	POD_EXECUTION_ROLE_ARN										SUBNETS										TAGS	STATUS
test2-fargate	test2-fargate		<none>		arn:aws:iam::133129065110:role/eksctl-eksworkshop-fargate-FargatePodExecutionRole-6UZdN3VEYTMT	subnet-049ad8896ca32ad98,subnet-0fa9c7b38b01cd9ba,subnet-053474fb58c51db51	<none>	ACTIVE
test3-mixed	test3-mixed		runon=fargate	arn:aws:iam::133129065110:role/eksctl-eksworkshop-fargate-FargatePodExecutionRole-6UZdN3VEYTMT	subnet-049ad8896ca32ad98,subnet-0fa9c7b38b01cd9ba,subnet-053474fb58c51db51	<none>	ACTIVE
```

### 2、创建Namespace

定义如下配置文件：

```yaml
---
apiVersion: v1
kind: Namespace
metadata: 
  name: test3-mixed
```

将以上内容保存为`test3-mixed-namespace.yaml`，然后创建之。

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
        image: public.ecr.aws/nginx/nginx:1.31-alpine-slim
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
  loadBalancerClass: service.k8s.aws/nlb
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

Fargate Profile的标签选择器匹配的是Pod的标签，因此`runon: fargate`必须写在Deployment的`spec.template.metadata.labels`中。Deployment与Service自身的`metadata.labels`中的同名标签仅用于分类查询，不参与Fargate调度。

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
        image: public.ecr.aws/nginx/nginx:1.31-alpine-slim
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
  loadBalancerClass: service.k8s.aws/nlb
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
NAME                                   READY   STATUS    RESTARTS   AGE   IP                NODE                                                         NOMINATED NODE   READINESS GATES
nginx-mixed-ec2-84fb648d7d-lvws4       1/1     Running   0          98s   100.64.3.133      ip-192-168-30-108.ap-southeast-1.compute.internal            <none>           <none>
nginx-mixed-ec2-84fb648d7d-wsk8v       1/1     Running   0          98s   100.64.2.242      ip-192-168-69-155.ap-southeast-1.compute.internal            <none>           <none>
nginx-mixed-fargate-7544c97997-jwnws   1/1     Running   0          96s   192.168.129.239   fargate-ip-192-168-129-239.ap-southeast-1.compute.internal   <none>           <none>
nginx-mixed-fargate-7544c97997-pzzp6   1/1     Running   0          96s   192.168.114.34    fargate-ip-192-168-114-34.ap-southeast-1.compute.internal    <none>           <none>
```

以上结果即可看到本Namespace下同时存在EC2节点和Fargate节点。

使用如下命令指定Label，查询配置了Label的Pod：

```shell
kubectl get pods -n test3-mixed -l runon -o wide
```

可以看到返回结果就是带有Label的两个Pod。

```shell
NAME                                   READY   STATUS    RESTARTS   AGE   IP                NODE                                                         NOMINATED NODE   READINESS GATES
nginx-mixed-fargate-7544c97997-jwnws   1/1     Running   0          97s   192.168.129.239   fargate-ip-192-168-129-239.ap-southeast-1.compute.internal   <none>           <none>
nginx-mixed-fargate-7544c97997-pzzp6   1/1     Running   0          97s   192.168.114.34    fargate-ip-192-168-114-34.ap-southeast-1.compute.internal    <none>           <none>
```

### 6、测试应用

执行如下命令，获取本Namespace对应的NLB入口。

```shell
kubectl get services --namespace test3-mixed
```

返回结果如下：

```shell
NAME                  TYPE           CLUSTER-IP    EXTERNAL-IP                                                                          PORT(S)        AGE
nginx-mixed-ec2       LoadBalancer   10.50.0.196   k8s-test3mix-nginxmix-edcd422957-440563bc0e37f77e.elb.ap-southeast-1.amazonaws.com   80:32242/TCP   101s
nginx-mixed-fargate   LoadBalancer   10.50.0.195   k8s-test3mix-nginxmix-b1d17ca41d-f5f93e9a2bdf750e.elb.ap-southeast-1.amazonaws.com   80:30399/TCP   99s
```

如果curl暂时返回连接失败，可先执行如下命令确认Target Group中的目标已处于`healthy`状态，再重试访问：

```shell
for tg in $(aws elbv2 describe-target-groups --region ap-southeast-1 \
  --query "TargetGroups[?starts_with(TargetGroupName,'k8s-test3')].TargetGroupArn" --output text); do
  aws elbv2 describe-target-health --target-group-arn $tg --region ap-southeast-1 \
    --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text
done
```

返回结果如下，EC2节点上的Pod与Fargate Pod均以IP目标的形式注册且状态健康：

```
100.64.3.133	healthy
100.64.2.242	healthy
192.168.129.239	healthy
192.168.114.34	healthy
```

分别使用curl测试之，两个入口均返回HTTP 200，确认正常。

### 7、小结

回顾以上实验，我们分别使用了传统的EC2 Nodegroup（Test1），指定Namespace部署Fargate（Test2），在同一个Namespace下通过Label标签区分Fargate（Test3）。

通过图形管理工具，如K9S，可以清晰的看到Pod分布和对应的Node。带有Fargate字样的是Fargate拉起的Node。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/fargate/fargate-01.png)

实验完成后，按如下顺序清理资源。先删除应用使Load Balancer Controller回收NLB，再删除Namespace和Fargate Profile：

```shell
kubectl delete -f test3-mixed-fargate.yaml -f test3-mixed-ec2.yaml -f test2-fargate.yaml -f test1-ec2nodegroup.yaml
kubectl delete -f test3-mixed-namespace.yaml --ignore-not-found
aws elbv2 describe-load-balancers --region ap-southeast-1 \
  --query "LoadBalancers[?starts_with(LoadBalancerName,'k8s-test')].LoadBalancerName" --output text
eksctl delete fargateprofile --cluster eksworkshop --region ap-southeast-1 --name test3-mixed --wait
eksctl delete fargateprofile --cluster eksworkshop --region ap-southeast-1 --name test2-fargate --wait
```

其中第三条命令返回空结果，表示NLB已全部删除。Fargate Profile删除后，Pod执行角色所在的CloudFormation栈`eksctl-eksworkshop-fargate`仍会保留，不产生费用；若后续不再使用Fargate，可在删除集群时一并清理。下面介绍Fargate的资源分配规则。

## 六、Fargate资源分配说明

### 1、在Yaml中定义Pod使用的资源量

指定Fargate的资源，是通过容器`resources`字段的`requests`或`limits`值指定。在使用Fargate的配置文件中，如果不指定申请的资源大小，则Fargate默认分配0.25vCPU和0.5GB内存。

在上述配置文件中，可看到如下定义：

```yaml
          requests:
            cpu: "1"
            memory: "1750M"
```

这就是申请的Fargate Pod资源。本文示例只设置了`requests`，实测可正常调度，Pod的QoS类别显示为`Burstable`。官方文档说明Fargate Pod以Guaranteed优先级运行、要求requests与limits相等，因此生产环境建议将`limits`设置为与`requests`相同的值。但是请注意，Fargate计费是按照实际创建的资源计费，二者之间有一个Gap，请看如下分析。

### 2、EKS Fargate支持的Pod资源量组合

EKS Fargate可以使用的资源组合范围如下表（来源为官方文档）。

|vCPU|内存|
|---|---|
|0.25 vCPU|0.5 GB、1 GB、2 GB|
|0.5 vCPU|1 GB、2 GB、3 GB、4 GB|
|1 vCPU|2 GB、3 GB、4 GB、5 GB、6 GB、7 GB、8 GB|
|2 vCPU|4 GB至16 GB，以1 GB为步长|
|4 vCPU|8 GB至30 GB，以1 GB为步长|
|8 vCPU|16 GB至60 GB，以4 GB为步长|
|16 vCPU|32 GB至120 GB，以8 GB为步长|

### 3、关于系统预留资源和Pod资源量规划

在EC2 Nodegroup上，每个EC2节点都会预留一定的资源，用于kube-proxy、kubelet等后台服务。

在Fargate上，每个Pod运行在一个Fargate环境中，这个Fargate也需要预留256MB内存用于kubelet、kube-proxy与containerd等系统进程。因此，申请Pod时候，EKS实际生成的Fargate都会自动添加256MB内存，并且向上凑整进位，才是真实的资源量。

这里举例如下：

- 在Yaml文件中申请`0.25vCPU/512MB`内存，Fargate将自动添加256MB内存等于768MB，根据上表规格清单中查询，向上进一位将真实分配`0.25vCPU/1GB`资源；
- 在Yaml文件中申请`0.5vCPU/750M`内存（本文`test2-fargate`的配置），750M约合715MiB，加上256MB后约为971MB，向上进一位将真实分配`0.5vCPU/1GB`资源，实测与此一致；
- 在Yaml文件中申请`0.5vCPU/1GB`内存，Fargate将自动添加256MB内存等于1280MB，根据上表规格清单中查询，向上进一位将真实分配`0.5vCPU/2GB`资源；
- 在Yaml文件中申请`1vCPU/1750MB`内存，Fargate将自动添加256MB内存等于2006MB（2GB是2048MB），根据上表规格清单中查询，向上进一位将真实分配`1vCPU/2GB`资源，实测与此一致；
- 在Yaml文件中申请`1vCPU/4GB`内存，Fargate将自动添加256MB内存等于4352MB，根据上表规格清单中查询，向上进一位将真实分配`1vCPU/5GB`内存；
- 在Yaml文件中申请`1vCPU/8GB`内存，Fargate将自动添加256MB内存等于8448MB，根据上表规格清单中查询，向上进一位将真实分配9GB内存；又因为1vCPU最大支持8GB内存，因此vCPU也会向上进位取整，最终真实分配是`2vCPU/9GB`内存；

注意Kubernetes中内存单位`M`为10的6次方字节，`Mi`为2的20次方字节，二者相差约4.9%，在接近规格边界时会影响进位结果。

其他情况以此类推。

### 4、查询现有Fargate Pod分配的资源

执行如下命令，请替换其中的Namespace和Pod名称为真实值。

```shell
kubectl describe pod --namespace test3-mixed nginx-mixed-fargate-7544c97997-jwnws
```

在输出结果中，可以看到如下一条：

```shell
Annotations:          CapacityProvisioned: 1vCPU 2GB
```

则表示本Pod分配的资源是1vCPU/2GB，实际计费也按照这个资源计费。对`test2-fargate`中申请`0.5vCPU/750M`的Pod执行同样的命令，返回结果为`CapacityProvisioned: 0.5vCPU 1GB`。

### 5、关于登录到Pod后使用Shell查询的系统资源

官方文档中的说法，Fargate Pod和实际分配的Fargate环境是不一样的，一般实际分配的规格会更大，但是二者没有直接关系。

    There is no correlation between the size of the Pod 
    running on Fargate and the node size reported by 
    Kubernetes with kubectl get nodes. The reported node 
    size is often larger than the Pod's capacity. 

举例来说，Yaml中申请的`1vCPU/3750MB`，实际分配的是`1vCPU/4GB`，使用上文的`kubectl describe pod`命令查看其`Annotations`中，也是显示`1vCPU/4GB`，这时候账单也是按照`1vCPU/4GB`计费的。但是，登录到Pod的Shell中，执行`free -m`命令查看内存，查看到的内存值可能大于4GB，有可能是6GB或者8GB。这是正常的。Fargate将只按照`Annotations`中显示的计费。

本文实测中，`CapacityProvisioned`为`0.5vCPU 1GB`的Pod，执行如下命令查看Pod内可见的资源：

```shell
kubectl exec -n test2-fargate nginx-fargate-pod-5cfd56b8c4-dbldw -- free -m
kubectl exec -n test2-fargate nginx-fargate-pod-5cfd56b8c4-dbldw -- nproc
kubectl get node fargate-ip-192-168-133-236.ap-southeast-1.compute.internal -o jsonpath='{.status.capacity}'
```

返回结果如下：

```
              total        used        free      shared  buff/cache   available
Mem:           3822         458         117           1        3247        3096
Swap:             0           0           0
2
{"cpu":"2","ephemeral-storage":"21498384Ki","hugepages-1Gi":"0","hugepages-2Mi":"0","memory":"3914020Ki","pods":"1"}
```

可见Pod内可见2个vCPU和约3.8GB内存，Fargate节点上报的容量同样为2vCPU/约3.7GiB，均大于实际分配的0.5vCPU/1GB。计费与资源保障以`CapacityProvisioned`为准，容器可以使用的资源仍受其申请量约束，不应依据`free -m`的结果规划应用内存。

## 七、参考资料

在 Amazon EKS 上使用 AWS Fargate 的总体介绍与使用约束：

[https://docs.aws.amazon.com/eks/latest/userguide/fargate.html](https://docs.aws.amazon.com/eks/latest/userguide/fargate.html)

Fargate Profile 的定义与选择器规则：

[https://docs.aws.amazon.com/eks/latest/userguide/fargate-profile.html](https://docs.aws.amazon.com/eks/latest/userguide/fargate-profile.html)

手工创建Fargate所需的Pod执行IAM Role：

[https://docs.aws.amazon.com/eks/latest/userguide/pod-execution-role.html](https://docs.aws.amazon.com/eks/latest/userguide/pod-execution-role.html)

Fargate Pod 日志路由配置（`aws-observability` 命名空间与 `aws-logging` ConfigMap）：

[https://docs.aws.amazon.com/eks/latest/userguide/fargate-logging.html](https://docs.aws.amazon.com/eks/latest/userguide/fargate-logging.html)

Fargate Pod configuration 资源组合、系统预留内存与计费说明：

[https://docs.aws.amazon.com/eks/latest/userguide/fargate-pod-configuration.html](https://docs.aws.amazon.com/eks/latest/userguide/fargate-pod-configuration.html)

使用 AWS Load Balancer Controller 创建 NLB，以及 Fargate 仅支持 IP 目标的说明：

[https://docs.aws.amazon.com/eks/latest/userguide/network-load-balancing.html](https://docs.aws.amazon.com/eks/latest/userguide/network-load-balancing.html)

eksctl - EKS Fargate Support：

[https://eksctl.io/usage/fargate-support/](https://eksctl.io/usage/fargate-support/)

EKS Mixed Mode Deployment Fargate Serverless & EC2 Worker Nodes - 3 Apps：

[https://www.stacksimplify.com/aws-eks/aws-fargate/learn-to-run-kubernetes-workloads-on-aws-eks-and-aws-fargate-serverless-part-2/](https://www.stacksimplify.com/aws-eks/aws-fargate/learn-to-run-kubernetes-workloads-on-aws-eks-and-aws-fargate-serverless-part-2/)
