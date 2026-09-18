# 实验三、启用CloudWatch Container Insight、新建Nodegroup节点组以及调整节点组机型配置

EKS 1.36版本 @2026 AWS Global区域测试通过

## 一、启用CloudWatch Container Insight

CloudWatch Container Insight面向EKS的EC2节点采集容器、Pod、节点与集群四个层级的运行参数，用于监控和诊断，采集内容包括CPU与内存利用率、网络吞吐、磁盘使用以及Pod重启次数等，同时通过FluentBit将应用日志、数据平面日志与主机日志投递到CloudWatch Logs。

本文采用EKS Addon方式部署，由EKS负责采集组件的安装、版本管理与生命周期维护，无需手工编写FluentBit与CloudWatch Agent的部署清单。整个部署分为配置IAM角色与创建Addon两步。

### 1、配置Service Role

执行如下命令配置OIDC。本步骤如果您在EKS安装过AWS Load Balancer Controller，那么这一步是已经执行过的，可以跳过。重复执行也不会报错。

```
eksctl utils associate-iam-oidc-provider --region ap-southeast-1 --cluster eksworkshop --approve
```

配置Service Role。请注意`--region`参数不可省略。

```
eksctl create iamserviceaccount \
  --name cloudwatch-agent \
  --namespace amazon-cloudwatch \
  --cluster eksworkshop \
  --region ap-southeast-1 \
  --role-name AmazonEKSContainerInsightRole \
  --attach-policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy \
  --role-only \
  --approve
```

执行成功返回信息如下：

```
2026-09-18 17:54:49 [ℹ]  1 existing iamserviceaccount(s) (kube-system/aws-load-balancer-controller) will be excluded
2026-09-18 17:54:49 [ℹ]  1 iamserviceaccount (amazon-cloudwatch/cloudwatch-agent) was included (based on the include/exclude rules)
2026-09-18 17:54:49 [!]  serviceaccounts in Kubernetes will not be created or modified, since the option --role-only is used
2026-09-18 17:54:49 [ℹ]  1 task: { create IAM role for serviceaccount "amazon-cloudwatch/cloudwatch-agent" }
2026-09-18 17:54:49 [ℹ]  building iamserviceaccount stack "eksctl-eksworkshop-addon-iamserviceaccount-amazon-cloudwatch-cloudwatch-agent"
2026-09-18 17:54:50 [ℹ]  deploying stack "eksctl-eksworkshop-addon-iamserviceaccount-amazon-cloudwatch-cloudwatch-agent"
2026-09-18 17:54:50 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-addon-iamserviceaccount-amazon-cloudwatch-cloudwatch-agent"
2026-09-18 17:55:21 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-addon-iamserviceaccount-amazon-cloudwatch-cloudwatch-agent"
```

整个过程由CloudFormation完成，实测耗时约60至90秒。若省略`--region`参数，eksctl会回退到AWS CLI配置文件中的默认区域，当默认区域与集群所在区域不一致时命令直接中止，报错如下：

```
Error: unable to describe cluster control plane: operation error EKS: DescribeCluster, https response error StatusCode: 404, ResourceNotFoundException: No cluster found for name: eksworkshop.
```

本章后续所有`eksctl`与`aws eks`命令均存在同样的约束。可执行`aws configure get region`确认当前默认区域，若与集群区域不同则必须逐条显式指定。

执行如下命令确认角色已经创建：

```
aws iam get-role --role-name AmazonEKSContainerInsightRole --query 'Role.Arn' --output text
```

返回结果如下：

```
arn:aws:iam::133129065110:role/AmazonEKSContainerInsightRole
```

### 2、通过EKS Addon安装

安装前可执行如下命令查询当前Kubernetes版本下可用的Addon版本，其中`Default`为`True`的即为不指定版本时所采用的默认版本：

```
aws eks describe-addon-versions --region ap-southeast-1 \
  --addon-name amazon-cloudwatch-observability \
  --kubernetes-version 1.36 \
  --query 'addons[0].addonVersions[].{Version:addonVersion,Default:compatibilities[0].defaultVersion}' \
  --output table
```

返回结果如下，本文实测所采用的默认版本为`v6.6.0-eksbuild.1`：

```
----------------------------------
|      DescribeAddonVersions     |
+----------+---------------------+
|  Default |       Version       |
+----------+---------------------+
|  True    |  v6.6.0-eksbuild.1  |
|  False   |  v6.5.0-eksbuild.1  |
|  False   |  v6.4.0-eksbuild.1  |
+----------+---------------------+
```

接下来创建Addon。此处必须通过`--service-account-role-arn`参数显式指定上一节创建的IAM角色，否则该角色不会被引用，Addon将回落到节点实例角色的权限：

