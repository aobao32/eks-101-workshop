# EKS 101动手实验（十二）使用Karpenter+HPA实现EKS集群扩展

EKS 1.27版本 & Karpenter 0.29版本 @2023-07 AWS Global区域测试通过

## 一、背景

EKS的扩容有两种方式：

- 1、单个应用的Deployment的replica扩容，Pod数量增加，Node不变
- 2、Node节点的扩容，Node增加，Pod不变

对于第一种扩容，常用的方式是Horizontal Pod Autoscaler (HPA)，通过metrics server，监控CPU负载等指标，然后发起对deployment的replica的变化。此配置会调整Pod数量，但不会调整节点数量。

对于第二种扩容，之前常用的方式是Cluster Autoscaler (CA)对NodeGroup节点组的EC2进行扩容，但是其扩展速度较慢。本文使用新的Karpenter组件对Nodegroup进行扩容。Karpenter不需要创建新的NodeGroup，而是直接根据匹配情况自动选择On-demand或者Spot类型的实例。

本实验流程如下：

- 1、创建一个EKS集群，大部分使用默认值，自带一个On-Demand形式的NodeGroup节点组（生产环境下一般会购买RI预留实例与之匹配），集群已经部署ALB Controller、但没有安装其他插件，因为Karpenter和HPA与这个话题无关
- 2、安装Karpenter，部署一个Nginx应用，由Karpenter自动调度Spot节点
- 3、手工修改replica参数，测试Karpenter扩容调度更多节点生效
- 4、配置HPA
- 5、创建一个负载发生器
- 6、从负载发生器对应用施加访问压力，同时触发HPA对应用deployment的replica自动扩容，并同时触发由Karpenter触发新的Spot节点扩容，观察以上现象确认运行正常

## 二、环境准备

### 1、创建新集群

本文假设集群已经创建好，并且有Nodegroup存在，同时部署了AWS Load Balancer Controller等必要的逐渐。搭建本文实验环境可参考[这篇](https://blog.bitipcman.com/use-dedicate-subnet-for-eks-node-with-aws-vpc-cni/)文档完成。下面开始部署Spot节点。

### 2、在On-demand的NodeGroup上创建测试应用

为了验证节点组的工作正常，我们可启动一个测试应用程序在这一组NodeGroup上运行。

编辑如下配置文件，并保存为`demo-nginx-nlb-on-demand.yaml`文件：

```
---
apiVersion: v1
kind: Namespace
metadata:
  name: nlb-app-ondemand
---
apiVersion: apps/v1
kind: Deployment
metadata:
  namespace: nlb-app-ondemand
  name: nginx-deployment
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: nginx
  replicas: 3
  template:
    metadata:
      labels:
        app.kubernetes.io/name: nginx
    spec:
      containers:
      - image: public.ecr.aws/nginx/nginx:1.24-alpine-slim
        imagePullPolicy: Always
        name: nginx
        ports:
        - containerPort: 80
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: eks.amazonaws.com/capacityType
                operator: In
                values:
                - ON_DEMAND
---
apiVersion: v1
kind: Service
metadata:
  namespace: nlb-app-ondemand
  name: "service-nginx"
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
spec:
  loadBalancerClass: service.k8s.aws/nlb
  selector:
    app.kubernetes.io/name: nginx
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

### 3、验证On-Demand节点的应用工作正常

执行如下命令获取这个应用NLB入口：

```
kubectl get service service-nginx -n nlb-app-ondemand -o wide 
```

获得如下结果：

```
NAME            TYPE           CLUSTER-IP    EXTERNAL-IP                                                                          PORT(S)        AGE     SELECTOR
service-nginx   LoadBalancer   10.50.0.161   k8s-nlbappon-servicen-e3100b48b9-34d14f57a6df395b.elb.ap-southeast-1.amazonaws.com   80:32217/TCP   3m50s   app.kubernetes.io/name=nginx

```

现在使用curl或者浏览器访问NLB的Ingress入口，可看到访问成功。

由此确认之前创建的On-demand模式的Nodegroup、以及测试应用的工作正常。

测试结束后，删除应用：

```
kubectl delete -f demo-nginx-nlb-on-demand.yaml
```

## 三、部署Karpenter实现Node缩放

### 1、设置环境变量

首先配置环境变量，在Bash或者Zsh的Shell环境下，执行如下命令：

```
export AWS_PARTITION="aws" # 如果是中国区请替换为aws-cn
export KARPENTER_VERSION=v0.29.0
export CLUSTER_NAME=$(eksctl get clusters -o json | jq -r '.[0].Name')
export ACCOUNT_ID=$(aws sts get-caller-identity --output text --query Account)
export AWS_REGION=ap-southeast-1
export OIDC_ENDPOINT="$(aws eks describe-cluster --name ${CLUSTER_NAME} \
    --query "cluster.identity.oidc.issuer" --output text)"
```

如此将自动获得集群名称、账户ID、Region等信息。

### 2、创建Karpenter分配的Node使用的IAM Role并绑定策略

执行如下命令：

```
echo '{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ec2.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }c
    ]
}' > node-trust-policy.json

aws iam create-role --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
    --assume-role-policy-document file://node-trust-policy.json
```

返回结果如下：

```
{
    "Role": {
        "Path": "/",
        "RoleName": "KarpenterNodeRole-eksworkshop",
        "RoleId": "AROAR57Y4KKLPP5IRAPLW",
        "Arn": "arn:aws:iam::133129065110:role/KarpenterNodeRole-eksworkshop",
        "CreateDate": "2023-07-12T08:59:38+00:00",
        "AssumeRolePolicyDocument": {
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Principal": {
                        "Service": "ec2.amazonaws.com"
                    },
                    "Action": "sts:AssumeRole"
                }
            ]
        }
    }
}
```

执行如下命令绑定策略（请确保上一步的环境变量正确）：

```
aws iam attach-role-policy --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
    --policy-arn arn:${AWS_PARTITION}:iam::aws:policy/AmazonEKSWorkerNodePolicy
