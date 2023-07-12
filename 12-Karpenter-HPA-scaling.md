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

## 三、部署Karpenter

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

## 四、测试Karpenter扩展

### 1、部署测试应用

构建如下测试应用，保存为`demo-nginx-nlb-karpenter.yaml`文件：

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

### 2、查看应用

这一步应用的replica设置为3，因此可看到有3个Pod。

```
kubectl get pods -n nlb-app-karpenter
```

返回结果如下，3个Pod与预期一致。

```
NAME                                READY   STATUS    RESTARTS   AGE
nginx-deployment-64c7f7d597-298xm   1/1     Running   0          7m30s
nginx-deployment-64c7f7d597-glz2c   1/1     Running   0          7m30s
nginx-deployment-64c7f7d597-vcccq   1/1     Running   0          7m30s
```

执行如下命令查看访问入口：

```
kubectl get service -n nlb-app-karpenter
```

由此可获得NLB入口。

```
NAME            TYPE           CLUSTER-IP    EXTERNAL-IP                                                                          PORT(S)        AGE
service-nginx   LoadBalancer   10.50.0.134   k8s-nlbappka-servicen-5fb53d7320-7d463ab8bae89927.elb.ap-southeast-1.amazonaws.com   80:30425/TCP   5m46s
```

使用curl或者浏览器访问NLB地址，可看到访问成功。

### 3、修改部署扩容

为了触发Node的库容，需要将应用的Pod数量从3扩容到9或者12，即明显超出现有Nodegroup的资源，如果只是从3扩展到4，因为生育资源足够，将不会生成新的Node。

执行如下命令：

```
kubectl scale deployment nginx-deployment -n nlb-app-karpenter --replicas 12
```

返回如下：

```
deployment.apps/nginx-deployment scaled
```

### 4、查看Karpenter扩展结果

在执行了上一步扩容后去查看Pod和Node，可以发现Karpenter已经对其进行了扩展。

执行如下命令可通过限定特定的标签，查看Karpenter扩容出来的Spot节点Node：

```
kubectl get node -l karpenter.sh/capacity-type=spot
```

### 5、查看Karpenter日志

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
```

关于Karpenter Provsioner对机型配置的选择，请参考有关配置文件修改说明。

由此，Karpenter配置完成，工作正常。最后执行如下命令将应用搜索回到1个Pod，便于后续实验发起压力扩容。

```
kubectl scale deployment demo-nginx-nlb-karpenter --replicas 1
```

至此实现了Karpenter即可实现Node的扩容。

从以上实验中可以看到，只要部署应用的Replica增加导致Node资源不足，就会自动创建新的Node。因此，只要实现按业务负载，自动调整Replica的数量，即可实现业务整体扩容。下一步来配置HPA，即实现根据业务压力自动缩放Replica。

## 五、部署HPA

接下来部署HPA过程中，将继续使用上文配置Karpenter的应用作为被测试的用例。

### 1、部署Metrics Server

执行以下命令部署metrics server。

```
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
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

执行如下命令。其中`min=1`表示最小1个pod，`max=10`表示最大10个pod，`--cpu-percent=30`表示CPU达到30%的阈值后触发扩容。此外如果使用了其他的部署名称，还需要替换命令中的deployment名称：

```
kubectl autoscale deployment demo-nginx-nlb-karpenter --cpu-percent=30 --min=1 --max=10
```

配置完毕后，可通过如下命令查看HPA的信息：

```
kubectl get hpa
```

## 六、测试HPA扩展

### 1、使用额外的EC2作为外部的负载生成器

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

### 2、观察压力导致的扩容

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

## 七、参考文档

Karpenter:

[https://www.eksworkshop.com/beginner/085_scaling_karpenter/](https://www.eksworkshop.com/beginner/085_scaling_karpenter/)

HPA:

[https://www.eksworkshop.com/beginner/080_scaling/](https://www.eksworkshop.com/beginner/080_scaling/)

HorizontalPodAutoscaler Walkthrough:

[https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/]()

Karpenter Provisioner指定EC2机型、架构、配置等参数：

[https://karpenter.sh/docs/concepts/scheduling/]()