```
aws eks create-addon --cluster-name eksworkshop --region ap-southeast-1 \
  --addon-name amazon-cloudwatch-observability \
  --service-account-role-arn arn:aws:iam::133129065110:role/AmazonEKSContainerInsightRole
```

返回结果如下：

```
{
    "addon": {
        "addonName": "amazon-cloudwatch-observability",
        "clusterName": "eksworkshop",
        "status": "CREATING",
        "addonVersion": "v6.6.0-eksbuild.1",
        "health": {
            "issues": []
        },
        "addonArn": "arn:aws:eks:ap-southeast-1:133129065110:addon/eksworkshop/amazon-cloudwatch-observability/42d059f9-c87f-89d5-6095-257fceda2362",
        "createdAt": "2026-09-18T17:57:59.316000+08:00",
        "modifiedAt": "2026-09-18T17:57:59.329000+08:00",
        "tags": {},
        "namespaceConfig": {
            "namespace": "amazon-cloudwatch"
        }
    }
}
```

关于上述`--service-account-role-arn`参数需要展开说明。该参数是把前一节的IAM角色与Addon自动创建的`cloudwatch-agent` ServiceAccount关联起来的唯一途径，即IRSA（IAM Roles for Service Accounts）机制的落地环节。实测中若省略该参数，Addon同样可以进入`ACTIVE`状态且指标正常上报，但`cloudwatch-agent`这个ServiceAccount上不会出现`eks.amazonaws.com/role-arn`注解，采集容器实际使用的是节点实例角色的凭证。之所以在这种情况下仍能工作，是因为实验一创建节点组时在`iam.withAddonPolicies`中设置了`cloudWatch: true`，eksctl据此为节点实例角色附加了`CloudWatchAgentServerPolicy`，该策略恰好覆盖了采集所需的权限。这一路径虽然可用，但等价于把CloudWatch写入权限授予节点上的全部Pod，不符合最小权限原则，同时也使前一节创建角色的步骤失去意义，因此本文要求显式传入该参数。

若Addon已经以缺省方式创建完毕，无需删除重建，执行如下命令补充绑定即可：

```
aws eks update-addon --cluster-name eksworkshop --region ap-southeast-1 \
  --addon-name amazon-cloudwatch-observability \
  --service-account-role-arn arn:aws:iam::133129065110:role/AmazonEKSContainerInsightRole
```

需要注意的是，该更新只修改ServiceAccount上的注解，不会重启已经在运行的采集Pod。凭证注入发生在Pod创建阶段，因此已有Pod仍沿用节点实例角色，只有此后新建的Pod才会通过IRSA获得该角色。实测在更新完成后新增节点，其上新建的`cloudwatch-agent` Pod已带有`AWS_ROLE_ARN`环境变量，而更新之前创建的Pod则没有。若需立即生效，可执行`kubectl rollout restart daemonset/cloudwatch-agent -n amazon-cloudwatch`主动重建。

部署完成。执行如下命令确认Addon状态，`status`为`ACTIVE`且`serviceAccountRoleArn`非空表示正常：

```
aws eks describe-addon --cluster-name eksworkshop --region ap-southeast-1 \
  --addon-name amazon-cloudwatch-observability \
  --query 'addon.{Status:status,Version:addonVersion,RoleArn:serviceAccountRoleArn,Issues:health.issues}' --output json
```

返回结果如下：

```
{
    "Status": "ACTIVE",
    "Version": "v6.6.0-eksbuild.1",
    "RoleArn": "arn:aws:iam::133129065110:role/AmazonEKSContainerInsightRole",
    "Issues": []
}
```

接下来确认采集组件的Pod已经就绪，执行如下命令：

```
kubectl get pods -n amazon-cloudwatch
```

返回结果如下。该Addon在三节点集群上共拉起七个Pod，其中`amazon-cloudwatch-observability-controller-manager`为单副本的控制器，`cloudwatch-agent`负责指标采集，`fluent-bit`负责日志采集，后两者均为DaemonSet，因此每个节点各有一个副本，节点数量变化时会自动跟随：

```
NAME                                                              READY   STATUS    RESTARTS   AGE
amazon-cloudwatch-observability-controller-manager-7bd6b64gzdz4   1/1     Running   0          78s
cloudwatch-agent-9dnfq                                            1/1     Running   0          72s
cloudwatch-agent-gvtfw                                            1/1     Running   0          72s
cloudwatch-agent-jffpd                                            1/1     Running   0          72s
fluent-bit-46hx4                                                  1/1     Running   0          79s
fluent-bit-w2jzr                                                  1/1     Running   0          79s
fluent-bit-xg4pk                                                  1/1     Running   0          79s
```

