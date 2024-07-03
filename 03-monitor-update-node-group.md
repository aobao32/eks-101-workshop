# 实验三、启用CloudWatch Container Insight、新建Nodegroup节点组以及调整节点组机型配置

EKS 1.30 版本 @2024-07 AWS Global区域测试通过

## 一、启用CloudWatch Container Insight

2023年11月之后发布的新版CloudWatch Container Insight支持对EKS的EC2节点采集多种运行参数用于监控和诊断，建议在2023年11月之前安装的旧版本升级到新版本。升级方法见本文末尾的参考文档。

以往的CloudWatch Container Insight部署需要手工拉起FluentBit的部署和服务，如今可通过EKS Addon功能直接安装，大大简化了部署。本文将讲解EKS Addon方式安装。如果需要参考以前的FluentBit部署方式，请见本文末尾的参考文档。

### 1、配置Service Role

执行如下命令配置OIDC。本步骤如果您在EKS安装过AWS Load Balancer Controller，那么这一步是已经执行过的，可以跳过。重复执行也不会报错。

```
eksctl utils associate-iam-oidc-provider --region ap-southeast-1 --cluster eksworkshop --approve
```

配置Service Role。

```
eksctl create iamserviceaccount \
  --name cloudwatch-agent \
  --namespace amazon-cloudwatch --cluster eksworkshop \
  --role-name AmazonEKSContainerInsightRole \
  --attach-policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy \
  --role-only \
  --approve
```

执行成功返回信息如下：

```
2024-07-03 14:57:12 [ℹ]  1 existing iamserviceaccount(s) (kube-system/aws-load-balancer-controller) will be excluded
2024-07-03 14:57:12 [ℹ]  1 iamserviceaccount (amazon-cloudwatch/cloudwatch-agent) was included (based on the include/exclude rules)
2024-07-03 14:57:12 [!]  serviceaccounts in Kubernetes will not be created or modified, since the option --role-only is used
2024-07-03 14:57:12 [ℹ]  1 task: { create IAM role for serviceaccount "amazon-cloudwatch/cloudwatch-agent" }
2024-07-03 14:57:12 [ℹ]  building iamserviceaccount stack "eksctl-eksworkshop-addon-iamserviceaccount-amazon-cloudwatch-cloudwatch-agent"
2024-07-03 14:57:12 [ℹ]  deploying stack "eksctl-eksworkshop-addon-iamserviceaccount-amazon-cloudwatch-cloudwatch-agent"
2024-07-03 14:57:12 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-addon-iamserviceaccount-amazon-cloudwatch-cloudwatch-agent"
2024-07-03 14:57:43 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-addon-iamserviceaccount-amazon-cloudwatch-cloudwatch-agent"
```

### 2、通过EKS Addon安装

```
aws eks create-addon --cluster-name eksworkshop --addon-name amazon-cloudwatch-observability
```

返回结果如下：

```
{
    "addon": {
        "addonName": "amazon-cloudwatch-observability",
        "clusterName": "eksworkshop",
        "status": "CREATING",
        "addonVersion": "v1.7.0-eksbuild.1",
        "health": {
            "issues": []
        },
        "addonArn": "arn:aws:eks:ap-southeast-1:133129065110:addon/eksworkshop/amazon-cloudwatch-observability/e0c83bb3-3d9f-6fb9-14e9-a6949ad63a2e",
        "createdAt": "2024-07-03T15:02:03.522000+08:00",
        "modifiedAt": "2024-07-03T15:02:03.539000+08:00",
        "tags": {}
    }
}
```

部署完成。

### 3、查看Container Insight监控效果

进入Cloudwatch服务，切换到EKS部署所在的Region界面，从左侧菜单选择`Insights`，在其中找到`Container Insight`，点击进入。

在右侧`Container Insights`的位置，从下拉框选择`Service: EKS`，下方即可看到Cluster的信息。由于是新部署的监控，因此需要等待数分钟，或者更长的一段时间后，监控数据即可正常加载。

## 二、手工调整节点组数量（不改变机型，只调整数量）

注意：下文是手动缩放节点数量，如果您需要自动缩放节点数量，请参考EKS实验对应Cluster Autoscaling（CA）章节。

前一步实验创建的集群时候，如果配置文件中没有指定节点数量，默认是3个节点，且系统会自动生成nodegroup。下面对这个nodegroup做扩容。

### 1、查看现有集群Nodegroup

查询刚才集群的nodegroup名称，执行如下命令，请替换集群名称为本次实验的名称。

```
eksctl get nodegroup --cluster eksworkshop
```

输出结果如下。

