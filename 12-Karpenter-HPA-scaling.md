# 使用Karpenter+HPA实现平滑的集群扩展

## 一、背景

EKS的弹性有两种方式：

- 1、单个应用的Deployment的replica扩容
- 2、Node节点的扩容

对于第一种扩容，常用的方式是Horizontal Pod Autoscaler (HPA)，通过metrics server，监控CPU负载等指标，然后发起对deployment的replica的变化。此配置会调整Pod数量，但不会调整节点数量。

对于第二种扩容，之前常用的方式是Cluster Autoscaler (CA)对NodeGroup节点组的EC2进行扩容，但是其扩展生效速度较慢。本文使用新的Karpenter组件对Nodegroup进行扩容。Karpenter不需要创建新的NodeGroup，而是直接根据匹配情况自动选择On-demand或者Spot类型的实例。

本实验流程如下：

- 1、创建一个EKS集群，大部分使用默认值，自带一个On-Demand形式的NodeGroup节点组（生产环境下一般会购买RI预留实例与之匹配），集群不部署ALB Controller、其他CNI、CSI等插件，因为Karpenter和HPA与这个话题无关
- 2、安装Karpenter，部署一个Nginx应用，由Karpenter自动调度Spot节点
- 3、手工修改replica参数，测试Karpenter扩容调度更多节点
- 4、配置HPA
- 5、创建一个生成负载的Pod作为负载发生器
- 6、从负债发生器对应用施加访问压力，触发HPA对应用deployment的replica自动扩容，并由Karpenter触发新的Spot节点扩容，观察以上现象确认运行正常

## 二、环境准备

### 1、创建新集群

使用默认配置创建一个EKS集群，网络方面使用新的VPC的配置，简化实验过程。编辑如下配置文件，保存为`newcluster.yaml`

```
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: eksworkshop
  region: ap-southeast-1
  version: "1.23"

vpc:
  clusterEndpoints:
    publicAccess:  true
    privateAccess: true

kubernetesNetworkConfig:
  serviceIPv4CIDR: 10.50.0.0/24

managedNodeGroups:
  - name: ng1-od
    labels:
      Name: ng1-od
    instanceType: t3.xlarge
    minSize: 2 
    desiredCapacity: 2
    maxSize: 4
    volumeType: gp3
    volumeSize: 100
    tags:
      nodegroup-name: ng1-od
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

执行如下命令：

```
eksctl create cluster -f newcluster.yaml
```

以上命令会新建一个VPC，并在其中创建一个On-demand模式的NodeGroup节点组。

### 2、创建测试应用

为了验证节点组的工作正常，我们可启动一个测试应用程序在这一组NodeGroup上运行。

编辑如下配置文件，并保存为`demo-nginx-nlb-on-demand.yaml`文件：

```
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-nginx-on-demand
  labels:
    app: demo-nginx-on-demand
spec:
  replicas: 2
  selector:
    matchLabels:
      app: demo-nginx-on-demand
  template:
    metadata:
      labels:
        app: demo-nginx-on-demand
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
      - name: demo-nginx-on-demand
        image: public.ecr.aws/nginx/nginx:1.23-alpine
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
  name: "demo-nginx-on-demand"
  annotations:
        service.beta.kubernetes.io/aws-load-balancer-type: nlb
spec:
  selector:
    app: demo-nginx-on-demand
  type: LoadBalancer
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
```

执行如下命令部署这个应用：

```
kubectl apply -f demo-nginx-nlb-on-demand.yaml
```

执行如下命令获取这个应用NLB入口：

```
kubectl get service
```

使用curl或者浏览器访问这个NLB入口，可看到访问成功。

由此创建EKS集群、On-demand模式和测试应用的工作完成。

## 三、部署Karpenter使用Spot实例进行节点扩容

### 1、安装Karpenter

#### （1）设置环境变量

首先配置环境变量，请替换命令中的AWS账户ID、Region等信息：

执行如下命令：

```
export KARPENTER_VERSION=v0.16.0
export CLUSTER_NAME=$(eksctl get clusters -o json | jq -r '.[0].Name')
export ACCOUNT_ID=$(aws sts get-caller-identity --output text --query Account)
export AWS_REGION=ap-southeast-1
```

#### （2）部署KarpenterNode IAM Role

执行如下命令部署KarpenterNode IAM Role：

```
TEMPOUT=$(mktemp)

