# 实验二、部署AWS Load Balancer Controller

EKS 1.22版本 @2022-04 Global区域和中国区域测试通过

## 一、部署AWS Load Balancer Controller

### 1、为EKS生成IAM的OIDC授权

执行如下命令。请注意替换集群名称和区域为实际操作的环境。

```
eksctl utils associate-iam-oidc-provider --region ap-southeast-1 --cluster eksworkshop --approve
```

### 2、创建IAM Policy（请注意区分Global区域和中国区配置文件）

下载已经预先配置好的IAM策略到本地，保持iam-policy.json的文件名。另外请注意，本文使用的ALB ingress是2.x，因此IAM policy与之前1.x的版本不通用，请注意部署时候才用正确的版本。

```
wget https://myworkshop.bitipcman.com/eks101/iam_policy.json
```

另外请注意：这个下载到的iam_policy.json是匹配AWS Global Region的，如果在中国区域使用，可以下载修改过arn标签的如下文件：

```
wget https://myworkshop.bitipcman.com/eks101/iam_policy-cn.json
```

创建IAM Policy，执行如下命令。注意上一步下载的文件如果是中国区的版本，注意文件名的区别。

```
aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file://iam_policy.json
```

返回如下结果表示成功。

```
{
    "Policy": {
        "PolicyName": "AWSLoadBalancerControllerIAMPolicy",
        "PolicyId": "ANPAR57Y4KKLCBZJGMRIT",
        "Arn": "arn:aws:iam::133129065110:policy/AWSLoadBalancerControllerIAMPolicy",
        "Path": "/",
        "DefaultVersionId": "v1",
        "AttachmentCount": 0,
        "PermissionsBoundaryUsageCount": 0,
        "IsAttachable": true,
        "CreateDate": "2022-04-09T03:48:58+00:00",
        "UpdateDate": "2022-04-09T03:48:58+00:00"
    }
}
(END)
```

此时需要记住这个新建Policy的ARN ID，下一步创建角色时候将会使用。注意中国区和Global区域的ARN标识是不同的，在中国区ARN中的标识是`aws-cn`，多含一个 `-cn` 后缀。

### 3、创建EKS Service Account

执行如下命令。请替换cluster、attach-policy-arn、region等参数为本次实验环境的参数。其他参数保持不变。

```
eksctl create iamserviceaccount --cluster=eksworkshop --namespace=kube-system --name=aws-load-balancer-controller --attach-policy-arn=arn:aws:iam::133129065110:policy/AWSLoadBalancerControllerIAMPolicy --override-existing-serviceaccounts --region ap-southeast-1 --approve
```

本步骤可能需要1-3分钟时间。

### 4、部署证书服务（v1.8.1）

执行如下命令：

```
kubectl apply --validate=false -f https://myworkshop.bitipcman.com/eks101/cert-manager_v1.8.1.yaml
```

返回信息创建成功：

