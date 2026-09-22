# EKS 101动手实验（十二）使用Karpenter+HPA实现EKS集群扩展

EKS 1.36版本 & Karpenter 1.14版本 @2026-09 AWS Global区域（ap-southeast-1）测试通过

## 一、背景

EKS的扩容有两种方式：

- 1、单个应用的Deployment的replica扩容，Pod数量增加，Node不变
- 2、Node节点的扩容，Node增加，Pod不变

对于第一种扩容，常用的方式是Horizontal Pod Autoscaler (HPA)，通过metrics server，监控CPU负载等指标，然后发起对deployment的replica的变化。此配置会调整Pod数量，但不会调整节点数量。

对于第二种扩容，之前常用的方式是Cluster Autoscaler (CA)对NodeGroup节点组的EC2进行扩容，但是其扩展速度较慢。本文使用Karpenter组件对节点进行扩容。Karpenter不需要预先创建新的NodeGroup，而是直接根据待调度Pod的资源诉求自动选择On-Demand或者Spot类型的实例。

需要特别说明的是，Karpenter自0.29版本以来经历了重大演进。自1.0.0版本起，Karpenter进入正式GA阶段，其自定义资源（Custom Resource Definition，CRD）从早期的`Provisioner`（API组`karpenter.sh/v1alpha5`）与`AWSNodeTemplate`（API组`karpenter.k8s.aws/v1alpha1`）演进为`NodePool`（`karpenter.sh/v1`）与`EC2NodeClass`（`karpenter.k8s.aws/v1`）两类资源。二者的职责划分为：`NodePool`描述与云厂商无关的调度约束（架构、容量类型、机型范围、整合策略等），`EC2NodeClass`描述AWS专有配置（节点IAM角色、AMI、子网与安全组的发现方式等）。本文基于Karpenter 1.14.1编写，该版本与EKS 1.36兼容（依据官方兼容性矩阵，EKS 1.36要求Karpenter版本不低于1.13）。

与早期版本相比，本文所用的1.x版本还有以下若干与操作直接相关的变化，读者在跟随旧版教程时需要留意：

- 控制器默认部署命名空间由独立的`karpenter`调整为`kube-system`。
- 节点使用的实例配置文件（Instance Profile）不再需要手工创建，改由`EC2NodeClass`的`role`字段声明节点角色后，Karpenter自动创建并维护。
- Helm安装参数由`settings.aws.clusterName`简化为`settings.clusterName`，并移除了`settings.aws.defaultInstanceProfile`。
- 控制器IAM策略新增了针对实例配置文件的一组权限，且实例回收的条件键由`karpenter.sh/provisioner-name`调整为`karpenter.sh/nodepool`。

本实验流程如下：

- 1、复用一个已经存在的EKS集群，该集群自带一个On-Demand形式的NodeGroup节点组（生产环境下一般会购买RI预留实例与之匹配），并已部署AWS Load Balancer Controller，但没有安装Karpenter与HPA相关组件
- 2、安装Karpenter，部署一个Nginx应用，由Karpenter自动调度Spot节点
- 3、手工修改replica参数，测试Karpenter扩容调度更多节点生效，并观察缩容整合
- 4、配置HPA
- 5、创建一个负载发生器
- 6、从负载发生器对应用施加访问压力，同时触发HPA对应用deployment的replica自动扩容，并同时触发由Karpenter触发新的Spot节点扩容，观察以上现象确认运行正常

下面从环境准备开始。

## 二、环境准备

### 1、创建新集群

