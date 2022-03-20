# 实验三、调整集群规格和配置

## 一、开启EKS管理平面的CloudWatch日志

```
eksctl utils update-cluster-logging --enable-types all --cluster eksworkshop --approve
```

## 二、启用CloudWatch Container Insight

注意：2021年之前本功能尚未在中国区发布，2021年10月在EKS 1.19上测试通过，2022年3月在EKS 1.21上测试通过。

### 1、添加IAM角色

进入IAM服务界面，找到Role角色界面，搜索关键字是 `eksctl-集群名称-nodegroup-node-NodeInstanceRole`，获得搜索结果：`eksctl-eksworkshop-nodegroup-node-NodeInstanceRole-1IZI5PCPB5OQP`。点击这个角色，为其增加策略。

点击角色后，在第一个标签页`Permissions`下，点击右上角的`Add permissions`，在下拉框中点击`Add policies`，然后在策略搜索框中查找`CloudWatchAgentServerPolicy`。找到这个策略后，选中这个策略，点击`Add policies`加入其中。

### 2、部署配置文件

执行如下命令，注意替换其中的Region和集群名称。

```
ClusterName=eksworkshop
RegionName=ap-southeast-1
FluentBitHttpPort='2020'
FluentBitReadFromHead='Off'
[[ ${FluentBitReadFromHead} = 'On' ]] && FluentBitReadFromTail='Off'|| FluentBitReadFromTail='On'
[[ -z ${FluentBitHttpPort} ]] && FluentBitHttpServer='Off' || FluentBitHttpServer='On'
curl https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/quickstart/cwagent-fluent-bit-quickstart.yaml | sed 's/{{cluster_name}}/'${ClusterName}'/;s/{{region_name}}/'${RegionName}'/;s/{{http_server_toggle}}/"'${FluentBitHttpServer}'"/;s/{{http_server_port}}/"'${FluentBitHttpPort}'"/;s/{{read_from_head}}/"'${FluentBitReadFromHead}'"/;s/{{read_from_tail}}/"'${FluentBitReadFromTail}'"/' | kubectl apply -f - 
```

部署完成。

当在中国区部署时候，中国区的节点可能无法访问到github的文件服务器，可以查看下用curl访问raw.githubusercontent.com是否能完成下载。如果缺失无法访问，那么可以通过如下链接使用中国区S3上的文件进行部署。

```
ClusterName=eksworkshop
RegionName=cn-northwest-1
FluentBitHttpPort='2020'
FluentBitReadFromHead='Off'
[[ ${FluentBitReadFromHead} = 'On' ]] && FluentBitReadFromTail='Off'|| FluentBitReadFromTail='On'
[[ -z ${FluentBitHttpPort} ]] && FluentBitHttpServer='Off' || FluentBitHttpServer='On'
curl https://myworkshop.bitipcman.com/eks101/cwagent-fluent-bit-quickstart.yaml | sed 's/{{cluster_name}}/'${ClusterName}'/;s/{{region_name}}/'${RegionName}'/;s/{{http_server_toggle}}/"'${FluentBitHttpServer}'"/;s/{{http_server_port}}/"'${FluentBitHttpPort}'"/;s/{{read_from_head}}/"'${FluentBitReadFromHead}'"/;s/{{read_from_tail}}/"'${FluentBitReadFromTail}'"/' | kubectl apply -f - 
```

部署完成。

### 3、查看Container Insight监控

进入Cloudwatch对应region界面，从左侧选择Container Insight，从右侧选择`View performance dashboards `，即可进入Container Insight。

## 三、调整节点组数量

前一步实验创建的集群时候没有指定节点数量，默认是2个节点，且系统会自动生成nodegroup，并分配nodegroup id。下面对这个nodegroup做扩容。

查询刚才集群的nodegroup id，执行如下命令，请替换集群名称为本次实验的名称。

```
eksctl get nodegroup --cluster eksworkshop
```

输出结果如下。

```
2021-07-01 22:19:49 [ℹ]  eksctl version 0.54.0
2021-07-01 22:19:49 [ℹ]  using region ap-southeast-1
CLUSTER		NODEGROUP	STATUS	CREATED			MIN SIZE	MAX SIZE	DESIRED CAPACITY	INSTANCE TYPE	IMAGE ID	ASG NAME
eksworkshop	ng-c61de5a8	ACTIVE	2021-07-01T12:31:40Z	2		2		2			m5.xlarge	AL2_x86_64	eks-40bd3106-cd37-5503-41ab-da2f4e060a3e
```

这里的 ng-c61de5a8 就是nodegroup的id，可以看到目前是最大2个节点，期望值是2个节点。

这个过程也可以使用json直接格式化输出，例如执行如下语句。

