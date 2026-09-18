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

在执行任何变更之前，应先确认集群当前的认证模式。执行如下命令：

```shell
aws eks describe-cluster --region <region> --name <cluster-name> --query 'cluster.accessConfig' --output json
```

返回结果如下：

```json
{
    "authenticationMode": "API_AND_CONFIG_MAP"
}
```

如果返回值为 API_AND_CONFIG_MAP 或 API，说明Access Entries已经启用，可直接跳过本小节，进入下一小节创建访问条目。按实验一使用eksctl创建的集群默认即为 API_AND_CONFIG_MAP，属于该情形。

仅当返回值为 CONFIG_MAP 时，才需要将认证模式迁移为包含Access Entries的模式。执行如下命令：

```shell
eksctl utils update-authentication-mode --cluster <cluster-name> --authentication-mode API_AND_CONFIG_MAP
```

其中 `<cluster-name>` 替换为实际的集群名称。该命令将认证模式更新为 API_AND_CONFIG_MAP，在保留原有 aws-auth ConfigMap 授权的同时启用Access Entries，便于逐步迁移。

注意：EKS不接受将认证模式更新为与当前相同的取值。若集群当前已是 API_AND_CONFIG_MAP 而仍然执行上述命令，将返回如下报错，此报错不影响集群状态，属于本小节可跳过的正常提示。

```
Error: failed to update cluster config: operation error EKS: UpdateClusterConfig, https response error StatusCode: 400, InvalidParameterException: Unsupported authentication mode update from API_AND_CONFIG_MAP to API_AND_CONFIG_MAP
```

### 2、创建访问条目并关联访问策略

创建访问条目分为两步：先为目标IAM主体创建访问条目，再为该条目关联访问策略。只有完成第二步，被授权的身份才真正获得集群内的操作权限；仅创建访问条目而未关联任何访问策略的主体，通过认证后不具备任何RBAC权限。

这两步可以通过 eksctl 配置文件一次完成，也可以通过 AWS CLI 分两条命令完成。

注意：`eksctl create accessentry` 的命令行参数只有 `--principal-arn`、`--type`、`--kubernetes-groups` 与 `--kubernetes-username`，不接受访问策略相关参数。若在命令行中传入 `--access-policy-arn`，将直接返回如下报错：

```
Error: unknown flag: --access-policy-arn
```

因此使用 eksctl 时，须在配置文件的 accessConfig.accessEntries 中以声明方式定义访问条目及其访问策略，示例如下：

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

其中 `<region>` 替换为集群所在区域，`<account-id>` 与 `<role-name>` 替换为目标IAM角色的账户ID与角色名称。中国区需将策略ARN与主体ARN中的 `aws` 替换为 `aws-cn`。将上述内容保存为 accessentry.yaml，执行如下命令：

```shell
eksctl create accessentry -f accessentry.yaml
```

返回结果如下：

```
2026-09-18 21:41:11 [ℹ]  creating access entry for principal ARN "arn:aws:iam::133129065110:role/newrolename"
2026-09-18 21:41:11 [ℹ]  deploying stack "eksctl-eksworkshop-accessentry-WO6UOWTLJGS4K24LRDV7442RAGV5MIW4"
2026-09-18 21:41:12 [ℹ]  waiting for CloudFormation stack "eksctl-eksworkshop-accessentry-WO6UOWTLJGS4K24LRDV7442RAGV5MIW4"
2026-09-18 21:41:43 [ℹ]  created access entry for principal ARN "arn:aws:iam::133129065110:role/newrolename"
```

由此可见，eksctl 为每一个访问条目单独创建一个名为 `eksctl-<cluster-name>-accessentry-*` 的CloudFormation堆栈，后续删除该条目须使用 `eksctl delete accessentry` 命令，以便同时清理对应的堆栈。

如果使用 AWS CLI，则分两条命令完成。首先创建访问条目，执行如下命令：

```shell
aws eks create-access-entry \
  --cluster-name <cluster-name> \
  --region <region> \
  --principal-arn arn:aws:iam::<account-id>:role/<role-name>
```

注意：如果目标IAM角色或IAM用户是刚刚创建的，此时立即执行上述命令可能返回如下报错。这是IAM身份在各区域间传播存在延迟所致，等待十余秒后重新执行即可成功，不需要修改命令参数。

