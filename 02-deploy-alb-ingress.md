# 实验二、部署AWS Load Balancer Controller

EKS 1.27版本 @2023-06 AWS Global区域测试通过

## 一、部署AWS Load Balancer Controller

### 1、为EKS生成IAM的OIDC授权

执行如下命令。请注意替换集群名称和区域为实际操作的环境。

```
eksctl utils associate-iam-oidc-provider --region ap-southeast-1 --cluster eksworkshop --approve
```

### 2、创建IAM Policy（请注意区分Global区域和中国区配置文件）

下载已经预先配置好的IAM策略到本地，保持iam-policy.json的文件名。另外请注意，本文使用的ALB ingress是2.x，因此IAM policy与之前1.x的版本不通用，请注意部署时候才用正确的版本。

```
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.4.7/docs/install/iam_policy.json
```

如果实验环境位于中国区，从Github的文件服务器下载文件失败，那么可以从如下实验用网址下载：

```
curl -O https://myworkshop.bitipcman.com/eks101/iam_policy.json
```

另外请注意：刚下载到的iam_policy.json是匹配AWS Global Region的，如果在中国区域使用，可以下载修改过arn标签的如下文件：

```
curl -O https://myworkshop.bitipcman.com/eks101/iam_policy-cn.json
```

创建IAM Policy，执行如下命令。注意上一步下载的文件如果是中国区的版本，注意文件名的区别。

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
        "PolicyId": "ANPAVSPQIF7MX2RY22JRH",
        "Arn": "arn:aws:iam::383292813273:policy/AWSLoadBalancerControllerIAMPolicy",
        "Path": "/",
        "DefaultVersionId": "v1",
        "AttachmentCount": 0,
        "PermissionsBoundaryUsageCount": 0,
        "IsAttachable": true,
        "CreateDate": "2023-06-13T00:53:37+00:00",
        "UpdateDate": "2023-06-13T00:53:37+00:00"
    }
}
```

此时需要记住这个新建Policy的ARN ID，下一步创建角色时候将会使用。注意中国区和Global区域的ARN标识是不同的，在中国区ARN中的标识是`aws-cn`，多含一个 `-cn` 后缀。

### 3、创建EKS Service Account

执行如下命令。请替换cluster、attach-policy-arn、region等参数为本次实验环境的参数。其他参数保持不变。

```
eksctl create iamserviceaccount \
  --cluster=eksworkshop \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn=arn:aws:iam::383292813273:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve
```

部署成功。

### 4、通过Helm安装Load Balancer Controller

在之前EKS 1.22～1.25版本上，可通过`Kubernetes manifest`来安装Load Balancer Controller。为了简化部署过程，这里可以使用Helm来安装。以前的安装方法备选，详细信息可从本文末尾的参考文档中获取`Kubernetes manifest`方式。

#### （1）安装Helm

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

#### （4）检查部署结果

在创建AWS Load Balancer Controller后，等待几分钟启动完成，执行如下命令检查部署结果：

```
kubectl get deployment -n kube-system aws-load-balancer-controller
```

返回结果如下：

```
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
aws-load-balancer-controller   2/2     2            2           42s
```

表示部署成功，控制器已经正常启动。

此时只是配置好了AWS Load Balancer Ingress Controller所需要的Controller对应的Pod，如果现在去查看EC2控制台的ELB界面，是看不到有负载均衡被创建出来的。接下来的步骤部署应用时候将随应用一起创建ALB。

### 5、为要创建ALB负载均衡器的VPC和Subnet打标签

注意：在以前需要手工为EKS使用的Public Subnet和Private Subnet打标签。在新版eksctl上自动创建的VPC是可包含Public subnet和Private Subnet的，已经都具有了对应的标签，不需要再手工打标签了。因此如果是使用eksctl自动创建了新的VPC，本步骤可以略过。

如果是使用现有VPC，在创建EKS和Nodegroup时候手工指定了现有子网，那么还是需要为现有子网打标签。

找到当前的VPC，找到有NAT Gateway的Public Subnet，为其添加标签，标签中的集群名称`eksworkshop`请替换为实际使用的集群名称。（如果标签已经存在请跳过）

- 标签名称：kubernetes.io/role/elb，值：1

接下来进入Private subnet，为其添加标签：

- 标签名称：kubernetes.io/role/internal-elb，值：1

接下来请重复以上工作，三个AZ的子网都实施相同的配置，注意第一项标签值都是数字1。

## 二、部署使用ALB Ingress的2048应用

### 1、部署应用

构建2048应用的配置文件。

```
---
apiVersion: v1
kind: Namespace
metadata:
  name: game-2048