```
eksctl get nodegroup --cluster eksworkshop --region=ap-southeast-1 -o json | jq -r '.[].Name'
```

现在扩展集群到3个节点，并设置最大6节点。注意请替换下边语句中的cluster名称、region、nodegroup名称为当前实验对应的名称。

```
eksctl scale nodegroup --cluster=eksworkshop --region=ap-southeast-1 --name=ng-c61de5a8 --nodes-max=6 --nodes=3
```

执行结果如下表示扩展成功。

```
2021-07-01 22:30:11 [ℹ]  scaling nodegroup "ng-c61de5a8" in cluster eksworkshop
2021-07-01 22:30:14 [ℹ]  waiting for scaling of nodegroup "ng-c61de5a8" to complete
2021-07-01 22:30:31 [ℹ]  waiting for scaling of nodegroup "ng-c61de5a8" to complete
2021-07-01 22:30:31 [ℹ]  nodegroup successfully scaled
```

执行如下命令检查node数量。

```
kubectl get node
```

返回结果如下表示扩容到3节点成功。

```
NAME                                                STATUS     ROLES    AGE    VERSION
ip-192-168-23-182.ap-southeast-1.compute.internal   Ready      <none>   118m   v1.20.4-eks-6b7464
ip-192-168-54-147.ap-southeast-1.compute.internal   NotReady   <none>   14s    v1.20.4-eks-6b7464
ip-192-168-71-75.ap-southeast-1.compute.internal    Ready      <none>   118m   v1.20.4-eks-6b7464
```

此时可以再次查询节点属性，执行如下命令。

```
eksctl get nodegroup --cluster eksworkshop
```

返回结果如下表示扩容成功。

```
2021-07-01 22:31:36 [ℹ]  eksctl version 0.54.0
2021-07-01 22:31:36 [ℹ]  using region ap-southeast-1
CLUSTER		NODEGROUP	STATUS	CREATED			MIN SIZE	MAX SIZE	DESIRED CAPACITY	INSTANCE TYPE	IMAGE ID	ASG NAME
eksworkshop	ng-c61de5a8	ACTIVE	2021-07-01T12:31:40Z	2		6		3			m5.xlarge	AL2_x86_64	eks-40bd3106-cd37-5503-41ab-da2f4e060a3e
```

## 三、调整节点组EC2规格

前文创建集群使用的是m5.xlarge规格，4vCPU/16GB内存，EKS不能对现有的nodegroup直接配置。因此，为更换规格需要在当前集群下新建一个nodegroup，并使用新的EC2规格。随后再删除旧的nodegroup，pod也将会自动在新nodegroup上拉起。整个过程不影响应用访问。

### 1、新建使用新的EC2规格的nodegroup

执行如下命令新建一个nodegroup。

```
eksctl create nodegroup \
--cluster eksworkshop \
--name newgroup \
--node-type t3.2xlarge \
--nodes 3 \
--nodes-min 3 \
--nodes-max 6 \
--tags Name=newgroup \
--managed
```

如果是对一个现有的VPC内的位于私有子网的EKS集群创建新的nodegroup，执行如下命令：

```

eksctl create nodegroup --cluster eksworkshop --name newgroup --node-type t3.2xlarge --node-volume-size=100 --node-volume-type=gp3 --nodes 3 --nodes-min 3 --nodes-max 6 --tags Name=newgroup --managed --alb-ingress-access --full-ecr-access --node-private-networking --region=ap-southeast-1
```

执行结果如下。