备注：Addon同时会创建`cloudwatch-agent-windows`、`dcgm-exporter`、`neuron-monitor`等若干DaemonSet，分别面向Windows节点、GPU节点与Inferentia/Trainium节点。在本实验的Linux通用机型节点上，这些DaemonSet的期望副本数为0，属于正常状态。

### 3、查看Container Insight监控效果

进入Cloudwatch服务，切换到EKS部署所在的Region界面，从左侧菜单选择`Insights`，在其中找到`Container Insight`，点击进入。

在右侧`Container Insights`的位置，从下拉框选择`Service: EKS`，下方即可看到Cluster的信息。由于是新部署的监控，因此需要等待数分钟，或者更长的一段时间后，监控数据即可正常加载。

在控制台界面之外，也可以从命令行确认采集链路是否真正打通，这在排查"界面无数据"问题时尤为有用，因为可以区分究竟是指标未上报还是控制台展示存在延迟。首先确认日志组已经创建，执行如下命令：

```
aws logs describe-log-groups --region ap-southeast-1 \
  --log-group-name-prefix /aws/containerinsights/eksworkshop \
  --query 'logGroups[].logGroupName' --output table
```

返回结果如下，四个日志组分别承载应用日志、数据平面日志、主机日志与性能指标日志：

```
---------------------------------------------------
|               DescribeLogGroups                 |
+-------------------------------------------------+
|  /aws/containerinsights/eksworkshop/application |
|  /aws/containerinsights/eksworkshop/dataplane   |
|  /aws/containerinsights/eksworkshop/host        |
|  /aws/containerinsights/eksworkshop/performance |
+-------------------------------------------------+
```

然后确认指标已经产生数据点。执行如下命令查询最近15分钟内节点CPU利用率的数据点：

```
aws cloudwatch get-metric-statistics --region ap-southeast-1 \
  --namespace ContainerInsights --metric-name node_cpu_utilization \
  --dimensions Name=ClusterName,Value=eksworkshop \
  --start-time $(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 --statistics Average \
  --query 'Datapoints[].{T:Timestamp,Avg:Average}' --output table
```

返回结果如下，出现数据点即表示采集正常：

```
-----------------------------------------------------
|                GetMetricStatistics                |
+---------------------+-----------------------------+
|         Avg         |              T              |
+---------------------+-----------------------------+
|  0.9613041268027814 |  2026-09-18T18:00:00+08:00  |
+---------------------+-----------------------------+
```

备注：上述`date`命令的`-v-15M`语法为MacOS与BSD系统专有。在Linux系统上请改用`date -u -d '15 minutes ago' +%Y-%m-%dT%H:%M:%SZ`。实测从Addon进入`ACTIVE`状态到出现第一个指标数据点约需2至3分钟，而日志组的`storedBytes`字段在初期可能仍显示为0，这是计量统计的延迟，不代表日志未写入。

## 二、手工调整节点组数量（不改变机型，只调整数量）

注意：下文是手动缩放节点数量，如果您需要自动缩放节点数量，请参考EKS实验对应Cluster Autoscaling（CA）章节。

前一步实验创建的集群时候，如果配置文件中没有指定节点数量，默认是3个节点，且系统会自动生成nodegroup。下面对这个nodegroup做扩容。

### 1、查看现有集群Nodegroup

查询刚才集群的nodegroup名称，执行如下命令，请替换集群名称和区域为本次实验的名称。

```
eksctl get nodegroup --cluster eksworkshop --region ap-southeast-1
```

输出结果如下。

```
CLUSTER		NODEGROUP	STATUS	CREATED			MIN SIZE	MAX SIZE	DESIRED CAPACITY	INSTANCE TYPE	IMAGE ID		ASG NAME						TYPE
eksworkshop	managed-ng	ACTIVE	2026-09-18T01:12:31Z	3		6		3			t3.2xlarge	AL2023_x86_64_STANDARD	eks-managed-ng-14d05909-37eb-4549-25c2-ce9fa5b32320	managed
```

这里可看到node group的名称是`managed-ng`，同时看到目前是最大（MAX）6个节点，期望值（DESIRED）是3个节点。

### 2、对现有Nodegroup做扩容

现在扩展集群到6个节点，并设置最大9节点。注意请替换下边语句中的cluster名称、region、nodegroup名称为当前实验对应的名称。

```
eksctl scale nodegroup --cluster=eksworkshop --region=ap-southeast-1 --name=managed-ng --nodes-min=3 --nodes-max=9 --nodes=6
```

执行结果如下表示扩展成功。

```
2026-09-18 18:04:24 [ℹ]  scaling nodegroup "managed-ng" in cluster eksworkshop
2026-09-18 18:04:28 [ℹ]  initiated scaling of nodegroup
2026-09-18 18:04:28 [ℹ]  to see the status of the scaling run `eksctl get nodegroup --cluster eksworkshop --region ap-southeast-1 --name managed-ng`
```