aws iam attach-role-policy --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
    --policy-arn arn:${AWS_PARTITION}:iam::aws:policy/AmazonEKS_CNI_Policy
aws iam attach-role-policy --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
    --policy-arn arn:${AWS_PARTITION}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
aws iam attach-role-policy --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
    --policy-arn arn:${AWS_PARTITION}:iam::aws:policy/AmazonSSMManagedInstanceCore
```

没有报错就是执行成功。

现在将创建的IAM Role绑定到EC2 Instance的Profile，即可用于EC2加载Role。执行如下命令：

```
aws iam create-instance-profile \
    --instance-profile-name "KarpenterNodeInstanceProfile-${CLUSTER_NAME}"
aws iam add-role-to-instance-profile \
    --instance-profile-name "KarpenterNodeInstanceProfile-${CLUSTER_NAME}" \
    --role-name "KarpenterNodeRole-${CLUSTER_NAME}"
```

返回如下结果表示成功：

```
{
    "InstanceProfile": {
        "Path": "/",
        "InstanceProfileName": "KarpenterNodeInstanceProfile-eksworkshop",
        "InstanceProfileId": "AIPAR57Y4KKLGQ5XHJY5C",
        "Arn": "arn:aws:iam::133129065110:instance-profile/KarpenterNodeInstanceProfile-eksworkshop",
        "CreateDate": "2023-07-12T09:12:33+00:00",
        "Roles": []
    }
}
```

### 3、创建Karpenter Controller使用的IAM Role并绑定策略

现在分别创建 `controller-trust-policy`、`controller-policy`，并将policy绑定到`KarpenterControllerRole`的角色上。

执行如下命令：

```
cat << EOF > controller-trust-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ENDPOINT#*//}"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "${OIDC_ENDPOINT#*//}:aud": "sts.amazonaws.com",
                    "${OIDC_ENDPOINT#*//}:sub": "system:serviceaccount:karpenter:karpenter"
                }
            }
        }
    ]
}
EOF

aws iam create-role --role-name KarpenterControllerRole-${CLUSTER_NAME} \
    --assume-role-policy-document file://controller-trust-policy.json

cat << EOF > controller-policy.json
{
    "Statement": [
        {
            "Action": [
                "ssm:GetParameter",
                "ec2:DescribeImages",
                "ec2:RunInstances",
                "ec2:DescribeSubnets",
                "ec2:DescribeSecurityGroups",
                "ec2:DescribeLaunchTemplates",
                "ec2:DescribeInstances",
                "ec2:DescribeInstanceTypes",
                "ec2:DescribeInstanceTypeOfferings",
                "ec2:DescribeAvailabilityZones",
                "ec2:DeleteLaunchTemplate",
                "ec2:CreateTags",
                "ec2:CreateLaunchTemplate",
                "ec2:CreateFleet",
                "ec2:DescribeSpotPriceHistory",
                "pricing:GetProducts"
            ],
            "Effect": "Allow",
            "Resource": "*",
            "Sid": "Karpenter"
        },
        {
            "Action": "ec2:TerminateInstances",
            "Condition": {
                "StringLike": {
                    "ec2:ResourceTag/karpenter.sh/provisioner-name": "*"
                }
            },
            "Effect": "Allow",
            "Resource": "*",
            "Sid": "ConditionalEC2Termination"
        },
        {
            "Effect": "Allow",
            "Action": "iam:PassRole",
            "Resource": "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}",
            "Sid": "PassNodeIAMRole"
        },
        {
            "Effect": "Allow",
            "Action": "eks:DescribeCluster",
            "Resource": "arn:${AWS_PARTITION}:eks:${AWS_REGION}:${AWS_ACCOUNT_ID}:cluster/${CLUSTER_NAME}",
            "Sid": "EKSClusterEndpointLookup"
        }
    ],
    "Version": "2012-10-17"
}
EOF

aws iam put-role-policy --role-name KarpenterControllerRole-${CLUSTER_NAME} \
    --policy-name KarpenterControllerPolicy-${CLUSTER_NAME} \
    --policy-document file://controller-policy.json
```

创建成功，返回结果如下：

```
{
    "Role": {
        "Path": "/",
        "RoleName": "KarpenterControllerRole-eksworkshop",
        "RoleId": "AROAR57Y4KKLAMDXMOHTU",
        "Arn": "arn:aws:iam::133129065110:role/KarpenterControllerRole-eksworkshop",
        "CreateDate": "2023-07-12T09:21:06+00:00",
        "AssumeRolePolicyDocument": {
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Principal": {
                        "Federated": "arn:aws:iam:::oidc-provider/oidc.eks.ap-southeast-1.amazonaws.com/id/FEF8C06A5E4A991EA145C17DB29083B2"
                    },
                    "Action": "sts:AssumeRoleWithWebIdentity",
                    "Condition": {
                        "StringEquals": {
                            "oidc.eks.ap-southeast-1.amazonaws.com/id/FEF8C06A5E4A991EA145C17DB29083B2:aud": "sts.amazonaws.com",
                            "oidc.eks.ap-southeast-1.amazonaws.com/id/FEF8C06A5E4A991EA145C17DB29083B2:sub": "system:serviceaccount:karpenter:karpenter"
                        }
                    }
                }
            ]
        }
    }
}
```

### 4、配置Service Account

执行如下命令：

```
eksctl create iamserviceaccount \
  --cluster "${CLUSTER_NAME}" --name karpenter --namespace karpenter \
  --role-name "${CLUSTER_NAME}-karpenter" \
  --attach-policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/KarpenterControllerPolicy-${CLUSTER_NAME}" \
  --role-only \
  --approve