curl -fsSL https://karpenter.sh/"${KARPENTER_VERSION}"/getting-started/getting-started-with-eksctl/cloudformation.yaml  > $TEMPOUT \
&& aws cloudformation deploy \
  --stack-name "Karpenter-${CLUSTER_NAME}" \
  --template-file "${TEMPOUT}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "ClusterName=${CLUSTER_NAME}"
```

这个过程可能持续3-5分钟。如果本账号内之前有集群安装过Karpenter已经部署了这个Role，那么这一步会提示已经完成。

```
Waiting for changeset to be created..
No changes to deploy. Stack Karpenter-eksworkshop is up to date
```

执行如下命令验证部署结果：

```
kubectl describe configmap -n kube-system aws-auth
```

在返回结果中，可以看到KarpenterNodeRole已经具有了系统权限。

#### （3）部署KarpenterController IAM Role

在上一步的基础上，保持上述环境变量的配置正确，然后执行如下命令：

```
eksctl utils associate-iam-oidc-provider --cluster ${CLUSTER_NAME} --approve
```

返回如下信息表示配置成功：

```
2022-10-20 18:20:52 [ℹ]  will create IAM Open ID Connect provider for cluster "eksworkshop" in "ap-southeast-1"
2022-10-20 18:20:55 [✔]  created IAM Open ID Connect provider for cluster "eksworkshop" in "ap-southeast-1"
```

执行如下命令创建IAM Service Account：

```
eksctl create iamserviceaccount \
  --cluster "${CLUSTER_NAME}" --name karpenter --namespace karpenter \
  --role-name "${CLUSTER_NAME}-karpenter" \
  --attach-policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/KarpenterControllerPolicy-${CLUSTER_NAME}" \
  --role-only \
  --approve

export KARPENTER_IAM_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${CLUSTER_NAME}-karpenter"
```

这一步可能需要等待2-3分钟，返回如下结果表示配置成功。

```
2022-10-20 18:23:16 [ℹ]  1 iamserviceaccount (karpenter/karpenter) was included (based on the include/exclude rules)
2022-10-20 18:23:16 [!]  serviceaccounts that exist in Kubernetes will be excluded, use --override-existing-serviceaccounts to override
2022-10-20 18:23:16 [ℹ]  1 task: { create IAM role for serviceaccount "karpenter/karpenter" }
2022-10-20 18:23:16 [ℹ]  building iamserviceaccount stack "eksctl-eksworkshop-addon-iamserviceaccount-karpenter-karpenter"
2022-10-20 18:23:16 [ℹ]  deploying stack "eksctl-eksworkshop-addon-iamserviceaccount-karpenter-karpenter"
2022-10-20 18:23:17 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-addon-iamserviceaccount-karpenter-karpenter"
2022-10-20 18:23:48 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-addon-iamserviceaccount-karpenter-karpenter"
2022-10-20 18:24:42 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-addon-iamserviceaccount-karpenter-karpenter"
```

#### （4）创建允许调用EC2 Spot的角色

执行如下命令：

```
aws iam create-service-linked-role --aws-service-name spot.amazonaws.com
```

如果本账号内使用过EC2 Spot，或者别的EKS集群配置过Karpenter，那么这一步会提示角色已经存在，这不会影响使用，可以略过：

```
An error occurred (InvalidInput) when calling the CreateServiceLinkedRole operation: Service role name AWSServiceRoleForEC2Spot has been taken in this account, please try a different suffix.
```

#### （5）安装Helm

在Windows、Linux、MacOS平台上安装Helm的方法可能有所不同。

本文以Linux为例，执行如下命令：

```
curl -sSL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash
helm repo add stable https://charts.helm.sh/stable
helm search repo stable
helm repo add karpenter https://charts.karpenter.sh/
helm repo update
```

如果本机在以前安装过Helm，可执行`helm repo update`命令更新软件仓库。

#### （6）通过Helm安装Karpenter

```
helm upgrade --install --namespace karpenter --create-namespace \
  karpenter karpenter/karpenter \
  --version ${KARPENTER_VERSION} \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=${KARPENTER_IAM_ROLE_ARN} \
  --set clusterName=${CLUSTER_NAME} \
  --set clusterEndpoint=$(aws eks describe-cluster --name ${CLUSTER_NAME} --query "cluster.endpoint" --output json) \
  --set defaultProvisioner.create=false \
  --set aws.defaultInstanceProfile=KarpenterNodeInstanceProfile-${CLUSTER_NAME} \
  --wait # for the defaulting webhook to install before creating a Provisioner
