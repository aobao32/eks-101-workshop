# 实验二、部署AWS Load Balancer Controller

EKS 1.30版本 @2024-07 AWS Global区域测试通过

## 一、部署AWS Load Balancer Controller

### 1、为EKS生成IAM的OIDC授权

执行如下命令。请注意替换集群名称和区域为实际操作的环境。

```
eksctl utils associate-iam-oidc-provider --region ap-southeast-1 --cluster eksworkshop --approve
```

返回信息如下表示成功。

```
2026-09-18 16:08:37 [ℹ]  will create IAM Open ID Connect provider for cluster "eksworkshop" in "ap-southeast-1"
2026-09-18 16:08:38 [✔]  created IAM Open ID Connect provider for cluster "eksworkshop" in "ap-southeast-1"
```

### 2、创建IAM Policy（请注意区分Global区域和中国区配置文件）

由于EKS版本的不断升级，AWS Load Balancer Controller的版本也在升级，需要的IAM Policy在一段时间内是稳定的，但时间长了（例如几年过去）也会变化，因此建议用最新的Policy。如果您之前在某一个Region使用过EKS服务，那么系统内可能已经有一个旧的Policy了，建议您删除替换为新的。

注意：本步骤必须从上游仓库获取当前最新的IAM Policy，使用过期的策略文件会导致后续的ALB创建完全失败。实测中若策略文件不完整，Ingress会持续输出`FailedDeployModel`告警事件，报错为`AccessDenied`，典型的缺失项是`elasticloadbalancing:DescribeListenerAttributes`，此时`kubectl get ingress`返回的`ADDRESS`列始终为空，负载均衡器不会被创建。控制器v3.5.0依赖如下九项权限，其中前三项用于安全组与路由表的自动探测，其余六项用于监听器属性、容量预留与规则优先级的读写，读者可在创建策略后核对这些条目是否齐备：

```
ec2:GetSecurityGroupsForVpc
ec2:DescribeIpamPools
ec2:DescribeRouteTables
elasticloadbalancing:DescribeListenerAttributes
elasticloadbalancing:ModifyListenerAttributes
elasticloadbalancing:DescribeCapacityReservation
elasticloadbalancing:ModifyCapacityReservation
elasticloadbalancing:ModifyIpPools
elasticloadbalancing:SetRulePriorities
```

将策略更新为最新版本后，控制器无需重启即可自行重试，实测在约一分钟内输出`SuccessfullyReconciled`并完成ALB创建，不需要删除重建Ingress资源。

对于IAM Policy，还区分AWS海外区和中国区。请选择您要部署的区域，下载对应的IAM Policy文件。

#### (1) 全球区域（海外区域）

从Github下载最新的IAM Policy。

```shell
curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
```

如果您从中国大陆地区通过普通互联网，访问Github时候可能会遇到网络连接失败的问题，那么可以从如下网址下载：

```shell
curl -o iam_policy.json https://blogimg.bitipcman.com/workshop/eks101/elb/iam_policy.json
```

#### (2) 中国区域（IAM Policy中带有aws-cn标识）

如果在中国区域使用，可以下载修改过arn标签的如下文件（从Github下载）：

```
curl -o iam_policy_cn.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy_cn.json
```

从中国区访问Github如果遇到下载失败，那么可从如下地址下载：

```
curl -o iam_policy_cn.json https://blogimg.bitipcman.com/workshop/eks101/elb/iam_policy_cn.json
```

#### (3) 创建IAM Policy

创建IAM Policy，执行如下命令。请注意上一步下载的文件如果是中国区的版本，则需要把命令中的文件名替换为`iam_policy_cn.json`。

```
aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam_policy.json
```

返回如下结果表示成功。

```
{
    "Policy": {
        "PolicyName": "AWSLoadBalancerControllerIAMPolicy",
        "PolicyId": "ANPAR57Y4KKLBSWJ4A2NG",
        "Arn": "arn:aws:iam::133129065110:policy/AWSLoadBalancerControllerIAMPolicy",
        "Path": "/",
        "DefaultVersionId": "v1",
        "AttachmentCount": 0,
        "PermissionsBoundaryUsageCount": 0,
        "IsAttachable": true,
        "CreateDate": "2026-09-18T08:09:47+00:00",
        "UpdateDate": "2026-09-18T08:09:47+00:00"
    }
}
```

