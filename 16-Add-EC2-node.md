# 将EC2手工加入EKS集群成为托管节点

## 一、背景

### 1、EKS服务使用EC2的两种模式

EKS服务使用EC2的两种模式

- 使用EKS自动生成的托管节点组：在EKS服务控制台或者通过eksctl命令完成，EKS会自动使用最新镜像，全自动创建，并使用Autoscaling缩放；如果是通过eksctl脚本，还会自动创建合适的IAM角色；这时候EC2会在托管节点组内。
- 使用EKS提供的AMI以托管节点方式自行加入集群：使用EKS官方提供的基础镜像，手工创建一个EC2，并手工配置IAM角色，然后使用bootstrap.sh脚本，将本EC2加入EKS集群；这时候EC2会成为托管节点，但不会进入上一步的托管节点组。

以上两种方式，都是EKS托管节点，意味着EKS可有效进行版本升级等管理。不过不在节点组中的EC2不能参与缩放，当节点不够用时候，需要手工拉起新的节点。

本文介绍第二种方式的使用。

### 2、手工加入EC2到EKS成为托管节点的必要条件

前提条件：

- 镜像来自AWS的EKS服务官方列表
- EKS控制平面允许网络连接（配置为Public&Private，或者其他满足EC2能连接的方式）
- EC2使用的安全组正确（出站可抵达API Server）
- 在EC2上使用curl验证EKS API可通达
- EC2使用的IAM Role正确
- 拉起的EC2的AMI是最新的托管镜像，与EKS控制平面版本相同（最多只能差1个小版本）
- 拉起的AMI是从官方AMI全新拉起，不是之前加入过别的集群后二次快照的镜像

## 二、创建EC2

### 1、查询要使用的AMI

使用AWSCLI可快速查询EKS服务官方AMI。注意替换如下命令中的区域。

查询Intel/AMD处理器的x86_64架构的命令如下：

```
aws ssm get-parameter --name /aws/service/eks/optimized-ami/1.28/amazon-linux-2/recommended/image_id --region ap-southeast-1 --query "Parameter.Value" --output text
```

查询ARM架构处理器的命令如下：

```
aws ssm get-parameter --name /aws/service/eks/optimized-ami/1.28/amazon-linux-2-arm64/recommended/image_id --region ap-southeast-1 --query "Parameter.Value" --output text
```

以查询x86_64架构为例，返回结果如下。

```
ami-0907f9c3714b53d1d
```

### 2、查询已经存在的托管节点组EC2使用的安全组

找到EKS集群已经存在的托管节点组EC2，查看其安全标签页，找到当前使用的安全组。复制下来名称，后续将要继续使用。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/node/node-04.png)


### 3、查询已经存在的托管节点组EC2使用IAM Role角色

找到EKS集群已经存在的托管节点组EC2，查看其安全标签页，找到当前使用的IAM Role的信息。点击进入，跳转到IAM页面。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/node/node-05.png)

在跳转到IAM页面后，可以在右侧看到`Instance profile ARN`，其中的`profile/`后边的这一个字符串，就是EKS集群节点组使用的IAM Role对应的Profile ID。将这个ID复制下来名称，后续将要继续使用。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/node/node-06.png)

### 4、用上述参数创建EC2

接下来以如上参数，包括AMI在对应的区域和VPC内，创建EC2。创建时候磁盘选择gp3，容量建议最小30GB，安全组如上选择，IAM Role如上选择。其他选项可暂不配置。

在创建向导页面最下方，点击Advanced高级设置，在`IAM instance profile`位置，选择上一步查找的IAM Profile ID的名称。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/node/node-07.png)

如果在创建EC2时候，并没有分配正确的IAM Role，那么可以在创建完成后，随时修改IAM Role。方法是从操作菜单中找到安全，找到里边的`Modify IAM role`选项。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/node/node-08.png)

EC2绑定的IAM Role只能是唯一的一个，不能像安全组那样绑定多个。请注意。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/node/node-09.png)

创建EC2完成。

## 三、查询现有EKS集群配置

### 1、查询Cluster CA证书

执行如下命令：

```
aws eks describe-cluster --query "cluster.certificateAuthority.data" --output text --name eksworkshop
```

返回结果就是证书内容。

此外，还可以到EKS控制台上查看。查看位置如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/node/node-01.png)

### 2、查询API Server Endpoint的地址

执行如下命令：

```
aws eks describe-cluster --query "cluster.endpoint" --output text --name eksworkshop
```

返回结果就是API Server地址。

```
https://D4EEF0B352E50F312F2F94C8E387E4F5.gr7.ap-southeast-1.eks.amazonaws.com
```