```
An error occurred (InvalidParameterException) when calling the CreateAccessEntry operation: The specified principalArn is invalid: invalid principal.
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

无论采用哪种方式创建访问条目，都应确认访问策略确实已经关联。执行如下命令：

```shell
aws eks list-associated-access-policies \
  --cluster-name <cluster-name> \
  --region <region> \
  --principal-arn arn:aws:iam::<account-id>:role/<role-name> \
  --output json
```

返回结果如下：

```json
{
    "associatedAccessPolicies": [
        {
            "policyArn": "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy",
            "accessScope": {
                "type": "cluster",
                "namespaces": []
            },
            "associatedAt": "2026-09-18T21:41:15.281000+08:00",
            "modifiedAt": "2026-09-18T21:41:15.281000+08:00"
        }
    ],
    "clusterName": "eksworkshop",
    "principalArn": "arn:aws:iam::133129065110:role/newrolename"
}
```

如果 associatedAccessPolicies 返回空数组，说明访问条目虽已存在但未关联任何访问策略，此时被授权身份仍然无法操作集群内的资源，须补充执行前述的 associate-access-policy 步骤。

### 3、从 aws-auth 迁移到 Access Entries（可选）

对于已经使用 aws-auth ConfigMap 授权的存量集群，可以将现有的 mapRoles 与 mapUsers 映射迁移为Access Entries。该命令默认只输出迁移计划而不实际执行，便于先行确认影响范围。执行如下命令：

```shell
eksctl utils migrate-to-access-entry --cluster <cluster-name> --region <region> --target-authentication-mode API_AND_CONFIG_MAP
```

返回结果如下：

```
2026-09-18 21:49:06 [ℹ]  current cluster authentication mode is API_AND_CONFIG_MAP; target cluster authentication mode is API_AND_CONFIG_MAP
2026-09-18 21:49:17 [!]  arn:aws:iam::133129065110:role/eksctl-eksworkshop-nodegroup-newng-NodeInstanceRole-afRSRpmtS30g already exists in access entry, skipping
2026-09-18 21:49:17 [ℹ]  1 task: {
    2 parallel sub-tasks: {
        create access entry for principal ARN arn:aws:iam::133129065110:role/newrolename,
        create access entry for principal ARN arn:aws:iam::133129065110:user/newusername,
    } }
2026-09-18 21:49:17 [ℹ]  all tasks were skipped
2026-09-18 21:49:17 [!]  no changes were applied, run again with '--approve' to apply the changes
```

由回显最后一行可见，此时并未产生任何实际变更。核对计划无误后，追加 `--approve` 参数重新执行，方可真正完成迁移。执行如下命令：

```shell
eksctl utils migrate-to-access-entry --cluster <cluster-name> --region <region> --target-authentication-mode API_AND_CONFIG_MAP --approve
```

返回结果如下：

```
2026-09-18 21:49:44 [ℹ]  creating access entry for principal ARN "arn:aws:iam::133129065110:user/newusername"
2026-09-18 21:49:44 [ℹ]  creating access entry for principal ARN "arn:aws:iam::133129065110:role/newrolename"
2026-09-18 21:49:45 [ℹ]  deploying stack "eksctl-eksworkshop-accessentry-SEIGJ5MTN4WKLH3HKWAROF4OPHX6BOFI"
2026-09-18 21:50:17 [ℹ]  all tasks were completed successfully
```

其中 `--target-authentication-mode` 可取 API_AND_CONFIG_MAP 或 API。取值为 API_AND_CONFIG_MAP 时，迁移后仍保留 aws-auth ConfigMap 的兼容性，其内容原样保留不被清空；取值为 API 时，迁移完成后将只使用Access Entries。迁移过程中，aws-auth 里 system:masters 组的映射被转换为关联 AmazonEKSClusterAdminPolicy 的集群级访问条目，而已经存在访问条目的IAM主体（例如托管节点组的实例角色）会被跳过。

注意：迁移前须核对现有 aws-auth 中的全部映射，确认每个管理员对应的IAM主体都能在迁移后获得等价的访问策略，避免因映射遗漏而丢失管理员访问权限。若 aws-auth 中残留了已被删除、实际不存在的IAM主体，迁移会直接中止并给出如下提示，须先按提示删除该映射或重建对应的IAM身份，之后才能继续。

```
Error: user "newusername" does not exists, either delete the iamidentitymapping using "eksctl delete iamidentitymapping --cluster <cluster-name> --arn arn:aws:iam::133129065110:user/newusername" or create the user in AWS
```

若目标模式选择纯 API，因该切换不可逆，须在充分验证后再执行。命令中涉及区域时以 `<region>` 占位，构造主体ARN时须区分AWS Global区域的 `aws` 与中国区的 `aws-cn`。

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
- rolearn: arn:aws:iam::133129065110:role/eksctl-eksworkshop-nodegroup-newng-NodeInstanceRole-afRSRpmtS30g
  groups:
  - system:bootstrappers
  - system:nodes
  username: system:node:{{EC2PrivateDNSName}}

BinaryData
====

Events:  <none>
```

