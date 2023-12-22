# 使用Kubecost管理EKS成本

## 一、简介

Kubecost是基于OpenCost的云原生的成本管理工具。在不使用Kubecost情况下，管理EKS的cost一般是基于预留实例的EC2 Node，并人为划分服务资源进行分割，某些情况下还需要搭配Cost and Usage Reports(CUR)详单。

使用Kubecost，可以在相对直观的看到各Deployment/Service对应的相应费用，并根据服务的运行时长显示对应成本。Kubecost免费版可通过Helm在EKS上快速部署。如果需要更多功能，还需要使用商业版的Kubecost。本文介绍如何部署免费版的Kubecost。

## 二、安装配置

### 1、通过EKS Addons功能为集群安装EBS CSI

Kubecost依赖EBS，因此需要首先安装EBS CSI。本文通过EKS控制台的图形界面来安装。进入Addons标签页。点击`Get more add-ons`按钮。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/kubecost/kubecost-01.png)

在下方的CSI中，找到`Amazon EBS CSI Driver`，选中之。将页面滚动到最下方。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/kubecost/kubecost-02.png)

选中其最新版本，在选择IAM Role位置，选择`Inherit from node`从Node节点继承角色。然后点击`Next`按钮安装。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/kubecost/kubecost-03.png)

在向导最后一步，点击`Create`按钮完成部署。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/kubecost/kubecost-04.png)

至此EBS CSI部署完成。

### 2、在开发者本机上安装helm

在MacOS下执行如下命令：

```shell
brew install helm
```

在Windows下执行如下命令：

```shell
choco install kubernetes-helm
```

### 3、安装最新版本

执行如下命令，安装最新版本Kubecost。

在官网文档的说明中，在安装命令的参数中包含了版本号，表示安装特定版本。如下的命令将不指定kubecost版本号，那么此时会安装当前的最新版。

```shell
helm upgrade -i kubecost oci://public.ecr.aws/kubecost/cost-analyzer \
    --namespace kubecost --create-namespace \
    -f https://raw.githubusercontent.com/kubecost/cost-analyzer-helm-chart/develop/cost-analyzer/values-eks-cost-monitoring.yaml
```

返回结果如下：

```
Release "kubecost" does not exist. Installing it now.
Pulled: public.ecr.aws/kubecost/cost-analyzer:1.108.0
Digest: sha256:b2f23af7c75310e7779c364d1aac8326a73525b2b250b16276d2bd8e364d9468
NAME: kubecost
LAST DEPLOYED: Sun Dec 17 19:52:36 2023
NAMESPACE: kubecost
STATUS: deployed
REVISION: 1
NOTES:
--------------------------------------------------
Kubecost 1.108.0 has been successfully installed.

WARNING: ON EKS v1.23+ INSTALLATION OF EBS-CSI DRIVER IS REQUIRED TO MANAGE PERSISTENT VOLUMES. LEARN MORE HERE: https://docs.kubecost.com/install-and-configure/install/provider-installations/aws-eks-cost-monitoring#prerequisites

Please allow 5-10 minutes for Kubecost to gather metrics.
When configured, cost reconciliation with cloud provider billing data will have a 48 hour delay.
When pods are Ready, you can enable port-forwarding with the following command:
    kubectl port-forward --namespace kubecost deployment/kubecost-cost-analyzer 9090
Then, navigate to http://localhost:9090 in a web browser.
Having installation issues? View our Troubleshooting Guide at http://docs.kubecost.com/troubleshoot-install
```

查询kubecost运行结果：

```shell
kubectl get pods -n kubecost
```

返回如下结果表示启动正常：

```shell
NAME                                         READY   STATUS    RESTARTS   AGE
kubecost-cost-analyzer-5cb6fd4f9d-gksdc      2/2     Running   0          4m10s
kubecost-prometheus-server-fd678dff7-q5cnn   1/1     Running   0          4m10s
```

注意：首次启动Kubecost服务收集指标可能需要5-10分钟。

### 4、设置端口转发在本机查看

执行端口转发：

```shell
kubectl port-forward --namespace kubecost deployment/kubecost-cost-analyzer 9090
```

返回结果如下：

```shell
Forwarding from 127.0.0.1:9090 -> 9090
Forwarding from [::1]:9090 -> 9090
```

打开本机浏览器，访问本机`http://localhost:9090/`端口查看网页。

可看到网页界面如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/kubecost/kubecost-04.png)

## 三、参考文档

EKS成本监控

[https://docs.aws.amazon.com/zh_cn/eks/latest/userguide/cost-monitoring.html]()

AWS and Kubecost collaborate to deliver cost monitoring for EKS customers

[https://aws.amazon.com/blogs/containers/aws-and-kubecost-collaborate-to-deliver-cost-monitoring-for-eks-customers/]()