该命令只负责修改托管节点组的容量参数，随后由Auto Scaling组异步完成实例的启动，因此命令返回并不代表节点已经就绪。可立即执行`eksctl get nodegroup`确认参数是否写入，实测返回的`MAX SIZE`为9、`DESIRED CAPACITY`为6，与命令一致。

### 3、查看扩容结果

扩容需要等待数分钟时间，等待新的Node的EC2节点被拉起。实测从命令返回到三个新节点全部进入`Ready`状态约100秒。

在等待几分钟后，执行如下命令检查node数量。

```
kubectl get node
```

返回结果如下表示扩容到6节点成功。

```
NAME                                                STATUS   ROLES    AGE   VERSION
ip-192-168-12-249.ap-southeast-1.compute.internal   Ready    <none>   90s   v1.36.3-eks-cb19647
ip-192-168-36-169.ap-southeast-1.compute.internal   Ready    <none>   8h    v1.36.3-eks-cb19647
ip-192-168-52-48.ap-southeast-1.compute.internal    Ready    <none>   90s   v1.36.3-eks-cb19647
ip-192-168-70-59.ap-southeast-1.compute.internal    Ready    <none>   89s   v1.36.3-eks-cb19647
ip-192-168-71-64.ap-southeast-1.compute.internal    Ready    <none>   8h    v1.36.3-eks-cb19647
ip-192-168-8-249.ap-southeast-1.compute.internal    Ready    <none>   8h    v1.36.3-eks-cb19647
```

节点数量变化会同步反映到DaemonSet类型的工作负载上。若已按第一章启用Container Insight，执行如下命令可以看到采集组件自动扩展到与节点数相同的副本数：

```
kubectl get ds -n amazon-cloudwatch
```

返回结果如下，`cloudwatch-agent`与`fluent-bit`的期望副本数均已从3变为6：

```
NAME               DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR            AGE
cloudwatch-agent   6         6         6       6            6           kubernetes.io/os=linux   8m11s
fluent-bit         6         6         6       6            6           kubernetes.io/os=linux   8m18s
```

### 4、缩小EC2节点组容量

执行如下命令：

```
eksctl scale nodegroup --cluster=eksworkshop --region=ap-southeast-1 --name=managed-ng --nodes-min=3 --nodes-max=6 --nodes=3
```

缩容的耗时明显长于扩容，实测约4分钟。原因在于托管节点组在实例终止前会执行节点排空的生命周期钩子，先驱逐节点上的Pod再允许Auto Scaling组终止实例。在此期间执行如下命令可以观察到对应的活动处于`MidTerminatingLifecycleAction`状态：

```
aws autoscaling describe-scaling-activities --region ap-southeast-1 \
  --auto-scaling-group-name eks-managed-ng-14d05909-37eb-4549-25c2-ce9fa5b32320 \
  --max-items 3 --query 'Activities[].{Status:StatusCode,Desc:Description}' --output json
```

返回结果如下：

```
[
    {
        "Status": "MidTerminatingLifecycleAction",
        "Desc": "Terminating EC2 instance: i-05aec37e67d9962b3"
    },
    {
        "Status": "MidTerminatingLifecycleAction",
        "Desc": "Terminating EC2 instance: i-0ab2e1706e3248a57"
    },
    {
        "Status": "MidTerminatingLifecycleAction",
        "Desc": "Terminating EC2 instance: i-00c25f0ab4be59df9"
    }
]
```

需要注意两点。第一点是被终止的实例是创建时间最早的三台，而非本次扩容新增的三台，因此缩容之后集群中保留的是较新的节点，节点名称与扩容前并不相同。第二点是缩容完成后，`kubectl get pods -A`会看到一批`Completed`或`Error`状态的残留Pod，这些是原先运行在已终止节点上的Pod对象，属于节点回收的产物，不影响服务。执行如下命令可以批量清理：

```
kubectl get pods -A --no-headers | awk '$4=="Completed"||$4=="Error"{print "-n", $1, $2}' | xargs -n3 kubectl delete pod
```

## 三、更换机型-新增其他规格的节点组并删除旧的节点组

创建集群使用EC2机型是作为默认的Nodegroup，已经存在的节点不能更换规格。为了更换EC2机型规格，需要在当前集群下新建一个使用新机型的Nodegroup，随后再删除旧的Nodegroup。创建完毕时，可从旧的Node上驱逐pod，此时pod会自动在新nodegroup上拉起。如果应用是非长连接的、无状态的应用，那么整个过程不影响应用访问。本文以从X86_64架构更换到ARM架构为例。