此时需要记住这个新建Policy的ARN ID，下一步创建角色时候将会使用。注意中国区和Global区域的ARN标识是不同的，在中国区ARN中的标识是`aws-cn`，多含一个 `-cn` 后缀。

如果账号内已经存在同名的旧策略，上述命令会返回如下报错而不会覆盖原有内容：

```
An error occurred (EntityAlreadyExists) when calling the CreatePolicy operation: A policy called AWSLoadBalancerControllerIAMPolicy already exists. Duplicate names are not allowed.
```

处理该情况有两种方式。第一种是从AWS控制台的IAM界面找到这个策略并删除，然后重新执行上述创建命令；但删除前必须确认该策略未被任何角色或用户附加，否则会影响正在运行的其他集群。第二种方式更为稳妥，即不删除策略而是为其追加一个新版本并设为默认版本，执行如下命令，其中ARN替换为实际的策略ARN：

```
aws iam create-policy-version \
    --policy-arn arn:aws:iam::133129065110:policy/AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam_policy.json \
    --set-as-default
```

返回结果如下，`VersionId`递增表示新版本已生效：

```
{
    "PolicyVersion": {
        "VersionId": "v2",
        "IsDefaultVersion": true,
        "CreateDate": "2026-09-18T08:09:47+00:00"
    }
}
```

采用第二种方式的优势在于旧版本会被保留，若新策略引入问题可通过`aws iam set-default-policy-version`快速回退，同时已附加该策略的角色无需重新绑定。需要注意的是单个IAM策略最多保留五个版本，超出后需要先用`aws iam delete-policy-version`清理历史版本。

### 3、创建EKS Service Account

执行如下命令。请替换cluster名称、region、attach-policy-arn等参数为本次实验环境的参数。其他参数保持不变。

```
eksctl create iamserviceaccount \
  --cluster=eksworkshop \
  --region=ap-southeast-1 \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn=arn:aws:iam::133129065110:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve
```

注意：上述命令中的`--region`参数不可省略。若省略该参数，eksctl会回退到AWS CLI配置文件中的默认区域，当默认区域与集群所在区域不一致时，命令会因找不到集群而中止。可执行`aws configure get region`确认当前默认区域，若与集群区域不同则必须显式指定。

配置成功返回如下信息。

```
2026-09-18 16:10:00 [ℹ]  1 iamserviceaccount (kube-system/aws-load-balancer-controller) was included (based on the include/exclude rules)
2026-09-18 16:10:00 [!]  serviceaccounts that exist in Kubernetes will be excluded, use --override-existing-serviceaccounts to override
2026-09-18 16:10:00 [ℹ]  1 task: {
    2 sequential sub-tasks: {
        create IAM role for serviceaccount "kube-system/aws-load-balancer-controller",
        create serviceaccount "kube-system/aws-load-balancer-controller",
    } }2026-09-18 16:10:00 [ℹ]  building iamserviceaccount stack "eksctl-eksworkshop-addon-iamserviceaccount-kube-system-aws-load-balancer-controller"
2026-09-18 16:10:01 [ℹ]  deploying stack "eksctl-eksworkshop-addon-iamserviceaccount-kube-system-aws-load-balancer-controller"
2026-09-18 16:10:01 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-addon-iamserviceaccount-kube-system-aws-load-balancer-controller"
2026-09-18 16:10:32 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-addon-iamserviceaccount-kube-system-aws-load-balancer-controller"
2026-09-18 16:10:33 [ℹ]  created serviceaccount "kube-system/aws-load-balancer-controller"
```

### 4、通过Helm安装Load Balancer Controller

