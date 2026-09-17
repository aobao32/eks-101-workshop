# 实验六、将IAM用户或角色授权为EKS集群管理员

EKS 1.36版本 @2026 AWS Global区域测试通过

使用EKS服务过程中，经常出现创建EKS集群和管理EKS集群的不是同一个人的情形。由此会导致在AWS控制台上显示EKS服务不正常，无法获取有关配置。在AWS控制台上访问EKS服务时候，会提示错误信息如下：

```
Your current IAM principal doesn’t have access to Kubernetes objects on this cluster.
This might be due to the current IAM principal not having an access entry with permissions to access the cluster.
```

具体而言：身份A使用eksctl命令行工具创建了集群，身份B在AWS控制台上看不到集群内的Kubernetes对象，此时需要由身份A为身份B授予访问权限。身份B可能是一个IAM User用户，也可能是一个IAM Role角色。根据身份B是用户还是角色，后续操作在对应示例中二选一。

注意：以下步骤需要在一个已经配置好IAM Service Account与Load Balancer Controller之后、可正常工作的EKS集群上执行。如果您的EKS集群只创建了Control Plane，尚未继续配置IAM Service Account与Load Balancer Controller，那么此时执行IAM身份配置将会报错。

## 一、两种授权机制的对比与选型

在为EKS集群授予访问权限之前，需要先理解当前EKS版本提供的两种授权机制及其适用条件，再决定采用何种方式，这样可以避免在错误的机制上重复操作。

自EKS引入访问条目（access entries）以来，Access Entries已成为默认且推荐的授权方式。使用eksctl创建集群时，其默认的认证模式为 API_AND_CONFIG_MAP，即同时启用Access Entries的原生API与传统的aws-auth ConfigMap。当集群认证模式被设置为纯 API 时，aws-auth ConfigMap将不再被读取，所有授权均须通过Access Entries完成。因此，在EKS 1.36上进行授权，应优先采用Access Entries。

两种授权机制的对比如下表所示。

| 对比项 | Access Entries | aws-auth ConfigMap |
| --- | --- | --- |
| 管理方式 | 通过EKS原生API管理，可用 eksctl、AWS CLI 或控制台操作 | 通过编辑 kube-system 命名空间下的 ConfigMap 管理 |
| 是否 AWS 原生 API | 是，属于EKS控制平面原生资源 | 否，属于Kubernetes对象，需具备集群访问权限后才能编辑 |
| 能否在控制台查看集群内 Kubernetes 对象 | 支持，关联访问策略后可在控制台查看 | 不直接支持，需依赖 ConfigMap 中的映射并具备相应权限 |
| 误操作风险 | 较低，条目与策略以结构化 API 管理，格式错误不易发生 | 较高，手工编辑 YAML 时缩进或字段错误可能导致全部授权失效 |
| 在 1.36 的推荐度 | 推荐，为默认机制 | 兼容保留，仅在认证模式包含 CONFIG_MAP 时有效 |

综合上表，对于新建集群以及运行在EKS 1.36上的集群，推荐使用Access Entries完成授权；aws-auth ConfigMap 作为传统兼容方式保留，主要用于早期集群或尚未迁移至Access Entries的场景。

注意：认证模式一旦从 API_AND_CONFIG_MAP 或 CONFIG_MAP 改为纯 API 后，不可回退到 CONFIG_MAP，属于不可逆操作。在切换为纯 API 模式之前，须确认所有依赖 aws-auth ConfigMap 的授权均已迁移至Access Entries，并谨慎评估影响范围，避免丢失管理员访问权限。

下面先介绍推荐的Access Entries方式，再介绍传统的aws-auth ConfigMap方式。

## 二、方式一：使用 Access Entries 授权（推荐）

本方式通过EKS原生API为IAM角色或IAM用户创建访问条目，并关联合适的访问策略，从而授予对集群的访问权限。

### 1、确认或设置集群认证模式

集群的认证模式由 accessConfig.authenticationMode 字段决定，取值为以下三种之一：

- CONFIG_MAP：仅使用 aws-auth ConfigMap，不启用Access Entries。
- API：仅使用Access Entries，不再读取 aws-auth ConfigMap。
- API_AND_CONFIG_MAP：同时启用Access Entries与 aws-auth ConfigMap，为eksctl创建集群时的默认取值。

如果现有集群的认证模式尚未包含 API，需先将其迁移为包含Access Entries的模式。执行如下命令：

```shell
eksctl utils update-authentication-mode --cluster <cluster-name> --authentication-mode API_AND_CONFIG_MAP
```