### 1、检查并升级集群系统组件

在新增节点组之前，建议先确认`coredns`、`kube-proxy`、`vpc-cni`等系统组件是否为最新版本。这些组件以DaemonSet或Deployment形式运行在每一个节点上，新节点加入时会拉起对应副本，若版本落后可能在新机型或新架构的节点上暴露兼容性问题。

在EKS 1.36中，上述系统组件均以托管Addon的形式安装和管理，因此版本查询与升级都通过Addon接口完成。执行如下命令列出集群内所有Addon及其版本状态：

```
eksctl get addon --cluster eksworkshop --region ap-southeast-1
```

返回结果如下：

```
NAME				VERSION			STATUS	ISSUES	IAMROLE								UPDATE AVAILABLE
amazon-cloudwatch-observability	v6.6.0-eksbuild.1	ACTIVE	0	arn:aws:iam::133129065110:role/AmazonEKSContainerInsightRole
coredns				v1.14.3-eksbuild.16	ACTIVE	0									v1.14.3-eksbuild.22
kube-proxy			v1.36.0-eksbuild.25	ACTIVE	0
metrics-server			v0.9.0-eksbuild.11	ACTIVE	0
vpc-cni				v1.22.4-eksbuild.3	ACTIVE	0									v1.23.1-eksbuild.1,v1.23.0-eksbuild.1
```

判读方式是看`UPDATE AVAILABLE`一列：该列为空表示当前版本已是该Kubernetes版本下的最新版本，例如上述结果中的`kube-proxy`与`metrics-server`；该列有值则表示存在可升级的目标版本，例如`coredns`可升级到`v1.14.3-eksbuild.22`，`vpc-cni`可升级到`v1.23.1-eksbuild.1`。该列可能同时列出多个候选版本，按从新到旧排列。

需要说明的是，`vpc-cni`这个Addon对应的Kubernetes工作负载名称是`aws-node`，二者指的是同一个组件，前者是Addon的名称，后者是DaemonSet的名称。

确认存在可升级版本后，执行如下命令进行升级，`--version`指定目标版本，`--wait`使命令阻塞至升级完成：

```
eksctl update addon --name coredns --cluster eksworkshop --region ap-southeast-1 --version v1.14.3-eksbuild.22 --wait
```

返回信息如下：

```
2026-09-18 18:08:21 [ℹ]  Kubernetes version "1.36" in use by cluster "eksworkshop"
2026-09-18 18:08:22 [ℹ]  new version provided v1.14.3-eksbuild.22
2026-09-18 18:08:22 [ℹ]  updating addon
```

实测该升级耗时约60秒。升级完成后再次查询，可看到`VERSION`已变更且`UPDATE AVAILABLE`一列转为空值：

```
NAME	VERSION			STATUS	ISSUES	IAMROLE	UPDATE AVAILABLE
coredns	v1.14.3-eksbuild.22	ACTIVE	0
```

注意：升级`coredns`会滚动重建DNS解析Pod，升级`vpc-cni`会滚动重建每个节点上的CNI插件，对集群网络存在短暂影响。生产环境应安排在变更窗口内执行，并逐个组件依次升级而非并行执行，以便在出现问题时定位范围。

备注：`eksctl utils update-coredns`、`eksctl utils update-kube-proxy`、`eksctl utils update-aws-node`这组命令针对的是以原生Kubernetes清单方式自行部署的系统组件，不适用于本实验的环境。当组件由EKS以托管Addon方式安装时，该组命令会直接拒绝执行并返回如下错误，此时应改用上述`eksctl update addon`命令：

```
Error: addon coredns is installed as a managed EKS addon; to update it, use `eksctl update addon` instead
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
  version: "1.36"

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
        awsLoadBalancerController: true
        xRay: true
        cloudWatch: true
```

注意：上述配置文件的`metadata.version`已设置为`"1.36"`，与实验一创建集群时的版本保持一致。同时`iam.withAddonPolicies`代码块中已移除`albIngress: true`一行，仅保留`awsLoadBalancerController: true`。原因在于`albIngress`参数在新版本中已被废弃，其功能由`awsLoadBalancerController`取代，二者语义重叠，若继续保留`albIngress`会导致配置冗余或校验告警。

注：如果您需要使用Intel处理器机型，请替换上文中的`m6g.2xlarge`为`m6i.2xlarge`即可使用Intel处理器机型。

编辑完毕后保存退出。建议先执行如下命令做一次配置校验，该命令不创建任何资源，仅输出eksctl解析并补全默认值之后的完整配置：

```
eksctl create nodegroup -f nodegroup-arm.yaml --dry-run
```

校验通过后，执行如下命令创建：

```
eksctl create nodegroup -f nodegroup-arm.yaml
```