```
namespace/cert-manager created
customresourcedefinition.apiextensions.k8s.io/certificaterequests.cert-manager.io created
customresourcedefinition.apiextensions.k8s.io/certificates.cert-manager.io created
customresourcedefinition.apiextensions.k8s.io/challenges.acme.cert-manager.io created
customresourcedefinition.apiextensions.k8s.io/clusterissuers.cert-manager.io created
customresourcedefinition.apiextensions.k8s.io/issuers.cert-manager.io created
customresourcedefinition.apiextensions.k8s.io/orders.acme.cert-manager.io created
serviceaccount/cert-manager-cainjector created
serviceaccount/cert-manager created
serviceaccount/cert-manager-webhook created
configmap/cert-manager-webhook created
clusterrole.rbac.authorization.k8s.io/cert-manager-cainjector created
clusterrole.rbac.authorization.k8s.io/cert-manager-controller-issuers created
clusterrole.rbac.authorization.k8s.io/cert-manager-controller-clusterissuers created
clusterrole.rbac.authorization.k8s.io/cert-manager-controller-certificates created
clusterrole.rbac.authorization.k8s.io/cert-manager-controller-orders created
clusterrole.rbac.authorization.k8s.io/cert-manager-controller-challenges created
clusterrole.rbac.authorization.k8s.io/cert-manager-controller-ingress-shim created
clusterrole.rbac.authorization.k8s.io/cert-manager-view created
clusterrole.rbac.authorization.k8s.io/cert-manager-edit created
clusterrole.rbac.authorization.k8s.io/cert-manager-controller-approve:cert-manager-io created
clusterrole.rbac.authorization.k8s.io/cert-manager-controller-certificatesigningrequests created
clusterrole.rbac.authorization.k8s.io/cert-manager-webhook:subjectaccessreviews created
clusterrolebinding.rbac.authorization.k8s.io/cert-manager-cainjector created
clusterrolebinding.rbac.authorization.k8s.io/cert-manager-controller-issuers created
clusterrolebinding.rbac.authorization.k8s.io/cert-manager-controller-clusterissuers created
clusterrolebinding.rbac.authorization.k8s.io/cert-manager-controller-certificates created
clusterrolebinding.rbac.authorization.k8s.io/cert-manager-controller-orders created
clusterrolebinding.rbac.authorization.k8s.io/cert-manager-controller-challenges created
clusterrolebinding.rbac.authorization.k8s.io/cert-manager-controller-ingress-shim created
clusterrolebinding.rbac.authorization.k8s.io/cert-manager-controller-approve:cert-manager-io created
clusterrolebinding.rbac.authorization.k8s.io/cert-manager-controller-certificatesigningrequests created
clusterrolebinding.rbac.authorization.k8s.io/cert-manager-webhook:subjectaccessreviews created
role.rbac.authorization.k8s.io/cert-manager-cainjector:leaderelection created
role.rbac.authorization.k8s.io/cert-manager:leaderelection created
role.rbac.authorization.k8s.io/cert-manager-webhook:dynamic-serving created
rolebinding.rbac.authorization.k8s.io/cert-manager-cainjector:leaderelection created
rolebinding.rbac.authorization.k8s.io/cert-manager:leaderelection created
rolebinding.rbac.authorization.k8s.io/cert-manager-webhook:dynamic-serving created
service/cert-manager created
service/cert-manager-webhook created
deployment.apps/cert-manager-cainjector created
deployment.apps/cert-manager created
deployment.apps/cert-manager-webhook created
mutatingwebhookconfiguration.admissionregistration.k8s.io/cert-manager-webhook created
validatingwebhookconfiguration.admissionregistration.k8s.io/cert-manager-webhook created
```

稍等几分钟让服务完全启动。

### 5、部署CRDS（本步骤为1.22版本必须，1.21或更低版本请跳过）

EKS 1.22版本使用AWS Load Balancer Ingress Controller需要事先部署CRDS。

```
kubectl apply -f https://myworkshop.bitipcman.com/eks101/crds.yaml
```

返回如下信息表示成功：

```
customresourcedefinition.apiextensions.k8s.io/ingressclassparams.elbv2.k8s.aws created
customresourcedefinition.apiextensions.k8s.io/targetgroupbindings.elbv2.k8s.aws created
```

### 6、部署AWS Load Balancer Controller（v2.4.1）

下载配置文件。

```
wget https://myworkshop.bitipcman.com/eks101/v2_4_2_full.yaml
```

下载后用编辑器打开，找到其中的`--cluster-name=your-cluster-name`部分，将eks集群名称`your-cluster-name`改成与前文一致的名称，例如本文是`eksworkshop`的名称。然后继续修改vpc-id和region，然后保存。

```
      containers:
      - args:
        - --cluster-name=your-cluster-name
        - --ingress-class=alb
        - --aws-vpc-id=vpc-xxxxxxxx
        - --aws-region=cn-northwest-1
```

执行如下命令：

```
kubectl apply -f v2_4_2_full.yaml
```

返回信息如下：