其中 `<cluster-name>` 替换为实际的集群名称。该命令将认证模式更新为 API_AND_CONFIG_MAP，在保留原有 aws-auth ConfigMap 授权的同时启用Access Entries，便于逐步迁移。

### 2、创建访问条目并关联访问策略

创建访问条目分为两步：先为目标IAM主体创建访问条目，再为该条目关联访问策略。可以使用 eksctl 或 AWS CLI 完成。

使用 eksctl 创建访问条目并直接关联集群管理员策略，执行如下命令：

```shell
eksctl create accessentry \
  --cluster <cluster-name> \
  --region <region> \
  --principal-arn arn:aws:iam::<account-id>:role/<role-name> \
  --access-policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope cluster
```

其中 `<region>` 替换为集群所在区域，`<account-id>` 与 `<role-name>` 替换为目标IAM角色的账户ID与角色名称。中国区需将策略ARN与主体ARN中的 `aws` 替换为 `aws-cn`。

也可以在集群配置文件的 accessConfig.accessEntries 中以声明方式定义访问条目，示例如下：

```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: <cluster-name>
  region: <region>

accessConfig:
  authenticationMode: API_AND_CONFIG_MAP
  accessEntries:
    - principalARN: arn:aws:iam::<account-id>:role/<role-name>
      accessPolicies:
        - policyARN: arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy
          accessScope:
            type: cluster
```

如果使用 AWS CLI，则分两条命令完成。首先创建访问条目，执行如下命令：

```shell
aws eks create-access-entry \
  --cluster-name <cluster-name> \
  --region <region> \
  --principal-arn arn:aws:iam::<account-id>:role/<role-name>
```

然后为该访问条目关联访问策略，执行如下命令：

```shell
aws eks associate-access-policy \
  --cluster-name <cluster-name> \
  --region <region> \
  --principal-arn arn:aws:iam::<account-id>:role/<role-name> \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
```

关于访问策略的选择，常用策略及其适用范围说明如下：

- AmazonEKSClusterAdminPolicy：集群级管理员权限，策略ARN为 `arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy`，适用于需要对整个集群进行管理的场景，等价于传统 aws-auth 中的 system:masters 授权。
- AmazonEKSViewPolicy：命名空间级只读权限，策略ARN为 `arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy`，适用于仅需查看资源、不进行修改的场景，可配合 `--access-scope type=namespace --namespaces <namespace>` 限定生效范围。

备注：上述策略ARN中的 `aws` 为AWS Global区域的写法，中国区须替换为 `aws-cn`。

### 3、从 aws-auth 迁移到 Access Entries（可选）

对于已经使用 aws-auth ConfigMap 授权的存量集群，可以将现有的 mapRoles 与 mapUsers 映射迁移为Access Entries。执行如下命令：

```shell
eksctl utils migrate-to-access-entry --cluster <cluster-name> --target-authentication-mode API_AND_CONFIG_MAP
```

其中 `--target-authentication-mode` 可取 API_AND_CONFIG_MAP 或 API。取值为 API_AND_CONFIG_MAP 时，迁移后仍保留 aws-auth ConfigMap 的兼容性；取值为 API 时，迁移完成后将只使用Access Entries。

注意：迁移前须核对现有 aws-auth 中的全部映射，确认每个管理员对应的IAM主体都能在迁移后获得等价的访问策略，避免因映射遗漏而丢失管理员访问权限。若目标模式选择纯 API，因该切换不可逆，须在充分验证后再执行。命令中涉及区域时以 `<region>` 占位，构造主体ARN时须区分AWS Global区域的 `aws` 与中国区的 `aws-cn`。

## 三、方式二：使用 aws-auth ConfigMap 授权（传统方式）

备注：本方式为传统兼容方式，仅在集群认证模式包含 CONFIG_MAP（即 CONFIG_MAP 或 API_AND_CONFIG_MAP）时有效。若集群已切换为纯 API 模式，aws-auth ConfigMap 不再被读取，须改用上一章介绍的Access Entries方式。

### 1、查看当前授权（前文提到的A身份）

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
  rolearn: arn:aws:iam::133129065110:role/eksctl-eksworkshop-nodegroup-newn-NodeInstanceRole-18ZJKIC69UFA1
  username: system:node:{{EC2PrivateDNSName}}


BinaryData
====