AWS Load Balancer Controller以Helm作为标准部署方式，本文实测所使用的Helm chart版本为3.5.0，对应的控制器镜像为`public.ecr.aws/eks/aws-load-balancer-controller:v3.5.0`。除Helm之外，AWS官方文档也提供基于Kubernetes manifest的部署方式，相关链接列于本文末尾的参考文档章节，但manifest方式需要手工维护CRD与RBAC定义，因此本文统一采用Helm部署。

控制器v3对IAM权限的要求高于早期发布的策略文件，必须配合上一节所述的最新IAM Policy使用，否则负载均衡器无法创建。

#### （1）操作环境安装Helm

在MacOS下执行如下命令：

```
brew install helm
```

在Windows下执行如下命令：

```
choco install kubernetes-helm
```

在Amazon Linux 2023下：

```
sudo dnf install helm
```

#### （2）安装Helm的软件库

执行如下命令：

```
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks
```

添加完成后，建议执行如下命令确认仓库中当前提供的chart版本，以便与本文实测版本作对照：

```
helm search repo eks/aws-load-balancer-controller
```

返回结果如下：

```
NAME                              CHART VERSION   APP VERSION   DESCRIPTION
eks/aws-load-balancer-controller  3.5.0           v3.5.0        AWS Load Balancer Controller Helm chart for Kub...
```

上述`CHART VERSION`与`APP VERSION`会随上游发布而持续更新，读者以实际返回值为准。若返回的版本低于本文所列版本，说明本地Helm仓库缓存未刷新，需要重新执行`helm repo update eks`。

#### （3）运行Load Balancer Controller

请替换如下命令的集群名称为真实名称：

```
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=eksworkshop \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
```

注意：如果使用的是EKS Fargate，则还需要添加`--set region=region-code`和`--set vpcId=vpc-xxxxxxxx`两个参数。由于本实验使用的是EKS EC2模式，因此不需要这两个参数了。

部署成功返回信息如下：

```
NAME: aws-load-balancer-controller
LAST DEPLOYED: Fri Sep 18 16:11:05 2026
NAMESPACE: kube-system
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
TEST SUITE: None
NOTES:
AWS Load Balancer controller installed!
```

#### （4）检查部署结果

在创建AWS Load Balancer Controller后，等待几分钟启动完成，执行如下命令检查部署结果：

```
kubectl get deployment -n kube-system aws-load-balancer-controller
```

返回结果如下：

```
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
aws-load-balancer-controller   2/2     2            2           55s
```

表示部署成功，控制器已经正常启动。

此外还可以执行如下两条命令，分别确认实际运行的控制器镜像版本，以及确认由控制器自动注册的IngressClass资源：

```
kubectl get deployment -n kube-system aws-load-balancer-controller -o jsonpath='{.spec.template.spec.containers[0].image}'
kubectl get ingressclass
```

返回结果如下，`alb`这个IngressClass由控制器在启动时自动创建，后续应用清单中的`ingressClassName: alb`正是引用此处的名称：

```
public.ecr.aws/eks/aws-load-balancer-controller:v3.5.0

NAME   CONTROLLER            PARAMETERS   AGE
alb    ingress.k8s.aws/alb   <none>       68s
```

此时只是配置好了AWS Load Balancer Ingress Controller所需要的Controller对应的Pod，如果现在去查看EC2控制台的ELB界面是看不到有负载均衡被提前创建出来的。每个应用可以在自己的yaml中定义负载均衡器相关参数，然后随着应用的pod一起创建负载均衡。

### 5、为要创建ALB负载均衡器的VPC和Subnet打标签

在创建EKS的第一步，需要选择是由eksctl新创建VPC还是使用现有VPC。如果是新创建VPC，那么eksctl已经自动加上了对应的标签，本步骤可以跳过。如果是使用的现有VPC创建的集群，那么需要手工配置如下标签。

找到当前的VPC，找到有NAT Gateway的Public Subnet，为其添加标签。（如果标签已经存在请跳过）

- 标签名称：kubernetes.io/role/elb，值：1

接下来进入Private subnet，为其添加标签：

- 标签名称：kubernetes.io/role/internal-elb，值：1

接下来请重复以上工作，多个AZ的子网都实施相同的配置，注意标签的值（Value）都是数字1。