此外，还可以到EKS控制台上查看。查看方法如上一步的截图。

### 3、查询Cluster的DNS地址

执行如下命令：

```
kubectl get services -A
```

返回结果是负责DNS的Service IP地址：

```
NAMESPACE     NAME         TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)         AGE
default       kubernetes   ClusterIP   10.50.0.1    <none>        443/TCP         42h
kube-system   kube-dns     ClusterIP   10.50.0.10   <none>        53/UDP,53/TCP   42h
```

在本例中，将使用`10.50.0.10`作为集群DNS的IP。EKS默认的DNS一般都是`.10`。

此外，还可以到EKS控制台上查看。查看方法是进入EKS集群，找到`Resource`资源标签页，点击其中的`Service and networking`服务和网络，从第一个菜单`Service`服务中，找到右侧的`kube-dns`。点击查看。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/node/node-02.png)

从`kube-dns`服务的详情中，可看到服务IP是`10.50.0.10`。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/node/node-03.png)

### 4、验证本EC2可以到达EKS网络平面

登录到上一步创建好的EC2上，确认EC2可以访问EKS的API，执行如下命令：

```
curl -k https://D4EEF0B352E50F312F2F94C8E387E4F5.gr7.ap-southeast-1.eks.amazonaws.com/livez?verbose 
```

返回结果如下表示正常：

```
[+]ping ok
[+]log ok
[+]etcd ok
[+]poststarthook/start-kube-apiserver-admission-initializer ok
[+]poststarthook/generic-apiserver-start-informers ok
[+]poststarthook/priority-and-fairness-config-consumer ok
[+]poststarthook/priority-and-fairness-filter ok
[+]poststarthook/storage-object-count-tracker-hook ok
[+]poststarthook/start-apiextensions-informers ok
[+]poststarthook/start-apiextensions-controllers ok
[+]poststarthook/crd-informer-synced ok
[+]poststarthook/start-service-ip-repair-controllers ok
[+]poststarthook/rbac/bootstrap-roles ok
[+]poststarthook/scheduling/bootstrap-system-priority-classes ok
[+]poststarthook/priority-and-fairness-config-producer ok
[+]poststarthook/start-system-namespaces-controller ok
[+]poststarthook/bootstrap-controller ok
[+]poststarthook/start-cluster-authentication-info-controller ok
[+]poststarthook/start-kube-apiserver-identity-lease-controller ok
[+]poststarthook/start-deprecated-kube-apiserver-identity-lease-garbage-collector ok
[+]poststarthook/start-kube-apiserver-identity-lease-garbage-collector ok
[+]poststarthook/start-legacy-token-tracking-controller ok
[+]poststarthook/aggregator-reload-proxy-client-cert ok
[+]poststarthook/start-kube-aggregator-informers ok
[+]poststarthook/apiservice-registration-controller ok
[+]poststarthook/apiservice-status-available-controller ok
[+]poststarthook/kube-apiserver-autoregistration ok
[+]autoregister-completion ok
[+]poststarthook/apiservice-openapi-controller ok
[+]poststarthook/apiservice-openapiv3-controller ok
[+]poststarthook/apiservice-discovery-controller ok
livez check passed
```

至此准备工作完毕。

## 四、将EC2作为托管节点加入集群

将上文步骤查询到的参数整合到如下脚本中，可以使用以下三种方式，三选一，即可将EC2加入集群。

### 1、在EC2节点上手工执行命令加入集群

使用Session Manager或者其他方式，登录到本文第二章创建的EC2上，在根据本文第三章查询的参数，拼接如下命令：

```
/etc/eks/bootstrap.sh eksworkshop \
  --b64-cluster-ca LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSURCVENDQWUyZ0F3SUJBZ0lJT0pBc1JwK3NiZmd3RFFZSktvWklodmNOQVFFTEJRQXdGVEVUTUJFR0ExVUUKQXhNS2EzVmlaWEp1WlhSbGN6QWVGdzB5TXpFeE1UVXdOekU0TVRSYUZ3MHpNekV4TVRJd056SXpNVFJhTUJVeApFekFSQmdOVkJBTVRDbXQxWW1WeWJtVjBaWE13Z2dFaU1BMEdDU3FHU0liM0RRRUJBUVVBQTRJQkR3QXdnZ0VLCkFvSUJBUURIc2ZwbVNlb2tQek8vcEg2Rk9mWUZla2U1WGwwSTc0ZHplTnBWZ2 \
  --apiserver-endpoint https://D4EEF0B352E50F312F2F94C8E387E4F5.gr7.ap-southeast-1.eks.amazonaws.com \
  --dns-cluster-ip 10.50.0.10 \
  --container-runtime containerd \
  --kubelet-extra-args '--max-pods=100' \
  --use-max-pods false
```

