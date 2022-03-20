# 实验五、使用Spot实例

## 一、使用Spot实例

### 1、新建使用新的EC2规格的nodegroup

执行如下命令新建一个nodegroup。请注意修改cluster名称与当前集群名称要匹配。

```
eksctl create nodegroup \
--cluster eksworkshop \
--spot \
--name spotgroup \
--node-type t3.2xlarge \
--nodes 3 \
--nodes-min 3 \
--nodes-max 6 \
--tags Name=spotgroup \
--managed
```

执行结果如下。

```
2021-10-11 11:24:23 [ℹ]  eksctl version 0.69.0
2021-10-11 11:24:23 [ℹ]  using region cn-northwest-1
2021-10-11 11:24:23 [ℹ]  will use version 1.21 for new nodegroup(s) based on control plane version
2021-10-11 11:24:29 [ℹ]  nodegroup "spotgroup" will use "" [AmazonLinux2/1.21]
2021-10-11 11:24:29 [ℹ]  1 existing nodegroup(s) (ng-91f33891) will be excluded
2021-10-11 11:24:29 [ℹ]  1 nodegroup (spotgroup) was included (based on the include/exclude rules)
2021-10-11 11:24:29 [ℹ]  will create a CloudFormation stack for each of 1 managed nodegroups in cluster "eks-demo-zhy"
2021-10-11 11:24:29 [ℹ]  2 sequential tasks: { fix cluster compatibility, 1 task: { 1 task: { create managed nodegroup "spotgroup" } } }
2021-10-11 11:24:29 [ℹ]  checking cluster stack for missing resources
2021-10-11 11:24:30 [ℹ]  cluster stack has all required resources
2021-10-11 11:24:30 [ℹ]  building managed nodegroup stack "eksctl-eks-demo-zhy-nodegroup-spotgroup"
2021-10-11 11:24:30 [ℹ]  deploying stack "eksctl-eks-demo-zhy-nodegroup-spotgroup"
2021-10-11 11:24:30 [ℹ]  waiting for CloudFormation stack "eksctl-eks-demo-zhy-nodegroup-spotgroup"
2021-10-11 11:24:46 [ℹ]  waiting for CloudFormation stack "eksctl-eks-demo-zhy-nodegroup-spotgroup"
2021-10-11 11:25:05 [ℹ]  waiting for CloudFormation stack "eksctl-eks-demo-zhy-nodegroup-spotgroup"
2021-10-11 11:25:25 [ℹ]  waiting for CloudFormation stack "eksctl-eks-demo-zhy-nodegroup-spotgroup"
2021-10-11 11:25:43 [ℹ]  waiting for CloudFormation stack "eksctl-eks-demo-zhy-nodegroup-spotgroup"
2021-10-11 11:26:04 [ℹ]  waiting for CloudFormation stack "eksctl-eks-demo-zhy-nodegroup-spotgroup"
2021-10-11 11:26:25 [ℹ]  waiting for CloudFormation stack "eksctl-eks-demo-zhy-nodegroup-spotgroup"
2021-10-11 11:26:45 [ℹ]  waiting for CloudFormation stack "eksctl-eks-demo-zhy-nodegroup-spotgroup"
2021-10-11 11:27:03 [ℹ]  waiting for CloudFormation stack "eksctl-eks-demo-zhy-nodegroup-spotgroup"
2021-10-11 11:27:22 [ℹ]  waiting for CloudFormation stack "eksctl-eks-demo-zhy-nodegroup-spotgroup"
2021-10-11 11:27:40 [ℹ]  waiting for CloudFormation stack "eksctl-eks-demo-zhy-nodegroup-spotgroup"
2021-10-11 11:27:57 [ℹ]  waiting for CloudFormation stack "eksctl-eks-demo-zhy-nodegroup-spotgroup"
2021-10-11 11:28:16 [ℹ]  waiting for CloudFormation stack "eksctl-eks-demo-zhy-nodegroup-spotgroup"
2021-10-11 11:28:18 [ℹ]  no tasks
2021-10-11 11:28:18 [✔]  created 0 nodegroup(s) in cluster "eks-demo-zhy"
2021-10-11 11:28:19 [ℹ]  nodegroup "spotgroup" has 3 node(s)
2021-10-11 11:28:19 [ℹ]  node "ip-192-168-3-154.cn-northwest-1.compute.internal" is ready
2021-10-11 11:28:19 [ℹ]  node "ip-192-168-36-157.cn-northwest-1.compute.internal" is ready
2021-10-11 11:28:19 [ℹ]  node "ip-192-168-67-71.cn-northwest-1.compute.internal" is ready
2021-10-11 11:28:19 [ℹ]  waiting for at least 3 node(s) to become ready in "spotgroup"
2021-10-11 11:28:19 [ℹ]  nodegroup "spotgroup" has 3 node(s)
2021-10-11 11:28:19 [ℹ]  node "ip-192-168-3-154.cn-northwest-1.compute.internal" is ready
2021-10-11 11:28:19 [ℹ]  node "ip-192-168-36-157.cn-northwest-1.compute.internal" is ready
2021-10-11 11:28:19 [ℹ]  node "ip-192-168-67-71.cn-northwest-1.compute.internal" is ready
2021-10-11 11:28:19 [✔]  created 1 managed nodegroup(s) in cluster "eks-demo-zhy"
2021-10-11 11:28:20 [ℹ]  checking security group configuration for all nodegroups
2021-10-11 11:28:20 [ℹ]  all nodegroups have up-to-date configuration
```