```

返回结果如下：

```
2023-07-12 18:15:51 [ℹ]  1 existing iamserviceaccount(s) (kube-system/aws-load-balancer-controller) will be excluded
2023-07-12 18:15:51 [ℹ]  1 iamserviceaccount (karpenter/karpenter) was included (based on the include/exclude rules)
2023-07-12 18:15:51 [!]  serviceaccounts in Kubernetes will not be created or modified, since the option --role-only is used
2023-07-12 18:15:51 [ℹ]  1 task: { create IAM role for serviceaccount "karpenter/karpenter" }
2023-07-12 18:15:51 [ℹ]  building iamserviceaccount stack "eksctl-eksworkshop-addon-iamserviceaccount-karpenter-karpenter"
2023-07-12 18:15:51 [ℹ]  deploying stack "eksctl-eksworkshop-addon-iamserviceaccount-karpenter-karpenter"
2023-07-12 18:15:52 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-addon-iamserviceaccount-karpenter-karpenter"
2023-07-12 18:16:23 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-addon-iamserviceaccount-karpenter-karpenter"
2023-07-12 18:17:02 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-addon-iamserviceaccount-karpenter-karpenter"
```

由此表示创建成功。

### 5、设置Karpenter可使用的Subnet和Security Group并为他们打上标签

在本配置部署说明中，我们是假设已经部署好了EKS的Nodegroup，有AWS Load Balancer Controller等组件的，因此，可通过AWSCLI获取当前Nodegroup使用的Subnet和Security Group，为其增加`karpenter.sh/discovery`的标签。

执行如下命令：

```
for NODEGROUP in $(aws eks list-nodegroups --cluster-name ${CLUSTER_NAME} \
    --query 'nodegroups' --output text); do aws ec2 create-tags \
        --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" \
        --resources $(aws eks describe-nodegroup --cluster-name ${CLUSTER_NAME} \
        --nodegroup-name $NODEGROUP --query 'nodegroup.subnets' --output text )
done
```

没有输出额外的信息则表示成功。现在进入VPC服务，进入Subnet子网，查看现有Nodegroup所在的子网，在标签Tag的位置即可看到新的标签名字叫`karpenter.sh/discovery`，值是集群名称`eksworkshop`。这表示打标签成功。

接下来是安全组的标签，执行如下命令：

```
NODEGROUP=$(aws eks list-nodegroups --cluster-name ${CLUSTER_NAME} \
    --query 'nodegroups[0]' --output text)

SECURITY_GROUPS=$(aws eks describe-cluster \
    --name ${CLUSTER_NAME} --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)

aws ec2 create-tags \
    --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" \
    --resources ${SECURITY_GROUPS}
```

没有输出额外的信息则表示成功。现在进入EC2服务，查看当前Nodegroup节点使用的Security Group。在标签Tag的位置即可看到新的标签名字叫`karpenter.sh/discovery`，值是集群名称`eksworkshop`。这表示打标签成功。

本步骤完成。

### 6、将Karpenter Node Role添加为EKS节点启动者身份

首先准备如下一段策略配置：

```
- groups:
  - system:bootstrappers
  - system:nodes
  rolearn: arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}
  username: system:node:{{EC2PrivateDNSName}}
```

在这段配置中，需要：

- 替换`${AWS_PARTITION}`为`aws`或者`aws-cn`
- 替换`${AWS_ACCOUNT_ID}`实际AWS账户ID
- 替换`${CLUSTER_NAME}`为集群名称
- 但是不要替换`{{EC2PrivateDNSName}}`

替换完毕效果如下：

```
- groups:
  - system:bootstrappers
  - system:nodes
  rolearn: arn:aws:iam::133129065110:role/KarpenterNodeRole-eksworkshop
  username: system:node:{{EC2PrivateDNSName}}
```

现在将这一段配置文件插入EKS的`aws-auth`。执行如下命令：

```
kubectl edit configmap aws-auth -n kube-system
```

找到和groups平级的位置，插入刚才准备好这一段配置。

```
apiVersion: v1
data:
  mapRoles: |
    - groups:
      - system:bootstrappers
      - system:nodes
      rolearn: arn:aws:iam::133129065110:role/eksctl-eksworkshop-nodegroup-newn-NodeInstanceRole-17EL7P7Q9BRQV
      username: system:node:{{EC2PrivateDNSName}}
    - groups:
      - system:bootstrappers
      - system:nodes
      rolearn: arn:aws:iam::133129065110:role/KarpenterNodeRole-eksworkshop
      username: system:node:{{EC2PrivateDNSName}}
kind: ConfigMap
metadata:
  creationTimestamp: "2023-06-21T07:45:49Z"
  name: aws-auth
  namespace: kube-system
  resourceVersion: "5599929"
  uid: df7e4259-129d-418c-91c9-61a822706630
```

配置好的`configmap`里边至少有两段`groups`定义，分别是现有的Nodegroup的使用的IAM Role，以及要给Karpenter Node使用Role。

至此权限配置完成。

### 7、准备Helm（如果之前已经安装可跳过）

如果在实验环境的准备阶段，已经安装了AWS Load Balancer Controller，那么意味着已经使用过helm了。本步骤可跳过。

如果之前没有安装过，请使用如下命令安装。

在MacOS上，执行如下命令：

```
brew install helm
```

在Linux系统上，执行如下命令：

```
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh```
```
在Windows上，建议通过choco包管理程序自动安装，执行如下命令：

```
choco install kubernetes-helm
```

如果本机在以前安装过Helm，可执行`helm repo update`命令更新软件仓库。

### 8、部署Karpenter控制器Pod

执行如下命令：