```
2021-07-01 22:40:59 [ℹ]  eksctl version 0.54.0
2021-07-01 22:40:59 [ℹ]  using region ap-southeast-1
2021-07-01 22:41:06 [ℹ]  nodegroup "newgroup" will use "" [AmazonLinux2/1.20]
2021-07-01 22:41:08 [ℹ]  1 existing nodegroup(s) (ng-c61de5a8) will be excluded
2021-07-01 22:41:08 [ℹ]  1 nodegroup (newgroup) was included (based on the include/exclude rules)
2021-07-01 22:41:08 [ℹ]  will create a CloudFormation stack for each of 1 managed nodegroups in cluster "eksworkshop"
2021-07-01 22:41:08 [ℹ]  2 sequential tasks: { fix cluster compatibility, 1 task: { 1 task: { create managed nodegroup "newgroup" } } }
2021-07-01 22:41:08 [ℹ]  checking cluster stack for missing resources
2021-07-01 22:41:09 [ℹ]  cluster stack has all required resources
2021-07-01 22:41:09 [ℹ]  building managed nodegroup stack "eksctl-eksworkshop-nodegroup-newgroup"
2021-07-01 22:41:09 [ℹ]  deploying stack "eksctl-eksworkshop-nodegroup-newgroup"
2021-07-01 22:41:09 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newgroup"
2021-07-01 22:41:26 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newgroup"
2021-07-01 22:41:44 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newgroup"
2021-07-01 22:42:04 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newgroup"
2021-07-01 22:42:21 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newgroup"
2021-07-01 22:42:42 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newgroup"
2021-07-01 22:43:02 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newgroup"
2021-07-01 22:43:21 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newgroup"
2021-07-01 22:43:39 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newgroup"
2021-07-01 22:43:57 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newgroup"
2021-07-01 22:44:15 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newgroup"
2021-07-01 22:44:31 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newgroup"
2021-07-01 22:44:50 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newgroup"
2021-07-01 22:45:07 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newgroup"
2021-07-01 22:45:08 [ℹ]  no tasks
2021-07-01 22:45:08 [✔]  created 0 nodegroup(s) in cluster "eksworkshop"
2021-07-01 22:45:09 [ℹ]  nodegroup "newgroup" has 3 node(s)
2021-07-01 22:45:09 [ℹ]  node "ip-192-168-28-177.ap-southeast-1.compute.internal" is ready
2021-07-01 22:45:09 [ℹ]  node "ip-192-168-41-212.ap-southeast-1.compute.internal" is ready
2021-07-01 22:45:09 [ℹ]  node "ip-192-168-72-127.ap-southeast-1.compute.internal" is ready
2021-07-01 22:45:09 [ℹ]  waiting for at least 3 node(s) to become ready in "newgroup"
2021-07-01 22:45:09 [ℹ]  nodegroup "newgroup" has 3 node(s)
2021-07-01 22:45:09 [ℹ]  node "ip-192-168-28-177.ap-southeast-1.compute.internal" is ready
2021-07-01 22:45:09 [ℹ]  node "ip-192-168-41-212.ap-southeast-1.compute.internal" is ready
2021-07-01 22:45:09 [ℹ]  node "ip-192-168-72-127.ap-southeast-1.compute.internal" is ready
2021-07-01 22:45:09 [✔]  created 1 managed nodegroup(s) in cluster "eksworkshop"
2021-07-01 22:45:11 [ℹ]  checking security group configuration for all nodegroups
2021-07-01 22:45:11 [ℹ]  all nodegroups have up-to-date configuration
```

执行如下命令查看nodegroup是否正常。

```
eksctl get nodegroup --cluster eksworkshop
```

返回结果可以看到原来的和新创建的两个nodegroup如下。

```
CLUSTER		NODEGROUP	STATUS	CREATED			MIN SIZE	MAX SIZE	DESIRED CAPACITY	INSTANCE TYPE	IMAGE ID	ASG NAME
eksworkshop	newgroup	ACTIVE	2021-07-01T14:42:09Z	3		6		3			t3.2xlarge	AL2_x86_64	eks-3ebd3142-8885-3e09-7bde-95be81eeabc5
eksworkshop	ng-c61de5a8	ACTIVE	2021-07-01T12:31:40Z	2		6		3			m5.xlarge	AL2_x86_64	eks-40bd3106-cd37-5503-41ab-da2f4e060a3e
```

另外需要注意，新创建的node group还需要额外配置Cloudwatch权限才可以完成监控。

### 2、删除旧的nodegroup

执行如下命令。

```
eksctl delete nodegroup --cluster eksworkshop --name ng-c61de5a8
```

执行效果如下。此时通过输出可以看到，EKS将旧的nodegroup设置为 "drained" 状态，并从集群中删除。