```
CLUSTER		NODEGROUP	STATUS	CREATED			MIN SIZE	MAX SIZE	DESIRED CAPACITY	INSTANCE TYPE	IMAGE ID		ASG NAME						TYPE
eksworkshop	managed-ng	ACTIVE	2024-07-02T14:04:58Z	3		6		3			t3.2xlarge	AL2023_x86_64_STANDARD	eks-managed-ng-26c839e1-a0b3-2d25-accb-775d8d86eb07	managed
```

这里可看到node group的名称是`managed-ng`，同时看到目前是最大（MAX）6个节点，期望值（DESIRED）是3个节点。

### 2、对现有Nodegroup做扩容

现在扩展集群到6个节点，并设置最大9节点。注意请替换下边语句中的cluster名称、region、nodegroup名称为当前实验对应的名称。

```
eksctl scale nodegroup --cluster=eksworkshop --region=ap-southeast-1 --name=managed-ng --nodes-min=3 --nodes-max=9 --nodes=6
```

执行结果如下表示扩展成功。

```
2024-07-03 15:11:33 [ℹ]  scaling nodegroup "managed-ng" in cluster eksworkshop
2024-07-03 15:11:37 [ℹ]  initiated scaling of nodegroup
2024-07-03 15:11:37 [ℹ]  to see the status of the scaling run `eksctl get nodegroup --cluster eksworkshop --region ap-southeast-1 --name managed-ng`
```

### 3、查看扩容结果

扩容需要等待3～5分钟时间，等待新的Node的EC2节点被拉起。

在等待几分钟后，执行如下命令检查node数量。

```
kubectl get node
```

返回结果如下表示扩容到6节点成功。

```
NAME                                                STATUS   ROLES    AGE   VERSION
ip-192-168-0-22.ap-southeast-1.compute.internal     Ready    <none>   17h   v1.30.0-eks-036c24b
ip-192-168-41-21.ap-southeast-1.compute.internal    Ready    <none>   76s   v1.30.0-eks-036c24b
ip-192-168-42-0.ap-southeast-1.compute.internal     Ready    <none>   17h   v1.30.0-eks-036c24b
ip-192-168-8-168.ap-southeast-1.compute.internal    Ready    <none>   74s   v1.30.0-eks-036c24b
ip-192-168-82-107.ap-southeast-1.compute.internal   Ready    <none>   72s   v1.30.0-eks-036c24b
ip-192-168-93-206.ap-southeast-1.compute.internal   Ready    <none>   17h   v1.30.0-eks-036c24b
```

### 4、缩小EC2节点组容量

执行如下命令：

```
eksctl scale nodegroup --cluster=eksworkshop --region=ap-southeast-1 --name=managed-ng --nodes-min=3 --nodes-max=6 --nodes=3
```

## 三、更换机型-新增其他规格的节点住并删除旧的节点组

创建集群使用EC2机型是作为默认的Nodegruop，已经存在的节点不能更换规格。为了更换EC2机型规格，需要在当前集群下新建一个使用新机型的Nodegroup，随后再删除旧的Nodegroup。创建完毕时，可从旧的Node上驱逐pod，此时pod会自动在新nodegroup上拉起。如果应用是非长连接的、无状态的应用，那么整个过程不影响应用访问。本文以从X86_64架构更换到ARM架构为例。

### 1、增加ARM机型Nodegroup的系统插件升级（建议EKS低于1.28版本的升级）

如果您的EKS版本低于1.28，建议进行升级。如果等于或者高于1.28版本，可选升级。

运行如下命令检查系统组件是否为最新版本。本命令仅检查版本，不会触发升级。替换如下命令中的集群名称为实际集群名称，然后执行如下命令：

```
eksctl utils update-coredns --cluster eksworkshop
eksctl utils update-kube-proxy --cluster eksworkshop
eksctl utils update-aws-node --cluster eksworkshop
```

返回信息如下：