执行结果如下。

```
2026-09-18 18:10:47 [ℹ]  nodegroup "newng" will use "" [AmazonLinux2023/1.36]
2026-09-18 18:10:50 [ℹ]  1 existing nodegroup(s) (managed-ng) will be excluded
2026-09-18 18:10:50 [ℹ]  1 nodegroup (newng) was included (based on the include/exclude rules)
2026-09-18 18:10:50 [ℹ]  will create a CloudFormation stack for each of 1 managed nodegroups in cluster "eksworkshop"
2026-09-18 18:10:50 [ℹ]
2 sequential tasks: { fix cluster compatibility, 1 task: { 1 task: { create managed nodegroup "newng" } }
}
2026-09-18 18:10:50 [ℹ]  checking cluster stack for missing resources
2026-09-18 18:10:52 [ℹ]  cluster stack has all required resources
2026-09-18 18:10:53 [ℹ]  building managed nodegroup stack "eksctl-eksworkshop-nodegroup-newng"
2026-09-18 18:10:54 [ℹ]  deploying stack "eksctl-eksworkshop-nodegroup-newng"
2026-09-18 18:10:54 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2026-09-18 18:11:25 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2026-09-18 18:12:02 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-nodegroup-newng"
2026-09-18 18:13:41 [ℹ]  nodegroup "newng" has 3 node(s)
2026-09-18 18:13:41 [ℹ]  node "ip-192-168-17-253.ap-southeast-1.compute.internal" is ready
2026-09-18 18:13:41 [ℹ]  node "ip-192-168-62-144.ap-southeast-1.compute.internal" is ready
2026-09-18 18:13:41 [ℹ]  node "ip-192-168-86-247.ap-southeast-1.compute.internal" is ready
2026-09-18 18:13:41 [✔]  created 1 managed nodegroup(s) in cluster "eksworkshop"
2026-09-18 18:13:43 [ℹ]  checking security group configuration for all nodegroups
2026-09-18 18:13:43 [ℹ]  all nodegroups have up-to-date cloudformation templates
```

创建完成，实测总耗时约3分钟。

注意：新建节点组会选用当前最新的AL2023镜像，因此其kubelet的补丁版本可能高于集群中原有节点组。实测原节点组为`v1.36.3-eks-cb19647`，新建的ARM节点组为`v1.36.4-eks-a887778`。同一集群内节点的补丁版本存在差异属于正常状态，只要不超出控制平面所允许的版本偏差范围即可，无需为此统一版本。若需要把原节点组也更新到最新镜像，可执行`eksctl upgrade nodegroup`。

### 3、按处理器架构类型查看Nodegroup

执行如下命令查看nodegroup是否正常。

```
eksctl get nodegroup --cluster eksworkshop --region ap-southeast-1
```

返回结果可以看到原来nodegroup名为`managed-ng`与和新创建nodegroup名为`newng`同时被列出来如下。

```
CLUSTER		NODEGROUP	STATUS	CREATED			MIN SIZE	MAX SIZE	DESIRED CAPACITY	INSTANCE TYPE	IMAGE ID		ASG NAME					TYPE
eksworkshop	managed-ng	ACTIVE	2026-09-18T01:12:31Z	3		6		3			t3.2xlarge	AL2023_x86_64_STANDARD	eks-managed-ng-14d05909-37eb-4549-25c2-ce9fa5b32320	managed
eksworkshop	newng		ACTIVE	2026-09-18T10:11:23Z	3		6		3			m6g.2xlarge	AL2023_ARM_64_STANDARD	eks-newng-22d059ff-e4ea-aa00-1c85-4270a34c008a		managed
```

其中`IMAGE ID`一列可以直接区分两个节点组的架构，`AL2023_x86_64_STANDARD`对应X86_64架构，`AL2023_ARM_64_STANDARD`对应Graviton的ARM架构。该值由eksctl依据所声明的机型自动推导，配置文件中无需显式指定`amiFamily`。

如果想按不同的处理器架构分别查看Nodegroup，执行如下命令查看节点的属性：

```
kubectl get nodes --label-columns=kubernetes.io/arch
```

返回结果如下，可看到最后一列`ARCH`就是对应的架构类型。

```
NAME                                                STATUS   ROLES    AGE     VERSION               ARCH
ip-192-168-12-249.ap-southeast-1.compute.internal   Ready    <none>   10m     v1.36.3-eks-cb19647   amd64
ip-192-168-17-253.ap-southeast-1.compute.internal   Ready    <none>   2m37s   v1.36.4-eks-a887778   arm64
ip-192-168-52-48.ap-southeast-1.compute.internal    Ready    <none>   10m     v1.36.3-eks-cb19647   amd64
ip-192-168-62-144.ap-southeast-1.compute.internal   Ready    <none>   2m36s   v1.36.4-eks-a887778   arm64
ip-192-168-70-59.ap-southeast-1.compute.internal    Ready    <none>   10m     v1.36.3-eks-cb19647   amd64
ip-192-168-86-247.ap-southeast-1.compute.internal   Ready    <none>   2m36s   v1.36.4-eks-a887778   arm64
```

