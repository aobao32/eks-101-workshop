# EKS使用预加载机制加速EC2 Nodegroup上大镜像的启动速度

## 目录

- 一、背景
- 二、测试环境准备
- 三、应用Yaml是否打开缓存开关的对比
- 四、使用EventBridge构建预加载
- 五、验证预缓存机制生效
- 六、参考文档

## 一、背景

在机器学习等场景下，可能需要在EKS上运行较大体积的Pod，其Image体积可能达到数个GB。此时在第一次启动Pod时候，会遇到所谓的冷启动问题，也就是EC2 Nodegroup需要从ECR容器镜像仓库去拉取较大尺寸的镜像，然后才能启动Pod。后续启动相同镜像即可利用缓存无须重复下载。此时，可以参考如下方法优化冷启动时间长的问题。

### 1、优化尺寸的几种方法

官方博客提到的几种优化方法：

- 让镜像最小化瘦身；
- 使用multi-stage builds去去除不需要的内容；
- 使用较大的EC2机型作为Nodegroup，因为较大的EC2机型其网络上限是10Gbps乃至25Gbps，100Gbps；
- 在EC2 Nodegroup上进行缓存。

### 2、在应用中复用ECR镜像缓存

在拉起应用的配置文件定义中，增加如下`imagePullPolicy`标签，即可复用EC2 Nodegroup节点上已经存在的缓存。

```yaml
    spec:
      containers:
      - name: bigimage2
        image: 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/bigimage:3
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 80
```

参数`IfNotPresent`表示复用EC2 Nodegroup节点上的缓存。那么对于第一次下载，是没有缓存的，还是需要比较长时间的冷启动。 为了解决冷启动，就需要预加载。

### 3、通过EventBridge和StepFunction自动推送镜像的方案

为了解决冷启动问题，可以使用EventBride采集ECR容器镜像的发布时间，当新的镜像推送到ECR后，通过EventBridge触发事件，然后通过System Manager向EC2 Nodegroup下发缓存命令，实现预加载。