```

返回如下结果表示部署完成。

```
Release "karpenter" does not exist. Installing it now.
NAME: karpenter
LAST DEPLOYED: Thu Oct 20 18:33:26 2022
NAMESPACE: karpenter
STATUS: deployed
REVISION: 1
TEST SUITE: None
```

#### （7）验证Karpenter启动正常

执行如下命令：

```
kubectl get all -n karpenter
```

返回结果如下：

```
NAME                             READY   STATUS    RESTARTS   AGE
pod/karpenter-7f4dbb74b6-nbvnk   2/2     Running   0          80s
pod/karpenter-7f4dbb74b6-rr7wh   2/2     Running   0          80s

NAME                TYPE        CLUSTER-IP    EXTERNAL-IP   PORT(S)            AGE
service/karpenter   ClusterIP   10.50.0.159   <none>        8080/TCP,443/TCP   81s

NAME                        READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/karpenter   2/2     2            2           81s

NAME                                   DESIRED   CURRENT   READY   AGE
replicaset.apps/karpenter-7f4dbb74b6   2         2         2       81s
```

这里需要注意，Karpenter需要有2个控制器同时运行，才可以确保高可用。否则遇到单个Node节点故障，可能正好Karpenter的控制器也在故障节点上，那么将影响集群缩放。

#### （7）部署Karpenter Provsioner指定Node配置

编辑如下保存为`provisioner.yaml`文件：

```
apiVersion: karpenter.sh/v1alpha5
kind: Provisioner
metadata:
  name: default
spec:
  labels:
    intent: apps
  requirements:
    - key: karpenter.sh/capacity-type
      operator: In
      values: ["spot"]
    - key: karpenter.k8s.aws/instance-size
      operator: NotIn
      values: [nano, micro, small, medium, large]
  limits:
    resources:
      cpu: 1000
      memory: 1000Gi
  ttlSecondsAfterEmpty: 30
  ttlSecondsUntilExpired: 2592000
  providerRef:
    name: default
---
apiVersion: karpenter.k8s.aws/v1alpha1
kind: AWSNodeTemplate
metadata:
  name: default
spec:
  subnetSelector:
    alpha.eksctl.io/cluster-name: ${CLUSTER_NAME}
  securityGroupSelector:
    alpha.eksctl.io/cluster-name: ${CLUSTER_NAME}
  tags:
    KarpenerProvisionerName: "default"
    NodeType: "karpenter-workshop"
    IntentLabel: "apps"
```

保存完毕后，运行如下文件：

```
kubectl apply -f provisioner.yaml
```

在以上配置文件中，表示Karpenter将启动Spot实力，并且自动匹配的机型将不包括`[nano, micro, small, medium, large]`系列。

至此Karpenter部署完成。

### 2、部署测试应用

构建如下测试应用，保存为`demo-nginx-nlb-karpenter.yaml`文件：

```
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-nginx-nlb-karpenter
  labels:
    app: demo-nginx-nlb-karpenter
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demo-nginx-nlb-karpenter
  template:
    metadata:
      labels:
        app: demo-nginx-nlb-karpenter
    spec:
      nodeSelector:
        intent: apps
      containers:
      - name: demo-nginx-nlb-karpenter
        image: registry.k8s.io/hpa-example
        ports:
        - containerPort: 80
        resources:
          limits:
            cpu: "1"
            memory: 2G
          requests:
            cpu: "1"
            memory: 2G
---
apiVersion: v1
kind: Service
metadata:
  name: "demo-nginx-nlb-karpenter"
  annotations:
        service.beta.kubernetes.io/aws-load-balancer-type: nlb
