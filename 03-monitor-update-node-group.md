# 实验三、启用CloudWatch Container Insight & 调整集群规格和配置

EKS 1.27版本 @2023-06 AWS Global区域测试通过

## 一、启用CloudWatch Container Insight

注意：2021年之前本功能尚未在中国区发布，后续支持本功能后逐渐更新：

- 2021年10月在EKS 1.19上测试通过
- 2022年3月在EKS 1.21上测试通过
- 2022年4月在EKS 1.22上测试通过
- 2023年3月在EKS 1.25上Global区域测试通过

### 1、部署配置文件

注意这一段需要Linux/MacOS的bash/sh/zsh来执行，Fish和Windows下cmd无法执行。

在AWS海外区域做实验时候，可以直接从Github下载文件，因此执行如下命令，注意替换其中的`ClusterName`为集群名称，替换``为所在Region名称。

```
ClusterName=eksworkshop
RegionName=ap-southeast-1
FluentBitHttpPort='2020'
FluentBitReadFromHead='Off'
[[ ${FluentBitReadFromHead} = 'On' ]] && FluentBitReadFromTail='Off'|| FluentBitReadFromTail='On'
[[ -z ${FluentBitHttpPort} ]] && FluentBitHttpServer='Off' || FluentBitHttpServer='On'
curl https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/quickstart/cwagent-fluent-bit-quickstart.yaml | sed 's/{{cluster_name}}/'${ClusterName}'/;s/{{region_name}}/'${RegionName}'/;s/{{http_server_toggle}}/"'${FluentBitHttpServer}'"/;s/{{http_server_port}}/"'${FluentBitHttpPort}'"/;s/{{read_from_head}}/"'${FluentBitReadFromHead}'"/;s/{{read_from_tail}}/"'${FluentBitReadFromTail}'"/' | kubectl apply -f - 
```

在上述命令中包含对Github服务上yaml文件的调用。如果执行本命令的操作者在中国网络环境下，即便操作的是AWS海外区的EKS集群，也会因为本机的Shell无法访问Github而报告失败，因此可使用如下地址，其中的Github地址已经替换为在中国区可访问的下载地址：

```
ClusterName=eksworkshop
RegionName=ap-southeast-1
FluentBitHttpPort='2020'
FluentBitReadFromHead='Off'
[[ ${FluentBitReadFromHead} = 'On' ]] && FluentBitReadFromTail='Off'|| FluentBitReadFromTail='On'
[[ -z ${FluentBitHttpPort} ]] && FluentBitHttpServer='Off' || FluentBitHttpServer='On'
curl https://myworkshop.bitipcman.com/eks101/cwagent-fluent-bit-quickstart.yaml | sed 's/{{cluster_name}}/'${ClusterName}'/;s/{{region_name}}/'${RegionName}'/;s/{{http_server_toggle}}/"'${FluentBitHttpServer}'"/;s/{{http_server_port}}/"'${FluentBitHttpPort}'"/;s/{{read_from_head}}/"'${FluentBitReadFromHead}'"/;s/{{read_from_tail}}/"'${FluentBitReadFromTail}'"/' | kubectl apply -f - 
```

返回结果如下：

```
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100 17143  100 17143    0     0  12730      0  0:00:01  0:00:01 --:--:-- 12793
namespace/amazon-cloudwatch created
serviceaccount/cloudwatch-agent created
clusterrole.rbac.authorization.k8s.io/cloudwatch-agent-role created
clusterrolebinding.rbac.authorization.k8s.io/cloudwatch-agent-role-binding created
configmap/cwagentconfig created
daemonset.apps/cloudwatch-agent created
configmap/fluent-bit-cluster-info created
serviceaccount/fluent-bit created
clusterrole.rbac.authorization.k8s.io/fluent-bit-role created
clusterrolebinding.rbac.authorization.k8s.io/fluent-bit-role-binding created
configmap/fluent-bit-config created
daemonset.apps/fluent-bit created
```

如果返回结果最后一行是`zsh: command not found: kubectl`，则表明系统的环境变量设置有问题，`kubectl`命令不在当前目录下，可切换至`kubectl`安装所在的目录，即可完成以上命令。

至此部署完成。

### 3、查看Container Insight监控效果

进入Cloudwatch对应region界面，从左侧选择Container Insight，从右侧选择`View performance dashboards `，即可进入Container Insight。

等待一段时间后，监控数据即可正常加载。

## 二、手工调整节点组数量