```
eksctl utils update-kube-proxy --cluster eksworkshop
eksctl utils update-aws-node --cluster eksworkshop
2024-07-03 15:26:54 [ℹ]  (plan) would have replaced "kube-system:Service/kube-dns"
2024-07-03 15:26:55 [ℹ]  (plan) would have replaced "kube-system:ServiceAccount/coredns"
2024-07-03 15:26:55 [ℹ]  (plan) would have replaced "kube-system:ConfigMap/coredns"
2024-07-03 15:26:55 [ℹ]  (plan) would have replaced "kube-system:Deployment.apps/coredns"
2024-07-03 15:26:55 [ℹ]  (plan) would have replaced "ClusterRole.rbac.authorization.k8s.io/system:coredns"
2024-07-03 15:26:55 [ℹ]  (plan) would have replaced "ClusterRoleBinding.rbac.authorization.k8s.io/system:coredns"
2024-07-03 15:26:55 [ℹ]  (plan) "coredns" is already up-to-date
2024-07-03 15:27:01 [✖]  (plan) "kube-proxy" is not up-to-date
2024-07-03 15:27:01 [!]  no changes were applied, run again with '--approve' to apply the changes
2024-07-03 15:27:05 [ℹ]  (plan) would have replaced "CustomResourceDefinition.apiextensions.k8s.io/eniconfigs.crd.k8s.amazonaws.com"
2024-07-03 15:27:05 [ℹ]  (plan) would have replaced "CustomResourceDefinition.apiextensions.k8s.io/policyendpoints.networking.k8s.aws"
2024-07-03 15:27:05 [ℹ]  (plan) would have skipped existing "kube-system:ServiceAccount/aws-node"
2024-07-03 15:27:05 [ℹ]  (plan) would have replaced "kube-system:ConfigMap/amazon-vpc-cni"
2024-07-03 15:27:05 [ℹ]  (plan) would have replaced "ClusterRole.rbac.authorization.k8s.io/aws-node"
2024-07-03 15:27:05 [ℹ]  (plan) would have replaced "ClusterRoleBinding.rbac.authorization.k8s.io/aws-node"
2024-07-03 15:27:06 [ℹ]  (plan) would have replaced "kube-system:DaemonSet.apps/aws-node"
2024-07-03 15:27:06 [✖]  (plan) "aws-node" is not up-to-date
2024-07-03 15:27:06 [!]  no changes were applied, run again with '--approve' to apply the changes
```

这其中可看到部分组件提示`is already up-to-date`表示已经是最新，提示`is not up-to-date`则不是最新版本。

在命令后加`--approve`进行升级。（注意可能会对集群有短暂影响）

```
eksctl utils update-coredns --cluster eksworkshop --approve
eksctl utils update-kube-proxy --cluster eksworkshop --approve
eksctl utils update-aws-node --cluster eksworkshop --approve
```

### 2、新建Nodegroup并使用Graviton处理器ARM架构EC2机型

编辑如下内容，并保存为`nodegroup-arm.yaml`文件。

需要注意的是，如果新创建的Nodegroup在VPC的Public Subnet公有子网内，那么直接使用如下内容即可。如果您创建EKS时候自定义了网络环境，并且新创建的Nodegroup在Private Subnet私有子网内，那么必须增加如下一行`privateNetworking: true`到配置文件中。添加的位置在`volumeSize`的下一行即可。

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
    instanceType: m6g.2xlarge
    minSize: 3
    desiredCapacity: 3
    maxSize: 6
    volumeType: gp3
    volumeSize: 100
    tags:
      nodegroup-name: newng
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

注：如果您需要使用Intel处理器机型，请替换上文中的`m6g.2xlarge`为`m6i.2xlarge`即可使用Intel处理器机型。

编辑完毕后保存退出。执行如下命令创建：

```
eksctl create nodegroup -f nodegroup-arm.yaml
```

执行结果如下。

```
2024-07-03 15:35:36 [ℹ]  nodegroup "newng" will use "" [AmazonLinux2023/1.30]
2024-07-03 15:35:39 [ℹ]  1 existing nodegroup(s) (managed-ng) will be excluded
2024-07-03 15:35:39 [ℹ]  1 nodegroup (newng) was included (based on the include/exclude rules)
2024-07-03 15:35:39 [ℹ]  will create a CloudFormation stack for each of 1 managed nodegroups in cluster "eksworkshop"
2024-07-03 15:35:39 [ℹ]
2 sequential tasks: { fix cluster compatibility, 1 task: { 1 task: { create managed nodegroup "newng" } }
}
2024-07-03 15:35:39 [ℹ]  checking cluster stack for missing resources
2024-07-03 15:35:40 [ℹ]  cluster stack has all required resources
2024-07-03 15:35:42 [ℹ]  building managed nodegroup stack "eksctl-eksworkshop-nodegroup-newng"
2024-07-03 15:35:42 [ℹ]  deploying stack "eksctl-eksworkshop-nodegroup-newng"
2024-07-03 15:35:43 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2024-07-03 15:36:14 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2024-07-03 15:37:00 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2024-07-03 15:38:29 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2024-07-03 15:38:29 [ℹ]  no tasks
2024-07-03 15:38:29 [✔]  created 0 nodegroup(s) in cluster "eksworkshop"
2024-07-03 15:38:30 [ℹ]  nodegroup "newng" has 3 node(s)
2024-07-03 15:38:30 [ℹ]  node "ip-192-168-6-252.ap-southeast-1.compute.internal" is ready
2024-07-03 15:38:30 [ℹ]  node "ip-192-168-60-2.ap-southeast-1.compute.internal" is ready
2024-07-03 15:38:30 [ℹ]  node "ip-192-168-89-203.ap-southeast-1.compute.internal" is ready
2024-07-03 15:38:30 [ℹ]  waiting for at least 3 node(s) to become ready in "newng"
2024-07-03 15:38:31 [ℹ]  nodegroup "newng" has 3 node(s)
2024-07-03 15:38:31 [ℹ]  node "ip-192-168-6-252.ap-southeast-1.compute.internal" is ready
2024-07-03 15:38:31 [ℹ]  node "ip-192-168-60-2.ap-southeast-1.compute.internal" is ready
2024-07-03 15:38:31 [ℹ]  node "ip-192-168-89-203.ap-southeast-1.compute.internal" is ready
2024-07-03 15:38:31 [✔]  created 1 managed nodegroup(s) in cluster "eksworkshop"
2024-07-03 15:38:32 [ℹ]  checking security group configuration for all nodegroups
2024-07-03 15:38:32 [ℹ]  all nodegroups have up-to-date cloudformation templates
```