此处可以看到 mapRoles 下只有一个默认项，即托管节点组实例角色的映射。接下来只需在 mapRoles 或 mapUsers 下增加一个新的IAM角色或IAM用户即可。

备注：如果集群中存在多个托管节点组，可能出现 aws-auth 中只有其中一部分节点组实例角色的情形。这是因为节点组的授权已通过Access Entries下发，`eksctl get accessentry` 可以看到对应主体带有 system:nodes 组。这种情况属于正常状态，不需要向 aws-auth 中补充缺少的节点组映射。

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
      rolearn: arn:aws:iam::133129065110:role/eksctl-eksworkshop-nodegroup-newng-NodeInstanceRole-afRSRpmtS30g
      username: system:node:{{EC2PrivateDNSName}}
    - groups:
      - system:masters
      rolearn: arn:aws:iam::133129065110:role/newrolename
      username: newrolename
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
      rolearn: arn:aws:iam::133129065110:role/eksctl-eksworkshop-nodegroup-newng-NodeInstanceRole-afRSRpmtS30g
      username: system:node:{{EC2PrivateDNSName}}
  mapUsers: |
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

在执行之前须先明确一个前提：前文的访问条目与 aws-auth 映射所授予的，都是Kubernetes层面的RBAC权限，并不包含IAM层面的 `eks:DescribeCluster` 等API调用权限。这两层权限相互独立，缺少任意一层都无法正常使用集群。因此B身份自身的IAM策略中必须允许 `eks:DescribeCluster`，最小权限的内联策略如下：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "eks:DescribeCluster",
        "eks:ListClusters"
      ],
      "Resource": "*"
    }
  ]
}
```

若缺少该IAM权限，即便访问条目已经正确创建并关联了 AmazonEKSClusterAdminPolicy，后续生成配置文件的命令也会直接失败，返回如下报错。这一现象容易被误判为集群授权没有生效，实际原因在IAM一侧。

```
An error occurred (AccessDeniedException) when calling the DescribeCluster operation: User: arn:aws:sts::133129065110:assumed-role/newrolename/session is not authorized to perform: eks:DescribeCluster on resource: arn:aws:eks:ap-southeast-1:133129065110:cluster/eksworkshop because no identity-based policy allows the eks:DescribeCluster action
```

以B身份执行，首先进入当前用户home目录下，删除掉旧的配置文件。这个目录是隐藏目录。Windows默认在 C:\Users\Administrator\.kube\config 位置。Linux默认在当前主目录下 ~/.kube/config 位置。

删除成功后，执行如下命令：

```shell
aws eks update-kubeconfig --region <region> --name <cluster-name>
```

即可为kubectl创建config文件。接下来可执行 `kubectl get nodes` 查看是否生效。

为进一步确认当前身份在集群内实际获得的权限，执行如下命令：

```shell
kubectl auth whoami
```

返回结果如下：

```
ATTRIBUTE                                              VALUE
Username                                               arn:aws:sts::133129065110:assumed-role/newrolename/session
UID                                                    aws-iam-authenticator:133129065110:<role-unique-id>
Groups                                                 [system:authenticated]
Extra: canonicalArn                                    [arn:aws:iam::133129065110:role/newrolename]
```

需要注意两种授权机制在此处的回显差异：通过Access Entries授权时，Groups 一列只显示 system:authenticated，管理员权限来自所关联的访问策略而非组映射；通过 aws-auth ConfigMap 授权时，Groups 一列会显示 `[system:masters system:authenticated]`。两者均可通过如下命令确认是否具备集群级管理权限：

```shell
kubectl auth can-i '*' '*' --all-namespaces
```

返回结果为 `yes` 即表示授权已经生效。若为只读授权并限定了命名空间，则在限定范围外执行查询会返回 Forbidden，属于预期行为。

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
