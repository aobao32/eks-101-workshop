# 实验二、部署AWS ELB Ingress (v2.x)

## 一、部署ELB Ingress

### 1、为EKS生成IAM的OIDC授权

执行如下命令。请注意替换集群名称和区域为实际操作的环境。

```
eksctl utils associate-iam-oidc-provider --region ap-southeast-1 --cluster eksworkshop --approve
```

返回结果如下表示成功。

```
2022-03-19 22:39:28 [ℹ]  eksctl version 0.87.0
2022-03-19 22:39:28 [ℹ]  using region ap-southeast-1
2022-03-19 22:39:29 [ℹ]  will create IAM Open ID Connect provider for cluster "eksworkshop" in "ap-southeast-1"
2022-03-19 22:39:30 [✔]  created IAM Open ID Connect provider for cluster "eksworkshop" in "ap-southeast-1"
```

### 2、创建IAM Policy（策略）

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
aws iam create-policy --policy-name ALBIngressControllerIAMPolicy --policy-document file://iam_policy.json
```

返回如下结果表示成功。

```
{
    "Policy": {
        "PolicyName": "ALBIngressControllerIAMPolicy",
        "PolicyId": "ANPARHG64UFG4YTWDYLRR",
        "Arn": "arn:aws:iam::084219306317:policy/ALBIngressControllerIAMPolicy",
        "Path": "/",
        "DefaultVersionId": "v1",
        "AttachmentCount": 0,
        "PermissionsBoundaryUsageCount": 0,
        "IsAttachable": true,
        "CreateDate": "2022-03-19T14:41:33+00:00",
        "UpdateDate": "2022-03-19T14:41:33+00:00"
    }
}
```

此时需要记住这个新建Policy的ARN ID，下一步创建角色时候将会使用。注意中国区和Global区域的ARN标识是不同的，在中国区ARN中的标识是`aws-cn`，多含一个 `-cn` 后缀。

### 3、创建EKS Service Account

执行如下命令。请替换cluster、attach-policy-arn参数为本次实验环境的参数。其他参数保持不变。

```
eksctl create iamserviceaccount --cluster=eksworkshop --namespace=kube-system --name=aws-load-balancer-controller --attach-policy-arn=arn:aws:iam::084219306317:policy/ALBIngressControllerIAMPolicy --override-existing-serviceaccounts --approve
```

本步骤可能需要1-3分钟时间。返回以下结果表示部署成功。

```
2022-03-19 22:44:34 [ℹ]  eksctl version 0.87.0
2022-03-19 22:44:34 [ℹ]  using region ap-southeast-1
2022-03-19 22:44:35 [ℹ]  1 iamserviceaccount (kube-system/aws-load-balancer-controller) was included (based on the include/exclude rules)
2022-03-19 22:44:35 [!]  metadata of serviceaccounts that exist in Kubernetes will be updated, as --override-existing-serviceaccounts was set
2022-03-19 22:44:35 [ℹ]  1 task: {
    2 sequential sub-tasks: {
        create IAM role for serviceaccount "kube-system/aws-load-balancer-controller",
        create serviceaccount "kube-system/aws-load-balancer-controller",
    } }2022-03-19 22:44:35 [ℹ]  building iamserviceaccount stack "eksctl-eksworkshop-addon-iamserviceaccount-kube-system-aws-load-balancer-controller"
