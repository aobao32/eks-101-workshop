# 将EC2手工加入EKS集群成为托管节点

> 更新到 EKS 1.36版本

## 一、背景

### 1、EKS服务使用EC2的两种模式

EKS服务使用EC2的两种模式

- 使用EKS自动生成的托管节点组：在EKS服务控制台或者通过eksctl命令完成，EKS会自动使用最新镜像，全自动创建，并使用Autoscaling缩放；如果是通过eksctl脚本，还会自动创建合适的IAM角色；这时候EC2会在托管节点组内。
- 使用EKS提供的AMI以托管节点方式自行加入集群：使用EKS官方提供的基础镜像（EKS 1.36对应Amazon Linux 2023），手工创建一个EC2，并手工配置IAM角色，然后通过nodeadm初始化程序读取NodeConfig配置，将本EC2加入EKS集群；这时候EC2会成为托管节点，但不会进入上一步的托管节点组。

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

使用AWSCLI可快速查询EKS服务官方AMI。EKS 1.36的官方节点镜像为Amazon Linux 2023，其SSM参数路径中包含版本号`1.36`、镜像类型`amazon-linux-2023`以及架构与变体`x86_64/standard`或`arm64/standard`。注意替换如下命令中的版本号与区域。

查询Intel/AMD处理器的x86_64架构的命令如下：

```shell
aws ssm get-parameter --name /aws/service/eks/optimized-ami/1.36/amazon-linux-2023/x86_64/standard/recommended/image_id --region ap-southeast-1 --query "Parameter.Value" --output text
```

查询ARM架构处理器的命令如下：

```shell
aws ssm get-parameter --name /aws/service/eks/optimized-ami/1.36/amazon-linux-2023/arm64/standard/recommended/image_id --region ap-southeast-1 --query "Parameter.Value" --output text
```

以查询x86_64架构为例，返回结果如下。

```
ami-0b7a5a1d35d68ea86
```

需要注意，EKS 1.36不再提供Amazon Linux 2的官方镜像，早期版本使用的`amazon-linux-2`参数路径已不存在，查询会返回`ParameterNotFound`。因此手工创建节点必须使用Amazon Linux 2023的镜像。

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
https://D0A7E4BBBBD26CD6E003B94E42FECFD2.gr7.ap-southeast-1.eks.amazonaws.com
```

此外，还可以到EKS控制台上查看。查看方法如上一步的截图。

### 3、查询Cluster的DNS地址

nodeadm的NodeConfig配置使用集群的Service CIDR（服务网段），并据此自动推导集群DNS地址，因此这里先查询集群的Service CIDR。执行如下命令：

```shell
aws eks describe-cluster --name eksworkshop --region ap-southeast-1 --query "cluster.kubernetesNetworkConfig.serviceIpv4Cidr" --output text
```

返回结果就是集群的Service CIDR：

```
10.50.0.0/24
```

集群DNS（CoreDNS）的Service IP是该网段中的第10个地址，本例即`10.50.0.10`，EKS默认的DNS地址一般都是所在Service网段的`.10`。也可以执行`kubectl get services -A`直接查看`kube-dns`的CLUSTER-IP进行核对：

```
NAMESPACE     NAME         TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)         AGE
default       kubernetes   ClusterIP   10.50.0.1    <none>        443/TCP         3d20h
kube-system   kube-dns     ClusterIP   10.50.0.10   <none>        53/UDP,53/TCP   3d20h
```

在使用nodeadm时，NodeConfig中填写的是Service CIDR（`10.50.0.0/24`），而不是单个DNS地址，nodeadm会自动完成DNS地址的推导。

此外，还可以到EKS控制台上查看。查看方法是进入EKS集群，找到`Resource`资源标签页，点击其中的`Service and networking`服务和网络，从第一个菜单`Service`服务中，找到右侧的`kube-dns`。点击查看。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/node/node-02.png)

从`kube-dns`服务的详情中，可看到服务IP是`10.50.0.10`。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/node/node-03.png)

### 4、验证本EC2可以到达EKS网络平面

登录到上一步创建好的EC2上，确认EC2可以访问EKS的API，执行如下命令：

```shell
curl -k https://D0A7E4BBBBD26CD6E003B94E42FECFD2.gr7.ap-southeast-1.eks.amazonaws.com/livez?verbose
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