注意，下文是手动缩放，如果您需要自动缩放，请参考EKS实验对应Cluster Autoscaling（CA）章节。

前一步实验创建的集群时候，如果配置文件中没有指定节点数量，默认是3个节点，且系统会自动生成nodegroup。下面对这个nodegroup做扩容。

### 1、查看现有集群Nodegroup

查询刚才集群的nodegroup id，执行如下命令，请替换集群名称为本次实验的名称。

```
eksctl get nodegroup --cluster eksworkshop
```

输出结果如下。

```
CLUSTER		NODEGROUP	STATUS	CREATED			MIN SIZE	MAX SIZE	DESIRED CAPACITY	INSTANCE TYPE	IMAGE ID	ASG NAME						TYPE
eksworkshop	managed-ng	ACTIVE	2023-06-12T14:39:13Z	3		6		3			t3.xlarge	AL2_x86_64	eks-managed-ng-30c45805-f3a9-09c2-6f2a-4683ad432afb	managed
```

这里可看到node group的名称是`managed-ng`，同时看到目前是最大6个节点，期望值是3个节点。

### 2、对现有Nodegroup做扩容

现在扩展集群到6个节点，并设置最大9节点。注意请替换下边语句中的cluster名称、region、nodegroup名称为当前实验对应的名称。

```
eksctl scale nodegroup --cluster=eksworkshop --region=ap-southeast-1 --name=managed-ng --nodes-min=3 --nodes-max=9 --nodes=6
```

执行结果如下表示扩展成功。

```
2023-06-13 09:58:46 [ℹ]  scaling nodegroup "managed-ng" in cluster eksworkshop
2023-06-13 09:58:51 [ℹ]  initiated scaling of nodegroup
2023-06-13 09:58:51 [ℹ]  to see the status of the scaling run `eksctl get nodegroup --cluster eksworkshop --region ap-southeast-1 --name managed-ng`
```

### 3、查看扩容结果

扩容需要等待1～3分钟时间，等待新的Node的EC2节点被拉起。

在等待几分钟后，执行如下命令检查node数量。

```
kubectl get node
```

返回结果如下表示扩容到6节点成功。

```
NAME                                                STATUS   ROLES    AGE   VERSION
ip-192-168-26-53.ap-southeast-1.compute.internal    Ready    <none>   11h   v1.27.1-eks-2f008fe
ip-192-168-28-249.ap-southeast-1.compute.internal   Ready    <none>   82s   v1.27.1-eks-2f008fe
ip-192-168-54-35.ap-southeast-1.compute.internal    Ready    <none>   81s   v1.27.1-eks-2f008fe
ip-192-168-57-38.ap-southeast-1.compute.internal    Ready    <none>   11h   v1.27.1-eks-2f008fe
ip-192-168-81-178.ap-southeast-1.compute.internal   Ready    <none>   76s   v1.27.1-eks-2f008fe
ip-192-168-88-55.ap-southeast-1.compute.internal    Ready    <none>   11h   v1.27.1-eks-2f008fe
```

此时可以再次查询节点属性，执行如下命令。

```
eksctl get nodegroup --cluster eksworkshop
```

返回结果如下表示扩容成功。

```
CLUSTER		NODEGROUP	STATUS	CREATED			MIN SIZE	MAX SIZE	DESIRED CAPACITY	INSTANCE TYPE	IMAGE ID	ASG NAME						TYPE
eksworkshop	managed-ng	ACTIVE	2023-06-12T14:39:13Z	3		9		6			t3.xlarge	AL2_x86_64	eks-managed-ng-30c45805-f3a9-09c2-6f2a-4683ad432afb	managed
```

## 三、调整节点组EC2规格

前文创建集群使用的EC2作为Nodegruop，节点不能更换规格。为此，需要在当前集群下新建一个nodegroup，并使用新的EC2规格，随后再删除旧的nodegroup。创建完毕后，可从旧的Node上驱逐pod，此时pod会自动在新nodegroup上拉起。如果应用是非长连接的、无状态的应用，那么整个过程不影响应用访问。

### 1、增加Graviton机型ARM架构处理器的Nodegroup的准备工作

使用Graviton的ARM架构的EC2，需要事先运行如下命令检查系统组件是否为最新版本。替换如下命令中的集群名称为实际集群名称，然后执行如下命令：

```
eksctl utils update-coredns --cluster eksworkshop
eksctl utils update-kube-proxy --cluster eksworkshop
eksctl utils update-aws-node --cluster eksworkshop
```

返回信息如下：