```
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version ${KARPENTER_VERSION} --namespace karpenter --create-namespace \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=${KARPENTER_IAM_ROLE_ARN} \
  --set settings.aws.clusterName=${CLUSTER_NAME} \
  --set settings.aws.defaultInstanceProfile=KarpenterNodeInstanceProfile-${CLUSTER_NAME} \
  --set settings.aws.interruptionQueueName=${CLUSTER_NAME} \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --wait
```

返回结果：

```
Release "karpenter" does not exist. Installing it now.
Pulled: public.ecr.aws/karpenter/karpenter:v0.29.0
Digest: sha256:4aad65a0484f9e71519fe9c3166f3a7cb29b0b1996a115663b0026f30e828a5b
NAME: karpenter
LAST DEPLOYED: Wed Jul 12 18:21:30 2023
NAMESPACE: karpenter
STATUS: deployed
REVISION: 1
TEST SUITE: None
```

执行如下命令确认Karpenter的pod启动成功：

```
kubectl get all -n karpenter
```

返回结果如下：

```
NAME                             READY   STATUS    RESTARTS   AGE
pod/karpenter-7574749b8f-mw767   1/1     Running   0          11m
pod/karpenter-7574749b8f-pqd4x   1/1     Running   0          11m

NAME                TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)             AGE
service/karpenter   ClusterIP   10.50.0.52   <none>        8000/TCP,8443/TCP   11m

NAME                        READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/karpenter   2/2     2            2           11m

NAME                                   DESIRED   CURRENT   READY   AGE
replicaset.apps/karpenter-7574749b8f   2         2         2       11m
```

这表示karpenter的控制器的Pod已经启动正常。

### 9、配置Karpenter Provsioner并指定机型

执行以下命令启动Provisioner（其中的集群名称等变量将自动代入）：

```
cat << EOF > karpenter-provisioner.yaml
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
    - key: kubernetes.io/arch
      operator: In
      values: ["arm64"]
    - key: node.kubernetes.io/instance-type
      operator: In
      values: ["m6g.xlarge", "r6g.xlarge", "c6g.2xlarge"]
  limits:
    resources:
      cpu: 1000
      memory: 1000Gi
  providerRef:
    name: default
  consolidation: 
    enabled: true
---
apiVersion: karpenter.k8s.aws/v1alpha1
kind: AWSNodeTemplate
metadata:
  name: default
spec:
  subnetSelector:
    karpenter.sh/discovery: ${CLUSTER_NAME}
  securityGroupSelector:
    karpenter.sh/discovery: ${CLUSTER_NAME}
EOF

kubectl apply -f karpenter-provisioner.yaml
```

返回结果如下：

```
provisioner.karpenter.sh/default created
awsnodetemplate.karpenter.k8s.aws/default created
```

在上一步的配置文件中，requirements这一段指定了Spot或On-Demand，并可以指定ARM架构或者Intel架构，以及特定机型的组合。更多参数写法，请参考本文末尾的参考文档。

至此Karpenter部署完成。

## 四、测试Karpenter扩展新的Node

### 1、查看集群现有剩余容量并规划扩展

在启动新的集群之前，我们查看下现有集群的剩余容量。由于还没有安装HPA，因此集群还没有Metric API被部署，这个时候`kubectl top node`等命令还暂时不可用。此时我们使用如下命令来检查资源情况：

```
kubectl describe node 
```

这个命令会分别列出当前所有节点的资源使用情况。例如如下信息就是某一个节点剩余资源情况：

```
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests     Limits
  --------           --------     ------
  cpu                1825m (46%)  1200m (30%)
  memory             1324Mi (8%)  1424Mi (9%)
  ephemeral-storage  0 (0%)       0 (0%)
  hugepages-1Gi      0 (0%)       0 (0%)
  hugepages-2Mi      0 (0%)       0 (0%)
  hugepages-32Mi     0 (0%)       0 (0%)
  hugepages-64Ki     0 (0%)       0 (0%)
Events:              <none>
```

由于`kubectl top node`是按节点依次输出的，因此向上滚动页面课查看前几个节点的输出信息。

根据以上结果可以看出，相对CPU资源不足。因为当前测试Nodegroup是`t4g.xlarge`，只有4个vCPU，也就是每个节点CPU资源是4000。以当前节点为例，Request的vCPU已经达到1825即折算1.825个vCPU。所以再增加几个容器，每个容器都Request申请2个vCPU，这样总量就会大于4，因此就会触发扩容。

现在我们来验证以上逻辑。

### 2、部署测试应用

为了明显的模拟扩展，用于应用将分配较多的资源。一般场景一个nginx只需要1GB内存，但我们这里故意分配2vCPU/4GB，用于明显的资源消耗以更早触发扩容。这个应用起步时候设置replica=1，即只创建1个Pod。

构建如下配置，保存为`demo-nginx-nlb-karpenter.yaml`文件：

