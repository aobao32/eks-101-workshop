# 实验五、使用Spot实例

## 一、使用Spot实例

### 1、新建使用新的EC2规格的nodegroup

编辑如下内容，并保存为`spot.yaml`文件。需要注意的是，如果新创建的Nodegroup在Public Subnet内，这直接使用如下内容即可。如果新创建的Nodegroup在Private Subnet内，那么请增加如下一行`privateNetworking: true`到配置文件中。添加的位置在`volumeSize`的下一行即可。

```
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: eksworkshop
  region: ap-southeast-1
  version: "1.22"

managedNodeGroups:
  - name: spot1
    labels:
      Name: spot1
    instanceTypes: ["m4.2xlarge","m5.2xlarge","m5d.2xlarge"]
    spot: true
    minSize: 3
    desiredCapacity: 3
    maxSize: 6
    volumeType: gp3
    volumeSize: 100
    tags:
      nodegroup-name: spot1
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
eksctl create nodegroup -f spot.yaml
```

执行如下命令查看nodegroup是否正常。请注意修改cluster名称与当前集群名称要匹配。

```
eksctl get nodegroup --cluster eksworkshop
```

返回结果可以看到原来的和新创建的两个nodegroup如下。

```

2022-04-09 23:48:30 [ℹ]  eksctl version 0.92.0
2022-04-09 23:48:30 [ℹ]  using region ap-southeast-1
CLUSTER		NODEGROUP	STATUS	CREATED			MIN SIZE	MAX SIZE	DESIRED CAPACITY	INSTANCE TYPE				IMAGE ID	ASG NAME					TYPE
eksworkshop	newng		ACTIVE	2022-04-09T08:52:48Z	3		6		3			m5.2xlarge				AL2_x86_64	eks-newng-c0c006c3-4874-faec-7ee9-61bcb715b925	managed
eksworkshop	spot1		ACTIVE	2022-04-09T14:59:52Z	3		6		3			m4.2xlarge,m5.2xlarge,m5d.2xlarge	AL2_x86_64	eks-spot1-a0c0076b-4fd6-ae3f-af17-06dc07d539db	managed
```

### 2、删除旧的nodegroup

执行如下命令。请注意修改cluster名称与当前集群名称要匹配。

```
eksctl delete nodegroup --cluster eksworkshop --name newng --region ap-southeast-1
```

通过以上返回结果可以看到，原来规格的nodegroup被删除，集群中新的nodegroup是使用新规格的节点。