本文假设集群已经创建好，并且有Nodegroup存在，同时部署了AWS Load Balancer Controller等必要的组件。搭建本文实验环境可参考[这篇](https://blog.bitipcman.com/use-dedicate-subnet-for-eks-node-with-aws-vpc-cni/)文档完成。

本文实验所用集群名称为`eksworkshop`，位于`ap-southeast-1`区域，Kubernetes版本为1.36，节点为3台`t3.2xlarge`（每台8个vCPU）的On-Demand实例，采用Amazon Linux 2023操作系统、x86_64（amd64）架构。集群的鉴权模式为`API_AND_CONFIG_MAP`，因此后文仍可通过`aws-auth`配置映射节点角色。下面开始部署Spot节点。

### 2、在On-demand的NodeGroup上创建测试应用

为了验证节点组的工作正常，我们可启动一个测试应用程序在这一组NodeGroup上运行。

编辑如下配置文件，并保存为`demo-nginx-nlb-on-demand.yaml`文件：

```yaml
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
      - image: public.ecr.aws/nginx/nginx:1.31-alpine-slim
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

```shell
kubectl apply -f demo-nginx-nlb-on-demand.yaml
```

### 3、验证On-Demand节点的应用工作正常

执行如下命令获取这个应用NLB入口：

```shell
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

```shell
kubectl delete -f demo-nginx-nlb-on-demand.yaml
```

## 三、部署Karpenter实现Node缩放

### 1、设置环境变量

首先配置环境变量，在Bash或者Zsh的Shell环境下，执行如下命令：

```shell
export KARPENTER_NAMESPACE="kube-system"
export KARPENTER_VERSION="1.14.1"
export AWS_PARTITION="aws"        # 如果是中国区请替换为 aws-cn
export CLUSTER_NAME="eksworkshop"
export AWS_REGION="ap-southeast-1"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export OIDC_ENDPOINT="$(aws eks describe-cluster --name ${CLUSTER_NAME} \
    --region ${AWS_REGION} --query "cluster.identity.oidc.issuer" --output text)"
```

需要注意两点变化。其一，`KARPENTER_NAMESPACE`设置为`kube-system`，这是Karpenter 1.x版本推荐的部署命名空间；后文所有针对Karpenter的`kubectl`命令都将使用该命名空间。其二，`KARPENTER_VERSION`使用不带`v`前缀的`1.14.1`，这也是1.x版本Helm仓库与镜像标签的命名方式。

执行如下命令确认环境变量已正确取值：

```shell
echo "${CLUSTER_NAME} ${AWS_REGION} ${AWS_ACCOUNT_ID} ${OIDC_ENDPOINT}"
```

返回结果类似如下：

```
eksworkshop ap-southeast-1 133129065110 https://oidc.eks.ap-southeast-1.amazonaws.com/id/D0A7E4BBBBD26CD6E003B94E42FECFD2
```

### 2、创建Karpenter分配的Node使用的IAM Role并绑定策略

执行如下命令创建节点角色的信任策略并创建角色：

```shell
echo '{
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
}' > node-trust-policy.json

aws iam create-role --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
    --assume-role-policy-document file://node-trust-policy.json
```

返回结果如下（节选`Arn`字段）：

```
arn:aws:iam::133129065110:role/KarpenterNodeRole-eksworkshop
```

执行如下命令绑定策略（请确保上一步的环境变量正确）：

```shell
aws iam attach-role-policy --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
    --policy-arn arn:${AWS_PARTITION}:iam::aws:policy/AmazonEKSWorkerNodePolicy
aws iam attach-role-policy --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
    --policy-arn arn:${AWS_PARTITION}:iam::aws:policy/AmazonEKS_CNI_Policy
aws iam attach-role-policy --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
    --policy-arn arn:${AWS_PARTITION}:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly
aws iam attach-role-policy --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
    --policy-arn arn:${AWS_PARTITION}:iam::aws:policy/AmazonSSMManagedInstanceCore
```

没有报错就是执行成功。此处与旧版教程相比有一处调整：容器镜像仓库的只读权限由`AmazonEC2ContainerRegistryReadOnly`更换为权限范围更小的`AmazonEC2ContainerRegistryPullOnly`，仅授予拉取镜像所需的最小权限，这是当前官方文档的推荐做法。

执行如下命令确认策略绑定结果：

```shell
aws iam list-attached-role-policies --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
    --query 'AttachedPolicies[].PolicyName' --output text
```

返回如下四条策略表示绑定成功：

```
AmazonSSMManagedInstanceCore    AmazonEKS_CNI_Policy    AmazonEKSWorkerNodePolicy    AmazonEC2ContainerRegistryPullOnly
```

需要特别说明的是，在Karpenter 1.x版本中，节点使用的实例配置文件（Instance Profile）不再需要手工创建。旧版教程中通过`aws iam create-instance-profile`与`aws iam add-role-to-instance-profile`手工创建实例配置文件的步骤已经取消，改为在后文的`EC2NodeClass`中通过`role`字段声明节点角色，由Karpenter控制器自动创建并维护对应的实例配置文件。因此本步骤到此结束。

### 3、创建Karpenter Controller使用的IAM Role并绑定策略

现在分别创建控制器角色的信任策略`controller-trust-policy`与权限策略`controller-policy`，并将权限策略绑定到`KarpenterControllerRole`角色上。

控制器采用IAM Roles for Service Accounts（IRSA）机制，通过集群的OIDC Provider换取AWS权限。信任策略中的`sub`条件需与后文Karpenter部署的命名空间与服务账户名称一致，即`system:serviceaccount:${KARPENTER_NAMESPACE}:karpenter`（本文为`kube-system:karpenter`）。

执行如下命令：

```shell
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
                    "${OIDC_ENDPOINT#*//}:sub": "system:serviceaccount:${KARPENTER_NAMESPACE}:karpenter"
                }
            }
        }
    ]
}
EOF

aws iam create-role --role-name "KarpenterControllerRole-${CLUSTER_NAME}" \
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
                    "ec2:ResourceTag/karpenter.sh/nodepool": "*"
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
        },
        {
            "Sid": "AllowScopedInstanceProfileCreationActions",
            "Effect": "Allow",
            "Resource": "*",
            "Action": [ "iam:CreateInstanceProfile" ],
            "Condition": {
                "StringEquals": {
                    "aws:RequestTag/kubernetes.io/cluster/${CLUSTER_NAME}": "owned",
                    "aws:RequestTag/topology.kubernetes.io/region": "${AWS_REGION}"
                },
                "StringLike": {
                    "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass": "*"
                }
            }
        },
        {
            "Sid": "AllowScopedInstanceProfileTagActions",
            "Effect": "Allow",
            "Resource": "*",
            "Action": [ "iam:TagInstanceProfile" ],
            "Condition": {
                "StringEquals": {
                    "aws:ResourceTag/kubernetes.io/cluster/${CLUSTER_NAME}": "owned",
                    "aws:ResourceTag/topology.kubernetes.io/region": "${AWS_REGION}",
                    "aws:RequestTag/kubernetes.io/cluster/${CLUSTER_NAME}": "owned",
                    "aws:RequestTag/topology.kubernetes.io/region": "${AWS_REGION}"
                },
                "StringLike": {
                    "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass": "*",
                    "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass": "*"
                }
            }
        },
        {
            "Sid": "AllowScopedInstanceProfileActions",
            "Effect": "Allow",
            "Resource": "*",
            "Action": [
                "iam:AddRoleToInstanceProfile",
                "iam:RemoveRoleFromInstanceProfile",
                "iam:DeleteInstanceProfile"
            ],
            "Condition": {
                "StringEquals": {
                    "aws:ResourceTag/kubernetes.io/cluster/${CLUSTER_NAME}": "owned",
                    "aws:ResourceTag/topology.kubernetes.io/region": "${AWS_REGION}"
                },
                "StringLike": {
                    "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass": "*"
                }
            }
        },
        {
            "Sid": "AllowInstanceProfileReadActions",
            "Effect": "Allow",
            "Resource": "*",
            "Action": "iam:GetInstanceProfile"
        },
        {
            "Sid": "AllowUnscopedInstanceProfileListAction",
            "Effect": "Allow",
            "Resource": "*",
            "Action": "iam:ListInstanceProfiles"
        }
    ],
    "Version": "2012-10-17"
}
EOF

aws iam put-role-policy --role-name "KarpenterControllerRole-${CLUSTER_NAME}" \
    --policy-name "KarpenterControllerPolicy-${CLUSTER_NAME}" \
    --policy-document file://controller-policy.json
```

创建成功后没有额外的报错输出。可执行如下命令确认内联策略已经附加：

```shell
aws iam list-role-policies --role-name "KarpenterControllerRole-${CLUSTER_NAME}" \
    --query 'PolicyNames' --output text
```

返回如下结果表示成功：

```
KarpenterControllerPolicy-eksworkshop
```

与旧版策略相比，此处的控制器权限策略有两处关键变化：其一，实例回收（`ec2:TerminateInstances`）的条件键由旧版的`karpenter.sh/provisioner-name`调整为`karpenter.sh/nodepool`，与新的`NodePool`资源模型对应；其二，新增了`AllowScopedInstanceProfileCreationActions`等一组针对实例配置文件的权限（`iam:CreateInstanceProfile`、`iam:TagInstanceProfile`、`iam:AddRoleToInstanceProfile`、`iam:GetInstanceProfile`、`iam:ListInstanceProfiles`等），这正是前文所述由Karpenter自动管理实例配置文件所必需的授权。

### 4、配置Service Account

在Karpenter 1.x版本中，控制器使用的ServiceAccount（命名空间`kube-system`下名为`karpenter`）由后文的Helm Chart在安装时自动创建，并通过注解绑定到上一步创建的`KarpenterControllerRole`角色，从而完成IRSA的绑定关系。因此本步骤无需再通过`eksctl create iamserviceaccount`单独创建角色，仅需将控制器角色的ARN导出为环境变量，供后文Helm安装时引用。

执行如下命令：

```shell
export KARPENTER_IAM_ROLE_ARN="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterControllerRole-${CLUSTER_NAME}"
echo "${KARPENTER_IAM_ROLE_ARN}"
```

返回结果类似如下：

```
arn:aws:iam::133129065110:role/KarpenterControllerRole-eksworkshop
```

至此控制器的身份与权限准备完成。

### 5、设置Karpenter可使用的Subnet和Security Group并为他们打上标签

在本配置部署说明中，我们假设已经部署好了EKS的Nodegroup，并有AWS Load Balancer Controller等组件，因此可通过AWS CLI获取当前Nodegroup使用的Subnet和Security Group，为其增加`karpenter.sh/discovery`标签。Karpenter将依据该标签自动发现可用于启动节点的子网与安全组。

执行如下命令为子网打标签：

```shell
for NODEGROUP in $(aws eks list-nodegroups --cluster-name ${CLUSTER_NAME} \
    --region ${AWS_REGION} --query 'nodegroups' --output text); do aws ec2 create-tags \
        --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" \
        --resources $(aws eks describe-nodegroup --cluster-name ${CLUSTER_NAME} \
        --region ${AWS_REGION} --nodegroup-name $NODEGROUP \
        --query 'nodegroup.subnets' --output text )
done
```

没有输出额外的信息则表示成功。现在进入VPC服务，进入Subnet子网，查看现有Nodegroup所在的子网，在标签Tag的位置即可看到新的标签名字叫`karpenter.sh/discovery`，值是集群名称`eksworkshop`。这表示打标签成功。

接下来是安全组的标签，执行如下命令：

```shell
SECURITY_GROUPS=$(aws eks describe-cluster \
    --name ${CLUSTER_NAME} --region ${AWS_REGION} \
    --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)

aws ec2 create-tags \
    --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" \
    --resources ${SECURITY_GROUPS}
```

没有输出额外的信息则表示成功。可执行如下命令验证标签生效，确认返回的子网与安全组均属于当前集群所在的VPC：

```shell
aws ec2 describe-subnets --region ${AWS_REGION} \
    --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME}" \
    --query 'Subnets[].{id:SubnetId,vpc:VpcId,az:AvailabilityZone}' --output text
```

返回结果类似如下：

```
ap-southeast-1c	subnet-0f54b0e3e082589d8	vpc-0a69fad178fdc8284
ap-southeast-1a	subnet-0cc67479094982fdf	vpc-0a69fad178fdc8284
ap-southeast-1b	subnet-0fcbf89630d3c64b3	vpc-0a69fad178fdc8284
```

注意：如果账户内曾经运行过其他实验并残留了同名标签的子网，且这些子网位于不同的VPC，Karpenter在发现阶段可能会误选到错误VPC的子网，导致节点启动失败。此时应通过`aws ec2 delete-tags`清除位于其他VPC上的`karpenter.sh/discovery`标签，确保带该标签的子网全部位于当前集群VPC内。

本步骤完成。

### 6、将Karpenter Node Role添加为EKS节点启动者身份

Karpenter拉起的新节点使用前文创建的`KarpenterNodeRole`加入集群，因此需要在集群的鉴权配置中将该节点角色映射为节点启动者身份。由于本文集群的鉴权模式为`API_AND_CONFIG_MAP`，此处沿用`aws-auth` ConfigMap的方式进行映射。

准备如下一段映射配置：

```
- groups:
  - system:bootstrappers
  - system:nodes
  rolearn: arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}
  username: system:node:{{EC2PrivateDNSName}}
```

在这段配置中，需要：

- 替换`${AWS_PARTITION}`为`aws`或者`aws-cn`
- 替换`${AWS_ACCOUNT_ID}`为实际AWS账户ID
- 替换`${CLUSTER_NAME}`为集群名称
- 但是不要替换`{{EC2PrivateDNSName}}`

将该映射写入`aws-auth`有两种方式。第一种是使用`eksctl`一条命令非交互式地完成，推荐在自动化环境下使用：

```shell
eksctl create iamidentitymapping --cluster ${CLUSTER_NAME} --region ${AWS_REGION} \
  --arn arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME} \
  --username "system:node:{{EC2PrivateDNSName}}" \
  --group system:bootstrappers --group system:nodes
```

第二种是手工编辑ConfigMap：

```shell
kubectl edit configmap aws-auth -n kube-system
```

找到和`groups`平级的位置，插入刚才准备好的这一段映射。编辑完成后，`aws-auth`的`mapRoles`中至少包含两段`groups`定义，分别对应现有Nodegroup使用的IAM Role，以及Karpenter Node使用的Role。执行如下命令查看结果：

```shell
kubectl get cm aws-auth -n kube-system -o jsonpath='{.data.mapRoles}'
```

返回结果类似如下：

```
- groups:
  - system:bootstrappers
  - system:nodes
  rolearn: arn:aws:iam::133129065110:role/eksctl-eksworkshop-nodegroup-podsu-NodeInstanceRole-56pwN1mum0sm
  username: system:node:{{EC2PrivateDNSName}}
- groups:
  - system:bootstrappers
  - system:nodes
  rolearn: arn:aws:iam::133129065110:role/KarpenterNodeRole-eksworkshop
  username: system:node:{{EC2PrivateDNSName}}
```

补充说明：EKS较新版本提供了访问条目（Access Entry）作为`aws-auth`的现代替代方案。若集群鉴权模式为`API`（仅访问条目），则应改用`aws eks create-access-entry`创建类型为`EC2_LINUX`的节点访问条目，而非编辑`aws-auth`。本文集群为`API_AND_CONFIG_MAP`模式，两种方式均可，此处采用`aws-auth`以保持流程连贯。

至此权限配置完成。

### 7、准备Helm（如果之前已经安装可跳过）

如果在实验环境的准备阶段已经安装了AWS Load Balancer Controller，那么意味着已经使用过Helm，本步骤可跳过。

如果之前没有安装过，请使用如下命令安装。

在MacOS上，执行如下命令：

```shell
brew install helm
```

在Linux系统上，执行如下命令：

```shell
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
```

在Windows上，建议通过choco包管理程序自动安装，执行如下命令：

```shell
choco install kubernetes-helm
```

如果本机在以前安装过Helm，可执行`helm repo update`命令更新软件仓库。

### 8、部署Karpenter控制器Pod

执行如下命令，通过Helm将Karpenter安装到`kube-system`命名空间：

```shell
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version ${KARPENTER_VERSION} --namespace ${KARPENTER_NAMESPACE} --create-namespace \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${KARPENTER_IAM_ROLE_ARN}" \
  --set settings.clusterName=${CLUSTER_NAME} \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --wait
```

返回结果类似如下：

```
Pulled: public.ecr.aws/karpenter/karpenter:1.14.1
Digest: sha256:...
NAME: karpenter
LAST DEPLOYED: Tue Sep 22 20:12:21 2026
NAMESPACE: kube-system
STATUS: deployed
REVISION: 1
TEST SUITE: None
```

此处的Helm安装参数与旧版有以下差异，需要留意：

- 集群名称参数由`settings.aws.clusterName`简化为`settings.clusterName`。
- 移除了旧版的`settings.aws.defaultInstanceProfile`参数，因为实例配置文件改由后文的`EC2NodeClass`的`role`字段声明并由Karpenter自动创建。
- 中断队列参数由`settings.aws.interruptionQueueName`调整为`settings.interruptionQueue`。该参数用于配合Spot中断、实例健康事件等的优雅处理，属于可选项，需要预先创建对应的SQS队列与EventBridge规则。本文未创建中断队列，因此省略该参数；若生产环境需要处理Spot中断事件，应先创建队列再通过该参数启用。
- Karpenter 1.x的Helm Chart在首次安装时会一并安装`NodePool`、`EC2NodeClass`、`NodeClaim`三类CRD，无需额外手工安装。

执行如下命令确认Karpenter的Pod启动成功：

```shell
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter -o wide
```

返回结果如下：

```
NAME                         READY   STATUS    RESTARTS   AGE   IP             NODE                                                NOMINATED NODE   READINESS GATES
karpenter-84dcdcfb99-fgfqs   1/1     Running   0          53s   100.64.2.175   ip-192-168-69-155.ap-southeast-1.compute.internal   <none>           <none>
karpenter-84dcdcfb99-wp64q   1/1     Running   0          53s   100.64.3.114   ip-192-168-30-108.ap-southeast-1.compute.internal   <none>           <none>
```

这表示Karpenter的控制器Pod（默认两个副本）已经在现有Nodegroup节点上启动正常。

### 9、配置Karpenter NodePool与EC2NodeClass并指定机型

在Karpenter 1.x版本中，旧版的`Provisioner`与`AWSNodeTemplate`两类资源已由`NodePool`（`karpenter.sh/v1`）与`EC2NodeClass`（`karpenter.k8s.aws/v1`）取代。`NodePool`描述与云厂商无关的调度约束，`EC2NodeClass`描述AWS专有配置。二者通过`NodePool`中的`nodeClassRef`（以`group`、`kind`、`name`三段引用）建立关联。

执行以下命令创建`NodePool`与`EC2NodeClass`（其中的集群名称等变量将自动代入）：

```shell
cat << EOF > karpenter-nodepool.yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    metadata:
      labels:
        intent: apps
    spec:
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["2"]
        - key: karpenter.k8s.aws/instance-size
          operator: NotIn
          values: ["nano", "micro", "small", "medium", "large"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      expireAfter: 720h
  limits:
    cpu: 1000
    memory: 1000Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  role: "KarpenterNodeRole-${CLUSTER_NAME}"
  amiSelectorTerms:
    - alias: "al2023@latest"
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}"
EOF

kubectl apply -f karpenter-nodepool.yaml
```

返回结果如下：

```
nodepool.karpenter.sh/default created
ec2nodeclass.karpenter.k8s.aws/default created
```

在上一步的配置文件中，`NodePool`的`requirements`一段指定了容量类型为Spot、架构为amd64（与本文集群节点架构一致），并将机型限定为C、M、R三个实例族、代次大于2、且排除了`large`及以下的较小规格。`disruption`一段声明了整合策略为`WhenEmptyOrUnderutilized`（当节点为空或利用率过低时整合），并通过`consolidateAfter: 1m`设置整合等待时间。`EC2NodeClass`的`role`字段声明节点角色，`amiSelectorTerms`使用`al2023@latest`别名选取最新的Amazon Linux 2023优化镜像。更多参数写法，请参考本文末尾的参考文档。

执行如下命令确认`NodePool`与`EC2NodeClass`就绪：

```shell
kubectl get nodepool,ec2nodeclass
```

返回结果中`READY`列为`True`表示就绪：

```
NAME                            NODECLASS   NODES   READY   AGE
nodepool.karpenter.sh/default   default     0       True    22s

NAME                                     READY   AGE
ec2nodeclass.karpenter.k8s.aws/default   True    22s
```

至此Karpenter部署完成。

## 四、测试Karpenter扩展新的Node

### 1、查看集群现有剩余容量并规划扩展

在触发扩容之前，我们先查看现有集群的剩余容量。此时metrics-server已经作为EKS托管插件存在（详见第五章），可使用`kubectl top node`查看节点资源占用；也可使用`kubectl describe node`查看每个节点的资源请求（Requests）与上限（Limits）分配情况。

执行如下命令：

```shell
kubectl describe node 
```

这个命令会分别列出当前所有节点的资源使用情况。例如如下信息就是某一个节点的剩余资源情况：

```
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests     Limits
  --------           --------     ------
  cpu                1825m (23%)  1200m (15%)
  memory             1324Mi (9%)  1424Mi (9%)
  ephemeral-storage  0 (0%)       0 (0%)
  hugepages-1Gi      0 (0%)       0 (0%)
  hugepages-2Mi      0 (0%)       0 (0%)
Events:              <none>
```

本文测试节点为`t3.2xlarge`，每台有8个vCPU，即每个节点CPU资源约为8000m（可分配约7910m）。集群共有3台此类节点，合计可分配约23.7个vCPU。因此，只要部署一批每个都请求2个vCPU的Pod，当其总请求量超过现有节点扣除系统组件后的剩余量时，就会有Pod因资源不足而处于Pending状态，从而触发Karpenter扩容。

现在我们来验证以上逻辑。

### 2、部署测试应用

为了明显地模拟扩展，测试应用将分配较多的资源。一般场景一个nginx只需要少量内存，但我们这里故意分配2vCPU/4GB，用于明显的资源消耗以更早触发扩容。这个应用起步时候设置replica=1，即只创建1个Pod。

构建如下配置，保存为`demo-nginx-nlb-karpenter.yaml`文件：

```yaml
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
      - image: public.ecr.aws/nginx/nginx:1.31-alpine-slim
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

```shell
kubectl apply -f demo-nginx-nlb-karpenter.yaml
```

### 3、查看应用运行正常

执行如下命令查看已经拉起的Pod。因为replica设置为1，因此可看到有1个Pod。

```shell
kubectl get pods -n nlb-app-karpenter -o wide
```

返回1个Pod与预期一致，且运行在现有Nodegroup节点上：

```
NAME                               READY   STATUS    RESTARTS   AGE   IP             NODE                                                NOMINATED NODE   READINESS GATES
nginx-deployment-645769f7b-8cr4n   1/1     Running   0          5s    100.64.1.201   ip-192-168-54-190.ap-southeast-1.compute.internal   <none>           <none>
```

执行如下命令查看访问入口：

```shell
kubectl get service -n nlb-app-karpenter
```

由此可获得NLB入口：

```
NAME            TYPE           CLUSTER-IP    EXTERNAL-IP                                                                          PORT(S)        AGE
service-nginx   LoadBalancer   10.50.0.252   k8s-nlbappka-servicen-fe94f67d82-c689aa49019bcfc8.elb.ap-southeast-1.amazonaws.com   80:30176/TCP   2m16s
```

使用curl或者浏览器访问NLB地址，可看到访问成功。由此表示Pod启动正常。

### 4、查看Node剩余资源

再次执行命令`kubectl describe node`分别打出所有Node的资源情况，找到上一步启动的那个Pod所在的节点，可看到其CPU请求量已经包含了该Pod的2个vCPU。由于测试节点`t3.2xlarge`共有8个vCPU，考虑到系统组件的占用，每个节点还能再容纳约3个请求2vCPU的Pod。3台节点合计可再容纳约9个此类Pod。

因此，为了用尽现有节点的资源并触发扩容，我们将应用的replica从1直接修改到12，以确保有若干Pod无法在现有节点上调度，从而进入Pending状态并触发Karpenter扩容。

### 5、修改部署扩容

执行如下命令：

```shell
kubectl scale deployment nginx-deployment -n nlb-app-karpenter --replicas 12
```

返回如下：

```
deployment.apps/nginx-deployment scaled
```

等待约1～2分钟时间让Karpenter拉起新的Node，然后继续下一步操作。

### 6、查看Karpenter扩展结果

执行如下命令查看调整Replica导致的Pod扩展状态。刚扩容时，由于现有节点资源不足，部分Pod会处于Pending状态：

```shell
kubectl get pods -n nlb-app-karpenter --no-headers | awk '{print $3}' | sort | uniq -c
```

返回结果类似如下，可看到9个Running、3个Pending：

```
   3 Pending
   9 Running
```

此时Karpenter会为这些Pending的Pod计算并创建新的节点声明（NodeClaim）。执行如下命令查看NodeClaim：

```shell
kubectl get nodeclaims
```

返回结果如下，可看到Karpenter创建了一个Spot类型的NodeClaim，并为其选择了具体机型：

```
NAME            TYPE         CAPACITY   ZONE              NODE                                              READY   AGE
default-jsct2   c4.2xlarge   spot       ap-southeast-1c   ip-192-168-2-97.ap-southeast-1.compute.internal   True    95s
```

需要说明的是，`NodeClaim`是Karpenter 1.x引入的资源，代表一次具体的节点申请，取代了早期版本日志中的`machine`概念。等待约1分钟后，执行如下命令可通过限定特定的标签，查看Karpenter扩容出来的Spot节点：

```shell
kubectl get node -l karpenter.sh/capacity-type=spot -o wide
```

返回结果如下：

```
NAME                                              STATUS   ROLES    AGE   VERSION               INTERNAL-IP    OS-IMAGE                        CONTAINER-RUNTIME
ip-192-168-2-97.ap-southeast-1.compute.internal   Ready    <none>   71s   v1.36.4-eks-a887778   192.168.2.97   Amazon Linux 2023.12.20260914   containerd://2.2.7+unknown
```

以上结果表示新拉起了一台Spot计费模式的节点（本次为`c4.2xlarge`），Kubernetes版本为`v1.36.4`，用于运行扩容出来的Pod。此时再次查看Pod状态，应看到12个Pod全部进入Running：

```shell
kubectl get pods -n nlb-app-karpenter --no-headers | awk '{print $3}' | sort | uniq -c
```

返回结果如下：

```
  12 Running
```

### 7、查看Karpenter扩展过程日志

执行如下命令可查看Karpenter扩展的日志（注意命名空间为`kube-system`）：

```shell
kubectl logs -f -n kube-system -c controller -l app.kubernetes.io/name=karpenter
```

Karpenter 1.x的日志采用结构化JSON格式。扩容过程的关键日志节选如下（为便于阅读已折行）：

```
{"level":"INFO","time":"2026-09-22T12:14:38.255Z","message":"found provisionable pod(s)","controller":"provisioner","Pods":"nlb-app-karpenter/nginx-deployment-645769f7b-pp4zg, nlb-app-karpenter/nginx-deployment-645769f7b-d72nn, nlb-app-karpenter/nginx-deployment-645769f7b-n278x","duration":"100.100974ms"}
{"level":"INFO","time":"2026-09-22T12:14:38.255Z","message":"computed new nodeclaim(s) to fit pod(s)","controller":"provisioner","nodeclaims":1,"pods":3}
{"level":"INFO","time":"2026-09-22T12:14:38.278Z","message":"created nodeclaim","controller":"provisioner","NodePool":{"name":"default"},"NodeClaim":{"name":"default-jsct2"},"requests":{"cpu":"6450m","memory":"12160432128","pods":"7"},"instance-types":"c3.2xlarge, c3.4xlarge, c3.8xlarge, c4.2xlarge, c4.4xlarge and 344 other(s)"}
{"level":"INFO","time":"2026-09-22T12:14:41.903Z","message":"launched nodeclaim","controller":"nodeclaim.lifecycle","NodeClaim":{"name":"default-jsct2"},"provider-id":"aws:///ap-southeast-1c/i-092d859e36dd9ab79","instance-type":"c4.2xlarge","zone":"ap-southeast-1c","capacity-type":"spot","allocatable":{"cpu":"7910m","ephemeral-storage":"17Gi","memory":"13215Mi","pods":"58"}}
{"level":"INFO","time":"2026-09-22T12:15:01.150Z","message":"registered nodeclaim","controller":"nodeclaim.lifecycle","NodeClaim":{"name":"default-jsct2"},"provider-id":"aws:///ap-southeast-1c/i-092d859e36dd9ab79","Node":{"name":"ip-192-168-2-97.ap-southeast-1.compute.internal"}}
{"level":"INFO","time":"2026-09-22T12:15:21.917Z","message":"initialized nodeclaim","controller":"nodeclaim.lifecycle","NodeClaim":{"name":"default-jsct2"},"Node":{"name":"ip-192-168-2-97.ap-southeast-1.compute.internal"},"allocatable":{"cpu":"7910m","memory":"14325300Ki","pods":"58"}}
```

在以上日志中可以看到，Karpenter先发现了3个待调度的Pod（`found provisionable pod(s)`），计算出需要1个新的NodeClaim（`computed new nodeclaim(s)`），随后创建、启动、注册并初始化了该NodeClaim。日志中的`instance-types`字段列出了满足`NodePool`约束的候选机型集合，最终启动的是`c4.2xlarge`（Spot），与前文`NodePool`中指定的C/M/R实例族、代次大于2等约束相符。

由此Karpenter扩容实验完成。

### 8、Node向下缩容

执行如下命令将应用程序的Replica收缩回到1个Pod：

```shell
kubectl scale deployment nginx-deployment -n nlb-app-karpenter --replicas 1
```

缩容后，Spot节点上的Pod被移除，该节点变为仅承载DaemonSet的空闲状态。由于前文`NodePool`配置了`consolidationPolicy: WhenEmptyOrUnderutilized`与`consolidateAfter: 1m`，Karpenter会在节点空闲约1分钟后将其整合回收。等待数分钟后，重复执行查看Pod数量、查看带Spot标签的Node、以及查看Karpenter日志的命令，即可看到缩容完成。缩容整合产生的日志节选如下：

```
{"level":"INFO","time":"2026-09-22T12:19:12.119Z","message":"disrupting node(s)","controller":"disruption","command":"Empty/...: delete: nodepools=[default]: [ip-192-168-2-97.ap-southeast-1.compute.internal] (savings: $0.17)","decision":"delete","disrupted-node-count":1,"replacement-node-count":0,"pod-count":0}
{"level":"INFO","time":"2026-09-22T12:19:12.214Z","message":"tainted node","controller":"node.termination","Node":{"name":"ip-192-168-2-97.ap-southeast-1.compute.internal"},"taint.Key":"karpenter.sh/disrupted","taint.Effect":"NoSchedule"}
{"level":"INFO","time":"2026-09-22T12:20:47.786Z","message":"deleted node","controller":"node.termination","Node":{"name":"ip-192-168-2-97.ap-southeast-1.compute.internal"}}
{"level":"INFO","time":"2026-09-22T12:20:48.153Z","message":"deleted nodeclaim","controller":"nodeclaim.lifecycle","NodeClaim":{"name":"default-jsct2"},"provider-id":"aws:///ap-southeast-1c/i-092d859e36dd9ab79","Node":{"name":"ip-192-168-2-97.ap-southeast-1.compute.internal"}}
```

在以上日志中可以看到，Karpenter判定该Spot节点为空（`Empty`），做出删除决策（并给出预计每小时节省成本），先为节点打上`karpenter.sh/disrupted`污点以阻止新Pod调度，随后删除节点并删除对应的NodeClaim。至此缩容整合完成。

### 9、使用Karpenter小结

从以上实验中可以看到，只要部署应用的Replica数量增加导致现有节点资源不足，Karpenter就会自动创建新的Node，且创建时可根据`NodePool`约束选择机型配置以及容量类型（Spot或On-Demand）；当节点空闲或利用率过低时，Karpenter又会依据整合策略自动回收节点以节省成本。

不过，上一步实验是手工调整的Replica也就是Pod的数量。如果能实现按业务负载自动调整Replica的数量，即可实现自动的整体扩缩容。由此下一步实验将引入HPA，实现业务压力自动缩放Replica。

## 五、部署HPA实现应用Pod的缩放

前文通过Karpenter实现了Node根据资源剩余情况的缩放，接下来使用HPA实现根据访问压力对Pod数量的缩放。接上一步部署Karpenter时候已经存在的应用和Deployment继续操作。注：之前Replica=1或者设置为Replica=3均可。

### 1、部署Metrics Server

HPA依赖Metrics Server提供的CPU、内存等指标数据。在EKS 1.36中，Metrics Server已作为托管插件（EKS add-on）提供，推荐通过插件方式安装与维护。

执行如下命令查看当前集群已安装的插件：

```shell
aws eks list-addons --cluster-name ${CLUSTER_NAME} --region ${AWS_REGION} --output text
```

返回结果如下，如果列表中已包含`metrics-server`，则说明已安装，本步骤可跳过：

```
ADDONS	amazon-cloudwatch-observability
ADDONS	coredns
ADDONS	kube-proxy
ADDONS	metrics-server
ADDONS	vpc-cni
```

如果尚未安装，可通过如下命令以托管插件方式安装：

```shell
aws eks create-addon --cluster-name ${CLUSTER_NAME} --region ${AWS_REGION} \
    --addon-name metrics-server
```

作为替代方案，也可以沿用社区提供的清单文件手工安装（适用于非托管场景）：

```shell
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

采用清单方式安装时，返回结果类似如下：

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

在前一步的部署完成后，还需要等待一段时间让服务启动，然后执行如下命令：

```shell
kubectl get apiservice v1beta1.metrics.k8s.io -o json | jq '.status'
```

如果返回结果如下，则表示部署完成：

```
{
  "conditions": [
    {
      "lastTransitionTime": "2026-09-22T14:42:59Z",
      "message": "all checks passed",
      "reason": "Passed",
      "status": "True",
      "type": "Available"
    }
  ]
}
```

如果没有获得以上结果，那么需要继续等待启动完成。

### 3、验证Metrics Server获取数据正常

执行如下命令查看所有节点负载：

```shell
kubectl top node
```

返回如下信息，能够正常返回各节点的CPU与内存占用即表示Metrics Server工作正常：

```
NAME                                                CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)   
ip-192-168-2-97.ap-southeast-1.compute.internal     1173m        14%      1032Mi          7%          
ip-192-168-30-108.ap-southeast-1.compute.internal   88m          1%       2014Mi          6%          
ip-192-168-54-190.ap-southeast-1.compute.internal   123m         1%       1958Mi          6%          
ip-192-168-69-155.ap-southeast-1.compute.internal   96m          1%       1551Mi          5%          
```

执行如下命令查看所有Namespaces中的Pod信息：

```shell
kubectl top pod -A
```

返回结果较长，这里不再赘述。

如果只希望返回特定Namespaces中的Pod的排行，可执行如下命令：

```shell
kubectl top pod -n nlb-app-karpenter
```

返回结果类似如下：

```
NAME                               CPU(cores)   MEMORY(bytes)   
nginx-deployment-645769f7b-f82nq   1m           3Mi             
```

### 4、配置性能监控并设置HPA弹性阈值

执行如下命令设置HPA。其中`--min=3`表示最小3个Pod，`--max=12`表示最大12个Pod，`--cpu=10%`表示CPU利用率达到10%的阈值后触发扩容。

注意：此处选择10%是为了在测试中快速地实现扩容效果，在生产环境中，一般使用50%或者70%作为扩容阈值。

```shell
kubectl autoscale deployment nginx-deployment -n nlb-app-karpenter --cpu=10% --min=3 --max=12
```

需要特别说明的是，较新版本的`kubectl`已经弃用了旧版的`--cpu-percent`参数，改用`--cpu`参数，其取值可以是百分比（如`10%`表示利用率）或资源量（如`500m`表示毫核）。如果沿用旧版教程使用`--cpu-percent=10`，`kubectl`会给出如下弃用提示：

```
Flag --cpu-percent has been deprecated, Use --cpu with percentage or resource quantity format (e.g., '70%' for utilization or '500m' for milliCPU).
```

命令执行成功后返回信息如下：

```
horizontalpodautoscaler.autoscaling/nginx-deployment autoscaled
```

配置完毕后，可通过如下命令查看HPA的信息：

```shell
kubectl get hpa -n nlb-app-karpenter
```

返回信息如下：

```
NAME               REFERENCE                     TARGETS            MINPODS   MAXPODS   REPLICAS   AGE
nginx-deployment   Deployment/nginx-deployment   cpu: 0%/10%        3         12        3          117s
```

在服务刚启动时候，由于还没有抓取到足够数据，`TARGETS`这一列可能显示`cpu: <unknown>/10%`。过一两分钟后即可正常显示资源实际使用情况。如果没有施压，且当前应用是nginx这种不占用资源的应用，这里一般显示`cpu: 0%/10%`。

如果希望修改刚配置的HPA，则执行如下命令，替换其中的Deployment名称和Namespace名称即可：

```shell
kubectl edit hpa/nginx-deployment -n nlb-app-karpenter
```

至此HPA配置成功。

## 六、对应用施压测试、触发HPA调整Replica实现Pod扩展并触发Karpenter扩充Node

经过以上准备，本实验终于来到了EKS缩放的完整形态，即HPA根据压力缩放Replica调整Pod数量，而Karpenter根据Node资源池剩余情况拉起新Node。下面开始操作。

### 1、启动额外的EC2作为外部的负载生成器

负载生成器可以使用普通的EC2 Linux进行，只要能部署Apache Benchmark工具即可。新部署一台`c6i.xlarge`或者`m6i.xlarge`规格（若使用ARM架构则为`c6g.xlarge`或`m6g.xlarge`）的EC2，系统选择为Amazon Linux 2023操作系统。

压力生成器几个注意事项：

- 考虑到多可用区多AZ分布的问题，需要在本VPC之外的其他VPC来部署。如果只是在与EKS相同VPC上、某个AZ内部署压力负载生成器，那么只有本AZ的Pod和Node会收到压力，这将与预期完全不符
- 压力测试建议不要跨region，在本region获得最大压力效果
- 机型不能太小，建议`c6i.xlarge`或者`m6i.xlarge`规格的EC2
- 另外不要选择t系列，可能会造成CPU算力不足

本例中，将使用Apache Benchmark（简称ab）发起压力测试。执行如下命令安装客户端：

```shell
yum update -y
yum install httpd -y
ab --help
```

由此压力发生器准备完毕。

### 2、查询施压的入口

执行如下命令查看访问入口：

```shell
kubectl get service -n nlb-app-karpenter
```

由此可获得NLB入口：

```
NAME            TYPE           CLUSTER-IP    EXTERNAL-IP                                                                          PORT(S)        AGE
service-nginx   LoadBalancer   10.50.0.252   k8s-nlbappka-servicen-fe94f67d82-c689aa49019bcfc8.elb.ap-southeast-1.amazonaws.com   80:30176/TCP   13m
```

### 3、发起负载

安装Apache Benchmark完成后，执行如下命令生成压力。参数`n`代表请求数量，参数`c`代表并发线程数。访问地址为上一步的NLB地址。本文使用`n=1000000`和`c=500`这个比较大的参数来施压。

注意：本实验启动的Pod是一个空白的nginx，里边没有脚本语言也没有预编译应用，因此其本身的损耗非常低。在做压力测试后，需要通过`-c`参数增加线程对其施加很大的压力，才能让CPU产生明显的负载，从而达到HPA事先指定的阈值。如果是真实生产环境，不要一开始就配置这么大的参数，因为这有可能会导致大量失败，甚至应用程序崩溃异常退出。在真实生产环境上，可以从`n=10000`和`c=10`起步，逐渐增加压力，逐渐过渡到较大且稳定的参数。

在负载生成器上，执行如下命令发起负载：

```shell
ab -n 1000000 -c 500 http://k8s-nlbappka-servicen-fe94f67d82-c689aa49019bcfc8.elb.ap-southeast-1.amazonaws.com/
```

由于EKS默认对HPA的检测周期约为15秒一次，因此负载发生器需要持续产生流量，以确保跨越多个HPA检测周期都能识别到负载的增加。

### 4、观察压力导致的HPA对Replica的调整和Pod扩容

使用如下命令观察HPA对Deployment的Replica的调整：

```shell
kubectl get deployment -n nlb-app-karpenter
```

可看到已经按要求完成了缩放：

```
NAME               READY   UP-TO-DATE   AVAILABLE   AGE
nginx-deployment   12/12   12           12          17h
```

使用如下命令观察Metrics Server采集的CPU负载以及Deployment的Replica的数量：

```shell
kubectl get hpa -n nlb-app-karpenter -w
```

这里加了`-w`参数，表示命令不会退出，而是每隔几秒自动打印出来新的一行，因此就不用反复执行本命令了。返回结果类似如下：

```
NAME               REFERENCE                     TARGETS         MINPODS   MAXPODS   REPLICAS   AGE
nginx-deployment   Deployment/nginx-deployment   cpu: 28%/10%    3         12        12         2m9s
```

由此可以看到，随着CPU利用率上升到28%并超过10%的阈值，HPA已经将Replica从初始的3个自动扩容到上限12个。

### 5、观察Pod增加导致的Node资源池用完然后引起的Node扩容

执行如下命令观察Replica数量变化导致的扩充的Spot节点：

```shell
kubectl get node -l karpenter.sh/capacity-type=spot
```

返回信息类似如下：

```
NAME                                               STATUS   ROLES    AGE   VERSION               INTERNAL-IP     OS-IMAGE                        CONTAINER-RUNTIME
ip-192-168-5-233.ap-southeast-1.compute.internal   Ready    <none>   61s   v1.36.4-eks-a887778   192.168.5.233   Amazon Linux 2023.12.20260914   containerd://2.2.7+unknown
```

同时查看NodeClaim，可看到Karpenter为无法调度的Pod新建的节点声明：

```
NAME            TYPE         CAPACITY   ZONE              NODE                                               READY   AGE
default-fhmt9   c5.2xlarge   spot       ap-southeast-1c   ip-192-168-5-233.ap-southeast-1.compute.internal   True    66s
```

以上信息可看到，HPA根据负载压力将Pod扩容到12个，现有节点资源不足以容纳全部Pod，进而由Karpenter扩展出新的Spot节点（本次为`c5.2xlarge`），为负载压力提供了支持。这就完整串联起了"CPU负载上升→HPA扩容Replica→Pod因资源不足Pending→Karpenter扩容Node"的端到端弹性链路。

至此本实验全部结束。停止负载发生器后，HPA会在其稳定窗口期结束后逐步将Replica缩回最小值，Karpenter随后整合并回收空闲的Spot节点。

## 七、环境清理

注意：本实验复用了实验一创建的共享集群`eksworkshop`。本章仅清理本实验新增的资源，请勿删除整个集群，否则会破坏其他实验依赖的环境。

首先删除测试用应用，执行如下命令：

```shell
kubectl delete hpa nginx-deployment -n nlb-app-karpenter
kubectl delete -f demo-nginx-nlb-karpenter.yaml
```

删除应用后，接下来先删除Karpenter管理的节点资源。如果不先删除，Karpenter在整合过程中仍可能拉起新的Node。执行如下命令删除`NodePool`与`EC2NodeClass`：

```shell
kubectl delete -f karpenter-nodepool.yaml
```

删除后，Karpenter会回收其管理的所有Spot节点。确认没有残留的NodeClaim：

```shell
kubectl get nodeclaims
```

随后卸载Karpenter控制器：

```shell
helm uninstall karpenter --namespace kube-system
```

如果需要进一步清理IAM相关资源，可执行如下命令（可选）。删除IAM角色前需先分离其绑定的策略：

```shell
# 分离并删除节点角色
for p in AmazonEKSWorkerNodePolicy AmazonEKS_CNI_Policy AmazonEC2ContainerRegistryPullOnly AmazonSSMManagedInstanceCore; do
  aws iam detach-role-policy --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
    --policy-arn arn:${AWS_PARTITION}:iam::aws:policy/${p}
done
aws iam delete-role --role-name "KarpenterNodeRole-${CLUSTER_NAME}"

# 删除控制器角色的内联策略并删除角色
aws iam delete-role-policy --role-name "KarpenterControllerRole-${CLUSTER_NAME}" \
    --policy-name "KarpenterControllerPolicy-${CLUSTER_NAME}"
aws iam delete-role --role-name "KarpenterControllerRole-${CLUSTER_NAME}"
```

如需彻底清理，还可移除子网与安全组上的`karpenter.sh/discovery`标签，以及`aws-auth`中为`KarpenterNodeRole`添加的映射条目。这些操作均不影响集群本身的运行。

## 八、小结

本文将Karpenter+HPA的EKS弹性扩缩容实验从早期的EKS 1.27/Karpenter 0.29版本升级适配至EKS 1.36/Karpenter 1.14版本，并在既有集群上完成了全流程验证。核心结论如下：

- Karpenter自1.0起进入正式GA，资源模型由`Provisioner`/`AWSNodeTemplate`演进为`NodePool`/`EC2NodeClass`，控制器默认部署在`kube-system`命名空间，节点实例配置文件改由Karpenter依据`EC2NodeClass`的`role`字段自动管理。
- 控制器IAM策略需要新增一组实例配置文件相关权限，且实例回收条件键调整为`karpenter.sh/nodepool`。
- Helm安装参数简化为`settings.clusterName`，并移除`settings.aws.defaultInstanceProfile`。
- 较新版本的`kubectl`中`kubectl autoscale`的`--cpu-percent`参数已弃用，应改用`--cpu=10%`。
- EKS 1.36的Metrics Server推荐以托管插件方式安装。

推荐的整体弹性方案为：以HPA根据业务负载自动调整应用副本数，以Karpenter根据待调度Pod的资源诉求自动供给与回收节点，二者配合即可实现从Pod到Node的端到端弹性伸缩。对于希望进一步降低运维负担的场景，也可评估EKS Auto Mode，由EKS托管数据平面的计算供给能力。

## 九、参考文档

Karpenter入门指南（Getting Started with Karpenter）：

[https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/](https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/)

从Cluster Autoscaler迁移到Karpenter（既有集群手工安装流程）：

[https://karpenter.sh/docs/getting-started/migrating-from-cas/](https://karpenter.sh/docs/getting-started/migrating-from-cas/)

Karpenter与Kubernetes版本兼容性矩阵：

[https://karpenter.sh/docs/upgrading/compatibility/](https://karpenter.sh/docs/upgrading/compatibility/)

Karpenter NodePool与调度约束参数说明：

[https://karpenter.sh/docs/concepts/scheduling/](https://karpenter.sh/docs/concepts/scheduling/)

Karpenter EC2NodeClass参数说明：

[https://karpenter.sh/docs/concepts/nodeclasses/](https://karpenter.sh/docs/concepts/nodeclasses/)

Kubernetes HorizontalPodAutoscaler Walkthrough：

[https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/)

Amazon EKS Metrics Server托管插件：

[https://docs.aws.amazon.com/eks/latest/userguide/metrics-server.html](https://docs.aws.amazon.com/eks/latest/userguide/metrics-server.html)