在Amazon Linux 2023节点上，节点的初始化由nodeadm程序完成，nodeadm读取名为`NodeConfig`的YAML配置对象获取集群信息。NodeConfig的最小必填字段为集群名称`name`、API Server地址`apiServerEndpoint`、集群CA证书`certificateAuthority`以及Service CIDR`cidr`，这些参数均已在第二章、第三章查询完毕。将EC2加入集群有两种方式：一是登录到已创建的EC2上手工执行nodeadm；二是在创建EC2时通过Userdata传入NodeConfig，由镜像自带的nodeadm在开机时自动完成加入。二者选其一即可，下面分别介绍。

### 1、在EC2节点上手工执行命令加入集群

使用Session Manager或者其他方式，登录到本文第二章创建的EC2上。

需要注意，Amazon Linux 2023镜像已不再提供早期版本中的`/etc/eks/bootstrap.sh`加入脚本。该路径下虽然仍保留了一个同名文件，但它只是一个提示脚本，执行后会直接报错退出，内容如下：

```shell
sudo /etc/eks/bootstrap.sh eksworkshop
```

```
!!!!!!!!!!
!!!!!!!!!! ERROR: bootstrap.sh has been removed from AL2023-based EKS AMIs.
!!!!!!!!!!
!!!!!!!!!! EKS nodes are now initialized by nodeadm.
!!!!!!!!!!
!!!!!!!!!! To migrate your user data, see:
!!!!!!!!!!
!!!!!!!!!!     https://awslabs.github.io/amazon-eks-ami/nodeadm/
!!!!!!!!!!
```

正确的做法是使用nodeadm。将第二章、第三章查询到的参数写入一个NodeConfig配置文件，例如`/root/nodeConfig.yaml`，内容如下。其中`certificateAuthority`填写第三章第1节查询到的CA证书内容（较长，此处截断示意），`cidr`填写第三章第3节查询到的Service CIDR：

```yaml
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: eksworkshop
    apiServerEndpoint: https://D0A7E4BBBBD26CD6E003B94E42FECFD2.gr7.ap-southeast-1.eks.amazonaws.com
    certificateAuthority: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t......（此处为CA证书的base64内容，请替换为实际值）
    cidr: 10.50.0.0/24
```

然后执行nodeadm初始化命令，通过`--config-source`指向该配置文件：

```shell
sudo nodeadm init --config-source file:///root/nodeConfig.yaml
```

命令执行后返回如下信息（节选），显示containerd与kubelet两个守护进程被配置并启动，最后输出`done!`表示初始化完成：

```
info init/init.go:129 Configuring daemons...
info init/init.go:218 Configuring daemon... {"name": "containerd"}
info containerd/config.go:77 Writing containerd config to file.. {"path": "/etc/containerd/config.toml"}
info init/init.go:222 Configured daemon {"name": "containerd"}
info init/init.go:218 Configuring daemon... {"name": "kubelet"}
info kubelet/config.go:232 Setup IP for node {"ip": "192.168.33.81"}
info kubelet/config.go:347 Writing kubelet config to file.. {"path": "/etc/kubernetes/kubelet/config.json"}
info init/init.go:222 Configured daemon {"name": "kubelet"}
info init/init.go:151 Running daemons...
info init/init.go:234 Ensuring daemon is running.. {"name": "containerd"}
info init/init.go:238 Daemon is running {"name": "containerd"}
info init/init.go:234 Ensuring daemon is running.. {"name": "kubelet"}
info init/init.go:238 Daemon is running {"name": "kubelet"}
info init/init.go:157 done! {"duration": 0.63711644}
```

执行过程中如果出现`Failed to cache config`一类的提示，是因为使用本地文件作为配置源时没有对应的配置缓存路径，属于非致命提示，不影响节点加入。初始化完成后，可执行`sudo systemctl is-active kubelet`确认kubelet已处于`active`状态。以上信息显示加入集群成功。

### 2、验证加入集群成功

登录到EKS服务界面，可从Compute界面中看到这台EC2加入集群成功。