创建完成。

### 3、按处理器架构类型查看Nodegroup

执行如下命令查看nodegroup是否正常。

```
eksctl get nodegroup --cluster eksworkshop
```

返回结果可以看到原来nodegroup名为`managed-ng`与和新创建nodegroup名为`newng`同时被列出来如下。

```
CLUSTER		NODEGROUP	STATUS	CREATED			MIN SIZE	MAX SIZE	DESIRED CAPACITY	INSTANCE TYPE	IMAGE ID		ASG NAME						TYPE
eksworkshop	managed-ng	ACTIVE	2024-07-02T14:04:58Z	3		6		3			t3.2xlarge	AL2023_x86_64_STANDARD	eks-managed-ng-26c839e1-a0b3-2d25-accb-775d8d86eb07	managed
eksworkshop	newng		ACTIVE	2024-07-03T07:36:10Z	3		6		3			t4g.xlarge	AL2023_ARM_64_STANDARD	eks-newng-64c83bc2-d362-3a0e-db9d-fbd395f0c899		managed
```

如果想按不同的处理器架构分别查看Nodegroup，执行如下命令查看节点的属性：

```
kubectl get nodes --label-columns=kubernetes.io/arch
```

返回结果如下，可看到最后一列`ARCH`就是对应的架构类型。

```
NAME                                                STATUS   ROLES    AGE     VERSION               ARCH
ip-192-168-41-21.ap-southeast-1.compute.internal    Ready    <none>   29m     v1.30.0-eks-036c24b   amd64
ip-192-168-6-252.ap-southeast-1.compute.internal    Ready    <none>   3m59s   v1.30.0-eks-036c24b   arm64
ip-192-168-60-2.ap-southeast-1.compute.internal     Ready    <none>   3m59s   v1.30.0-eks-036c24b   arm64
ip-192-168-8-168.ap-southeast-1.compute.internal    Ready    <none>   29m     v1.30.0-eks-036c24b   amd64
ip-192-168-82-107.ap-southeast-1.compute.internal   Ready    <none>   29m     v1.30.0-eks-036c24b   amd64
ip-192-168-89-203.ap-southeast-1.compute.internal   Ready    <none>   4m2s    v1.30.0-eks-036c24b   arm64
```

### 4、驱逐原Nodegroup上的Pod（可选）

注意：驱逐Pod只能在同架构的Nodegroup之间。如果一个Nodegroup是X86_64处理器，一个是Graviton的ARM处理器，二者运行的Pod是不同的版本，是不能互相驱逐Pod的。为了让之前在X86_64处理器构建好的Pod运行在ARM处理器上，您需要在ARM架构上重新构建Pod，并且上传ARM版本的Image到ECR服务。所以，跨架构是不能直接驱逐Pod的。如果您的应用在ECR上只有X86_64，然后您又删除了X86_64处理器的所有节点组，那么ARM架构的Nodegroup上不会有对应Pod，您的应用也就下线了。因此使用不同架构处理器时候请注意Pod运行架构。

本步骤为可选。当通过下文的`eksctl`命令执行删除Nodegroup时候，对应的pod也会被驱逐到新的Nodegroup的健康的节点上。如果您使用K9S等管理工具，也可以从这些管理工具上发起驱逐命令。

首先将节点调度标记为不可用，执行如下命令。

```
kubectl cordon <node name>
```

然后驱逐节点上的所有pod，执行如下命令。

```
kubectl drain --ignore-daemonsets <node name>
```

### 5、删除旧的nodegroup（可选）

执行如下命令。

```
eksctl delete nodegroup --cluster eksworkshop --name managed-ng --region ap-southeast-1
```

等待几分钟后，再次查询集群所对应的nodegroup，执行如下命令。

```
eksctl get nodegroup --cluster eksworkshop
```

通过以上返回结果可以看到，原来规格的nodegroup被删除。

## 四、参考文档

Upgrading to Container Insights with enhanced observability for Amazon EKS

[https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Container-Insights-upgrade-enhanced.html]()

Quick Start setup for Container Insights on Amazon EKS and Kubernetes

[https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Container-Insights-setup-EKS-quickstart.html]()