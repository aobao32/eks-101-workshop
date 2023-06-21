# 实验六、将IAM用户或角色授权为EKS集群管理员

使用EKS服务过程中，经常出现创建EKS集群和管理EKS集群的不是一个人。由此会导致在AWS控制台上显示EKS服务不正常，无法获取有关配置。在AWS控制台上访问EKS服务时候，会提示错误信息如下：

```
Your current IAM principal doesn’t have access to Kubernetes objects on this cluster.
This might be due to the current IAM principal not having an access entry with permissions to access the cluster.
```

通俗点说：A使用eksctl命令行工具创建了集群，B在AWS控制台上看不到，现在需要A给B授权。B可能是一个IAM User用户，也可能是一个IAM Role角色（虚拟的）。根据B是用户还是角色，后续操作二选一。

注意：以下步骤需要在一个已经配置好IAM Service Account/Load Balancer Controller之后的可正常工作的EKS集群上执行。如果您的EKS集群只创建了Control Plane，还没有继续配置IAM Service Account/Load Balancer Controller，那么现在来执行IAM身份配置将会报错。

## 一、查看当前授权（前文提到的A身份）

以EKS创建者的身份，在命令行下执行如下命令:

```
kubectl describe configmap -n kube-system aws-auth
```

返回结果如下：

```
Name:         aws-auth
Namespace:    kube-system
Labels:       <none>
Annotations:  <none>

Data
====
mapRoles:
----
- groups:
  - system:bootstrappers
  - system:nodes
  rolearn: arn:aws-cn:iam::420029960748:role/eksctl-eksworkshopbj-nodegroup-no-NodeInstanceRole-BGKUROWI9QA5
  username: system:node:{{EC2PrivateDNSName}}
Events:  <none>
```

这里可以看到只在groups下边只有一个默认的。接下来只要将groups这一段增加一个新的IAM角色或者IAM用户即可。

## 二、编辑配置文件添加新的管理员

### 1、编辑配置文件（前文提到的A身份）

本步骤需要在使用eksctl命令创建EKS集群的这个客户端上执行。当使用eksctl创建好集群时，eksctl会在这台电脑上自动设置kubectl配置文件。因此继续使用kubectl可以在创建者这个客户端上完成配置。

（用前文提到的A身份运行）执行如下命令：

```
kubectl edit -n kube-system configmap/aws-auth
```

编辑配置文件，此时会Windows会自动弹出记事本编辑器，Linux会自动进入vi编辑器。其默认内容如下。

```
# Please edit the object below. Lines beginning with a '#' will be ignored,
# and an empty file will abort the edit. If an error occurs while saving this file will be
# reopened with the relevant failures.
#
apiVersion: v1
data:
  mapRoles: |
    - groups:
      - system:bootstrappers
      - system:nodes
      rolearn: arn:aws-cn:iam::420029960748:role/eksctl-eksworkshopbj-nodegroup-no-NodeInstanceRole-BGKUROWI9QA5
      username: system:node:{{EC2PrivateDNSName}}
kind: ConfigMap
metadata:
  creationTimestamp: "2022-03-23T10:36:54Z"
  name: aws-auth
  namespace: kube-system
  resourceVersion: "1256"
  uid: b019ca52-a416-4726-96f0-a468d86203ac</code></pre>
```

### 2、添加新的IAM角色

首先明确下，要添加的身份（也就是前文提到的B身份）角色还是用户。如果要给角色授权，参考本文这一段。如果要给用户授权，参考下文这一段。

从AWS控制台进入IAM模块，找到要授权的IAM（前文提到的B身份）对应的ARN ID，构造如下一段：

```
    - groups:
      - system:masters
      rolearn: arn:aws-cn:iam::420029960748:role/newrolename
      username: newrolename
```

将这一段加入到mapRoles下，注意空格缩进要对齐。添加完毕后效果如下：

```
# Please edit the object below. Lines beginning with a '#' will be ignored,
# and an empty file will abort the edit. If an error occurs while saving this file will be
# reopened with the relevant failures.
#
apiVersion: v1
data:
  mapRoles: |
    - groups:
      - system:bootstrappers
      - system:nodes
      rolearn: arn:aws-cn:iam::420029960748:role/eksctl-eksworkshopbj-nodegroup-no-NodeInstanceRole-BGKUROWI9QA5
      username: system:node:{{EC2PrivateDNSName}}
    - groups:
      - system:masters
      rolearn: arn:aws-cn:iam::420029960748:role/newrolename
      username: newrolename
kind: ConfigMap
metadata:
  creationTimestamp: "2022-03-23T10:36:54Z"
  name: aws-auth
  namespace: kube-system
  resourceVersion: "1256"
  uid: b019ca52-a416-4726-96f0-a468d86203ac</code></pre>
```

修改后保存配置文件，关闭窗口即可生效。

### 3、增加新的IAM用户

从AWS控制台进入IAM模块，找到要授权的IAM角色（也就是前文提到的B身份）的ARN ID（中国区注意是aws-cn，Global区域不带-cn），构造如下一段：

```
  mapUsers: | 
    - userarn: arn:aws-cn:iam::420029960748:user/newusername 
      username: newusername 
      groups: 
        - system:masters
```

将这一段加入到mapRoles下，注意空格缩进要对齐。添加完毕后效果如下：

```
# Please edit the object below. Lines beginning with a '#' will be ignored,
# and an empty file will abort the edit. If an error occurs while saving this file will be
# reopened with the relevant failures.
#
apiVersion: v1
data:
  mapRoles: |
    - groups:
      - system:bootstrappers
      - system:nodes
      rolearn: arn:aws-cn:iam::420029960748:role/eksctl-eksworkshopbj-nodegroup-no-NodeInstanceRole-BGKUROWI9QA5
      username: system:node:{{EC2PrivateDNSName}}
  mapUsers: | 
    - userarn: arn:aws-cn:iam::420029960748:user/newusername 
      username: newusername 
      groups: 
        - system:masters
    - userarn: arn:aws-cn:iam::420029960748:user/newusername 
      username: newusername 
      groups: 
        - system:masters
kind: ConfigMap
metadata:
  creationTimestamp: "2022-03-23T10:36:54Z"
  name: aws-auth
  namespace: kube-system
  resourceVersion: "1256"
  uid: b019ca52-a416-4726-96f0-a468d86203ac</code></pre>
```

修改后保存配置文件，关闭窗口即可生效。

### 4、验证访问

（以前文提到的A身份运行）执行：

```
kubectl describe configmap -n kube-system aws-auth
```

即可看到返回的授权信息中已经包含了新创建的IAM角色（B身份）或者IAM用户（B身份）了。

## 三、为新的用户生成kubectl配置

在上文授权完毕后，可为新授权的IAM Role（B身份）或者IAM User（B身份）创建kube config配置文件，即可开始管理集群。

（以B身份执行）首先进入当前用户home目录下，删除掉旧的配置文件。这个目录是隐藏目录。Windows默认在 C:\Users\Administrator\.kube\config 位置。Linux默认在当前主目录下 .kube/config 位置。

删除成功后，执行如下命令：

```
aws eks update-kubeconfig --region region-code --name cluster-name
```

即可为kubectl创建config文件。接下来可执行`kubectl get nodes`查看是否生效。

## 四、参考文档

在 Amazon EKS 中创建集群之后，如何提供对其他 IAM 用户和角色的访问权限

[https://aws.amazon.com/cn/premiumsupport/knowledge-center/amazon-eks-cluster-access/]()

Enabling IAM principal access to your cluster

[https://docs.aws.amazon.com/eks/latest/userguide/add-user-role.html]()