```
2023-06-13 10:06:37 [ℹ]  (plan) would have replaced "kube-system:Service/kube-dns"
2023-06-13 10:06:37 [ℹ]  (plan) would have replaced "kube-system:ServiceAccount/coredns"
2023-06-13 10:06:37 [ℹ]  (plan) would have replaced "kube-system:ConfigMap/coredns"
2023-06-13 10:06:38 [ℹ]  (plan) would have replaced "kube-system:Deployment.apps/coredns"
2023-06-13 10:06:38 [ℹ]  (plan) would have replaced "ClusterRole.rbac.authorization.k8s.io/system:coredns"
2023-06-13 10:06:38 [ℹ]  (plan) would have replaced "ClusterRoleBinding.rbac.authorization.k8s.io/system:coredns"
2023-06-13 10:06:38 [ℹ]  (plan) "coredns" is already up-to-date
2023-06-13 10:06:46 [✖]  (plan) "kube-proxy" is not up-to-date
2023-06-13 10:06:46 [!]  no changes were applied, run again with '--approve' to apply the changes
2023-06-13 10:06:52 [ℹ]  (plan) would have skipped existing "kube-system:ServiceAccount/aws-node"
2023-06-13 10:06:52 [ℹ]  (plan) would have replaced "CustomResourceDefinition.apiextensions.k8s.io/eniconfigs.crd.k8s.amazonaws.com"
2023-06-13 10:06:53 [ℹ]  (plan) would have replaced "ClusterRole.rbac.authorization.k8s.io/aws-node"
2023-06-13 10:06:53 [ℹ]  (plan) would have replaced "ClusterRoleBinding.rbac.authorization.k8s.io/aws-node"
2023-06-13 10:06:53 [ℹ]  (plan) would have replaced "kube-system:DaemonSet.apps/aws-node"
2023-06-13 10:06:53 [✖]  (plan) "aws-node" is not up-to-date
2023-06-13 10:06:53 [!]  no changes were applied, run again with '--approve' to apply the changes
```

这其中可看到部分组件不是最新。在命令后加`--approve`进行升级。（注意可能会对集群有短暂影响）

```
eksctl utils update-coredns --cluster eksworkshop --approve
eksctl utils update-kube-proxy --cluster eksworkshop --approve
eksctl utils update-aws-node --cluster eksworkshop --approve
```

### 2、新建使用新的Graviton处理器ARM架构EC2的Nodegroup

编辑如下内容，并保存为`newnodegroup.yaml`文件。需要注意的是，如果新创建的Nodegroup在Public Subnet内，这直接使用如下内容即可。如果新创建的Nodegroup在Private Subnet内，那么请增加如下一行`privateNetworking: true`到配置文件中。添加的位置在`volumeSize`的下一行即可。

```
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: eksworkshop
  region: ap-southeast-1
  version: "1.27"

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
        certManager: true
        efs: true
        ebs: true
        albIngress: true
        xRay: true
        cloudWatch: true
```

编辑完毕后保存退出。执行如下命令创建：

```
eksctl create nodegroup -f newnodegroup.yaml
```

执行结果如下。