```
---
apiVersion: v1
kind: Namespace
metadata:
  name: nlb-app-karpenter
---
apiVersion: apps/v1
kind: Deployment
metadata:
  namespace: nlb-app-karpenter
  name: nginx-deployment
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: nginx
  replicas: 1
  template:
    metadata:
      labels:
        app.kubernetes.io/name: nginx
    spec:
      containers:
      - image: public.ecr.aws/nginx/nginx:1.24-alpine-slim
        imagePullPolicy: Always
        name: nginx
        ports:
        - containerPort: 80
        resources:
          limits:
            cpu: "2"
            memory: 4G
          requests:
            cpu: "2"
            memory: 4G
---
apiVersion: v1
kind: Service
metadata:
  namespace: nlb-app-karpenter
  name: "service-nginx"
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
spec:
  loadBalancerClass: service.k8s.aws/nlb
  selector:
    app.kubernetes.io/name: nginx
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

### 3、查看应用运行正常

执行如下命令查看已经拉起的Pod。因为replica设置为1，因此可看到有1个Pod。

```
kubectl get pods -n nlb-app-karpenter
```

返回1个Pod与预期一致。

```
NAME                               READY   STATUS    RESTARTS   AGE
nginx-deployment-75d9ffff7-7pvlg   1/1     Running   0          49s
```

执行如下命令查看访问入口：

```
kubectl get service -n nlb-app-karpenter
```

由此可获得NLB入口。

```
NAME            TYPE           CLUSTER-IP    EXTERNAL-IP                                                                          PORT(S)        AGE
service-nginx   LoadBalancer   10.50.0.131   k8s-nlbappka-servicen-1b114eb166-77c1568fcaa70b7e.elb.ap-southeast-1.amazonaws.com   80:32371/TCP   13m
```

使用curl或者浏览器访问NLB地址，可看到访问成功。由此表示Pod启动正常。

### 4、查看Node剩余资源

再次执行命令`kubectl describe node`分别打出所有Node的资源情况。找到上一步启动的那个Pod所在的节点，可看到信息如下（部分输出节选）

```
Non-terminated Pods:          (6 in total)
  Namespace                   Name                                             CPU Requests  CPU Limits  Memory Requests  Memory Limits  Age
  ---------                   ----                                             ------------  ----------  ---------------  -------------  ---
  amazon-cloudwatch           cloudwatch-agent-zfpsv                           200m (5%)     200m (5%)   200Mi (1%)       200Mi (1%)     21d
  amazon-cloudwatch           fluent-bit-bk92r                                 500m (12%)    0 (0%)      100Mi (0%)       200Mi (1%)     21d
  karpenter                   karpenter-7574749b8f-pqd4x                       1 (25%)       1 (25%)     1Gi (6%)         1Gi (6%)       3h45m
  kube-system                 aws-load-balancer-controller-6c94cf8d47-vdk7k    0 (0%)        0 (0%)      0 (0%)           0 (0%)         21d
  kube-system                 aws-node-6bmxr                                   25m (0%)      0 (0%)      0 (0%)           0 (0%)         21d
  kube-system                 kube-proxy-7v5b6                                 100m (2%)     0 (0%)      0 (0%)           0 (0%)         21d
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests     Limits
  --------           --------     ------
  cpu                1825m (46%)  1200m (30%)
  memory             1324Mi (8%)  1424Mi (9%)
  ephemeral-storage  0 (0%)       0 (0%)
  hugepages-1Gi      0 (0%)       0 (0%)
  hugepages-2Mi      0 (0%)       0 (0%)
  hugepages-32Mi     0 (0%)       0 (0%)
  hugepages-64Ki     0 (0%)       0 (0%)
