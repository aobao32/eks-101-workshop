# 实验十一、为NodeGroup使用EC2 Spot实例

## 一、使用Spot实例

### 1、使用ec2-instance-selector查看可选合适的机型

要查看能提供特定CPU和内存比例数量的机型，可以使用ec2-instance-selector工具，参考[这个](https://blog.bitipcman.com/ec2-instance-type-selector-cli/)文章。

执行如下命令可以查看相似进行：

```
ec2-instance-selector --base-instance-type m5.2xlarge --flexible
```

也可以手工指定vCPU和内存进行查询

```
ec2-instance-selector --vcpus 8 --memory 32
```

即可获得匹配的机型清单。

### 2、新建使用新的EC2规格的nodegroup

编辑如下内容，并保存为`spot-nodegroup.yaml`文件。需要注意的是，如果新创建的Nodegroup在Public Subnet内，这直接使用如下内容即可。如果新创建的Nodegroup在Private Subnet内，那么请增加如下一行`privateNetworking: true`到配置文件中。添加的位置在`volumeSize`的下一行即可。

```
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: eksworkshop
  region: ap-southeast-1
  version: "1.23"

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
eksctl create nodegroup -f spot-nodegroup.yaml
```

执行如下命令查看nodegroup是否正常。请注意修改cluster名称与当前集群名称要匹配。

```
eksctl get nodegroup --cluster eksworkshop
```

返回结果可以看到原来的和新创建的两个nodegroup如下。

```
CLUSTER		NODEGROUP	STATUS	CREATED			MIN SIZE	MAX SIZE	DESIRED CAPACITY	INSTANCE TYPE				IMAGE ID	ASG NAME						TYPE
eksworkshop	managed-ng	ACTIVE	2022-10-14T08:25:52Z	3		6		3			m5.2xlarge				AL2_x86_64	eks-managed-ng-32c1eacc-bd74-6172-37c3-d9a66afa8512	managed
eksworkshop	spot1		ACTIVE	2022-10-14T09:39:29Z	3		6		3			m4.2xlarge,m5.2xlarge,m5d.2xlarge	AL2_x86_64	eks-spot1-88c1eaee-6f0f-0da3-a6a4-3b2792ee447a		managed
```

查看节点的创建时间：

```
kubectl get nodes --sort-by=.metadata.creationTimestamp
```

返回信息类似如下：

```
NAME                                               STATUS   ROLES    AGE     VERSION
ip-192-168-73-49.ap-southeast-1.compute.internal   Ready    <none>   3h30m   v1.23.9-eks-ba74326
ip-192-168-3-225.ap-southeast-1.compute.internal   Ready    <none>   3h30m   v1.23.9-eks-ba74326
ip-192-168-53-33.ap-southeast-1.compute.internal   Ready    <none>   3h30m   v1.23.9-eks-ba74326
ip-192-168-27-19.ap-southeast-1.compute.internal   Ready    <none>   136m    v1.23.9-eks-ba74326
ip-192-168-46-69.ap-southeast-1.compute.internal   Ready    <none>   136m    v1.23.9-eks-ba74326
ip-192-168-65-14.ap-southeast-1.compute.internal   Ready    <none>   136m    v1.23.9-eks-ba74326
```

### 3、查看当前集群的On-Demand节点

执行如下命令：

```
kubectl get nodes \
  --label-columns=eks.amazonaws.com/capacityType \
  --selector=eks.amazonaws.com/capacityType=ON_DEMAND
```

输出结果类似如下：

```
NAME                                               STATUS   ROLES    AGE   VERSION               CAPACITYTYPE
ip-192-168-3-225.ap-southeast-1.compute.internal   Ready    <none>   68m   v1.23.9-eks-ba74326   ON_DEMAND
ip-192-168-53-33.ap-southeast-1.compute.internal   Ready    <none>   68m   v1.23.9-eks-ba74326   ON_DEMAND
ip-192-168-73-49.ap-southeast-1.compute.internal   Ready    <none>   68m   v1.23.9-eks-ba74326   ON_DEMAND
```

### 4、查看当前集群的Spot节点

查看节点类型是Spot的Node：

```
kubectl get nodes \
  --label-columns=eks.amazonaws.com/capacityType \
  --selector=eks.amazonaws.com/capacityType=SPOT
```

返回结果如下：

```
NAME                                               STATUS   ROLES    AGE    VERSION               CAPACITYTYPE
ip-192-168-27-19.ap-southeast-1.compute.internal   Ready    <none>   141m   v1.23.9-eks-ba74326   SPOT
ip-192-168-46-69.ap-southeast-1.compute.internal   Ready    <none>   141m   v1.23.9-eks-ba74326   SPOT
ip-192-168-65-14.ap-southeast-1.compute.internal   Ready    <none>   141m   v1.23.9-eks-ba74326   SPOT
```

## 二、部署应用分别运行在Spot和On-demand机型上

### 1、使用Spot的yaml配置文件

在和Container配置平级的位置，增加如下一段配置，表示优先使用Spot节点运行服务：

```
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 1
            preference:
              matchExpressions:
              - key: eks.amazonaws.com/capacityType
                operator: In
                values:
                - SPOT
      tolerations:
      - key: "spotInstance"
        operator: "Equal"
        value: "true"
        effect: "PreferNoSchedule"
```

在和Container配置平级的位置，增加如下一段配置，表示强制使用On-demand节点运行服务：

```
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: eks.amazonaws.com/capacityType
                operator: In
                values:
                - ON_DEMAND
```

### 2、使用Spot的yaml文件示例

```
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-nginx-od
  labels:
    app: demo-nginx-od
spec:
  replicas: 3
  selector:
    matchLabels:
      app: demo-nginx-od
  template:
    metadata:
      labels:
        app: demo-nginx-od
    spec:
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 1
            preference:
              matchExpressions:
              - key: eks.amazonaws.com/capacityType
                operator: In
                values:
                - SPOT
      tolerations:
      - key: "spotInstance"
        operator: "Equal"
        value: "true"
        effect: "PreferNoSchedule"
      containers:
      - name: demo-nginx-od
        image: public.ecr.aws/nginx/nginx:1.21.6-alpine
        ports:
        - containerPort: 80
        resources:
          limits:
            cpu: "1"
            memory: 2G
---
apiVersion: v1
kind: Service
metadata:
  name: "demo-nginx-od"
  annotations:
        service.beta.kubernetes.io/aws-load-balancer-type: nlb
spec:
  selector:
    app: demo-nginx-od
  type: LoadBalancer
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
```

### 3、使用On-demand的yaml文件示例

```
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-nginx-spot
  labels:
    app: demo-nginx-spot
spec:
  replicas: 3
  selector:
    matchLabels:
      app: demo-nginx-spot
  template:
    metadata:
      labels:
        app: demo-nginx-spot
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: eks.amazonaws.com/capacityType
                operator: In
                values:
                - ON_DEMAND
      containers:
      - name: demo-nginx-spot
        image: public.ecr.aws/nginx/nginx:1.21.6-alpine
        ports:
        - containerPort: 80
        resources:
          limits:
            cpu: "1"
            memory: 2G
---
apiVersion: v1
kind: Service
metadata:
  name: "demo-nginx-spot"
  annotations:
        service.beta.kubernetes.io/aws-load-balancer-type: nlb
spec:
  selector:
    app: demo-nginx-spot
  type: LoadBalancer
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
```

## 三、查看在On-demand和Spot节点上的Pod

### 1、查看Spot节点上的Pod

执行如下命令：

```
 for n in $(kubectl get nodes -l eks.amazonaws.com/capacityType=SPOT --no-headers | cut -d " " -f1); do echo "Pods on instance ${n}:";kubectl get pods --all-namespaces  --no-headers --field-selector spec.nodeName=${n} ; echo ; done
```

返回信息如下：

```
Pods on instance ip-192-168-27-19.ap-southeast-1.compute.internal:
default       demo-nginx-spot-79676dcc79-2mlv8   1/1   Running   0             117s
kube-system   aws-node-pdcx2                     1/1   Running   1 (11h ago)   2d3h
kube-system   kube-proxy-j5xdm                   1/1   Running   1 (11h ago)   2d3h

Pods on instance ip-192-168-46-69.ap-southeast-1.compute.internal:
default       demo-nginx-spot-79676dcc79-gpk4z   1/1   Running   0             118s
kube-system   aws-node-nmz6k                     1/1   Running   1 (11h ago)   2d3h
kube-system   kube-proxy-qpb6f                   1/1   Running   1 (11h ago)   2d3h

Pods on instance ip-192-168-65-14.ap-southeast-1.compute.internal:
default       demo-nginx-spot-79676dcc79-bllnb   1/1   Running   0             119s
kube-system   aws-node-vbl6f                     1/1   Running   1 (11h ago)   2d3h
kube-system   kube-proxy-45jfj                   1/1   Running   1 (11h ago)   2d3h
```

### 2、查看On-demand节点上的Pod

执行如下命令：

```
 for n in $(kubectl get nodes -l eks.amazonaws.com/capacityType=ON_DEMAND --no-headers | cut -d " " -f1); do echo "Pods on instance ${n}:";kubectl get pods --all-namespaces  --no-headers --field-selector spec.nodeName=${n} ; echo ; done
```

返回信息如下：

```
Pods on instance ip-192-168-3-225.ap-southeast-1.compute.internal:
default       demo-nginx-on-demand-5549798b4c-ftwq2   1/1   Running   0             3m5s
kube-system   aws-node-lgwn5                          1/1   Running   1 (11h ago)   2d4h
kube-system   kube-proxy-kvqd9                        1/1   Running   1 (11h ago)   2d4h

Pods on instance ip-192-168-53-33.ap-southeast-1.compute.internal:
default       demo-nginx-on-demand-5549798b4c-zkns8   1/1   Running   0             3m6s
kube-system   aws-node-jw6t2                          1/1   Running   1 (11h ago)   2d4h
kube-system   kube-proxy-6ncrr                        1/1   Running   1 (11h ago)   2d4h

Pods on instance ip-192-168-73-49.ap-southeast-1.compute.internal:
default       demo-nginx-on-demand-5549798b4c-nbxf8   1/1   Running   0             3m7s
kube-system   aws-node-7wh29                          1/1   Running   1 (11h ago)   2d4h
kube-system   coredns-6d8cc4bb5d-bfmmb                1/1   Running   1 (11h ago)   2d5h
kube-system   coredns-6d8cc4bb5d-fhj8p                1/1   Running   1 (11h ago)   2d5h
kube-system   kube-proxy-2wm22                        1/1   Running   1 (11h ago)   2d4h
```