### 4、驱逐原Nodegroup上的Pod（可选）

注意：跨架构驱逐Pod能否成功，完全取决于工作负载所引用的容器镜像是否为多架构清单（multi-architecture manifest list）。这一点必须在删除旧节点组之前确认清楚，否则会造成应用下线。两种情形的区别如下。

- 镜像为多架构清单：清单中同时包含`linux/amd64`与`linux/arm64`两个条目，Pod被调度到ARM节点后，该节点的kubelet依据自身架构从清单中选取对应的镜像层拉取，Pod正常启动，整个过程对用户无感知，不需要任何额外配置。
- 镜像为单架构：清单中只有`linux/amd64`一个条目，Pod被调度到ARM节点后会因无法拉取匹配架构的镜像而失败，典型表现为`ImagePullBackOff`，若镜像被强行拉起则会在容器启动阶段报`exec format error`。此时必须先在ARM架构上重新构建镜像并推送到ECR，或者构建为多架构清单，然后才能迁移。

本实验所使用的`public.ecr.aws/nginx/nginx:1.31-alpine-slim`属于前者。实测从X86_64节点驱逐全部业务Pod后，三个`nginx`副本直接在ARM节点上重建并进入`Running`状态，进入容器执行`uname -m`返回`aarch64`，确证容器实际以ARM64架构运行，同时实验一的NLB与实验二的ALB在整个迁移过程中均持续返回HTTP 200。

因此，规划机型更换时的正确做法是先核对镜像清单而非假定跨架构不可行。可通过`docker manifest inspect <镜像>`或`crane manifest <镜像>`查看清单中包含的架构列表。若集群中同时存在两种架构的节点，而部分应用只有单架构镜像，则应为这些应用显式设置`nodeSelector`或`nodeAffinity`约束到`kubernetes.io/arch: amd64`，避免被调度到不兼容的节点上。

本步骤为可选。当通过下文的`eksctl`命令执行删除Nodegroup时候，对应的pod也会被驱逐到新的Nodegroup的健康的节点上。如果您使用K9S等管理工具，也可以从这些管理工具上发起驱逐命令。

首先将节点调度标记为不可用，执行如下命令。

```
kubectl cordon <node name>
```

执行后该节点在`kubectl get node`中的状态变为`Ready,SchedulingDisabled`，表示现有Pod继续运行但不再接受新的调度。若旧节点组有多个节点，应将它们全部标记，否则被驱逐的Pod可能落到同一个节点组的其他节点上。

然后驱逐节点上的所有pod，执行如下命令。

```
kubectl drain --ignore-daemonsets --delete-emptydir-data <node name>
```

此处`--delete-emptydir-data`参数不可省略。`kubectl drain`默认拒绝删除挂载了本地存储的Pod，以避免数据静默丢失。实测集群中的`metrics-server`使用了emptyDir卷，仅执行`kubectl drain --ignore-daemonsets`会直接中止并返回如下错误：

```
error: unable to drain node "ip-192-168-17-253.ap-southeast-1.compute.internal" due to error: cannot delete Pods with local storage (use --delete-emptydir-data to override): kube-system/metrics-server-798fdf979c-p9h94, continuing command...
```

需要注意的是，该参数意味着确认emptyDir中的数据可以丢弃。emptyDir的生命周期本身与Pod绑定，Pod被删除时数据即失效，因此对于`metrics-server`这类将其用作临时缓存的组件并无影响。但若集群中存在把emptyDir用于暂存业务数据的工作负载，则应在驱逐前自行完成数据转移。

排空成功后返回结果如下：

```
pod/nginx-deployment-785bd8cb9d-n5q6g evicted
pod/nginx-7c95596954-kfjhk evicted
pod/aws-load-balancer-controller-6cc6d6bb67-2ld6q evicted
pod/metrics-server-798fdf979c-wpxbt evicted
pod/coredns-7fbc8d5596-kbd8v evicted
node/ip-192-168-12-249.ap-southeast-1.compute.internal drained
```

执行如下命令确认Pod已经落到新架构的节点上：

```
kubectl get pods -A -o wide | grep -E "nginx"
```

### 5、删除旧的nodegroup（可选）

执行如下命令。

```
eksctl delete nodegroup --cluster eksworkshop --name managed-ng --region ap-southeast-1
```

返回结果如下：