Events:              <none>          
```

这部分返回信息里，可看到上一步启动的名为`nlb-app-karpenter`的应用的Pod就运行在本机。对比前文步骤，其Node节点CPU资源使用小于50%，目前已经来到了`2925m (74%)`。由于测试Node的配置`t4g.xlarge`只有4个vCPU，也就是换算为`4000m`，因此这里看到只需要再增加一个Pod，即可触发扩容。

考虑到一共有3个Node，因此为了用尽所有资源触发扩容，我们将应用的repica从1直接修改到6，以确保现有Nodegroup所有Node资源都将不足，从而触发扩容。

### 5、修改部署扩容

执行如下命令：

```
kubectl scale deployment nginx-deployment -n nlb-app-karpenter --replicas 6
```

返回如下：

```
deployment.apps/nginx-deployment scaled
```

等待1～2分钟时间让Karpenter拉起新的Node，然后继续下一步操作。

### 6、查看Karpenter扩展结果

执行如下命令查看调整Replica导致的Pod扩展是否生效：

```
kubectl get pod -n nlb-app-karpenter
```

可看到返回结果是6个Pod，表示扩展生效。

```
NAME                               READY   STATUS              RESTARTS   AGE
nginx-deployment-75d9ffff7-6kjz5   0/1     ContainerCreating   0          63s
nginx-deployment-75d9ffff7-7pvlg   1/1     Running             0          18m
nginx-deployment-75d9ffff7-fgcdf   1/1     Running             0          63s
nginx-deployment-75d9ffff7-fsq7d   0/1     ContainerCreating   0          63s
nginx-deployment-75d9ffff7-g4gjx   0/1     ContainerCreating   0          63s
nginx-deployment-75d9ffff7-xmhbr   0/1     ContainerCreating   0          63s
```

执行如下命令可通过限定特定的标签，查看Karpenter扩容出来的Spot节点Node：

```
kubectl get node -l karpenter.sh/capacity-type=spot
```

返回结果如下：

```
NAME                                               STATUS   ROLES    AGE   VERSION
ip-172-31-56-118.ap-southeast-1.compute.internal   Ready    <none>   49s   v1.27.1-eks-2f008fe
ip-172-31-86-165.ap-southeast-1.compute.internal   Ready    <none>   46s   v1.27.1-eks-2f008fe
```

以上结果表示新拉起了两台Spot计费模式的节点，用于运行扩容出来的Pod。

### 7、查看Karpenter扩展过程日志

执行如下命令可查看Karpenter扩展的日志：

```
kubectl logs -f -n karpenter -c controller -l app.kubernetes.io/name=karpenter
```

返回结果如下：

```
2023-07-12T14:18:48.166Z	DEBUG	controller.provisioner	15 out of 527 instance types were excluded because they would breach provisioner limits	{"commit": "61cc8f7-dirty", "provisioner": "default"}
2023-07-12T14:18:48.178Z	DEBUG	controller.provisioner	15 out of 527 instance types were excluded because they would breach provisioner limits	{"commit": "61cc8f7-dirty", "provisioner": "default"}
2023-07-12T14:18:48.188Z	INFO	controller.provisioner	found provisionable pod(s)	{"commit": "61cc8f7-dirty", "pods": 4}
2023-07-12T14:18:48.188Z	INFO	controller.provisioner	computed new machine(s) to fit pod(s)	{"commit": "61cc8f7-dirty", "machines": 2, "pods": 4}
2023-07-12T14:18:48.199Z	INFO	controller.provisioner	created machine	{"commit": "61cc8f7-dirty", "provisioner": "default", "requests": {"cpu":"6825m","memory":"12025950Ki","pods":"7"}, "instance-types": "c6g.2xlarge"}
2023-07-12T14:18:48.200Z	INFO	controller.provisioner	created machine	{"commit": "61cc8f7-dirty", "provisioner": "default", "requests": {"cpu":"2825m","memory":"4213450Ki","pods":"5"}, "instance-types": "c6g.2xlarge, m6g.xlarge, r6g.xlarge"}
2023-07-12T14:18:48.395Z	DEBUG	controller.machine.lifecycle	discovered subnets	{"commit": "61cc8f7-dirty", "machine": "default-s4ltt", "provisioner": "default", "subnets": ["subnet-04a7c6e7e1589c953 (ap-southeast-1a)", "subnet-031022a6aab9b9e70 (ap-southeast-1b)", "subnet-0eaf9054aa6daa68e (ap-southeast-1c)"]}
2023-07-12T14:18:49.192Z	DEBUG	controller.machine.lifecycle	created launch template	{"commit": "61cc8f7-dirty", "machine": "default-s4ltt", "provisioner": "default", "launch-template-name": "karpenter.k8s.aws/15396317734744136304", "id": "lt-0a25a414a695bd805"}
2023-07-12T14:18:51.040Z	INFO	controller.machine.lifecycle	launched machine	{"commit": "61cc8f7-dirty", "machine": "default-tzjgw", "provisioner": "default", "provider-id": "aws:///ap-southeast-1c/i-02b793c67431ea61f", "instance-type": "m6g.xlarge", "zone": "ap-southeast-1c", "capacity-type": "spot", "allocatable": {"cpu":"3920m","ephemeral-storage":"17Gi","memory":"14103Mi","pods":"58"}}
2023-07-12T14:18:51.267Z	INFO	controller.machine.lifecycle	launched machine	{"commit": "61cc8f7-dirty", "machine": "default-s4ltt", "provisioner": "default", "provider-id": "aws:///ap-southeast-1a/i-0c9f4e83474dafa7b", "instance-type": "c6g.2xlarge", "zone": "ap-southeast-1a", "capacity-type": "spot", "allocatable": {"cpu":"7910m","ephemeral-storage":"17Gi","memory":"14103Mi","pods":"58"}}
2023-07-12T14:19:12.453Z	DEBUG	controller.machine.lifecycle	registered machine	{"commit": "61cc8f7-dirty", "machine": "default-s4ltt", "provisioner": "default", "provider-id": "aws:///ap-southeast-1a/i-0c9f4e83474dafa7b", "node": "ip-172-31-56-118.ap-southeast-1.compute.internal"}
2023-07-12T14:19:15.133Z	DEBUG	controller.machine.lifecycle	registered machine	{"commit": "61cc8f7-dirty", "machine": "default-tzjgw", "provisioner": "default", "provider-id": "aws:///ap-southeast-1c/i-02b793c67431ea61f", "node": "ip-172-31-86-165.ap-southeast-1.compute.internal"}
2023-07-12T14:19:35.516Z	DEBUG	controller.machine.lifecycle	initialized machine	{"commit": "61cc8f7-dirty", "machine": "default-s4ltt", "provisioner": "default", "provider-id": "aws:///ap-southeast-1a/i-0c9f4e83474dafa7b", "node": "ip-172-31-56-118.ap-southeast-1.compute.internal"}
2023-07-12T14:19:38.748Z	DEBUG	controller.machine.lifecycle	initialized machine	{"commit": "61cc8f7-dirty", "machine": "default-tzjgw", "provisioner": "default", "provider-id": "aws:///ap-southeast-1c/i-02b793c67431ea61f", "node": "ip-172-31-86-165.ap-southeast-1.compute.internal"}
2023-07-12T14:20:12.986Z	DEBUG	controller.deprovisioning	discovered subnets	{"commit": "61cc8f7-dirty", "subnets": ["subnet-04a7c6e7e1589c953 (ap-southeast-1a)", "subnet-031022a6aab9b9e70 (ap-southeast-1b)", "subnet-0eaf9054aa6daa68e (ap-southeast-1c)"]}
2023-07-12T14:21:40.547Z	DEBUG	controller	deleted launch template	{"commit": "61cc8f7-dirty", "id": "lt-0a25a414a695bd805", "name": "karpenter.k8s.aws/15396317734744136304"}
```

在以上这段日志中肯看到，两个Spot节点分别选用了`m6g.xlarge`和`c6g.2xlarge`机型。这两个机型的选用，与前文指定Karpenter Provisioner时候选择的配置相符。

由此Karpenter扩容实验完成。

### 8、Node向下缩容

执行如下命令将应用程序的Replica收缩回到1个Pod。

```
kubectl scale deployment nginx-deployment -n nlb-app-karpenter --replicas 1
```

重复以上实验过程的几个命令，分别查看Pod数量、查看带有Spot标签的Node、以及查看Karpenter日志，即可看到缩容完成。而缩容产生的日志类似如下：

```
2023-07-12T14:31:30.361Z	INFO	controller.deprovisioning	deprovisioning via consolidation delete, terminating 2 machines ip-172-31-86-165.ap-southeast-1.compute.internal/m6g.xlarge/spot, ip-172-31-56-118.ap-southeast-1.compute.internal/c6g.2xlarge/spot	{"commit": "61cc8f7-dirty"}
2023-07-12T14:31:30.434Z	INFO	controller.termination	cordoned node	{"commit": "61cc8f7-dirty", "node": "ip-172-31-86-165.ap-southeast-1.compute.internal"}
2023-07-12T14:31:30.439Z	INFO	controller.termination	cordoned node	{"commit": "61cc8f7-dirty", "node": "ip-172-31-56-118.ap-southeast-1.compute.internal"}
2023-07-12T14:31:30.790Z	INFO	controller.termination	deleted node	{"commit": "61cc8f7-dirty", "node": "ip-172-31-86-165.ap-southeast-1.compute.internal"}
2023-07-12T14:31:30.791Z	INFO	controller.termination	deleted node	{"commit": "61cc8f7-dirty", "node": "ip-172-31-56-118.ap-southeast-1.compute.internal"}
2023-07-12T14:31:31.095Z	INFO	controller.machine.termination	deleted machine	{"commit": "61cc8f7-dirty", "machine": "default-tzjgw", "node": "ip-172-31-86-165.ap-southeast-1.compute.internal", "provisioner": "default", "provider-id": "aws:///ap-southeast-1c/i-02b793c67431ea61f"}
2023-07-12T14:31:31.097Z	INFO	controller.machine.termination	deleted machine	{"commit": "61cc8f7-dirty", "machine": "default-s4ltt", "node": "ip-172-31-56-118.ap-southeast-1.compute.internal", "provisioner": "default", "provider-id": "aws:///ap-southeast-1a/i-0c9f4e83474dafa7b"}
```

### 9、使用Karpenter小结

从以上实验中可以看到，只要部署应用的Replica数量增加导致Node资源不足，Karpenter就会自动创建新的Node，且创建时候可选择机型配置以及是否Spot类型。

不过，上一步实验是手工调整的Replica也就是Pod的数量，如果能实现按业务负载自动调整Replica的数量，即可实现自动的整体扩缩容。由此下一步实验将HPA，实现业务压力自动缩放Replica。

## 五、部署HPA实现应用Pod的缩放

前文通过Karpenter实现了Node根据资源剩余情况的缩放，接下来使用HPA实现根据访问压力对Pod数量的缩放。接上一步部署Karpenter时候已经存在的应用和已经存在的Deployment继续操作。注：之前Replica=1或者设置为Replica=3均可。

### 1、部署Metrics Server

执行以下命令部署metrics server。

```
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