执行如下命令查看nodegroup是否正常。请注意修改cluster名称与当前集群名称要匹配。

```
eksctl get nodegroup --cluster eksworkshop
```

返回结果可以看到原来的和新创建的两个nodegroup如下。

```
CLUSTER		NODEGROUP	STATUS	CREATED			MIN SIZE	MAX SIZE	DESIRED CAPACITY	INSTANCE TYPE	IMAGE ID	ASG NAME
eks-demo-zhy	ng-91f33891	ACTIVE	2021-10-08T12:20:09Z	2		2		2			m5.2xlarge	AL2_x86_64	eks-ng-91f33891-30be2fec-54a2-624b-4090-054628064351
eks-demo-zhy	spotgroup	ACTIVE	2021-10-11T03:25:22Z	3		6		3			t3.2xlarge	AL2_x86_64	eks-spotgroup-72be36b1-129a-d74e-107d-9386e7ae4442
```

### 2、删除旧的nodegroup

执行如下命令。请注意修改cluster名称与当前集群名称要匹配。

```
eksctl delete nodegroup --cluster eksworkshop --name ng-91f33891
```

执行效果如下。此时通过输出可以看到，EKS将旧的nodegroup设置为 "drained" 状态，并从集群中删除。

```
2021-10-11 11:53:04 [ℹ]  eksctl version 0.69.0
2021-10-11 11:53:04 [ℹ]  using region cn-northwest-1
2021-10-11 11:53:06 [ℹ]  1 nodegroup (ng-91f33891) was included (based on the include/exclude rules)
2021-10-11 11:53:06 [ℹ]  will drain 1 nodegroup(s) in cluster "eks-demo-zhy"
2021-10-11 11:53:07 [ℹ]  cordon node "ip-192-168-25-128.cn-northwest-1.compute.internal"
2021-10-11 11:53:07 [ℹ]  cordon node "ip-192-168-61-44.cn-northwest-1.compute.internal"
2021-10-11 11:53:08 [!]  ignoring DaemonSet-managed Pods: amazon-cloudwatch/cloudwatch-agent-jh2xw, amazon-cloudwatch/fluent-bit-vg9jf, kube-system/aws-node-8vvvp, kube-system/kube-proxy-nm2wj
2021-10-11 11:53:08 [!]  ignoring DaemonSet-managed Pods: amazon-cloudwatch/cloudwatch-agent-8fvpc, amazon-cloudwatch/fluent-bit-lxqdz, kube-system/aws-node-k8rpc, kube-system/kube-proxy-g7424
2021-10-11 11:53:09 [!]  ignoring DaemonSet-managed Pods: amazon-cloudwatch/cloudwatch-agent-jh2xw, amazon-cloudwatch/fluent-bit-vg9jf, kube-system/aws-node-8vvvp, kube-system/kube-proxy-nm2wj
2021-10-11 11:53:10 [!]  ignoring DaemonSet-managed Pods: amazon-cloudwatch/cloudwatch-agent-8fvpc, amazon-cloudwatch/fluent-bit-lxqdz, kube-system/aws-node-k8rpc, kube-system/kube-proxy-g7424
2021-10-11 11:53:12 [!]  ignoring DaemonSet-managed Pods: amazon-cloudwatch/cloudwatch-agent-jh2xw, amazon-cloudwatch/fluent-bit-vg9jf, kube-system/aws-node-8vvvp, kube-system/kube-proxy-nm2wj
2021-10-11 11:53:13 [!]  ignoring DaemonSet-managed Pods: amazon-cloudwatch/cloudwatch-agent-8fvpc, amazon-cloudwatch/fluent-bit-lxqdz, kube-system/aws-node-k8rpc, kube-system/kube-proxy-g7424
2021-10-11 11:53:14 [!]  ignoring DaemonSet-managed Pods: amazon-cloudwatch/cloudwatch-agent-jh2xw, amazon-cloudwatch/fluent-bit-vg9jf, kube-system/aws-node-8vvvp, kube-system/kube-proxy-nm2wj
2021-10-11 11:53:15 [!]  ignoring DaemonSet-managed Pods: amazon-cloudwatch/cloudwatch-agent-8fvpc, amazon-cloudwatch/fluent-bit-lxqdz, kube-system/aws-node-k8rpc, kube-system/kube-proxy-g7424
2021-10-11 11:53:17 [!]  ignoring DaemonSet-managed Pods: amazon-cloudwatch/cloudwatch-agent-jh2xw, amazon-cloudwatch/fluent-bit-vg9jf, kube-system/aws-node-8vvvp, kube-system/kube-proxy-nm2wj
2021-10-11 11:53:18 [!]  ignoring DaemonSet-managed Pods: amazon-cloudwatch/cloudwatch-agent-8fvpc, amazon-cloudwatch/fluent-bit-lxqdz, kube-system/aws-node-k8rpc, kube-system/kube-proxy-g7424
2021-10-11 11:53:18 [!]  pod eviction error ("error evicting pod: game-2048/deployment-2048-79785cfdff-f9db2: pods \"deployment-2048-79785cfdff-f9db2\" not found") on node ip-192-168-61-44.cn-northwest-1.compute.internal
2021-10-11 11:53:23 [!]  ignoring DaemonSet-managed Pods: amazon-cloudwatch/cloudwatch-agent-jh2xw, amazon-cloudwatch/fluent-bit-vg9jf, kube-system/aws-node-8vvvp, kube-system/kube-proxy-nm2wj
2021-10-11 11:53:24 [!]  ignoring DaemonSet-managed Pods: amazon-cloudwatch/cloudwatch-agent-8fvpc, amazon-cloudwatch/fluent-bit-lxqdz, kube-system/aws-node-k8rpc, kube-system/kube-proxy-g7424
2021-10-11 11:53:24 [✔]  drained all nodes: [ip-192-168-25-128.cn-northwest-1.compute.internal ip-192-168-61-44.cn-northwest-1.compute.internal]
2021-10-11 11:53:24 [ℹ]  will delete 1 nodegroups from cluster "eks-demo-zhy"
2021-10-11 11:53:25 [ℹ]  1 task: { 1 task: { delete nodegroup "ng-91f33891" [async] } }
2021-10-11 11:53:25 [ℹ]  will delete stack "eksctl-eks-demo-zhy-nodegroup-ng-91f33891"
2021-10-11 11:53:25 [ℹ]  will delete 0 nodegroups from auth ConfigMap in cluster "eks-demo-zhy"
2021-10-11 11:53:25 [✔]  deleted 1 nodegroup(s) from cluster "eks-demo-zhy"
```

显示当前集群nodegroup，执行如下命令。请注意修改cluster名称与当前集群名称要匹配。

```
eksctl get nodegroup --cluster eksworkshop
```

返回结果如下。

```
2021-10-11 11:56:33 [ℹ]  eksctl version 0.69.0
2021-10-11 11:56:33 [ℹ]  using region cn-northwest-1
2021-10-11 11:56:34 [!]  stack's status of nodegroup named eksctl-eks-demo-zhy-nodegroup-ng-91f33891 is DELETE_FAILED
CLUSTER		NODEGROUP	STATUS	CREATED			MIN SIZE	MAX SIZE	DESIRED CAPACITY	INSTANCE TYPE	IMAGE ID	ASG NAME
eks-demo-zhy	spotgroup	ACTIVE	2021-10-11T03:25:22Z	3		6		3			t3.2xlarge	AL2_x86_64	eks-spotgroup-72be36b1-129a-d74e-107d-9386e7ae4442
```

通过以上返回结果可以看到，原来规格的nodegroup被删除，集群中新的nodegroup是使用新规格的节点。

此时如果集群中有应用运行，将自动在新的nodegroup中拉起pod运行，更换nodegroup的过程不影响应用运行。