# 实验三、调整集群规格和配置

## 一、启用CloudWatch Container Insight

注意：2021年之前本功能尚未在中国区发布，2021年10月在EKS 1.19上测试通过，2022年3月在EKS 1.21上测试通过，2022年4月在EKS 1.22上测试通过。

### 1、部署配置文件（注意这一段需要Linux的bash来执行，Windows下cmd无法执行）

执行如下命令，注意替换其中的Region和集群名称。

```
ClusterName=eksworkshop
RegionName=ap-southeast-1
FluentBitHttpPort='2020'
FluentBitReadFromHead='Off'
[[ ${FluentBitReadFromHead} = 'On' ]] && FluentBitReadFromTail='Off'|| FluentBitReadFromTail='On'
[[ -z ${FluentBitHttpPort} ]] && FluentBitHttpServer='Off' || FluentBitHttpServer='On'
curl https://myworkshop.bitipcman.com/eks101/cwagent-fluent-bit-quickstart.yaml | sed 's/{{cluster_name}}/'${ClusterName}'/;s/{{region_name}}/'${RegionName}'/;s/{{http_server_toggle}}/"'${FluentBitHttpServer}'"/;s/{{http_server_port}}/"'${FluentBitHttpPort}'"/;s/{{read_from_head}}/"'${FluentBitReadFromHead}'"/;s/{{read_from_tail}}/"'${FluentBitReadFromTail}'"/' | kubectl apply -f - 
```

部署完成。

### 3、查看Container Insight监控效果

进入Cloudwatch对应region界面，从左侧选择Container Insight，从右侧选择`View performance dashboards `，即可进入Container Insight。

## 二、调整节点组数量

前一步实验创建的集群时候没有指定节点数量，默认是2个节点，且系统会自动生成nodegroup，并分配nodegroup id。下面对这个nodegroup做扩容。

查询刚才集群的nodegroup id，执行如下命令，请替换集群名称为本次实验的名称。

```
eksctl get nodegroup --cluster eksworkshop
```

输出结果如下。

```

2022-04-09 15:39:34 [ℹ]  eksctl version 0.92.0
2022-04-09 15:39:34 [ℹ]  using region ap-southeast-1
CLUSTER		NODEGROUP	STATUS	CREATED			MIN SIZE	MAX SIZE	DESIRED CAPACITY	INSTANCE TYPE	IMAGE ID	ASG NAME	TYPE
eksworkshop	managed-ng	ACTIVE	2022-04-09T04:34:33Z	3		6		3			t3.2xlarge	AL2_x86_64	eks-managed-ng-64c0064d-112b-eeb2-f9be-87b0414216d7	managed
```

这里可看到node group的名称是`managed-ng`，同时看到目前是最大6个节点，期望值是3个节点。

现在扩展集群到6个节点，并设置最大9节点。注意请替换下边语句中的cluster名称、region、nodegroup名称为当前实验对应的名称。

```
eksctl scale nodegroup --cluster=eksworkshop --region=ap-southeast-1 --name=managed-ng --nodes-max=9 --nodes=6
```

执行结果如下表示扩展成功。

```
2022-04-09 15:44:48 [ℹ]  eksctl version 0.92.0
2022-04-09 15:44:48 [ℹ]  using region ap-southeast-1
2022-04-09 15:44:50 [ℹ]  scaling nodegroup "managed-ng" in cluster eksworkshop
2022-04-09 15:44:54 [ℹ]  waiting for scaling of nodegroup "managed-ng" to complete
2022-04-09 15:45:10 [ℹ]  waiting for scaling of nodegroup "managed-ng" to complete
2022-04-09 15:45:26 [ℹ]  waiting for scaling of nodegroup "managed-ng" to complete
2022-04-09 15:45:45 [ℹ]  waiting for scaling of nodegroup "managed-ng" to complete
2022-04-09 15:46:03 [ℹ]  waiting for scaling of nodegroup "managed-ng" to complete
2022-04-09 15:46:04 [ℹ]  nodegroup successfully scaled
```

执行如下命令检查node数量。

```
kubectl get node
```

返回结果如下表示扩容到6节点成功。

```
NAME                                                 STATUS   ROLES    AGE     VERSION
ip-192-168-109-58.ap-southeast-1.compute.internal    Ready    <none>   29m     v1.22.6-eks-7d68063
ip-192-168-122-179.ap-southeast-1.compute.internal   Ready    <none>   3h40m   v1.22.6-eks-7d68063
ip-192-168-137-83.ap-southeast-1.compute.internal    Ready    <none>   3h40m   v1.22.6-eks-7d68063
ip-192-168-151-125.ap-southeast-1.compute.internal   Ready    <none>   29m     v1.22.6-eks-7d68063
ip-192-168-177-150.ap-southeast-1.compute.internal   Ready    <none>   29m     v1.22.6-eks-7d68063
ip-192-168-181-37.ap-southeast-1.compute.internal    Ready    <none>   3h39m   v1.22.6-eks-7d68063


```

此时可以再次查询节点属性，执行如下命令。