返回结果如下：

```
serviceaccount/metrics-server created
clusterrole.rbac.authorization.k8s.io/system:aggregated-metrics-reader created
clusterrole.rbac.authorization.k8s.io/system:metrics-server created
rolebinding.rbac.authorization.k8s.io/metrics-server-auth-reader created
clusterrolebinding.rbac.authorization.k8s.io/metrics-server:system:auth-delegator created
clusterrolebinding.rbac.authorization.k8s.io/system:metrics-server created
service/metrics-server created
deployment.apps/metrics-server created
apiservice.apiregistration.k8s.io/v1beta1.metrics.k8s.io created
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
      "lastTransitionTime": "2023-07-12T14:42:59Z",
      "message": "all checks passed",
      "reason": "Passed",
      "status": "True",
      "type": "Available"
    }
  ]
}
```

如果没有获得以上结果，那么需要继续等待启动完成。

### 3、验证Metrics Server获取数据正常。

执行如下命令查看所有Pod负载。

```
kubectl top node
```

返回如下信息。

```
NAME                                               CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%   
ip-172-31-55-131.ap-southeast-1.compute.internal   43m          1%     559Mi           3%        
ip-172-31-75-60.ap-southeast-1.compute.internal    44m          1%     610Mi           4%        
ip-172-31-82-248.ap-southeast-1.compute.internal   34m          0%     714Mi           4%        
ip-172-31-93-53.ap-southeast-1.compute.internal    25m          0%     453Mi           3%        
```

执行如下命令查看所有Namespaces中的Pod信息。

```
kubectl top pod -A
```

返回结果较长，这里不再赘述。

如果只希望返回特定Namespaces中的Pod的排行，可执行如下命令：

```
kubectl top pod -n nlb-app-karpenter
```

返回结果如下：（上一个实验缩容后保留了1个Pod或者3个Pod都可以，不影响后续测试）

```
NAME                               CPU(cores)   MEMORY(bytes)   
nginx-deployment-75d9ffff7-7pvlg   1m           3Mi             
nginx-deployment-75d9ffff7-hspwt   1m           4Mi             
nginx-deployment-75d9ffff7-mb56v   1m           3Mi     
```

### 3、配置性能监控并设置HPA弹性阈值

执行如下命令设置HPA。其中`min=1`表示最小3个pod，`max=12`表示最大12个pod，`--cpu-percent=10`表示CPU达到10%的阈值后触发扩容。

注意：此处选择10%是为了在测试中快速的实现扩容效果，在生产环境中，一般使用50%或者70%作为扩容阈值。

```
kubectl autoscale deployment nginx-deployment -n nlb-app-karpenter --cpu-percent=10 --min=3 --max=12
```

返回信息如下：

```
horizontalpodautoscaler.autoscaling/nginx-deployment autoscaled
```

配置完毕后，可通过如下命令查看HPA的信息：

```
kubectl get hpa -n nlb-app-karpenter
```

返回信息如下：

```                          23:36:03
NAME               REFERENCE                     TARGETS   MINPODS   MAXPODS   REPLICAS   AGE
nginx-deployment   Deployment/nginx-deployment   0%/10%    3         12        3          117s 
```

在服务刚启动功能时候，由于没有抓取到足够数据，在`TARGETS`这一列可能显示`Unknown/10%`。过几分钟后即可正常显示资源实际使用情况。如果没打压，且当前应用是nginx这种不占用资源的应用，这里一般显示当前`0%/10%`。

如果希望修改刚配置的HPA，则执行如下命令，替换其中的Deployment名称和Namespace名称即可：