在执行此命令后，返回如下信息，加入集群成功。

```
2023-11-17T02:16:06+0000 [eks-bootstrap] INFO: starting...
2023-11-17T02:16:06+0000 [eks-bootstrap] INFO: --b64-cluster-ca='LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSURCVENDQWUyZ0F3SUJBZ0lJT0pBc1JwK3NiZmd3RFFZSktvWklodmNOQVFFTEJRQXdGVEVUTUJFR0ExVUUKQXhNS2EzVmlaWEp1WlhSbGN6QWVGdzB5TXpFeE1UVXdOekU0TVRSYUZ3MHpNekV4TVRJd056SXpNVFJhTUJVeApFekFSQmdOVkJBTVRDbXQxWW1WeWJtVjBaWE13Z2dFaU1BMEdDU3FHU0liM0RRRUJBUVVBQTRJQkR3QXdnZ0VLCkFvSUJBUURIc2ZwbVNlb2tQek8vcEg2Rk9mWUZla2U1WGwwSTc0ZHplTnBWZ2'
2023-11-17T02:16:06+0000 [eks-bootstrap] INFO: --apiserver-endpoint='https://D4EEF0B352E50F312F2F94C8E387E4F5.gr7.ap-southeast-1.eks.amazonaws.com'
2023-11-17T02:16:06+0000 [eks-bootstrap] INFO: --dns-cluster-ip='10.50.0.10'
2023-11-17T02:16:06+0000 [eks-bootstrap] INFO: --container-runtime='containerd'
2023-11-17T02:16:06+0000 [eks-bootstrap] INFO: --kubelet-extra-args='--max-pods=100'
2023-11-17T02:16:06+0000 [eks-bootstrap] INFO: --use-max-pods='false'
2023-11-17T02:16:06+0000 [eks-bootstrap] INFO: Using kubelet version 1.28.3
2023-11-17T02:16:06+0000 [eks-bootstrap] INFO: Using containerd as the container runtime
‘/etc/eks/configure-clocksource.service’ -> ‘/etc/systemd/system/configure-clocksource.service’
2023-11-17T02:16:07+0000 [eks-bootstrap] INFO: Using IP family: ipv4
++ imds /latest/meta-data/instance-id
+ INSTANCE_ID=i-0fedf1e3889b81cda
++ imds /latest/meta-data/placement/region
+ REGION=ap-southeast-1
+ PRIVATE_DNS_NAME_MAX_ATTEMPTS=20
+ PRIVATE_DNS_NAME_ATTEMPT_INTERVAL=6
+ log 'will make up to 20 attempt(s) every 6 second(s)'
++ date +%Y-%m-%dT%H:%M:%S%z
+ echo 2023-11-17T02:16:07+0000 '[private-dns-name]' 'will make up to 20 attempt(s) every 6 second(s)'
2023-11-17T02:16:07+0000 [private-dns-name] will make up to 20 attempt(s) every 6 second(s)
+ ATTEMPT=0
+ true
++ aws ec2 describe-instances --region ap-southeast-1 --instance-ids i-0fedf1e3889b81cda
++ jq -r '.Reservations[].Instances[].PrivateDnsName'
+ PRIVATE_DNS_NAME=ip-192-168-117-179.ap-southeast-1.compute.internal
+ '[' '!' ip-192-168-117-179.ap-southeast-1.compute.internal = '' ']'
+ break
+ '[' ip-192-168-117-179.ap-southeast-1.compute.internal = '' ']'
+ log 'INFO: retrieved PrivateDnsName: ip-192-168-117-179.ap-southeast-1.compute.internal'
++ date +%Y-%m-%dT%H:%M:%S%z
+ echo 2023-11-17T02:16:08+0000 '[private-dns-name]' 'INFO: retrieved PrivateDnsName: ip-192-168-117-179.ap-southeast-1.compute.internal'
2023-11-17T02:16:08+0000 [private-dns-name] INFO: retrieved PrivateDnsName: ip-192-168-117-179.ap-southeast-1.compute.internal
+ echo ip-192-168-117-179.ap-southeast-1.compute.internal
+ exit 0
‘/etc/eks/containerd/containerd-config.toml’ -> ‘/etc/containerd/config.toml’
‘/etc/eks/containerd/sandbox-image.service’ -> ‘/etc/systemd/system/sandbox-image.service’
‘/etc/eks/containerd/kubelet-containerd.service’ -> ‘/etc/systemd/system/kubelet.service’
Created symlink from /etc/systemd/system/multi-user.target.wants/kubelet.service to /etc/systemd/system/kubelet.service.
2023-11-17T02:16:11+0000 [eks-bootstrap] INFO: complete!
```