2022-03-19 22:44:36 [ℹ]  deploying stack "eksctl-eksworkshop-addon-iamserviceaccount-kube-system-aws-load-balancer-controller"
2022-03-19 22:44:36 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-addon-iamserviceaccount-kube-system-aws-load-balancer-controller"
2022-03-19 22:44:53 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-addon-iamserviceaccount-kube-system-aws-load-balancer-controller"
2022-03-19 22:45:09 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-addon-iamserviceaccount-kube-system-aws-load-balancer-controller"
2022-03-19 22:45:11 [ℹ]  created serviceaccount "kube-system/aws-load-balancer-controller"
```

### 4、部署证书服务

执行如下命令：

```
kubectl apply --validate=false -f https://myworkshop.bitipcman.com/eks101/cert-manager.yaml
```

返回信息创建成功：

```
customresourcedefinition.apiextensions.k8s.io/certificaterequests.cert-manager.io created
customresourcedefinition.apiextensions.k8s.io/certificates.cert-manager.io created
customresourcedefinition.apiextensions.k8s.io/challenges.acme.cert-manager.io created
customresourcedefinition.apiextensions.k8s.io/clusterissuers.cert-manager.io created
customresourcedefinition.apiextensions.k8s.io/issuers.cert-manager.io created
customresourcedefinition.apiextensions.k8s.io/orders.acme.cert-manager.io created
namespace/cert-manager created
serviceaccount/cert-manager-cainjector created
serviceaccount/cert-manager created
serviceaccount/cert-manager-webhook created
clusterrole.rbac.authorization.k8s.io/cert-manager-cainjector created
clusterrole.rbac.authorization.k8s.io/cert-manager-controller-issuers created
clusterrole.rbac.authorization.k8s.io/cert-manager-controller-clusterissuers created
clusterrole.rbac.authorization.k8s.io/cert-manager-controller-certificates created
clusterrole.rbac.authorization.k8s.io/cert-manager-controller-orders created
clusterrole.rbac.authorization.k8s.io/cert-manager-controller-challenges created
clusterrole.rbac.authorization.k8s.io/cert-manager-controller-ingress-shim created
clusterrole.rbac.authorization.k8s.io/cert-manager-view created
clusterrole.rbac.authorization.k8s.io/cert-manager-edit created
clusterrolebinding.rbac.authorization.k8s.io/cert-manager-cainjector created
clusterrolebinding.rbac.authorization.k8s.io/cert-manager-controller-issuers created
clusterrolebinding.rbac.authorization.k8s.io/cert-manager-controller-clusterissuers created
clusterrolebinding.rbac.authorization.k8s.io/cert-manager-controller-certificates created
clusterrolebinding.rbac.authorization.k8s.io/cert-manager-controller-orders created
clusterrolebinding.rbac.authorization.k8s.io/cert-manager-controller-challenges created
clusterrolebinding.rbac.authorization.k8s.io/cert-manager-controller-ingress-shim created
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

### 5、部署ELB Ingress

执行如下命令：

```
kubectl apply -f https://myworkshop.bitipcman.com/eks101/v2_2_0_full.yaml
```

返回信息如下：

```
customresourcedefinition.apiextensions.k8s.io/ingressclassparams.elbv2.k8s.aws created
customresourcedefinition.apiextensions.k8s.io/targetgroupbindings.elbv2.k8s.aws created
Warning: resource serviceaccounts/aws-load-balancer-controller is missing the kubectl.kubernetes.io/last-applied-configuration annotation which is required by kubectl apply. kubectl apply should only be used on resources created declaratively by either kubectl create --save-config or kubectl apply. The missing annotation will be patched automatically.
serviceaccount/aws-load-balancer-controller configured
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
```

返回信息中包含Warning提示如上，可以忽略，会自动修复。

### 6、检查部署结果

执行如下命令检查部署结果：

```
kubectl get deployment -n kube-system aws-load-balancer-controller
```

返回结果如下：

```
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
aws-load-balancer-controller   1/1     1            1           3m26s
```

表示部署成功。

此时只是配置好了EKS Ingress所需要的Controller，如果立刻去查看EC2控制台的ELB界面，是看不到ALB的。接下来的步骤部署应用时候将随应用一起创建ALB。

## 二、部署2048应用

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
Namespace:        game-2048
Address:          k8s-game2048-ingress2-330cc1efad-50734125.ap-southeast-1.elb.amazonaws.com
Default backend:  default-http-backend:80 (<error: endpoints "default-http-backend" not found>)
Rules:
  Host        Path  Backends
  ----        ----  --------
  *
              /   service-2048:80 (192.168.3.242:80,192.168.35.143:80,192.168.54.95:80)
Annotations:  alb.ingress.kubernetes.io/scheme: internet-facing
              alb.ingress.kubernetes.io/target-type: ip
              kubernetes.io/ingress.class: alb
Events:
  Type    Reason                  Age   From     Message
  ----    ------                  ----  ----     -------
  Normal  SuccessfullyReconciled  4m4s  ingress  Successfully reconciled
```

此外也可以只查看入口地址，执行如下命令可查看。命令后边没有加 -n 的参数表示是在default namespace，如果是在其他name space下需要使用 -n namespace名字 的方式声明要查询的命名空间。

```
kubectl get ingress -n game-2048
```

返回结果：

```
NAME           CLASS    HOSTS   ADDRESS                                                                      PORTS   AGE
ingress-2048   <none>   *       k8s-game2048-ingress2-330cc1efad-50734125.ap-southeast-1.elb.amazonaws.com   80      10m
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

[https://github.com/guoxun19/gcr-eks-workshop](https://github.com/guoxun19/gcr-eks-workshop)