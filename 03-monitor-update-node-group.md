# 实验三、启用CloudWatch Container Insight & 调整集群规格和配置

## 一、启用CloudWatch Container Insight

注意：2021年之前本功能尚未在中国区发布，后续支持本功能后逐渐更新：

- 2021年10月在EKS 1.19上测试通过
- 2022年3月在EKS 1.21上测试通过
- 2022年4月在EKS 1.22上测试通过
- 2023年3月在EKS 1.25上Global区域测试通过

### 1、部署配置文件（注意这一段需要Linux的bash来执行，Windows下cmd无法执行）

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

在上述命令中包含对Github服务上yaml文件的调用。如果在中国区操作，那么可能访问Github会失败，因此可使用如下地址，其中的Github地址已经替换为在中国区可访问的下载地址：

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
100 16784  100 16784    0     0   4337      0  0:00:03  0:00:03 --:--:--  4340
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

至此部署完成。

### 3、查看Container Insight监控效果

进入Cloudwatch对应region界面，从左侧选择Container Insight，从右侧选择`View performance dashboards `，即可进入Container Insight。

## 二、手工调整节点组数量

注意，下文是手动缩放，如果您需要自动缩放，请参考EKS实验对应Cluster Autoscaling（CA）章节。

前一步实验创建的集群时候，如果配置文件中没有指定节点数量，默认是3个节点，且系统会自动生成nodegroup。下面对这个nodegroup做扩容。

查询刚才集群的nodegroup id，执行如下命令，请替换集群名称为本次实验的名称。

```
eksctl get nodegroup --cluster eksworkshop
```

输出结果如下。

```
CLUSTER		NODEGROUP	STATUS	CREATED			MIN SIZE	MAX SIZE	DESIRED CAPACITY	INSTANCE TYPE	IMAGE ID	ASG NAME						TYPE
eksworkshop	managed-ng	ACTIVE	2023-03-06T02:34:49Z	3		6		3			t3.xlarge	AL2_x86_64	eks-managed-ng-4cc35a62-bc08-a3d9-245f-9d1cb82dc90e	managed
```

这里可看到node group的名称是`managed-ng`，同时看到目前是最大6个节点，期望值是3个节点。

现在扩展集群到6个节点，并设置最大9节点。注意请替换下边语句中的cluster名称、region、nodegroup名称为当前实验对应的名称。

```
eksctl scale nodegroup --cluster=eksworkshop --region=ap-southeast-1 --name=managed-ng --nodes-min=3 --nodes-max=9 --nodes=6
```

执行结果如下表示扩展成功。

```
2023-03-07 16:15:19 [ℹ]  scaling nodegroup "managed-ng" in cluster eksworkshop
2023-03-07 16:15:30 [ℹ]  waiting for scaling of nodegroup "managed-ng" to complete
2023-03-07 16:17:17 [ℹ]  nodegroup successfully scaled
```

执行如下命令检查node数量。

```
kubectl get node
```

返回结果如下表示扩容到6节点成功。

```
NAME                                                STATUS   ROLES    AGE   VERSION
ip-192-168-1-67.ap-southeast-1.compute.internal     Ready    <none>   18m   v1.25.6-eks-48e63af
ip-192-168-20-36.ap-southeast-1.compute.internal    Ready    <none>   29h   v1.25.6-eks-48e63af
ip-192-168-33-69.ap-southeast-1.compute.internal    Ready    <none>   18m   v1.25.6-eks-48e63af
ip-192-168-49-35.ap-southeast-1.compute.internal    Ready    <none>   29h   v1.25.6-eks-48e63af
ip-192-168-90-221.ap-southeast-1.compute.internal   Ready    <none>   29h   v1.25.6-eks-48e63af
ip-192-168-94-37.ap-southeast-1.compute.internal    Ready    <none>   18m   v1.25.6-eks-48e63af
```

此时可以再次查询节点属性，执行如下命令。

```
eksctl get nodegroup --cluster eksworkshop
```

返回结果如下表示扩容成功。

```
CLUSTER		NODEGROUP	STATUS	CREATED			MIN SIZE	MAX SIZE	DESIRED CAPACITY	INSTANCE TYPE	IMAGE ID	ASG NAME						TYPE
eksworkshop	managed-ng	ACTIVE	2023-03-06T02:34:49Z	3		9		6			t3.xlarge	AL2_x86_64	eks-managed-ng-4cc35a62-bc08-a3d9-245f-9d1cb82dc90e	managed
```

## 三、调整节点组EC2规格

前文创建集群使用的EC2作为Nodegruop，节点不能更换规格。为此，需要在当前集群下新建一个nodegroup，并使用新的EC2规格，随后再删除旧的nodegroup。创建完毕后，可从旧的Node上驱逐pod，此时pod会自动在新nodegroup上拉起。如果应用是非长连接的、无状态的应用，那么整个过程不影响应用访问。