以上提示信息显示加入集群成功。

### 2、验证加入集群成功

登录到EKS服务界面，可从Compute界面中看到这台EC2加入集群成功。

![](https://blogimg.bitipcman.com/workshop/eks101/node/node-10.png)

在上述截图中，可看到三个EC2节点的Nodegroup。

在命令行执行如下命令，验证加入集群成功：

```
kubectl get nodes
```

返回结果如下：

```
NAME                                                 STATUS   ROLES    AGE   VERSION
ip-192-168-117-179.ap-southeast-1.compute.internal   Ready    <none>   97m   v1.28.3-eks-e71965b
ip-192-168-27-221.ap-southeast-1.compute.internal    Ready    <none>   91m   v1.28.3-eks-e71965b
ip-192-168-56-207.ap-southeast-1.compute.internal    Ready    <none>   91m   v1.28.3-eks-e71965b
ip-192-168-89-110.ap-southeast-1.compute.internal    Ready    <none>   91m   v1.28.3-eks-e71965b
```

由此可看到EKS集群中，已经包含了新加入的节点。

如果本机安装了eksctl工具，还可以通过eksctl来确认：

```
eksctl get nodegroup --cluster eksworkshop
```

返回结果如下：

```
CLUSTER		NODEGROUP	STATUS	CREATED			MIN SIZE	MAX SIZE	DESIRED CAPACITY	INSTANCE TYPE	IMAGE ID	ASG  NAME					    	TYPE
eksworkshop	managed-ng	ACTIVE	2023-11-15T07:30:43Z	3		6		3			t3.xlarge	AL2_x86_64	eks-managed-ng-08c5e8f1-d276-2787-180c-77a56f6f6452	managed
```

由此可确认Nodegroup节点组是3台机器，而刚才`kubectl get nodes`看到的第4台EC2就是手工加入的集群。

## 五、使用Userdata脚本在EC2创建时候自动加入集群（可选）

上文的方法，是采用事先创建好EC2，然后在EC2上执行命令的方式加入集群。此外，还可以通过Userdata脚本方式，在创建一个全新EC2时候，自动加入集群。

这个时候脚本编写如下，然后放到创建EC2服务的的高级菜单中的Userdata对话框下：

```
#! /bin/bash
/etc/eks/bootstrap.sh eksworkshop \
  --b64-cluster-ca LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSURCVENDQWUyZ0F3SUJBZ0lJT0pBc1JwK3NiZmd3RFFZSktvWklodmNOQVFFTEJRQXdGVEVUTUJFR0ExVUUKQXhNS2EzVmlaWEp1WlhSbGN6QWVGdzB5TXpFeE1UVXdOekU0TVRSYUZ3MHpNekV4TVRJd056SXpNVFJhTUJVeApFekFSQmdOVkJBTVRDbXQxWW1WeWJtVjBaWE13Z2dFaU1BMEdDU3FHU0liM0RRRUJBUVVBQTRJQkR3QXdnZ0VLCkFvSUJBUURIc2ZwbVNlb2tQek8vcEg2Rk9mWUZla2U1WGwwSTc0ZHplTnBWZ2 \
  --apiserver-endpoint https://D4EEF0B352E50F312F2F94C8E387E4F5.gr7.ap-southeast-1.eks.amazonaws.com \
  --dns-cluster-ip 10.50.0.10 \
  --container-runtime containerd \
  --kubelet-extra-args '--max-pods=100' \
  --use-max-pods false
```

如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/node/node-11-2.png)

启动EC2，并等待3-5分钟。

通过EKS服务界面，可看到Node加入成功。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/node/node-12.png)

通过K9S等管理工具，也可以看到Node添加成功。

![](https://blogimg.bitipcman.com/workshop/eks101/node/node-13.png)

## 六、参考文档

检索 Amazon EKS 优化版 Amazon Linux AMI ID

[https://docs.aws.amazon.com/zh_cn/eks/latest/userguide/eks-optimized-ami.html]()

使用启动模板自定义托管节点

[https://docs.aws.amazon.com/zh_cn/eks/latest/userguide/launch-templates.html#launch-template-custom-ami]()

amazon-eks-ami/bootstrap.sh

[https://github.com/awslabs/amazon-eks-ami/blob/master/files/bootstrap.sh]()