详情参考[这篇](https://aws.amazon.com/cn/blogs/containers/start-pods-faster-by-prefetching-images/)博客。

本文后续篇幅将讲述本方案的部署。

### 4、使用BottleRocket作为Node底层系统实现快速启动的方案

BottleRocket是AWS开发的开源的、用于运行容器的操作系统，其体积更小、更安全。EKS默认使用Amazon Linux 2操作系统作为EC2 Nodegroup的默认OS，可选使用BottleRocket来作为操作系统运行容器。二者的区别是，使用Amazon Linux 2的Nodegroup只有唯一的EBS磁盘，操作系统和容器镜像缓存都在这个磁盘上。而使用BottleRocket作为OS，会使用两个EBS磁盘，分别作为OS系统盘和容器镜像的数据盘，由此当升级节点、替换节点时候只有系统盘被替换，存放容器镜像的EBS磁盘不会被替换。

篇幅所限，本文不会展开描述本方案。详情请参考[这篇](https://aws.amazon.com/cn/blogs/containers/reduce-container-startup-time-on-amazon-eks-with-bottlerocket-data-volume/)博客。

### 5、局限

以上均为不支持Fargate场景。Fargate应用拉起无法利用到缓存特性。

## 二、测试环境准备

### 1、构建应用

为了模拟大体积的容器镜像，本文使用Amazon Linux 2023的系统镜像填充到容器镜像中。下载地址在[这里](https://docs.aws.amazon.com/linux/al2023/ug/outside-ec2-download.html)。

构建Image的定义如下：

```yaml
FROM public.ecr.aws/amazonlinux/amazonlinux:2

# Install apache/php
RUN yum update -y && yum install httpd -y && yum clean all

# Install configuration file
ADD src/httpd.conf /etc/httpd/conf/
ADD src/run_apache.sh /root/
ADD src/test.html /var/www/html/
# 总体积约10GB
ADD src/al2023-kvm-2023.3.20231218.0-kernel-6.1-x86_64.xfs.gpt.qcow2    /root
ADD src/al2023-kvm-2023.3.20231218.0-kernel-6.1-x86_64.xfs.gpt.qcow2-2  /root
ADD src/al2023-kvm-2023.3.20231218.0-kernel-6.1-x86_64.xfs.gpt.qcow2-3  /root
ADD src/al2023-kvm-2023.3.20231218.0-kernel-6.1-x86_64.xfs.gpt.qcow2-4  /root
ADD src/al2023-kvm-2023.3.20231218.0-kernel-6.1-x86_64.xfs.gpt.qcow2-5  /root
ADD src/al2023-kvm-2023.3.20231218.0-kernel-6.1-x86_64.xfs.gpt.qcow2-6  /root
ADD src/al2023-kvm-2023.3.20231218.0-kernel-6.1-x86_64.xfs.gpt.qcow2-7  /root

# Configure apache
RUN chown -R apache:apache /var/www
RUN chmod +x /root/run_apache.sh
ENV APACHE_RUN_USER apache
ENV APACHE_RUN_GROUP apache
ENV APACHE_LOG_DIR /var/log/apache2

EXPOSE 80

# starting script for php-fpm and httpd
CMD ["/bin/bash", "-c", "/root/run_apache.sh"]
```

其中`run_apache.sh`的脚本如下。

```yaml
mkdir -p /var/run/apache2
mkdir -p /var/lock/apache2
/usr/sbin/php-fpm -D
/usr/sbin/httpd -D FOREGROUND
```

正常构建容器。

![](https://blogimg.bitipcman.com/workshop/eks101/ecr-cache/bigimage-02.png)

并上传到ECR。相关步骤，请参考[这篇](https://blog.bitipcman.com/push-docker-image-to-aws-ecr-docker-repository/)博客。

![](https://blogimg.bitipcman.com/workshop/eks101/ecr-cache/bigimage-01.png)

### 2、构建EC2 Nodegroup

现在创建一个EKS集群，使用两台EC2 Nodegroup节点。相关工具包括eksctl、kubectl等脚本的下载和使用请参考[本篇](https://blog.bitipcman.com/eks-workshop-101-part1/)博客。

定义如下配置文件：

```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: eksworkshop
  region: ap-southeast-1
  version: "1.28"

vpc:
  clusterEndpoints:
    publicAccess:  true
    privateAccess: true
  subnets:
    private:
      ap-southeast-1a: { id: subnet-04a7c6e7e1589c953 }
      ap-southeast-1b: { id: subnet-031022a6aab9b9e70 }
      ap-southeast-1c: { id: subnet-0eaf9054aa6daa68e }

kubernetesNetworkConfig:
  serviceIPv4CIDR: 10.50.0.0/24

managedNodeGroups:
  - name: managed-ng
    labels:
      Name: managed-ng
    instanceType: t3.xlarge
    minSize: 2
    desiredCapacity: 2
    maxSize: 2
    privateNetworking: true
    subnets:
      - subnet-04a7c6e7e1589c953
      - subnet-031022a6aab9b9e70
      - subnet-0eaf9054aa6daa68e
    volumeType: gp3
    volumeSize: 100
    tags:
      nodegroup-name: managed-ng
    iam:
      withAddonPolicies:
        imageBuilder: true
        autoScaler: true
        certManager: true
        efs: true
        ebs: true
        albIngress: true
        xRay: true
        cloudWatch: true

cloudWatch:
  clusterLogging:
    enableTypes: ["api", "audit", "authenticator", "controllerManager", "scheduler"]
    logRetentionInDays: 30
```

将以上配置文件保存为`eks-private-subnet.yaml`，然后执行如下命令启动集群。

```shell
eksctl create cluster -f eks-private-subnet.yaml
```

集群启动完成。这个集群将在私有子网启动，包括2个t3.xlarge节点组成NodeGroup。

### 3、构建测试应用

构建如下应用：

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bigimage2
  namespace: 	bigimage
  labels:
    app: bigimage2
spec:
  replicas: 2
  selector:
    matchLabels:
      app: bigimage2
  template:
    metadata:
      labels:
        app: bigimage2
    spec:
      containers:
      - name: bigimage2
        image: 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/bigimage:3
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: bigimage2
  namespace: bigimage
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
spec:
  selector:
    app: bigimage2
  type: LoadBalancer
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
```

在以上配置中，可看到`imagePullPolicy: IfNotPresent`参数表示如果镜像已经存在，则使用缓存。将以上文件保存为`bigimage.yaml`。

## 三、应用Yaml是否打开缓存开关的对比

### 1、查询Pod启动时间的脚本

这里使用Github上`aws-samples`库中的`containers-blog-maelstrom/prefetch-data-to-EKSnodes\get-pod-boot-time.sh`的脚本来统计Pod启动时间。由于Github上原始脚本没有指定Namespace，因此只能显示默认的default namespaces，所以这里增加了Namespaces输入参数。代码如下。

```shell
#!/usr/bin/env bash
namespace="$1"
pod="$2"
fail() {
  echo "$@" 1>&2
  exit 1
}
# https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-conditions
get_condition_time() {
  condition="$1"
  iso_time=$(kubectl get pod "$pod" --namespace "$namespace" -o json | jq ".status.conditions[] | select(.type == \"$condition\" and .status == \"True\") | .lastTransitionTime" | tr -d '"\n')
  test -n "$iso_time" || fail "Pod $pod is not in $condition yet"
  if [[ "$(uname)" == "Darwin" ]]; then
      date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso_time" +%s
  elif [[ "$(uname)" == "Linux" ]]; then
      date -d $iso_time +%s
  fi
}
initialized_time=$(get_condition_time PodScheduled)
ready_time=$(get_condition_time Ready)
duration_seconds=$(( ready_time - initialized_time ))
OS=$(uname)
echo "It took approximately $duration_seconds seconds for $pod to boot up and this script is ran on $OS operating system"
```

保存到本地，文件名为`get-pod-boot-time.sh`。在具有运行kubectl正确权限的环境下，运行命令：

```shell
./get-pod-boot-time.sh [namespace] [podname]
```

即可显示启动时间。

### 2、首次拉起没有缓存的测试

首先正常启动容器。

```shell
kubectl apply -f bigimage.yaml
```

![](https://blogimg.bitipcman.com/workshop/eks101/ecr-cache/bigimage-03.png)

可看到容器启动成功。现在使用上文的脚本，来查看Pod启动时间。

替换命令中的namespace和pod名称，执行命令如下：

```shell
./get-pod-boot-time.sh bigimage bigimage-57dd856658-chsd9
```

返回结果如下：

```
It took approximately 109 seconds for bigimage-57dd856658-chsd9 to boot up and this script is ran on Darwin operating system
```

测试结果时间：1分45秒左右，EC2 Nodegroup节点是t3.xlarge机型。

### 3、使用缓存的测试

再次启动一个新的应用，但是复用image。启动成功后，执行如下命令，查看Pod启动时间。

替换命令中的namespace和pod名称，执行命令如下：

```shell
./get-pod-boot-time.sh bigimage bigimage2-56bb8d5d6-6qw49
```

返回结果如下：

```
It took approximately 2 seconds for bigimage2-56bb8d5d6-6qw49 to boot up and this script is ran on Darwin operating system
```

花费时间：5秒左右。由此可看出，缓存明显提升了启动速度。

### 4、测试过程的录屏演示

![](https://video.bitipcman.com/eks-pull-cache.mp4)

### 5、测试流程小结

整个流程小结如下：

- 1、用Amazon linux 2 docker镜像，体积大约是100MB
- 2、从官网下载Amazon linxu 2023的ova虚拟机镜像版本，向docker内放入8个虚拟机镜像，每个1.2GB，总容量强- 行凑到10GB，然后build docker成功
- 3、docker上传到ECR后，ECR自动压缩，在ECR界面上显式为3.5GB
- 4、在EC2 nodegroup是t3.xlarge机型上（网卡up-to-5Gbps），node的EBS是100GB的gp3磁盘，拉起应用共花费1分45秒启动成功
- 5、在应用配置文件yaml中指定可利用缓存，使用相同image拉起新应用，大概不到5秒钟启动完毕

## 四、使用EventBridge进行预加载

前文介绍过，针对EKS的EC2 Nodegroup，可以使用预加载机制，通过EventBridge触发。

在实际使用EKS过程中，有两种场景需要考虑：

- 在ECR上发布最新版镜像后，现有Nodegroup节点已经缓存了旧版本的镜像，需要预加载最新版做缓存 —— EventBridge + System Manager RunCommend ；
- EKS的Nodegroup扩容，新增了新的EC2节点，此时EC2节点上还没有任何一个版本做过缓存，需要预加载最新版做缓存 —— EventBridge + System Manager State Manager 。

两种场景的配置过程如下。

### 1、创建EventBridge要使用的IAM Role

配置IAM Role可以通过AWS控制台，也可以通过AWSCLI，二者效果一样。本文使用CLI创建。

准备IAM Role配置如下：

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": "sts:AssumeRole",
            "Principal": {
                "Service": "events.amazonaws.com"
            },
            "Effect": "Allow",
            "Sid": ""
        }
    ]
}
```

将其保存为`iam-role.json`，然后使用AWSCLI如下命令创建这个IAM Role。

```shell
aws iam create-role --role-name ecr-push-cache --assume-role-policy-document file://iam-role.json
```

返回结果如下表示创建成功：

```json
{
    "Role": {
        "Path": "/",
        "RoleName": "ecr-push-cache",
        "RoleId": "AROAR57Y4KKLDNVZCM4TO",
        "Arn": "arn:aws:iam::133129065110:role/ecr-push-cache",
        "CreateDate": "2023-12-26T04:50:16+00:00",
        "AssumeRolePolicyDocument": {
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Action": "sts:AssumeRole",
                    "Principal": {
                        "Service": "events.amazonaws.com"
                    },
                    "Effect": "Allow",
                    "Sid": ""
                }
            ]
        }
    }
}
```

最终生成的IAM Role名称是`ecr-push-cache`，后文会使用这个名称。

### 2、挂载IAM Policy到上一步创建的Role

编写如下一段IAM Policy，请替换其中的Region代号、AWS账户ID（12位数字）、以及集群名称`eksworkshop`替换为实际的名称

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": "ssm:SendCommand",
            "Effect": "Allow",
            "Resource": [
                "arn:aws:ec2:ap-southeast-1:133129065110:instance/*"
            ],
            "Condition": {
                "StringEquals": {
                    "ec2:ResourceTag/*": [
                        "eksworkshop"
                    ]
                }
            }
        },
        {
            "Action": "ssm:SendCommand",
            "Effect": "Allow",
            "Resource": [
                "arn:aws:ssm:ap-southeast-1:*:document/AWS-RunShellScript"
            ]
        }
    ]
}
```

将其保存为`iam-policy.json`，然后使用AWSCLI如下命令将这个IAM Policy挂载到上一步创建的IAM Role上。请注意替换上一步创建IAM Role的名称。

```shell
aws iam put-role-policy --role-name ecr-push-cache --policy-name ecr-push-cache-ssm-policy --policy-document file://iam-policy.json
```

配置成功则返回命令行，否则会提示错误信息。

### 3、创建EventBridge规则

配置EventBridge可以通过AWS控制台，也可以通过AWSCLI，二者效果一样。但是由于在AWS控制台上配置EventBridge步骤较多，页面跳转和输入选项复杂，容易遗漏和出错，因此本文通过AWSCLI预先写好的JSON格式的配置文件，快速加载配置。

准备如下一段EventBridge配置规则，替换其中的`Name`为规则的名称，此处可以自定义。在`repository-name`位置，输入ECR容器镜像仓库的名称为实际名称。注意这里不是写完整URI，因此不需要带有容器镜像仓库的网址，也不要带有tag，只是名称。例如本文叫做`bigimage`。

```json
{
    "Name": "ecr-push-cache",
    "Description": "Rule to trigger SSM Run Command on ECR Image PUSH Action Success",
    "EventPattern": "{\"source\": [\"aws.ecr\"], \"detail-type\": [\"ECR Image Action\"], \"detail\": {\"action-type\": [\"PUSH\"], \"result\": [\"SUCCESS\"], \"repository-name\": [\"bigimage\"]}}"
}
```

将其保存为`event-rule.json`，然后使用AWSCLI如下命令将这个规则配置到EventBridge上。请注意文件名和对应region的正确。执行如下命令：

```shell
aws events put-rule --cli-input-json file://event-rule.json --region ap-southeast-1
```

配置成功，返回信息如下：

```json
{
    "RuleArn": "arn:aws:events:ap-southeast-1:133129065110:rule/ecr-push-cache"
}
```

在配置完成后，通过EventBridge控制台在搜索框内输入名字，即可看到刚才创建的规则。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/ecr-cache/bigimage-04.png)

点击规则进入查看详情，可以在第一个标签页`Event pattern`下看到刚才配置的规则。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/ecr-cache/bigimage-05.png)

接下来继续配置规则的Target对象。

### 4、配置EventBridge规则的Target（用于现有EC2预加载最新版镜像）

准备如下一段Target规则，其中多处要替换：

```json
  {
      "Targets": [{
          "Id": "Id4000985d-1b4b-4e14-8a45-b04103f9871b",
          "Arn": "arn:aws:ssm:ap-southeast-1::document/AWS-RunShellScript",
          "RoleArn": "arn:aws:iam::133129065110:role/ecr-push-cache",
          "Input": "{\"commands\":[\"tag=$(aws ecr describe-images --repository-name bigimage --query 'sort_by(imageDetails,& imagePushedAt)[-1].imageTags[0]' --output text)\",\"sudo ctr -n k8s.io images pull -u AWS:$(aws ecr get-login-password) 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/bigimage:$tag\"]}",
          "RunCommandParameters": {
              "RunCommandTargets": [{
                  "Key": "tag:Name",
                  "Values": ["eksworkshop-managed-ng-Node"]
              }]
          }
      }]
  }
```

替换的内容如下：

- Arn部分的Region代号要替换
- RoleArn里边的Region代号、IAM Role名称要替换
- Input中的ECR仓库名称要替换（多处），Region代号要替换（多处）
- RunCommandParameters中的集群名称要替换（本文是`eksworkshop`，替换时候要保留`-managed-ng-Node`这个后缀）

替换后效果如下：

![](https://blogimg.bitipcman.com/workshop/eks101/ecr-cache/bigimage-06-2.png)

将其保存为`rule-targe.json`，然后使用AWSCLI如下命令将这个规则配置到EventBridge的Rule上。请注意替换上一步使用的Rule规则名称，文件名和对应region的正确。执行如下命令：

```shell
aws events put-targets --rule ecr-push-cache --cli-input-json file://rule-target.json --region ap-southeast-1
```

配置成功，返回如下：

```json
{
    "FailedEntryCount": 0,
    "FailedEntries": []
}
```

在配置完成后，通过EventBridge控制台，就可以看到规则下能显示出来target了。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/ecr-cache/bigimage-07-2.png)

### 5、配置System Manager的State Manager任务（用于新扩容的EC2预加载最新版镜像）

编辑如下一段配置文件，替换其中的关键字，包括Targets下的集群名称（保留`-managed-ng-Node`作为后缀）替换，commands里边的Region代号、ECR仓库名称等。最后一个参数`AssociationName`是最终在System Manager上创建后显示的名称，可自定义输入，后续用于查找和区分任务。

```json
{
  "Name": "AWS-RunShellScript",
  "Targets": [
    {
      "Key": "tag:Name",
      "Values": ["eksworkshop-managed-ng-Node"]
    }
  ],
  "Parameters": {
    "commands": [
      "tag=$(aws ecr describe-images --repository-name bigimage --query 'sort_by(imageDetails,& imagePushedAt)[-1].imageTags[0]' --output text)",
      "sudo ctr -n k8s.io images pull -u AWS:$(aws ecr get-login-password) 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/bigimage:$tag"
    ]
  },
  "AssociationName": "ecr-push-image"
}
```

替换效果如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/ecr-cache/bigimage-08-2.png)

将其保存为`ssm-command.json`，构建如下AWSCLI命令，请注意替换上一步使用的Rule规则名称，文件名和对应region的正确。执行如下命令：

```shell
aws ssm create-association --cli-input-json file://ssm-command.json --region ap-southeast-1
```

配置成功则返回：

```json
{
    "AssociationDescription": {
        "Name": "AWS-RunShellScript",
        "AssociationVersion": "1",
        "Date": "2023-12-26T15:23:49.523000+08:00",
        "LastUpdateAssociationDate": "2023-12-26T15:23:49.523000+08:00",
        "Overview": {
            "Status": "Pending",
            "DetailedStatus": "Creating"
        },
        "DocumentVersion": "$DEFAULT",
        "Parameters": {
            "commands": [
                "tag=$(aws ecr describe-images --repository-name bigimage --query 'sort_by(imageDetails,& imagePushedAt)[-1].imageTags[0]' --output text)",
                "sudo ctr -n k8s.io images pull -u AWS:$(aws ecr get-login-password) 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/bigimage:$tag"
            ]
        },
        "AssociationId": "176524fc-7dd5-4e61-9111-ace738f0d122",
        "Targets": [
            {
                "Key": "tag:Name",
                "Values": [
                    "eksworkshop-managed-ng-Node"
                ]
            }
        ],
        "AssociationName": "ecr-push-image",
        "ApplyOnlyAtCronInterval": false
    }
}
```

配置成功后，可以在System Manager中看到这一个命令。从AWS控制台左上角，搜索关键字`System Manager`，点击服务进入。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/ecr-cache/bigimage-09.png)

从左侧菜单中，找到`Node Management`，点击`State Manager`，右侧清单中可看到名为`ecr-push-image`的任务。这个名称是上一步JSON文件中指定的。

![](https://blogimg.bitipcman.com/workshop/eks101/ecr-cache/bigimage-10.png)

至此配置完成。

现在来验证整个机制工作正常。

## 五、验证预缓存机制生效

这里验证两个场景：

- 1、现有EC2 Nodegroup不变，之前启动过旧版本，现在发布新版镜像到ECR，观察所有EC2 Nodegroup是否会自动获取新镜像作为缓存；
- 2、集群变配或者升级，增加新的EC2 Nodegroup到集群，观察新的EC2 Nodegroup是否会自动获取新镜像作为缓存。

### 1、新发布新版镜像到ECR后查看预加载

现在修改容器镜像定义，将其中的大文件改名，即可触发生成新的层（layer）。修改后上传到ECR。进入ECR界面，确认最新版上传成功。

执行如下命令，确认预加载是否成功。

```shell
aws ssm list-command-invocations --details \
  --filter "[{\"key\": \"DocumentName\", \"value\": \"arn:aws:ssm:ap-southeast-1::document/AWS-RunShellScript\"}]" \
  --region ap-southeast-1
```

如果返回一个空的大括号，表示配置错误，没有正确执行。返回结果如下表示执行成功：

```json
{
    "CommandInvocations": [
        {
            "CommandId": "617e3255-ddae-41f1-9cf0-9d440e2ed594",
            "InstanceId": "i-0cea3f7b2c93968d0",
            "InstanceName": "ip-172-31-53-43.ap-southeast-1.compute.internal",
            "Comment": "",
            "DocumentName": "arn:aws:ssm:ap-southeast-1::document/AWS-RunShellScript",
            "DocumentVersion": "$DEFAULT",
            "RequestedDateTime": "2023-12-26T23:23:16.835000+08:00",
            "Status": "Success",
            "StatusDetails": "Success",
            "StandardOutputUrl": "",
            "StandardErrorUrl": "",
            "CommandPlugins": [
                {
                    "Name": "aws:runShellScript",
                    "Status": "Success",
                    "StatusDetails": "Success",
                    "ResponseCode": 0,
                    "ResponseStartDateTime": "2023-12-26T23:23:17.010000+08:00",
                    "ResponseFinishDateTime": "2023-12-26T23:23:19.126000+08:00",
                    "Output": "133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/bigimage:6: resolving      |\u001b[32m\u001b[0m--------------------------------------| \nelapsed: 0.1 s                                                total:   0.0 B (0.0 B/s)                                         \n133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/bigimage:6:                     resolved       |\u001b[32m++++++++++++++++++++++++++++++++++++++\u001b[0m| \nmanifest-sha256:3c19f93e9afadec0642739284d6de1ec30e664d4e23556c26e471b52663592e0: done           |\u001b[32m++++++++++++++++++++++++++++++++++++++\u001b[0m| \nlayer-sha256:a9b83078f411c227d05f22f80d86d4e39633a9d086b2bc016026c958716ed960:    done           |\u001b[32m++++++++++++++++++++++++++++++++++++++\u001b[0m| \nlayer-sha256:afaad9788645da2e5b4c9c362c0a952273b0175d1809530e3edd975d401ec667:    done           |\u001b[32m++++++++++++++++++++++++++++++++++++++\u001b[0m| \nlayer-sha256:81c894a2e8d3d6d5b53909a6e5e1dbd8fff112528736262585403a7395bbb099:    done           |\u001b[32m++++++++++++++++++++++++++++++++++++++\u001b[0m| \nlayer-sha256:acf174ffa6c76e77d73ba88d7db6ba6f14052e82088447d739951511b7662b31:    done           |\u001b[32m++++++++++++++++++++++++++++++++++++++\u001b[0m| \nconfig-sha256:030bc9b779c05f02daf7d0e362cb5d16032f2a84f736c30eca1ece950e74d5dc:   done           |\u001b[32m++++++++++++++++++++++++++++++++++++++\u001b[0m| \nlayer-sha256:994cb88ff790af5dd5ca5db37db091cfbcef49f7ba6d51c8998a779d9debb584:    done           |\u001b[32m++++++++++++++++++++++++++++++++++++++\u001b[0m| \nlayer-sha256:bbb5b4eb3b657fc15c2f54e8893ed2cff3aaf9e0344c360c8e9be1c8ff6cb099:    done           |\u001b[32m++++++++++++++++++++++++++++++++++++++\u001b[0m| \nlayer-sha256:6ebddf7084e9402a3ba6cf1360703e12633f9c49f51772f99c298cd1048d728e:    done           |\u001b[32m++++++++++++++++++++++++++++++++++
++++\u001b[0m| \nelapsed: 0.2 s                                                                    total:   0.0 B (0.0 B/s)                                         \nunpacking linux/amd64 sha256:3c19f93e9afadec0642739284d6de1ec30e664d4e23556c26e471b52663592e0...\ndone: 11.718685ms\t\n",
                    "StandardOutputUrl": "",
                    "StandardErrorUrl": "",
                    "OutputS3Region": "ap-southeast-1",
                    "OutputS3BucketName": "",
                    "OutputS3KeyPrefix": ""
                }
            ],
            "ServiceRole": "",
            "NotificationConfig": {
                "NotificationArn": "",
                "NotificationEvents": [],
                "NotificationType": ""
            },
            "CloudWatchOutputConfig": {
                "CloudWatchLogGroupName": "",
                "CloudWatchOutputEnabled": false
            }
        },
```

在System Manager的RunShellScript命令执行后，可以进一步登录到EC2 Nodegroup的节点上，查询镜像是否被缓存。操作方法是，进入EC2控制台，选中EC2实例，点击`Connect`按钮。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/ecr-cache/bigimage-11.png)

点击`Connect`按钮后，即可登录到EKS的EC2 Nodegroup节点。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/ecr-cache/bigimage-12.png)

执行如下命令查询特定的ECR镜像名称，替换`bigimage`为ECR上镜像名称即可。

```shell
ctr -n k8s.io images ls | grep bigimage
```

此步骤，也可以通过AWSCLI并搭配Session Manager在EC2 Nodegroup上执行查询，确认镜像是否缓存成功。

```shell
aws ec2 describe-instances \
    --filters "Name=tag:eks:cluster-name,Values=eksworkshop" "Name=tag:eks:nodegroup-name,Values=managed-ng" \
    --query "Reservations[*].Instances[*].InstanceId" \
    --output text \
    --region ap-southeast-1 | xargs -I {} aws ssm start-session \
    --target {} \
    --document-name AWS-StartInteractiveCommand \
    --parameters "command=echo \$(curl -s http://169.254.169.254/latest/meta-data/instance-id) && sudo ctr -n k8s.io images ls | grep bigimage" \
    --region ap-southeast-1
```

在上述其中，需要替换：

- 替换`--filters`中第1个Values是集群名称，本例为`eksworkshop`
- 替换`--filters`中第2个Values是Nodegroup的标签，本例为`managed-ng`
- 替换region（有两处）
- 替换ECR容器镜像仓库的名称，在`parameters`末尾，本例为`bigimage`

执行后，返回结果如下表示查询到缓存：

```shell
Starting session with SessionId: pcman-0d6a82887247367cf

133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/bigimage:1                                                                                              application/vnd.docker.distribution.manifest.v2+json      sha256:52ad7265deccdafea6bb97874df28d02748e84bd84c6b43c67732a9284280fc5 95.6 MiB  linux/amd64                           io.cri-containerd.image=managed
133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/bigimage:3                                                                                              application/vnd.docker.distribution.manifest.v2+json      sha256:53aa09537a4f212d3814f87995424ed4e88969e84f8754a3f2ec4c26eec433ed 3.3 GiB   linux/amd64                           io.cri-containerd.image=managed
133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/bigimage:6                                                                                              application/vnd.docker.distribution.manifest.v2+json      sha256:3c19f93e9afadec0642739284d6de1ec30e664d4e23556c26e471b52663592e0 207.9 MiB linux/amd64                           io.cri-containerd.image=managed
133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/bigimage@sha256:52ad7265deccdafea6bb97874df28d02748e84bd84c6b43c67732a9284280fc5                        application/vnd.docker.distribution.manifest.v2+json      sha256:52ad7265deccdafea6bb97874df28d02748e84bd84c6b43c67732a9284280fc5 95.6 MiB  linux/amd64                           io.cri-containerd.image=managed
133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/bigimage@sha256:53aa09537a4f212d3814f87995424ed4e88969e84f8754a3f2ec4c26eec433ed                        application/vnd.docker.distribution.manifest.v2+json      sha256:53aa09537a4f212d3814f87995424ed4e88969e84f8754a3f2ec4c26eec433ed 3.3 GiB   linux/amd64                           io.cri-containerd.image=managed

Exiting session with sessionId: pcman-0d6a82887247367cf.
Starting session with SessionId: pcman-01c9b3556a3ccf42c
Cannot perform start session: EOF
```

由此可看到，节点已经加载了缓存。

现在使用使用这个镜像，去启动一个全新的应用，并且可运行在不同的Namespace下。然后用上一章节的办法查询Pod启动时间，可看到Pod在1-2秒内就完成了启动。

### 2、集群变配增加新的EC2 Nodegroup节点后查看预加载

在集群变配场景下，现有应用在现存节点是有缓存的，但Nodegroup中新生成的EC2是没有下载过任何一个镜像的，因此对于这些新节点，所有启动都是冷启动，需要从ECR加载镜像。按照本文配置过System Manager State Manager之后，新扩容出来的节点，也会自动缓存制定的镜像。

首先进行节点扩容。请替换Cluster名称、Nodegroup名称和区域ID三个参数，然后执行如下命令。

```shell
eksctl scale nodegroup \
  --cluster eksworkshop \
  --name managed-ng \
  --nodes 3 \
  --nodes-min 2 \
  --nodes-max 4 \
  --region ap-southeast-1
```

为了确认是否触发了System Manager的State Manager，可以进入State Manager，找到上一步配置的`ecr-push-image`任务，查看其上一次运行的历史记录。

在运行历史中，可看到其最新一次状态是失败，提示1个成功1个失败。这是正常的。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/ecr-cache/bigimage-13.png)

点击详情，进入State Manager的任务，可看到里边有2个EC2，其中新的一个运行成功，表示加载了最新镜像。另一个运行错误没有关系，这是因为之前的老的节点，已经有了缓存。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/ecr-cache/bigimage-14.png)

为了进一步确认加载成功，现在登录到EC2上查询。按照上文的方法，使用Session Manager登录到Nodegroup新扩容出来的EC2上，执行如下命令查询特定的ECR镜像名称，替换`bigimage`为ECR上镜像名称即可。

```shell
ctr -n k8s.io images ls | grep bigimage
```

由此可看到新EC2节点也有了缓存文件。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/ecr-cache/bigimage-15.png)

现在拉起新的应用，可看到应用在几秒内启动完毕。

至此验证配置成功。

注意：新拉起Node之后，全新加载一个较大的image需要非t系列的机型、已经配置较高的EBS IOPS。如果是使用默认的gp3/3000iops/125MB吞吐，那么首次启动加载时间会稍长，但依然小于从ECR下载Image所需的时间，后续推送新镜像的速度也都会很快。如果EC2 Nodegroup拉起的是c/m/r系列机型且gp3磁盘配置了较高的iops，那么Pod启动会在几秒内即可完成。

## 六、参考文档

部署示例应用程序

[https://docs.aws.amazon.com/zh_cn/eks/latest/userguide/sample-deployment.html]()

Start Pods faster by prefetching images

[https://aws.amazon.com/cn/blogs/containers/start-pods-faster-by-prefetching-images/]()

Reduce container startup time on Amazon EKS with Bottlerocket data volume

[https://aws.amazon.com/cn/blogs/containers/reduce-container-startup-time-on-amazon-eks-with-bottlerocket-data-volume/]()

Improve container startup time by caching images

[https://github.com/aws-samples/containers-blog-maelstrom/tree/main/prefetch-data-to-EKSnodes]()

Reducing AWS Fargate Startup Times with zstd Compressed Container Images

[https://aws.amazon.com/cn/blogs/containers/reducing-aws-fargate-startup-times-with-zstd-compressed-container-images/]()