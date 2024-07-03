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
2024-07-03 08:51:09 [ℹ]  will create IAM Open ID Connect provider for cluster "eksworkshop" in "ap-southeast-1"
2024-07-03 08:51:11 [✔]  created IAM Open ID Connect provider for cluster "eksworkshop" in "ap-southeast-1"
```

### 2、创建IAM Policy（请注意区分Global区域和中国区配置文件）

由于EKS版本的不断升级，AWS Load Balancer Controller的版本也在升级，需要的IAM Policy在一段时间内是稳定的，但时间长了（例如几年过去）也会变化，因此建议用最新的Policy。如果您之前在某一个Region使用过EKS服务，那么系统内可能已经有一个旧的Policy了，建议您删除替换为新的。

对于IAM Policy，还区分AWS海外区和中国区。请选择您要部署的区域，下载对应的IAM Policy文件。

#### (1) 全球区域（海外区域）

从Github下载最新的IAM Policy。

```shell
curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
```

如果您从中国大陆地区通过普通互联网，访问Github时候可能会遇到网络连接失败的问题，那么可以从如下网址下载：

```shell
curl -o iam-policy.json https://blogimg.bitipcman.com/workshop/eks101/elb/iam_policy.json
```

#### (2) 中国区域（IAM Policy中带有aws-cn标识）

如果在中国区域使用，可以下载修改过arn标签的如下文件（从Github下载）：

```
curl -o iam-policy_cn.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy_cn.json
```

从中国区访问Github如果遇到下载失败，那么可从如下地址下载：

```
curl -o iam-policy_cn.json https://blogimg.bitipcman.com/workshop/eks101/elb/iam_policy_cn.json
```

#### (3) 创建IAM Policy

创建IAM Policy，执行如下命令。如果您之前创建过旧版本的策略，那么可以从AWS控制台的IAM中找到这个Policy并删掉它，然后重新创建。注意上一步下载的文件如果是中国区的版本，注意文件名的区别。

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
        "CreateDate": "2024-07-03T04:15:12+00:00",
        "UpdateDate": "2024-07-03T04:15:12+00:00"
    }
}
```

此时需要记住这个新建Policy的ARN ID，下一步创建角色时候将会使用。注意中国区和Global区域的ARN标识是不同的，在中国区ARN中的标识是`aws-cn`，多含一个 `-cn` 后缀。

### 3、创建EKS Service Account

执行如下命令。请替换cluster名称、attach-policy-arn、region等参数为本次实验环境的参数。其他参数保持不变。

```
eksctl create iamserviceaccount \
  --cluster=eksworkshop \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn=arn:aws:iam::133129065110:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve
```

配置成功返回如下信息。

```
2024-07-03 12:16:02 [ℹ]  1 iamserviceaccount (kube-system/aws-load-balancer-controller) was included (based on the include/exclude rules)
2024-07-03 12:16:02 [!]  serviceaccounts that exist in Kubernetes will be excluded, use --override-existing-serviceaccounts to override
2024-07-03 12:16:02 [ℹ]  1 task: {
    2 sequential sub-tasks: {
        create IAM role for serviceaccount "kube-system/aws-load-balancer-controller",
        create serviceaccount "kube-system/aws-load-balancer-controller",
    } }2024-07-03 12:16:02 [ℹ]  building iamserviceaccount stack "eksctl-eksworkshop-addon-iamserviceaccount-kube-system-aws-load-balancer-controller"
2024-07-03 12:16:02 [ℹ]  deploying stack "eksctl-eksworkshop-addon-iamserviceaccount-kube-system-aws-load-balancer-controller"
2024-07-03 12:16:02 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-addon-iamserviceaccount-kube-system-aws-load-balancer-controller"
2024-07-03 12:16:33 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-addon-iamserviceaccount-kube-system-aws-load-balancer-controller"
2024-07-03 12:16:34 [ℹ]  created serviceaccount "kube-system/aws-load-balancer-controller"
```

### 4、通过Helm安装Load Balancer Controller

在之前EKS版本上，主要通过`Kubernetes manifest`来安装Load Balancer Controller。为了简化部署过程，后续都推家使用Helm来安装。以前manifest安装方法可从本文末尾的参考文档中获取。

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
LAST DEPLOYED: Wed Jul  3 12:21:16 2024
NAMESPACE: kube-system
STATUS: deployed
REVISION: 1
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
aws-load-balancer-controller   2/2     2            2           88s
```

表示部署成功，控制器已经正常启动。

此时只是配置好了AWS Load Balancer Ingress Controller所需要的Controller对应的Pod，如果现在去查看EC2控制台的ELB界面是看不到有负载均衡被提前创建出来的。每个应用可以在自己的yaml中定义负载均衡器相关参数，然后随着应用的pod一起一起创建负载均衡。

### 5、为要创建ALB负载均衡器的VPC和Subnet打标签

在创建EKS的第一步，需要选择是由eksctl新创建VPC还是使用现有VPC。如果是新创建VPC，那么eksctl已经自动加上了对应的标签，本步骤可以跳过。如果是使用的现有VPC创建的DNS，那么需要手工配置如下标签。

找到当前的VPC，找到有NAT Gateway的Public Subnet，为其添加标签，标签中的集群名称`eksworkshop`请替换为实际使用的集群名称。（如果标签已经存在请跳过）

- 标签名称：kubernetes.io/role/elb，值：1

接下来进入Private subnet，为其添加标签：

- 标签名称：kubernetes.io/role/internal-elb，值：1

接下来请重复以上工作，多个AZ的子网都实施相同的配置，注意标签的值（Value）都是数字1。

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
      - image: public.ecr.aws/nginx/nginx:1.27-alpine-slim
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
Address:          k8s-mydemo-ingressf-ecff36a9c4-1779793606.ap-southeast-1.elb.amazonaws.com
Ingress Class:    alb
Default backend:  <default>
Rules:
  Host        Path  Backends
  ----        ----  --------
  *
              /   nginx:80 (192.168.11.46:80,192.168.56.82:80,192.168.88.25:80)
Annotations:  alb.ingress.kubernetes.io/scheme: internet-facing
              alb.ingress.kubernetes.io/target-type: ip
Events:
  Type    Reason                  Age    From     Message
  ----    ------                  ----   ----     -------
  Normal  SuccessfullyReconciled  3m57s  ingress  Successfully reconciled
```

此外也可以只查看入口地址，执行如下命令可查看。命令后边没有加 -n 的参数表示是在default namespace，如果是在其他name space下需要使用 -n namespace名字 的方式声明要查询的命名空间。

```
kubectl get ingress -n mydemo
```

返回结果：

```
NAME                    CLASS   HOSTS   ADDRESS                                                                      PORTS   AGE
ingress-for-nginx-app   alb     *       k8s-mydemo-ingressf-ecff36a9c4-1779793606.ap-southeast-1.elb.amazonaws.com   80      4m25s
```

使用浏览器访问ALB的地址，即可看到应用部署成功。

### 3、删除实验环境（可选）

本步骤为可选，实验环境也可以继续保留，用于后续测试。

执行如下命令：

```
kubectl delete -f nginx-app.yaml
kubectl delete namespaces mydemo
```

至此实验完成。

## 三、参考文档

Install the AWS Load Balancer Controller using Helm

[https://docs.aws.amazon.com/eks/latest/userguide/lbc-helm.html]()

Install the AWS Load Balancer Controller add-on using Kubernetes Manifests

[https://docs.aws.amazon.com/eks/latest/userguide/lbc-manifest.html]()