上述两个标签均不包含集群名称，因此在同一个VPC内运行多个集群时无需为每个集群重复打标签，控制器v3也不要求子网额外携带`kubernetes.io/cluster/<集群名称>`形式的归属标签。

若使用eksctl新建VPC，可执行如下命令核对标签是否已自动生成，其中VPC ID通过查询集群配置获得：

```
VPC=$(aws eks describe-cluster --name eksworkshop --region ap-southeast-1 --query 'cluster.resourcesVpcConfig.vpcId' --output text)
aws ec2 describe-subnets --region ap-southeast-1 --filters Name=vpc-id,Values=$VPC \
  --query 'Subnets[].{Subnet:SubnetId,AZ:AvailabilityZone,Tags:Tags[?starts_with(Key,`kubernetes.io/role`)].[Key,Value]}' --output json
```

实测返回结果中，三个Public Subnet携带`kubernetes.io/role/elb`标签，三个Private Subnet携带`kubernetes.io/role/internal-elb`标签，值均为1，确认eksctl已完成自动打标，无需人工干预。

## 二、部署使用ALB Ingress的测试应用

### 1、部署应用

构建应用配置文件。

```
---
apiVersion: v1
kind: Namespace
metadata:
  name: mydemo
---
apiVersion: apps/v1
kind: Deployment
metadata:
  namespace: mydemo
  name: nginx
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
---
apiVersion: v1
kind: Service
metadata:
  namespace: mydemo
  name: nginx
spec:
  ports:
    - port: 80
      targetPort: 80
      protocol: TCP
  type: NodePort
  selector:
    app.kubernetes.io/name: nginx
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  namespace: mydemo
  name: ingress-for-nginx-app
  labels:
    app: ingress-for-nginx-app
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
spec:
  ingressClassName: alb
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nginx
            port:
              number: 80

```

上述清单中的容器镜像使用了`public.ecr.aws/nginx/nginx:1.31-alpine-slim`，该标签为次版本浮动标签，实测解析到的实际版本为nginx/1.31.6，并且同时提供amd64与arm64两种架构的镜像，因此在Graviton处理器的节点上同样可以直接运行。若读者需要固定到确切的补丁版本以保证可重现性，可将标签替换为完整的三段式版本号。

将上述配置文件保存为`nginx-app.yaml`。然后执行如下命令启动：

```
kubectl apply -f nginx-app.yaml
```

返回结果如下表示已经创建：

```
namespace/mydemo created
deployment.apps/nginx created
service/nginx created
ingress.networking.k8s.io/ingress-for-nginx-app created
```

### 2、查看部署效果

在创建并等待几分钟后，运行如下命令查看部署：

```
kubectl describe ingress -n mydemo
```

返回结果如下：

```
Name:             ingress-for-nginx-app
Labels:           app=ingress-for-nginx-app
Namespace:        mydemo
Address:          k8s-mydemo-ingressf-ecff36a9c4-1777573605.ap-southeast-1.elb.amazonaws.com
Ingress Class:    alb
Default backend:  <default>
Rules:
  Host        Path  Backends
  ----        ----  --------
  *
              /   nginx:80 (192.168.95.81:80,192.168.13.68:80,192.168.38.43:80)
Annotations:  alb.ingress.kubernetes.io/scheme: internet-facing
              alb.ingress.kubernetes.io/target-type: ip
Events:
  Type    Reason                  Age   From     Message
  ----    ------                  ----  ----     -------
  Normal  SuccessfullyReconciled  46s   ingress  Successfully reconciled
```

上述`Backends`一列显示的是三个Pod的IP地址而非节点地址，这是`alb.ingress.kubernetes.io/target-type: ip`注解生效的结果，流量由ALB直接转发到Pod，不再经过节点的NodePort跳转。若`Events`中出现`FailedDeployModel`类型的Warning而非`SuccessfullyReconciled`，且`Address`一列为空，请回到第一章第2节核对IAM Policy是否为最新版本。

此外也可以只查看入口地址，执行如下命令可查看。命令后边没有加 -n 的参数表示是在default namespace，如果是在其他name space下需要使用 -n namespace名字 的方式声明要查询的命名空间。

