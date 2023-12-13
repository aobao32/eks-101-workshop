# 使用Fargate创建无服务器容器服务

## 一、背景

### 1、什么是Fargate

EKS服务使用EC2作为底层运行平台，要创建Pod，需要先指定EC2特定机型创建Nodegroup，然后在其上运行Pod。使用EC2作为Pod运行环境，需要用户管理EC2的资源使用情况，包括CPU分配、内存分配等，并辅以人工扩容或者自动扩容的方式。在此情况下，EKS除集群管理平面的计费之外，主要的计费就是EC2计费。EKS Nodegroup使用的EC2计费默认是按机型的按需计费方式，为优化成本可为对应机型购买RI预留实例，或者使用Spot竞价实例。

EKS Fargate是EKS的无服务器运行环境。使用EKS Fargate，可以直接创建对应Pod，而无需事先准备EC2 Nodegroup。由此，可简化整个技术架构的管理方式，无需考虑EC2的资源使用使用率是否充分、空闲是否足够的情况，可完全按照业务要求来定义Pod资源，直接启动Pod。使用Fargate模式时候，EKS除集群管理平面的计费之外，Fargate的资源是按照vCPU/内存的运行时长（秒计费）。

### 2、选择EC2 Nodegroup模式和Fargate模式

EKS的EC2模式和Fargate模式可同时使用。在一个EKS集群内，可同时使用EC2 Nodegroup和Fargate。当拉起一个应用环境的时候，可在Yaml中指定Namespaces或者通过Namespaces+Lable的方式，指定特定Pod跑在EC2 Nodegroup上、并指定特定Pod跑在Fargate上。当然，也可以创建一个仅使用Fargate的EKS集群；也可以给之前创建的仅有EC2 Nodegroup的集群随时添加Fargate模式，这两种方式都是可行的。再操作步骤上是一致的。

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
eksctl create cluster -f eks-private-subnet.yaml.yaml
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
  name: nginx-ec2nodegroup
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-ec2nodegroup
  namespace: 	nginx-ec2nodegroup
  annotations:
    CapacityProvisioned: 0.25vCPU 0.5GB
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
  name: "service-nginx-ec2nodegroup"
  namespace: 	nginx-ec2nodegroup
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

启动成功后，查看NLB的地址，注意添加Namespace的名称`nginx-ec2nodegroup`，查询服务入口：

```
kubectl get services service-nginx-ec2nodegroup --namespace nginx-ec2nodegroup
```

查询结果如下：

```
NAME                         TYPE           CLUSTER-IP    EXTERNAL-IP                                                                          PORT(S)        AGE
service-nginx-ec2nodegroup   LoadBalancer   10.50.0.149   k8s-nginxec2-servicen-7d894c50a4-d88e28f7253c4dc2.elb.ap-southeast-1.amazonaws.com   80:32097/TCP   15m
```

使用curl访问NLB的地址，可测试访问成功。

## 三、部署Fargate

### 1、创建Fargate需要的基础IAM Role

Fargate模式下，创建容器使用会调度Pod，因此需要创建Fargate说需要的IAM Role。其过程可以手动在IAM控制台上创建，也可以通过eksctl命令在创建Fargate Profile时候自动创建。本文使用自动创建。

### 2、创建EKS Fargate Profile并设定Selector

执行如下命令创建Fargate Profile、设定Selector且自动创建需要的IAM role。

```shell

```

创建完成。

### 3、编写应用配置Yaml文件指定使用Fargate启动



```yaml

```

注意：使用Fargate时候，ELB的Target group模式必须是指定为IP模式，不支持Instance模式。

## 四、参考资料

手工创建Fargate所需的Pod运行IAM Role

[https://docs.aws.amazon.com/zh_cn/eks/latest/userguide/pod-execution-role.html]()

EKS Mixed Mode Deployment Fargate Serverless & EC2 Worker Nodes - 3 Apps ¶

[https://www.stacksimplify.com/aws-eks/aws-fargate/learn-to-run-kubernetes-workloads-on-aws-eks-and-aws-fargate-serverless-part-2/#create-fargate-profile-manifest]()

eksctl - EKS Fargate Support¶

[https://eksctl.io/usage/fargate-support/]()