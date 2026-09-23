# 使用EKS控制台的Addon功能升级EKS VPC CNI

> 更新的到 EKS 1.36版本

本文介绍使用EKS控制台的Addon功能升级EKS插件。

## 一、背景

### 1、EKS控制台无法显示现有Addon的问题

新创建的EKS可正常使用。但是进入控制台，在Addon界面下，看不到aws-vpc-cni等插件。不过网络又工作正常。这是什么原因？

在EKS控制台上查看Addon，如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/addon/a-01.png)

执行如下命令：

```shell
kubectl describe daemonset aws-node --namespace kube-system
```

可以看到aws-vpc-cni等插件工作正常。

则是由于自行安装插件和从EKS控制台安装Addons是完全独立的两个安装通道。互相不可见。

官网文档介绍如下：

    如果集群是使用除控制台以外的任何方式创建的，则每个集群都将附带内置附加组件的自行管理版本。自行管理的版本不能从 AWS Management Console、AWS Command Line Interface 或 SDK 进行管理。您可以管理自行管理附加组件的配置和升级。
    
    建议您向集群添加 Amazon EKS 类型的附加组件，而不是自行管理类型的附加组件。如果集群是通过控制台创建的，则会安装这些附加组件的 Amazon EKS 类型。

这是由于插件存在两种安装形态：EKS托管类型（Amazon EKS add-on）与自管理类型（self-managed）。以自管理形态安装的插件不会出现在控制台的Add-ons界面中，也无法通过控制台、CLI或SDK进行管理；只有以EKS托管形态安装的插件才会在Add-ons界面中显示并可被管理。二者互相独立。

需要说明的是，当前较新版本的eksctl在创建集群时，默认会将vpc-cni、coredns、kube-proxy等核心插件以EKS托管形态安装，因此用eksctl新建的EKS 1.36集群在控制台中通常已经可以看到这些托管插件。本节描述的"看不到插件"的现象，主要出现在以自管理形态安装插件的集群上（例如通过manifest手工部署CNI，或使用不安装托管插件的创建方式）。可执行如下命令确认集群当前已安装的EKS托管插件清单：

```shell
aws eks list-addons --cluster-name eksworkshop --region ap-southeast-1 --output table
```

本文环境返回结果如下，可见核心插件均以EKS托管形态存在：

```
---------------------------------------
|             ListAddons              |
+-------------------------------------+
||              addons               ||
|+-----------------------------------+|
||  amazon-cloudwatch-observability  ||
||  coredns                          ||
||  kube-proxy                       ||
||  metrics-server                   ||
||  vpc-cni                          ||
|+-----------------------------------+|
```

### 2、EKS版本对aws-vpc-cni的版本要求

执行如下命令查询当前集群正在使用的VPC CNI版本：

```shell
kubectl describe daemonset aws-node --namespace kube-system | grep amazon-k8s-cni: | cut -d : -f 3
```

本文环境为EKS 1.36，查询到当前运行的版本为`v1.22.4-eksbuild.3`。

每个EKS版本都有其推荐（默认）的VPC CNI版本，以及一组兼容的可选版本。可通过如下命令查询指定EKS版本下VPC CNI的所有可用版本，其中`defaultVersion`为`True`的即为该EKS版本的默认版本：

```shell
aws eks describe-addon-versions --addon-name vpc-cni --kubernetes-version 1.36 --region ap-southeast-1 --query "addons[0].addonVersions[].{version:addonVersion,default:compatibilities[0].defaultVersion}" --output table
```

截至本文编写时，EKS 1.36下VPC CNI的默认版本为`v1.22.4-eksbuild.3`，最新可用版本为`v1.23.1-eksbuild.1`。

升级EKS集群时，需要保证VPC CNI等插件的版本与目标Kubernetes版本兼容。如果仅升级控制平面而不同步升级插件，可能出现插件版本与新控制平面不兼容的问题，EKS控制台也会在集群健康检查中给出相应的版本兼容性提示。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/addon/a-02.png)

因此在升级集群前，建议先将VPC CNI升级到与目标版本兼容的版本。下面开始操作。

## 二、在EKS控制台以Addon的方式升级插件

### 1、进入EKS控制台

如果在EKS控制台中提示：

```
Your current IAM principal doesn't have access to Kubernetes objects on this cluster.
This may be due to the current user or role not having Kubernetes RBAC permissions to describe cluster resources or not having an entry in the cluster’s auth config map.
```

如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/addon/a-03.png)

这是因为您创建EKS时候使用的AKSK在其他用户或者角色下。此问题可以通过[这篇](https://blog.bitipcman.com/authorize-iam-role-and-user-for-eks/)文档的办法解决。

### 2、升级VPC CNI Addon

进入EKS控制台界面，找到当前集群，点击`Add-ons`标签页。点击`Get more add-ons`。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/addon/a-04.png)

从插件清单中，找到`Amazon VPC CNI`，点击右上角，选中之。本页面上其他选项不需要选中。将页面滚动到最下方，点击下一步。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/addon/a-05.png)

在`Amazon VPC CNI`的详情位置，选择插件版本为最新（截止本文编写时候是`v1.23.1-eksbuild.1`版本），然后在`Select IAM role`位置保持默认值。点击`Optional configuration settings`展开可选设置的菜单。然后向下滚动页面。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/addon/a-06.png)

在可选设置的最下方，选中`Override`，这表示将强制升级现有VPC CNI的版本。然后点击下一步。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/addon/a-07.png)

在向导最后一步Review界面，确认设置正确，点击`Create`按钮发起安装。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/addon/a-08.png)

安装需要3-5分钟。此时界面上显示创建中。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/addon/a-09.png)

等待大约3-5分钟，安装完成。

对应用测试访问正常后，按以上方法，继续升级其他插件。

### 3、升级其他Addon

推荐升级的插件包括：

- kube-proxy
- CoreDNS
- Amazon CloudWatch Observability

根据实际使用EBS和EFS，可选升级插件：

- Amazon EFS CSI Driver
- Amazon EBS CSI Driver

如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/addon/a-10.png)

在升级向导中，在可选设置的最下方，选中`Override`，这表示将强制升级现有插件。如果没有选中Override，那么会提示插件已经存在。

至此升级完成。

## 三、参考文档

[https://docs.aws.amazon.com/eks/latest/userguide/managing-vpc-cni.html#vpc-add-on-create]()