```
2021-07-01 23:21:13 [ℹ]  eksctl version 0.54.0
2021-07-01 23:21:13 [ℹ]  using region ap-southeast-1
2021-07-01 23:21:14 [ℹ]  1 nodegroup (ng-c61de5a8) was included (based on the include/exclude rules)
2021-07-01 23:21:14 [ℹ]  will drain 1 nodegroup(s) in cluster "eksworkshop"
2021-07-01 23:21:17 [ℹ]  cordon node "ip-192-168-23-182.ap-southeast-1.compute.internal"
2021-07-01 23:21:17 [ℹ]  cordon node "ip-192-168-54-147.ap-southeast-1.compute.internal"
2021-07-01 23:21:17 [ℹ]  cordon node "ip-192-168-71-75.ap-southeast-1.compute.internal"
2021-07-01 23:21:18 [!]  ignoring DaemonSet-managed Pods: amazon-cloudwatch/cloudwatch-agent-mjnt6, amazon-cloudwatch/fluent-bit-rdcqp, kube-system/aws-node-t5cxc, kube-system/kube-proxy-wrvnx
2021-07-01 23:21:20 [!]  ignoring DaemonSet-managed Pods: amazon-cloudwatch/cloudwatch-agent-ngmfj, amazon-cloudwatch/fluent-bit-v7vls, kube-system/aws-node-9lftq, kube-system/kube-proxy-vmm2n
2021-07-01 23:21:21 [!]  ignoring DaemonSet-managed Pods: amazon-cloudwatch/cloudwatch-agent-45jc2, amazon-cloudwatch/fluent-bit-klqlt, kube-system/aws-node-652sf, kube-system/kube-proxy-5llsm
2021-07-01 23:21:23 [!]  ignoring DaemonSet-managed Pods: amazon-cloudwatch/cloudwatch-agent-mjnt6, amazon-cloudwatch/fluent-bit-rdcqp, kube-system/aws-node-t5cxc, kube-system/kube-proxy-wrvnx
2021-07-01 23:21:24 [!]  pod eviction error ("pods \"deployment-2048-79785cfdff-kxxxj\" not found") on node ip-192-168-23-182.ap-southeast-1.compute.internal
2021-07-01 23:21:30 [!]  ignoring DaemonSet-managed Pods: amazon-cloudwatch/cloudwatch-agent-45jc2, amazon-cloudwatch/fluent-bit-klqlt, kube-system/aws-node-652sf, kube-system/kube-proxy-5llsm
2021-07-01 23:21:31 [!]  ignoring DaemonSet-managed Pods: amazon-cloudwatch/cloudwatch-agent-mjnt6, amazon-cloudwatch/fluent-bit-rdcqp, kube-system/aws-node-t5cxc, kube-system/kube-proxy-wrvnx
2021-07-01 23:21:33 [!]  ignoring DaemonSet-managed Pods: amazon-cloudwatch/cloudwatch-agent-mjnt6, amazon-cloudwatch/fluent-bit-rdcqp, kube-system/aws-node-t5cxc, kube-system/kube-proxy-wrvnx
2021-07-01 23:21:34 [!]  ignoring DaemonSet-managed Pods: amazon-cloudwatch/cloudwatch-agent-mjnt6, amazon-cloudwatch/fluent-bit-rdcqp, kube-system/aws-node-t5cxc, kube-system/kube-proxy-wrvnx
2021-07-01 23:21:34 [!]  pod eviction error ("pods \"aws-load-balancer-controller-797fc99b8c-l29rc\" not found") on node ip-192-168-23-182.ap-southeast-1.compute.internal
2021-07-01 23:21:41 [!]  ignoring DaemonSet-managed Pods: amazon-cloudwatch/cloudwatch-agent-mjnt6, amazon-cloudwatch/fluent-bit-rdcqp, kube-system/aws-node-t5cxc, kube-system/kube-proxy-wrvnx
2021-07-01 23:21:41 [✔]  drained all nodes: [ip-192-168-23-182.ap-southeast-1.compute.internal ip-192-168-54-147.ap-southeast-1.compute.internal ip-192-168-71-75.ap-southeast-1.compute.internal]
2021-07-01 23:21:41 [ℹ]  will delete 1 nodegroups from cluster "eksworkshop"
2021-07-01 23:21:43 [ℹ]  1 task: { 1 task: { delete nodegroup "ng-c61de5a8" [async] } }
2021-07-01 23:21:44 [ℹ]  will delete stack "eksctl-eksworkshop-nodegroup-ng-c61de5a8"
2021-07-01 23:21:44 [ℹ]  will delete 0 nodegroups from auth ConfigMap in cluster "eksworkshop"
2021-07-01 23:21:44 [✔]  deleted 1 nodegroup(s) from cluster "eksworkshop"
```

显示当前集群nodegroup，执行如下命令。

```
eksctl get nodegroup --cluster eksworkshop
```

返回结果如下。

```
2021-07-01 23:23:09 [ℹ]  eksctl version 0.54.0
2021-07-01 23:23:09 [ℹ]  using region ap-southeast-1
CLUSTER		NODEGROUP	STATUS		CREATED			MIN SIZE	MAX SIZE	DESIRED CAPACITY	INSTANCE TYPE	IMAGE ID	ASG NAME
eksworkshop	newgroup	ACTIVE		2021-07-01T14:42:09Z	2		6		3			t3.2xlarge	AL2_x86_64	eks-3ebd3142-8885-3e09-7bde-95be81eeabc5
eksworkshop	ng-c61de5a8	DELETING	2021-07-01T12:31:40Z	2		6		3			m5.xlarge	AL2_x86_64	eks-40bd3106-cd37-5503-41ab-da2f4e060a3e
```

通过以上返回结果可以看到，原来规格的nodegroup被删除，集群中新的nodegroup是使用新规格的节点。

此时如果集群中有应用运行，将自动在新的nodegroup中拉起pod运行，更换nodegroup的过程不影响应用运行。