```
eksctl get nodegroup --cluster eksworkshop
```

返回结果如下表示扩容成功。

```
2022-04-09 16:17:15 [ℹ]  eksctl version 0.92.0
2022-04-09 16:17:15 [ℹ]  using region ap-southeast-1
CLUSTER		NODEGROUP	STATUS	CREATED			MIN SIZE	MAX SIZE	DESIRED CAPACITY	INSTANCE TYPE	IMAGE ID	ASG NAME						TYPE
eksworkshop	managed-ng	ACTIVE	2022-04-09T04:34:33Z	3		9		6			t3.2xlarge	AL2_x86_64	eks-managed-ng-64c0064d-112b-eeb2-f9be-87b0414216d7	managed
```

## 三、调整节点组EC2规格

前文创建集群使用node节点不能直接更换规格。为此，需要在当前集群下新建一个nodegroup，并使用新的EC2规格，随后再删除旧的nodegroup。此时pod也将会自动在新nodegroup上拉起。整个过程不影响应用访问。

### 1、新建使用新的EC2规格的nodegroup

编辑如下内容，并保存为`newnodegroup.yaml`文件。需要注意的是，如果新创建的Nodegroup在Public Subnet内，这直接使用如下内容即可。如果新创建的Nodegroup在Private Subnet内，那么请增加如下一行`privateNetworking: true`到配置文件中。添加的位置在`volumeSize`的下一行即可。

```
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: eksworkshop
  region: ap-southeast-1
  version: "1.22"

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
2022-04-09 16:40:22 [ℹ]  eksctl version 0.92.0
2022-04-09 16:40:22 [ℹ]  using region ap-southeast-1
2022-04-09 16:40:33 [ℹ]  nodegroup "newng" will use "" [AmazonLinux2/1.22]
2022-04-09 16:40:34 [ℹ]  1 existing nodegroup(s) (managed-ng) will be excluded
2022-04-09 16:40:34 [ℹ]  1 nodegroup (newng) was included (based on the include/exclude rules)
2022-04-09 16:40:34 [ℹ]  will create a CloudFormation stack for each of 1 managed nodegroups in cluster "eksworkshop"
2022-04-09 16:40:35 [ℹ]  
2 sequential tasks: { fix cluster compatibility, 1 task: { 1 task: { create managed nodegroup "newng" } } 
}
2022-04-09 16:40:35 [ℹ]  checking cluster stack for missing resources
2022-04-09 16:40:36 [ℹ]  cluster stack has all required resources
2022-04-09 16:40:37 [ℹ]  building managed nodegroup stack "eksctl-eksworkshop-nodegroup-newng"
2022-04-09 16:40:38 [ℹ]  deploying stack "eksctl-eksworkshop-nodegroup-newng"
2022-04-09 16:40:38 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2022-04-09 16:40:55 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2022-04-09 16:41:12 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2022-04-09 16:41:33 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2022-04-09 16:41:52 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2022-04-09 16:42:09 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2022-04-09 16:42:31 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2022-04-09 16:42:49 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2022-04-09 16:43:10 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2022-04-09 16:43:26 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2022-04-09 16:43:45 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2022-04-09 16:43:47 [ℹ]  no tasks
2022-04-09 16:43:47 [✔]  created 0 nodegroup(s) in cluster "eksworkshop"
2022-04-09 16:43:48 [ℹ]  nodegroup "newng" has 3 node(s)
2022-04-09 16:43:48 [ℹ]  node "ip-192-168-124-223.ap-southeast-1.compute.internal" is ready
2022-04-09 16:43:48 [ℹ]  node "ip-192-168-130-40.ap-southeast-1.compute.internal" is ready
2022-04-09 16:43:48 [ℹ]  node "ip-192-168-172-17.ap-southeast-1.compute.internal" is ready
2022-04-09 16:43:48 [ℹ]  waiting for at least 3 node(s) to become ready in "newng"
2022-04-09 16:43:48 [ℹ]  nodegroup "newng" has 3 node(s)
2022-04-09 16:43:48 [ℹ]  node "ip-192-168-124-223.ap-southeast-1.compute.internal" is ready
2022-04-09 16:43:48 [ℹ]  node "ip-192-168-130-40.ap-southeast-1.compute.internal" is ready
2022-04-09 16:43:48 [ℹ]  node "ip-192-168-172-17.ap-southeast-1.compute.internal" is ready
2022-04-09 16:43:48 [✔]  created 1 managed nodegroup(s) in cluster "eksworkshop"
2022-04-09 16:43:50 [ℹ]  checking security group configuration for all nodegroups
2022-04-09 16:43:50 [ℹ]  all nodegroups have up-to-date cloudformation templates
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

### 2、删除旧的nodegroup

执行如下命令。

```
eksctl delete nodegroup --cluster eksworkshop --name managed-gp --region ap-southeast-1
```

等待几分钟后，再次查询集群所对应的nodegroup，执行如下命令。

```
eksctl get nodegroup --cluster eksworkshop
```

通过以上返回结果可以看到，原来规格的nodegroup被删除。