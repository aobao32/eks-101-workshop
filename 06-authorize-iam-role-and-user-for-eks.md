# 将IAM用户或角色授权为EKS集群管理员

使用EKS服务过程中，经常出现创建EKS集群和管理EKS集群的不是一个人。由此会导致在AWS控制台上显示EKS服务不正常，无法获取有关配置。解决办法如下。

## 一、查看当前授权

以EKS创建者的身份，在命令行下执行如下命令:</p>

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

这里可以看到只有当前的创建者。

## 二、编辑配置文件添加新的管理员

### 1、编辑配置文件

执行如下命令：

```
kubectl edit -n kube-system configmap/aws-auth
```

编辑配置文件，其默认内容如下。

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

如果是给一个新的IAM Role赋权，则在mapRoles下增加如下一段后效果如下：

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

如果是给一个新的IAM User授权，则增加如下一段。则在mapRoles下增加如下一段后效果如下：

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
    - userarn: arn:aws:iam::11122223333:user/newusername 
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

再次执行：

```
kubectl describe configmap -n kube-system aws-auth
```

即可看到返回的授权信息中已经包含了新创建的IAM角色或者用户了。

## 三、为新的用户生成kubectl配置

在上文授权完毕后，可为新授权的IAM Role或者IAM User创建kube config配置文件，即可开始管理集群。

首先进入当前用户home目录下，删除掉旧的配置文件。这个目录是隐藏目录。Windows默认在 C:\Users\Administrator\.kube\config 位置。Linux默认在当前主目录下 .kube/config 位置。

删除成功后，执行如下命令：

```
aws eks update-kubeconfig --region region-code --name cluster-name
```

即可为kubectl创建config文件。接下来可执行`kubectl get nodes`查看是否生效。

## 四、参考文档

[在 Amazon EKS 中创建集群之后，如何提供对其他 IAM 用户和角色的访问权限？](https://aws.amazon.com/cn/premiumsupport/knowledge-center/amazon-eks-cluster-access/)

[为 Amazon EKS 创建 kubeconfig](https://docs.amazonaws.cn/eks/latest/userguide/create-kubeconfig.html)