```
kubectl get ingress -n mydemo
```

返回结果：

```
NAME                    CLASS   HOSTS   ADDRESS                                                                      PORTS   AGE
ingress-for-nginx-app   alb     *       k8s-mydemo-ingressf-ecff36a9c4-1777573605.ap-southeast-1.elb.amazonaws.com   80      4m25s
```

需要说明的是，`ADDRESS`列出现域名仅表示控制器已经完成ALB的创建调用，此时负载均衡器本身仍可能处于`provisioning`状态，实测约需2至3分钟才会转为`active`，目标组内的Pod也需要通过健康检查后才能承接流量。可执行如下命令确认负载均衡器状态与目标健康状况：

```
aws elbv2 describe-load-balancers --region ap-southeast-1 --query 'LoadBalancers[?contains(DNSName,`k8s-mydemo`)].{Name:LoadBalancerName,State:State.Code,Type:Type,Scheme:Scheme}' --output table
TG=$(aws elbv2 describe-target-groups --region ap-southeast-1 --query 'TargetGroups[?contains(TargetGroupName,`k8s-mydemo`)].TargetGroupArn' --output text)
aws elbv2 describe-target-health --region ap-southeast-1 --target-group-arn $TG --query 'TargetHealthDescriptions[].{Target:Target.Id,Port:Target.Port,State:TargetHealth.State}' --output table
```

返回结果如下，`State`为`active`且三个目标均为`healthy`时表示可以正常访问：

```
--------------------------------------
|        DescribeTargetHealth        |
+------+-----------+-----------------+
| Port |   State   |     Target      |
+------+-----------+-----------------+
|  80  |  healthy  |  192.168.95.81  |
|  80  |  healthy  |  192.168.13.68  |
|  80  |  healthy  |  192.168.38.43  |
+------+-----------+-----------------+
```

使用浏览器访问ALB的地址，即可看到应用部署成功。也可以在命令行上通过curl验证，执行如下命令：

```
ALB=$(kubectl get ingress -n mydemo ingress-for-nginx-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s -m 10 -o /dev/null -w "HTTP %{http_code}  耗时 %{time_total}s\n" "http://$ALB"
```

返回结果如下表示访问成功：

```
HTTP 200  耗时 0.375507s
```

### 3、删除实验环境（可选）

本步骤为可选，实验环境也可以继续保留，用于后续测试。

执行如下命令：

```
kubectl delete -f nginx-app.yaml
kubectl delete namespaces mydemo
```

删除Ingress资源后，控制器会自动回收对应的ALB与目标组，该过程需要数十秒。在删除整个集群之前务必先完成本步骤，否则残留的负载均衡器及其ENI会导致VPC删除失败。可执行如下命令确认负载均衡器已被回收，返回空值表示回收完成：

```
aws elbv2 describe-load-balancers --region ap-southeast-1 --query 'LoadBalancers[?contains(DNSName,`k8s-mydemo`)].LoadBalancerName' --output text
```

至此实验完成。

## 三、参考文档

Install the AWS Load Balancer Controller using Helm

[https://docs.aws.amazon.com/eks/latest/userguide/lbc-helm.html](https://docs.aws.amazon.com/eks/latest/userguide/lbc-helm.html)

Install the AWS Load Balancer Controller add-on using Kubernetes Manifests

[https://docs.aws.amazon.com/eks/latest/userguide/lbc-manifest.html](https://docs.aws.amazon.com/eks/latest/userguide/lbc-manifest.html)

AWS Load Balancer Controller项目仓库，其中`docs/install/iam_policy.json`为本文所使用的IAM Policy的上游出处：

[https://github.com/kubernetes-sigs/aws-load-balancer-controller](https://github.com/kubernetes-sigs/aws-load-balancer-controller)

AWS Load Balancer Controller官方文档中的Ingress注解完整列表：

[https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/annotations/](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/annotations/)

IAM策略版本管理，用于替换已存在的同名策略：

[https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_managed-versioning.html](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_managed-versioning.html)