Events:  <none>
```

此处可以看到 groups 下只有一个默认项。接下来只需在 mapRoles 或 mapUsers 下增加一个新的IAM角色或IAM用户即可。

### 2、开始编辑配置文件（前文提到的A身份）

本步骤需要在使用eksctl命令创建EKS集群的这个客户端上执行。当使用eksctl创建好集群时，eksctl会在这台电脑上自动设置kubectl配置文件。因此继续使用kubectl可以在创建者这个客户端上完成配置。

以前文提到的A身份运行，执行如下命令：

```
kubectl edit -n kube-system configmap/aws-auth
```

编辑配置文件时，Windows会自动弹出记事本编辑器，Linux会自动进入vi编辑器。

### 3、添加新的IAM角色

首先明确要添加的身份（也就是前文提到的B身份）是角色还是用户。如果要为角色授权，参考本小节；如果要为用户授权，参考下一小节。

从AWS控制台进入IAM模块，找到要授权的IAM角色（前文提到的B身份）对应的ARN ID，构造如下一段：

```
    - groups:
      - system:masters
      rolearn: arn:aws:iam::133129065110:role/newrolename
      username: newrolename
```

将这一段加入到 mapRoles 下，注意空格缩进要对齐。添加完毕后效果如下：

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
      rolearn: arn:aws:iam::133129065110:role/eksctl-eksworkshop-nodegroup-newn-NodeInstanceRole-18ZJKIC69UFA1
      username: system:node:{{EC2PrivateDNSName}}
    - groups:
      - system:masters
      rolearn: arn:aws:iam::133129065110:role/admin2
      username: admin2
kind: ConfigMap
metadata:
  creationTimestamp: "2023-06-21T07:45:49Z"
  name: aws-auth
  namespace: kube-system
  resourceVersion: "26609"
  uid: df7e4259-129d-418c-91c9-61a822706630
```

修改后保存配置文件，关闭窗口即可生效。

### 4、增加新的IAM用户

从AWS控制台进入IAM模块，找到要授权的IAM用户（也就是前文提到的B身份）的ARN ID（中国区注意是aws-cn，Global区域不带-cn），构造如下一段：

```
  mapUsers: | 
    - userarn: arn:aws:iam::133129065110:user/newusername 
      username: newusername 
      groups: 
        - system:masters
```

将这一段加入到配置文件中，注意空格缩进要对齐。添加完毕后效果如下：

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
      rolearn: arn:aws-cn:iam::133129065110:role/eksctl-eksworkshopbj-nodegroup-no-NodeInstanceRole-BGKUROWI9QA5
      username: system:node:{{EC2PrivateDNSName}}
  mapUsers: | 
    - userarn: arn:aws:iam::133129065110:user/newusername 
      username: newusername 
      groups: 
        - system:masters
    - userarn: arn:aws:iam::133129065110:user/newusername 
      username: newusername 
      groups: 
        - system:masters
kind: ConfigMap
metadata:
  creationTimestamp: "2023-06-21T07:45:49Z"
  name: aws-auth
  namespace: kube-system
  resourceVersion: "26609"
  uid: df7e4259-129d-418c-91c9-61a822706630
```

修改后保存配置文件，关闭窗口即可生效。

### 5、验证访问

以前文提到的A身份运行，执行如下命令：

```
kubectl describe configmap -n kube-system aws-auth
```

即可看到返回的授权信息中已经包含了新创建的IAM角色（B身份）或者IAM用户（B身份）。

这样，在AWS控制台上EKS服务界面显示的 `Your current IAM principal doesn’t have access to Kubernetes objects on this cluster. This might be due to the current IAM principal not having an access entry with permissions to access the cluster.` 这段错误信息也就消失了。

## 四、为新的用户生成kubectl配置

在上文授权完毕后，可为新授权的IAM Role（B身份）或者IAM User（B身份）创建 kube config 配置文件，即可开始管理集群。

以B身份执行，首先进入当前用户home目录下，删除掉旧的配置文件。这个目录是隐藏目录。Windows默认在 C:\Users\Administrator\.kube\config 位置。Linux默认在当前主目录下 ~/.kube/config 位置。

删除成功后，执行如下命令：

```shell
aws eks update-kubeconfig --region <region> --name <cluster-name>
```

即可为kubectl创建config文件。接下来可执行 `kubectl get nodes` 查看是否生效。

## 五、参考文档

在 Amazon EKS 中创建集群之后，如何提供对其他 IAM 用户和角色的访问权限

[https://aws.amazon.com/cn/premiumsupport/knowledge-center/amazon-eks-cluster-access/]()

Enabling IAM principal access to your cluster

[https://docs.aws.amazon.com/eks/latest/userguide/add-user-role.html]()

管理集群的访问条目（Access Entries）

[https://docs.aws.amazon.com/eks/latest/userguide/access-entries.html]()

使用 eksctl 管理访问条目

[https://docs.aws.amazon.com/eks/latest/eksctl/access-entries.html]()

从 aws-auth ConfigMap 迁移至访问条目

[https://docs.aws.amazon.com/eks/latest/userguide/migrating-access-entries.html]()