```
customresourcedefinition.apiextensions.k8s.io/ingressclassparams.elbv2.k8s.aws configured
customresourcedefinition.apiextensions.k8s.io/targetgroupbindings.elbv2.k8s.aws configured
role.rbac.authorization.k8s.io/aws-load-balancer-controller-leader-election-role created
clusterrole.rbac.authorization.k8s.io/aws-load-balancer-controller-role created
rolebinding.rbac.authorization.k8s.io/aws-load-balancer-controller-leader-election-rolebinding created
clusterrolebinding.rbac.authorization.k8s.io/aws-load-balancer-controller-rolebinding created
service/aws-load-balancer-webhook-service created
deployment.apps/aws-load-balancer-controller created
certificate.cert-manager.io/aws-load-balancer-serving-cert created
issuer.cert-manager.io/aws-load-balancer-selfsigned-issuer created
mutatingwebhookconfiguration.admissionregistration.k8s.io/aws-load-balancer-webhook created
validatingwebhookconfiguration.admissionregistration.k8s.io/aws-load-balancer-webhook created
ingressclassparams.elbv2.k8s.aws/alb created
ingressclass.networking.k8s.io/alb created
```

### 7、检查部署结果

在创建AWS Load Balancer Controller后，等待几分钟启动完成，执行如下命令检查部署结果：

```
kubectl get deployment -n kube-system aws-load-balancer-controller
```

返回结果如下：

```
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
aws-load-balancer-controller   1/1     1            1           3m2s
```

表示部署成功。如果READY位置状态是0/1，则表示启动失败，需要检查前几个步骤的输出信息是否有报错。

此时只是配置好了AWS Load Balancer Ingress Controller所需要的Controller对应的Pod，如果现在去查看EC2控制台的ELB界面，是看不到有负载均衡被创建出来的。接下来的步骤部署应用时候将随应用一起创建ALB。

### 8、子网打标签

请确保本子网已经设置了正确的路由表，且VPC内包含NAT Gateway可以提供外网访问能力。然后接下来为其打标签。

找到当前的VPC，找到有EIP和NAT Gateway的Public Subnet，为其添加标签：

标签名称：kubernetes.io/role/elb，值：1
标签名称：kubernetes.io/cluster/eksworkshop，值：shared
接下来进入Private subnet，为其添加标签：

标签名称：kubernetes.io/role/internal-elb，值：1
标签名称：kubernetes.io/cluster/eksworkshop，值：shared
接下来请重复以上工作，三个AZ的子网都实施相同的配置，注意第一项标签值都是1。

## 二、部署使用ALB Ingress的2048应用

### 1、部署应用

执行如下命令：

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
Address:          k8s-game2048-ingress2-2810c0c2ad-1338588716.ap-southeast-1.elb.amazonaws.com
Default backend:  default-http-backend:80 (<error: endpoints "default-http-backend" not found>)
Rules:
  Host        Path  Backends
  ----        ----  --------
  *           
              /   service-2048:80 (192.168.117.236:80,192.168.150.66:80,192.168.188.76:80)
Annotations:  alb.ingress.kubernetes.io/scheme: internet-facing
              alb.ingress.kubernetes.io/target-type: ip
              kubernetes.io/ingress.class: alb
Events:
  Type    Reason                  Age   From     Message
  ----    ------                  ----  ----     -------
  Normal  SuccessfullyReconciled  71s   ingress  Successfully reconciled
```

此外也可以只查看入口地址，执行如下命令可查看。命令后边没有加 -n 的参数表示是在default namespace，如果是在其他name space下需要使用 -n namespace名字 的方式声明要查询的命名空间。

```
kubectl get ingress -n game-2048
```

返回结果：

```
NAME           CLASS    HOSTS   ADDRESS                                                                        PORTS   AGE
ingress-2048   <none>   *       k8s-game2048-ingress2-2810c0c2ad-1338588716.ap-southeast-1.elb.amazonaws.com   80      146m
```

使用浏览器访问ALB的地址，即可看到应用部署成功。

### 3、删除实验环境

执行如下命令：

```
kubectl delete -f https://myworkshop.bitipcman.com/eks101/2048_full_latest.yaml
```

至此实验完成。

## 三、参考文档

ALB Ingress：

[https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html](https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html)

AWS GCR Workshop：

[https://github.com/guoxun19/gcr-eks-workshop](https://github.com/guoxun19/gcr-eks-workshop)`