spec:
  selector:
    app: demo-nginx-nlb-karpenter
  type: LoadBalancer
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
```

执行如下命令启动这个应用：

```
kubectl apply -f demo-nginx-nlb-karpenter.yaml
```

执行如下命令查看访问入口：

```
kubectl get service
```

返回结果可能会包含多个不同的服务，查找名为`demo-nginx-nlb-karpenter`的应用对应的ALB，例如如下：

```
NAME                       TYPE           CLUSTER-IP    EXTERNAL-IP                                                                          PORT(S)        AGE
demo-nginx-nlb-karpenter   LoadBalancer   10.50.0.58    a59b500e279d94b2880502c8782ad6dc-bf2ef05babf12887.elb.ap-southeast-1.amazonaws.com   80:31157/TCP   104s
demo-nginx-on-demand       LoadBalancer   10.50.0.35    adc375ee9dc9d4705bca9642986c3d2b-712c38519c0e4303.elb.ap-southeast-1.amazonaws.com   80:30338/TCP   83m
kubernetes                 ClusterIP      10.50.0.1     <none>                                                                               443/TCP        5d1h
php-apache                 ClusterIP      10.50.0.207   <none>                                                                               80/TCP         26h
```

使用curl或者浏览器访问NLB地址，可看到访问成功。

### 3、修改部署扩容

执行如下命令：

```
kubectl scale deployment demo-nginx-nlb-karpenter --replicas 6
```

### 4、查看集群扩容生效

在执行了上一步扩容后，立刻去查看Pod和Node，可以发现Karpenter已经对其进行了扩展。

执行如下命令可查看所有Pod：

```
kubectl get pods -A
```

执行如下命令可通过指定标签方式，查看本应用所对应的Pod：

```
kubectl get pod -l app=demo-nginx-nlb-karpenter
```

执行如下命令可通过限定特定的标签，查看Karpenter扩容出来的Spot节点Node：

```
kubectl get node -l karpenter.sh/capacity-type=spot
```

### 5、查看Karpenter日志（可选）

执行如下命令可查看Karpenter控制器的日子：

```
kubectl logs -f deployment/karpenter -n karpenter controller
```

执行如下命令，可查看Karpenter控制器的配置，包括日志级别等信息：

```
kubectl describe configmap config-logging -n karpenter
```

执行如下命令，可调整Karpenter日志级别：

```
kubectl patch configmap config-logging -n karpenter --patch '{"data":{"loglevel.controller":"debug"}}'
```

当执行扩容的时候，日志中包含如下一段信息，表示扩容正常：

```
2022-10-19T14:13:07.480Z	DEBUG	controller.provisioning	16 out of 375 instance types were excluded because they would breach provisioner limits	{"commit": "639756a"}
2022-10-19T14:13:07.486Z	INFO	controller.provisioning	Found 3 provisionable pod(s)	{"commit": "639756a"}
2022-10-19T14:13:07.486Z	INFO	controller.provisioning	Computed 1 new node(s) will fit 3 pod(s)	{"commit": "639756a"}
2022-10-19T14:13:07.486Z	INFO	controller.provisioning	Launching node with 3 pods requesting {"cpu":"3825m","memory":"6166575Ki","pods":"7"} from types c6g.2xlarge, t4g.2xlarge, c5a.2xlarge, c6gd.2xlarge, t3a.2xlarge and 249 other(s)	{"commit": "639756a", "provisioner": "default"}
2022-10-19T14:13:07.803Z	DEBUG	controller.provisioning.cloudprovider	Discovered ami-02b94a304b3bfa084 for query "/aws/service/eks/optimized-ami/1.23/amazon-linux-2-arm64/recommended/image_id"	{"commit": "639756a", "provisioner": "default"}
2022-10-19T14:13:07.829Z	DEBUG	controller.provisioning.cloudprovider	Discovered ami-06f260a58e539402d for query "/aws/service/eks/optimized-ami/1.23/amazon-linux-2/recommended/image_id"	{"commit": "639756a", "provisioner": "default"}
2022-10-19T14:13:07.970Z	DEBUG	controller.provisioning.cloudprovider	Created launch template, Karpenter-eksworkshop-17123065573808364729	{"commit": "639756a", "provisioner": "default"}
2022-10-19T14:13:08.185Z	DEBUG	controller.provisioning.cloudprovider	Created launch template, Karpenter-eksworkshop-3756467097324561401	{"commit": "639756a", "provisioner": "default"}
2022-10-19T14:13:10.414Z	INFO	controller.provisioning.cloudprovider	Launched instance: i-00a5ed6da4aebca0f, hostname: ip-192-168-129-22.ap-southeast-1.compute.internal, type: t4g.2xlarge, zone: ap-southeast-1a, capacityType: spot	{"commit": "639756a", "provisioner": "default"}
```

以上的信息中，可以看到，备选机型主要是`c6g.2xlarge, t4g.2xlarge, c5a.2xlarge, c6gd.2xlarge, t3a.2xlarge`等机型。最后实际在`ap-southeast-1a`以`Spot`方式生成了 `t4g.2xlarge`实例，其EC2 ID是`i-00a5ed6da4aebca0f`，主机名叫做`ip-192-168-129-22.ap-southeast-1.compute.internal`。

关于Karpenter Provsioner对机型配置的选择，请参考有关配置文件修改说明。

由此，Karpenter配置完成，工作正常。最后执行如下命令将应用搜索回到1个Pod，便于后续实验发起压力扩容。

```
kubectl scale deployment demo-nginx-nlb-karpenter --replicas 1
```

## 四、部署HPA并测试扩展

接下来部署HPA过程中，将继续使用上文配置Karpenter的应用作为被测试的用例。

### 1、部署Metrics Server

执行以下命令部署metrics server。

```
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# 备选旧版本
# kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.5.0/components.yaml
```

### 2、确认Metrics Server运行正常

在前一步的部署完成后，还需要等待一段时间让服务启动。然后执行如下命令：

```
kubectl get apiservice v1beta1.metrics.k8s.io -o json | jq '.status'
```

如果返回结果如下，则表示部署完成。

```
{
  "conditions": [
    {
      "lastTransitionTime": "2022-10-18T06:52:14Z",
      "message": "all checks passed",
      "reason": "Passed",
      "status": "True",
      "type": "Available"
    }
  ]
}
```

如果没有获得以上结果，那么需要继续等待启动完成。

### 3、配置性能监控并设置HPA弹性阈值

执行如下命令。其中`min=1`表示最小1个pod，`max=10`表示最大10个pod。同时还需要替换其中的deployment名称：

```
kubectl autoscale deployment demo-nginx-nlb-karpenter --cpu-percent=50 --min=1 --max=10
```

配置完毕后，可通过如下命令查看HPA的信息：

```
kubectl get hpa
```

### 4、使用额外的EC2作为外部的负载生成器

负载生成器可以使用普通的EC2进行，只要能部署apache benchmark工具即可。也可以在本VPC之外的其他位置，通过网络访问NLB即可。压力测试建议不要跨region，在本region获得最大压力效果。

本例中，建议创建一台EC2，使用m5或者c5.2xlarge规格，系统选择为Amazon Linux 2操作系统。我们将使用Apache Benchmark（简称ab）发起压力测试。执行如下命令安装客户端：

```
yum update -y
yum install httpd
```

安装完成后，执行如下命令生成压力，请替换访问地址为上一步的NLB地址

```
ab -n 1000000 -c 100 http://a44c5e6ec923a442a8204ae6eb10dcf7-a98659c1108f3882.elb.ap-southeast-1.amazonaws.com/
```

### 5、观察压力导致的扩容

使用如下命令观察Metrics Server、CPU负载以及Deployment的Replica的数量：

```
kubectl get hpa -w
```

注意以上命令为不断刷新，新的一行为最新数据。

使用如下命令观察Deployment的Replica对应的Pod数量：

```
kubectl get pod -l app=demo-nginx-nlb-karpenter
```

使用如下命令观察Karpenter扩充的Spot节点：

```
kubectl get node -l karpenter.sh/capacity-type=spot
```

以上信息可看到，HPA和Karpenter扩展了新的Spot节点，为负载压力提供了支持。

## 五、参考文档

Karpenter:

[https://www.eksworkshop.com/beginner/085_scaling_karpenter/](https://www.eksworkshop.com/beginner/085_scaling_karpenter/)

HPA:

[https://www.eksworkshop.com/beginner/080_scaling/](https://www.eksworkshop.com/beginner/080_scaling/)

HorizontalPodAutoscaler Walkthrough:

[https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/)


--------------

本次实验的负载生成器使用容器实现。以创建的集群自带的On-Demand的NodeGroup作为环境，在其上部署容器作为压力客户端，然后从On-demand的NodeGroup节点组对Spot节点组上的应用进行施压。

执行如下命令启动负载生成器。

```
kubectl run -i --tty load-generator --image=public.ecr.aws/bitnami/apache:latest /bin/sh
```

如果断开了shell，希望重新登录到shell，可以使用如下命令：

```
kubectl attach load-generator -c load-generator -i -t
```

执行如下命令删除负载生成器

```
kubectl delete pod load-generator
```