```
2026-09-18 18:19:07 [ℹ]  1 nodegroup (managed-ng) was included (based on the include/exclude rules)
2026-09-18 18:19:07 [ℹ]  will drain 1 nodegroup(s) in cluster "eksworkshop"
2026-09-18 18:19:07 [ℹ]  starting parallel draining, max in-flight of 1
2026-09-18 18:19:44 [✔]  drained all nodes: [ip-192-168-52-48.ap-southeast-1.compute.internal ip-192-168-70-59.ap-southeast-1.compute.internal ip-192-168-12-249.ap-southeast-1.compute.internal]
2026-09-18 18:19:44 [ℹ]  will delete 1 nodegroups from cluster "eksworkshop"
2026-09-18 18:19:46 [ℹ]  1 task: { 1 task: { delete nodegroup "managed-ng" [async] } }
2026-09-18 18:19:47 [ℹ]  will delete stack "eksctl-eksworkshop-nodegroup-managed-ng"
2026-09-18 18:19:47 [✔]  deleted 1 nodegroup(s) from cluster "eksworkshop"
```

从上述输出可以看到该命令自行完成了节点排空，实测约40秒，因此上一节的手工`cordon`与`drain`确实是可选步骤。排空阶段不受`--delete-emptydir-data`的限制，eksctl内部已按强制驱逐处理。随后的CloudFormation栈删除标注为`[async]`，即命令返回时栈删除仍在后台进行，EC2实例的实际终止需要再等待1至2分钟。

等待几分钟后，再次查询集群所对应的nodegroup，执行如下命令。

```
eksctl get nodegroup --cluster eksworkshop --region ap-southeast-1
```

通过以上返回结果可以看到，原来规格的nodegroup被删除，集群中仅保留ARM架构的`newng`：

```
CLUSTER		NODEGROUP	STATUS	CREATED			MIN SIZE	MAX SIZE	DESIRED CAPACITY	INSTANCE TYPE	IMAGE ID		ASG NAME					TYPE
eksworkshop	newng		ACTIVE	2026-09-18T10:11:23Z	3		6		3			m6g.2xlarge	AL2023_ARM_64_STANDARD	eks-newng-22d059ff-e4ea-aa00-1c85-4270a34c008a	managed
```

在实例终止的过程中，`kubectl get pods -A`会短暂出现一批`Pending`状态的DaemonSet Pod，执行`kubectl describe pod`可以看到事件为`NodeShutdown`，消息内容为`Pod was rejected as the node is shutting down`。这些Pod绑定的是正在关机的旧节点，属于节点回收窗口内的产物，约1至2分钟后随节点对象一并被清除，无需人工干预。

清理完成后建议做一次整体复核，确认全部Pod均为`Running`，且两个实验的负载均衡入口仍然可用：

```
kubectl get pods -A --no-headers | awk '{print $4}' | sort | uniq -c
ALB=$(kubectl get ingress -n mydemo ingress-for-nginx-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
NLB=$(kubectl get svc service-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s -m 15 -o /dev/null -w "ALB: HTTP %{http_code}\n" "http://$ALB"
curl -s -m 15 -o /dev/null -w "NLB: HTTP %{http_code}\n" "http://$NLB"
```

返回结果如下，表示在集群节点从X86_64全量更换为ARM架构之后，应用与负载均衡链路均保持正常：

```
  26 Running
ALB: HTTP 200
NLB: HTTP 200
```

至此机型更换完成。Container Insight的采集在更换过程中不中断，`cloudwatch-agent`与`fluent-bit`的容器镜像同样提供ARM64版本，因此在全ARM集群上指标与日志继续正常上报。

## 四、参考文档

Upgrading to Container Insights with enhanced observability for Amazon EKS

[https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Container-Insights-upgrade-enhanced.html](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Container-Insights-upgrade-enhanced.html)

Quick Start setup for Container Insights on Amazon EKS and Kubernetes

[https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Container-Insights-setup-EKS-quickstart.html](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Container-Insights-setup-EKS-quickstart.html)

CloudWatch Observability EKS Addon的配置参数与IAM权限要求：

[https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/install-CloudWatch-Observability-EKS-addon.html](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/install-CloudWatch-Observability-EKS-addon.html)

eksctl管理EKS Addon的官方文档，对应本文第三章第1节所使用的命令：

[https://eksctl.io/usage/addons/](https://eksctl.io/usage/addons/)

eksctl管理节点组的官方文档，包含节点组的创建、扩缩容、升级与删除：

[https://eksctl.io/usage/nodegroups/](https://eksctl.io/usage/nodegroups/)

Kubernetes官方关于安全驱逐节点上Pod的说明，对应本文第三章第4节的cordon与drain操作：

[https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/)