```
2023-06-13 10:11:50 [ℹ]  nodegroup "newng" will use "" [AmazonLinux2/1.27]
2023-06-13 10:11:57 [ℹ]  1 existing nodegroup(s) (managed-ng) will be excluded
2023-06-13 10:11:57 [ℹ]  1 nodegroup (newng) was included (based on the include/exclude rules)
2023-06-13 10:11:57 [ℹ]  will create a CloudFormation stack for each of 1 managed nodegroups in cluster "eksworkshop"
2023-06-13 10:11:57 [ℹ]  
2 sequential tasks: { fix cluster compatibility, 1 task: { 1 task: { create managed nodegroup "newng" } } 
}
2023-06-13 10:11:57 [ℹ]  checking cluster stack for missing resources
2023-06-13 10:12:00 [ℹ]  cluster stack has all required resources
2023-06-13 10:12:03 [ℹ]  building managed nodegroup stack "eksctl-eksworkshop-nodegroup-newng"
2023-06-13 10:12:05 [ℹ]  deploying stack "eksctl-eksworkshop-nodegroup-newng"
2023-06-13 10:12:05 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2023-06-13 10:12:38 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2023-06-13 10:13:17 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2023-06-13 10:14:21 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2023-06-13 10:15:36 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2023-06-13 10:17:13 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2023-06-13 10:17:13 [ℹ]  no tasks
2023-06-13 10:17:13 [✔]  created 0 nodegroup(s) in cluster "eksworkshop"
2023-06-13 10:17:15 [ℹ]  nodegroup "newng" has 3 node(s)
2023-06-13 10:17:15 [ℹ]  node "ip-192-168-0-137.ap-southeast-1.compute.internal" is ready
2023-06-13 10:17:15 [ℹ]  node "ip-192-168-39-199.ap-southeast-1.compute.internal" is ready
2023-06-13 10:17:15 [ℹ]  node "ip-192-168-76-179.ap-southeast-1.compute.internal" is ready
2023-06-13 10:17:15 [ℹ]  waiting for at least 3 node(s) to become ready in "newng"
2023-06-13 10:17:16 [ℹ]  nodegroup "newng" has 3 node(s)
2023-06-13 10:17:16 [ℹ]  node "ip-192-168-0-137.ap-southeast-1.compute.internal" is ready
2023-06-13 10:17:16 [ℹ]  node "ip-192-168-39-199.ap-southeast-1.compute.internal" is ready
2023-06-13 10:17:16 [ℹ]  node "ip-192-168-76-179.ap-southeast-1.compute.internal" is ready
2023-06-13 10:17:16 [✔]  created 1 managed nodegroup(s) in cluster "eksworkshop"
2023-06-13 10:17:19 [ℹ]  checking security group configuration for all nodegroups
2023-06-13 10:17:19 [ℹ]  all nodegroups have up-to-date cloudformation templates
```

执行如下命令查看nodegroup是否正常。

```
eksctl get nodegroup --cluster eksworkshop
```

返回结果可以看到原来nodegroup名为`managed-ng`与和新创建nodegroup名为`newng`同时被列出来如下。

```
CLUSTER		NODEGROUP	STATUS	CREATED			MIN SIZE	MAX SIZE	DESIRED CAPACITY	INSTANCE TYPE	IMAGE ID	ASG NAME						TYPE
eksworkshop	managed-ng	ACTIVE	2023-06-12T14:39:13Z	3		9		3			t3.xlarge	AL2_x86_64	eks-managed-ng-30c45805-f3a9-09c2-6f2a-4683ad432afb	managed
eksworkshop	newng		ACTIVE	2023-06-13T02:12:42Z	3		6		3			t4g.xlarge	AL2_ARM_64	eks-newng-3ac45943-6531-2c65-237c-1596bd61832e		managed
```

如果创建的是不同架构的Nodegroup，可以执行如下命令查看节点的属性：

```
kubectl get nodes --label-columns=kubernetes.io/arch
```

返回结果如下，可看到最后一列就是对应的机型。

```
NAME                                                STATUS   ROLES    AGE    VERSION               ARCH
ip-192-168-0-137.ap-southeast-1.compute.internal    Ready    <none>   169m   v1.27.1-eks-2f008fe   arm64
ip-192-168-28-249.ap-southeast-1.compute.internal   Ready    <none>   3h4m   v1.27.1-eks-2f008fe   amd64
ip-192-168-39-199.ap-southeast-1.compute.internal   Ready    <none>   169m   v1.27.1-eks-2f008fe   arm64
ip-192-168-54-35.ap-southeast-1.compute.internal    Ready    <none>   3h4m   v1.27.1-eks-2f008fe   amd64
ip-192-168-76-179.ap-southeast-1.compute.internal   Ready    <none>   169m   v1.27.1-eks-2f008fe   arm64
ip-192-168-81-178.ap-southeast-1.compute.internal   Ready    <none>   3h4m   v1.27.1-eks-2f008fe   amd64
```

### 2、驱逐原Nodegroup上的Pod（可选）

本步骤为可选。当通过下文的`eksctl`命令执行删除Nodegroup时候，对应的pod也会被驱逐到新的Nodegroup的健康的节点上。如果您使用K9S等管理工具，也可以从这些管理工具上发起驱逐命令。

注意：驱逐Pod只能在同架构的Nodegroup之间。如果一个Nodegroup是Intel处理器，一个是Graviton的ARM处理器，是不能互相驱逐Pod的。

首先将节点调度标记为不可用，执行如下命令。

```
kubectl cordon <node name>
```

然后驱逐节点上的所有pod，执行如下命令。

```
kubectl drain --ignore-daemonsets <node name>
```

### 3、删除旧的nodegroup

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

Quick Start setup for Container Insights on Amazon EKS and Kubernetes

[https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Container-Insights-setup-EKS-quickstart.html](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Container-Insights-setup-EKS-quickstart.html)