---
apiVersion: apps/v1
kind: Deployment
metadata:
  namespace: game-2048
  name: deployment-2048
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: app-2048
  replicas: 3
  template:
    metadata:
      labels:
        app.kubernetes.io/name: app-2048
    spec:
      containers:
      - image: public.ecr.aws/l6m2t8p7/docker-2048:latest
        imagePullPolicy: Always
        name: app-2048
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  namespace: game-2048
  name: service-2048
spec:
  ports:
    - port: 80
      targetPort: 80
      protocol: TCP
  type: NodePort
  selector:
    app.kubernetes.io/name: app-2048
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  namespace: game-2048
  name: ingress-2048
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
spec:
  rules:
    - http:
        paths:
        - path: /
          pathType: Prefix
          backend:
            service:
              name: service-2048
              port:
                number: 80
```

将上述配置文件保存为`2048.yaml`。然后执行如下命令启动：

```
kubectl apply -f 2048.yaml
```

如果不希望编辑、保存配置文件，希望直接从网络启动，那么可执行如下命令直接启动：

```
kubectl apply -f https://myworkshop.bitipcman.com/eks101/2048_full_latest.yaml
```

返回结果如下表示已经创建：

```
namespace/game-2048 created
deployment.apps/deployment-2048 created
service/service-2048 created
ingress.networking.k8s.io/ingress-2048 created
```

### 2、查看部署效果

在创建并等待几分钟后，运行如下命令查看部署：

```
kubectl describe ingress -n game-2048
```

返回结果如下：

```
Name:             ingress-2048
Labels:           <none>
Namespace:        game-2048
Address:          k8s-game2048-ingress2-2810c0c2ad-1325099403.ap-southeast-1.elb.amazonaws.com
Ingress Class:    alb
Default backend:  <default>
Rules:
  Host        Path  Backends
  ----        ----  --------
  *           
              /   service-2048:80 (192.168.47.150:80,192.168.6.169:80,192.168.82.98:80)
Annotations:  alb.ingress.kubernetes.io/scheme: internet-facing
              alb.ingress.kubernetes.io/target-type: ip
Events:
  Type    Reason                  Age   From     Message
  ----    ------                  ----  ----     -------
  Normal  SuccessfullyReconciled  26s   ingress  Successfully reconciled
```

此外也可以只查看入口地址，执行如下命令可查看。命令后边没有加 -n 的参数表示是在default namespace，如果是在其他name space下需要使用 -n namespace名字 的方式声明要查询的命名空间。

```
kubectl get ingress -n game-2048
```

返回结果：

```
NAME           CLASS   HOSTS   ADDRESS                                                                        PORTS   AGE
ingress-2048   alb     *       k8s-game2048-ingress2-2810c0c2ad-1325099403.ap-southeast-1.elb.amazonaws.com   80      5m43s
```

使用浏览器访问ALB的地址，即可看到应用部署成功。

### 3、删除实验环境（可选）

本步骤为可选，实验环境也可以继续保留，用于后续测试。

执行如下命令：

```
kubectl delete -f https://myworkshop.bitipcman.com/eks101/2048_full_latest.yaml
```

至此实验完成。

## 三、参考文档

Installing the AWS Load Balancer Controller add-on

[https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html](https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html)