![](https://blogimg.bitipcman.com/workshop/eks101/node/node-10.png)

在上述截图中，可看到三个EC2节点的Nodegroup。

在命令行执行如下命令，验证加入集群成功：

```shell
kubectl get nodes
```

返回结果如下（其中AGE很短的一台即为手工加入的节点）：

```
NAME                                                STATUS   ROLES    AGE     VERSION
ip-192-168-30-108.ap-southeast-1.compute.internal   Ready    <none>   3d20h   v1.36.4-eks-a887778
ip-192-168-33-81.ap-southeast-1.compute.internal    Ready    <none>   45s     v1.36.4-eks-a887778
ip-192-168-54-190.ap-southeast-1.compute.internal   Ready    <none>   3d20h   v1.36.4-eks-a887778
ip-192-168-69-155.ap-southeast-1.compute.internal   Ready    <none>   3d20h   v1.36.4-eks-a887778
```

由此可看到EKS集群中，已经包含了新加入的节点，其Kubernetes版本与其余节点一致，均为`v1.36.4-eks-a887778`。

如果本机安装了eksctl工具，还可以通过eksctl来确认托管节点组的构成：

```shell
eksctl get nodegroup --cluster eksworkshop --region ap-southeast-1
```

返回结果如下：

```
CLUSTER		NODEGROUP	STATUS	CREATED			MIN SIZE	MAX SIZE	DESIRED CAPACITY	INSTANCE TYPE	IMAGE ID		ASG NAME						TYPE
eksworkshop	podsubnet-ng	ACTIVE	2026-09-19T13:40:54Z	3		6		3			t3.2xlarge	AL2023_x86_64_STANDARD	eks-podsubnet-ng-74d05cf2-fab0-a446-979c-fabf549e22c2	managed
```

由此可确认托管节点组内是3台机器（`IMAGE ID`一列已显示为`AL2023_x86_64_STANDARD`，表明使用的是Amazon Linux 2023镜像），而刚才`kubectl get nodes`中多出来的那一台，就是本文手工加入集群的EC2。

## 五、使用Userdata脚本在EC2创建时候自动加入集群（可选）

上文的方法，是采用事先创建好EC2，然后在EC2上执行命令的方式加入集群。此外，还可以通过Userdata脚本方式，在创建一个全新EC2时候，自动加入集群。

Amazon Linux 2023的EKS官方镜像在开机时会自动运行nodeadm，它会从EC2的Userdata中读取NodeConfig并完成节点初始化。因此这里无须在Userdata中显式调用`nodeadm init`（重复调用反而会与镜像自带的初始化流程冲突），只需将NodeConfig以MIME多部分格式放入Userdata即可。

Userdata内容编写如下，然后放到创建EC2服务的高级菜单中的Userdata对话框下。其中`Content-Type: application/node.eks.aws`用于告知nodeadm这是一段NodeConfig，各参数含义与第四章一致：

```
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="//"

--//
Content-Type: application/node.eks.aws

apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: eksworkshop
    apiServerEndpoint: https://D0A7E4BBBBD26CD6E003B94E42FECFD2.gr7.ap-southeast-1.eks.amazonaws.com
    certificateAuthority: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t......（此处为CA证书的base64内容，请替换为实际值）
    cidr: 10.50.0.0/24
--//--
```

如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/node/node-11-2.png)

启动EC2，并等待3-5分钟。镜像自带的nodeadm会分两个阶段执行：`nodeadm-config`在Userdata执行之前完成containerd与kubelet的基础配置，`nodeadm-run`在其后启动相关守护进程。在节点上可通过`sudo journalctl -u nodeadm-run --no-pager`查看其执行日志，看到`Finished nodeadm-run.service`即表示初始化完成。

通过EKS服务界面，可看到Node加入成功。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/node/node-12.png)

通过K9S等管理工具，也可以看到Node添加成功。

![](https://blogimg.bitipcman.com/workshop/eks101/node/node-13.png)

## 六、参考文档

检索 Amazon EKS 优化版 Amazon Linux AMI ID

[https://docs.aws.amazon.com/zh_cn/eks/latest/userguide/eks-optimized-ami.html]()

Amazon EKS 优化版 Amazon Linux 2023 加速版 AMI（nodeadm 初始化说明）

[https://docs.aws.amazon.com/eks/latest/userguide/al2023.html]()

nodeadm 与 NodeConfig 配置参考（amazon-eks-ami 文档）

[https://awslabs.github.io/amazon-eks-ami/nodeadm/]()

在 AL2023 的 Amazon EKS 节点上使用自定义 Userdata

[https://repost.aws/knowledge-center/custom-user-eks-2023]()

使用启动模板自定义托管节点

[https://docs.aws.amazon.com/zh_cn/eks/latest/userguide/launch-templates.html#launch-template-custom-ami]()