```
kubectl edit hpa/nginx-deployment -n  nlb-app-karpenter
```

至此HPA配置成功。

## 六、对应用施压测试、触发HPA调整Replica实现Pod扩展并触发Karpenter扩充Node

经过以上准备，本实验终于来到了EKS缩放的完整形态，即HPA负载根据压力缩放Replica调整Pod数量，而Karpenter根据Node资源池剩余资源情况拉起新Node。下面开始操作。

### 1、启动额外的EC2作为外部的负载生成器

负载生成器可以使用普通的EC2 Linux进行，只要能部署apache benchmark工具即可。新部署一台`c6g.xlarge`或者`m6g.xlarge`规格的EC2，系统选择为Amazon Linux 2023操作系统。

压力生成器几个注意事项：

- 考虑到多可用区多AZ分布的问题，需要在本VPC之外的其他VPC来部署，如果只是在与EKS相同VPC上，某个AZ内部署压力负载生成器，那么只有本AZ的Pod和Node会收到压力。这将与预期完全不符
- 压力测试建议不要跨region，在本region获得最大压力效果
- 机型不能太小，建议`c6g.xlarge`或者`m6g.xlarge`规格的EC2
- 另外不要选择t系列，可能会造成CPU算力不足

本例中，将使用Apache Benchmark（简称ab）发起压力测试。执行如下命令安装客户端：

```
yum update -y
yum install httpd -y
ab --help
```

由此压力发生器准备完毕。

### 2、查询施压的入口

执行如下命令查看访问入口：

```
kubectl get service -n nlb-app-karpenter
```

由此可获得NLB入口。

```
NAME            TYPE           CLUSTER-IP    EXTERNAL-IP                                                                          PORT(S)        AGE
service-nginx   LoadBalancer   10.50.0.131   k8s-nlbappka-servicen-1b114eb166-77c1568fcaa70b7e.elb.ap-southeast-1.amazonaws.com   80:32371/TCP   13m
```

### 3、发起负载

安装Apache Benchmark完成后，执行如下命令生成压力。参数`n`代表数量，参数`c`代表线程。访问地址为上一步的NLB地址。本文使用`n=1000000`和`c=500`这个比较大的参数来施压。

注意：本实验启动的Pod是一个空白的nginx，里边没有脚本语言也没有预编译应用，因此其本身的损耗非常低。在做压力测试后，需要通过`-c`参数增加线程对其施加很大的压力，才能让CPU产生明显的负载，从而达到HPA事先指定的阈值。如果是真实生产环境，不要一开始就配置这么大的参数，因为这有可能会导致大量失败，甚至应用程序崩溃异常退出。在真实生产环境上，可以从`n=10000`和`c=10`起步，逐渐增加压力，逐渐过渡到较大且稳定的参数。

在负载生成器上，执行如下命令发起负载：

```
ab -n 1000000 -c 500 http://k8s-nlbappka-servicen-1b114eb166-77c1568fcaa70b7e.elb.ap-southeast-1.amazonaws.com/
```

以上脚本执行数秒即可完成。由于EKS的默认参数对HPA的响应是15秒一次且这个参数在EKS上不能修改，因此负载发生器需要持续发生流量，以确保不止一个HPA的检测周期都能识别到负载的增加。

### 4、观察压力导致的HPA对Replica的调整和Pod扩容

使用如下命令观察HPA对Deployment的Replica的调整：

```
kubectl get deployment -n nlb-app-karpenter
```

可看到已经按要求完成了缩放：

```
NAME               READY   UP-TO-DATE   AVAILABLE   AGE
nginx-deployment   12/12   12           12          17h
```

使用如下命令观察Metrics Server、CPU负载以及Deployment的Replica的数量：

```
kubectl get hpa -n nlb-app-karpenter -w
```

这里加了-w参数，表示命令不会退出，而是每隔几秒自动打印出来新的一行。因此就不用反复执行本命令了。返回结果如下：

```
nginx-deployment   Deployment/nginx-deployment   39%/10%   3         12        6          15h
```

由此可以看到HPA已经对Pod完成扩容。

### 5、观察Pod增加导致的Node资源池用完然后引起的Node扩容

执行如下命令观察Replica数量变化导致的扩充的Spot节点：

```
kubectl get node -l karpenter.sh/capacity-type=spot
```

返回信息如下：

```
NAME                                               STATUS   ROLES    AGE     VERSION
ip-172-31-64-191.ap-southeast-1.compute.internal   Ready    <none>   3m21s   v1.27.1-eks-2f008fe
ip-172-31-67-50.ap-southeast-1.compute.internal    Ready    <none>   3m21s   v1.27.1-eks-2f008fe
ip-172-31-78-112.ap-southeast-1.compute.internal   Ready    <none>   3m29s   v1.27.1-eks-2f008fe
ip-172-31-83-78.ap-southeast-1.compute.internal    Ready    <none>   175m    v1.27.1-eks-2f008fe
```

以上信息可看到，HPA和Karpenter扩展了新的Spot节点，为负载压力提供了支持。

至此本实验全部结束。

## 七、环境清理

首先删除测试用应用，执行如下命令：

```
kubectl delete -f demo-nginx-nlb-karpenter.yaml
```

删除应用后，接下来要先删除Karpenter。如果不先删除Karpenter，那么删除一个Node时候，因为整体资源池容量不足，Karpenter会继续拉起新的Node去为资源池扩容。因此要先删除Karpenter禁止拉起新node。执行如下命令：

```
helm uninstall karpenter --namespace karpenter
```

执行如下命令删除集群：

```
eksctl delete cluster eksworkshop --region ap-southeast-1
```

## 八、参考文档

HorizontalPodAutoscaler Walkthrough:

[https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/]()

Karpenter Provisioner指定EC2机型、架构、配置等参数：

[https://karpenter.sh/docs/concepts/scheduling/]()