### 1、新建使用新的EC2规格的nodegroup

编辑如下内容，并保存为`newnodegroup.yaml`文件。需要注意的是，如果新创建的Nodegroup在Public Subnet内，这直接使用如下内容即可。如果新创建的Nodegroup在Private Subnet内，那么请增加如下一行`privateNetworking: true`到配置文件中。添加的位置在`volumeSize`的下一行即可。

```
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: eksworkshop
  region: ap-southeast-1
  version: "1.25"

managedNodeGroups:
  - name: newng
    labels:
      Name: newng
    instanceType: m5.2xlarge
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
2023-03-07 16:40:55 [ℹ]  nodegroup "newng" will use "" [AmazonLinux2/1.25]
2023-03-07 16:41:00 [ℹ]  1 existing nodegroup(s) (managed-ng) will be excluded
2023-03-07 16:41:00 [ℹ]  1 nodegroup (newng) was included (based on the include/exclude rules)
2023-03-07 16:41:00 [ℹ]  will create a CloudFormation stack for each of 1 managed nodegroups in cluster "eksworkshop"
2023-03-07 16:41:00 [ℹ]
2 sequential tasks: { fix cluster compatibility, 1 task: { 1 task: { create managed nodegroup "newng" } }
}
2023-03-07 16:41:00 [ℹ]  checking cluster stack for missing resources
2023-03-07 16:41:02 [ℹ]  cluster stack has all required resources
2023-03-07 16:41:04 [ℹ]  building managed nodegroup stack "eksctl-eksworkshop-nodegroup-newng"
2023-03-07 16:41:05 [ℹ]  deploying stack "eksctl-eksworkshop-nodegroup-newng"
2023-03-07 16:41:05 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2023-03-07 16:41:36 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2023-03-07 16:42:14 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2023-03-07 16:42:54 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2023-03-07 16:44:06 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2023-03-07 16:44:06 [ℹ]  no tasks
2023-03-07 16:44:06 [✔]  created 0 nodegroup(s) in cluster "eksworkshop"
2023-03-07 16:44:07 [ℹ]  nodegroup "newng" has 3 node(s)
2023-03-07 16:44:07 [ℹ]  node "ip-192-168-15-90.ap-southeast-1.compute.internal" is ready
2023-03-07 16:44:07 [ℹ]  node "ip-192-168-34-9.ap-southeast-1.compute.internal" is ready
2023-03-07 16:44:07 [ℹ]  node "ip-192-168-66-49.ap-southeast-1.compute.internal" is ready
2023-03-07 16:44:07 [ℹ]  waiting for at least 3 node(s) to become ready in "newng"
2023-03-07 16:44:08 [ℹ]  nodegroup "newng" has 3 node(s)
2023-03-07 16:44:08 [ℹ]  node "ip-192-168-15-90.ap-southeast-1.compute.internal" is ready
2023-03-07 16:44:08 [ℹ]  node "ip-192-168-34-9.ap-southeast-1.compute.internal" is ready
2023-03-07 16:44:08 [ℹ]  node "ip-192-168-66-49.ap-southeast-1.compute.internal" is ready
2023-03-07 16:44:08 [✔]  created 1 managed nodegroup(s) in cluster "eksworkshop"
2023-03-07 16:44:10 [ℹ]  checking security group configuration for all nodegroups
2023-03-07 16:44:10 [ℹ]  all nodegroups have up-to-date cloudformation templates
```

执行如下命令查看nodegroup是否正常。

```
eksctl get nodegroup --cluster eksworkshop
```

返回结果可以看到原来nodegroup名为`managed-ng`与和新创建nodegroup名为`newng`同时被列出来如下。

```
2022-04-09 16:45:45 [ℹ]  eksctl version 0.92.0
2022-04-09 16:45:45 [ℹ]  using region ap-southeast-1
CLUSTER		NODEGROUP	STATUS	CREATED			MIN SIZE	MAX SIZE	DESIRED CAPACITY	INSTANCE TYPE	IMAGE ID	ASG NAME						TYPE
eksworkshop	managed-ng	ACTIVE	2022-04-09T04:34:33Z	3		9		6			t3.2xlarge	AL2_x86_64	eks-managed-ng-64c0064d-112b-eeb2-f9be-87b0414216d7	managed
eksworkshop	newng		ACTIVE	2022-04-09T08:41:16Z	3		6		3			m5.2xlarge	AL2_x86_64	eks-newng-14c006be-000e-1344-e82b-229371651c95		managed
```

### 2、驱逐原Nodegroup上的Pod（可选）

本步骤为可选。当通过下文的`eksctl`命令执行删除Nodegroup时候，对应的pod也会被驱逐到新的Nodegroup的健康的节点上。

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