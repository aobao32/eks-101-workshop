# 为VPC扩展IP地址并配置EKS Pod使用独立的IP地址段

## 一、背景

### 1、关于EKS的默认CNI

AWS EKS默认使用AWS VPC CNI（了解更多点[这里](https://github.com/aws/amazon-vpc-cni-k8s)），所有的Pod都将自动获得一个本VPC内的IP地址，从外部网络看Pod，它们的表现就如同一个普通EC2。这是AWS EKS默认的网络模式，也是强烈推荐的使用模式。

### 2、需要额外IP的解决方案（三选一）

某些场景下，可能当前创建VPC时候预留IP地址过少，要大规模启动容器会遇到VPC内可用IP地址不足。此时有几个办法：

#### （1）方案一、创建全新的VPC运行EKS

由于云上可以随时创建多个VPC，并可通过多种方式实现VPC和应用之间的互通，因此创建一个独立的VPC运行新的应用是最快捷的解决地址不足的办法。EKS的命令行管理工具eksctl默认的参数就是创建一个全新VPC。当创建全新VPC后，一般可通过如下方式让两个VPC之间的服务互通：

- 路由模式。如果两个VPC IP地址段不重叠且可路由，可通过VPC Peering或Transit Gateway打通两个VPC网络，实现三层和四层协议的全面互通；
- 通过公网方式。在一个VPC上的应用前配置好ELB并对外发布服务，然后对ELB可限制来源IP白名单，仅允许另一个VPC访问；
- 通过内网方式。在一个VPC上配置PrivateLink映射Endpoint Service，并在另一个VPC内提供Endpoint服务。

除此以外，可能还有其他方式用于实现跨VPC的应用互访，再次不逐个罗列。

#### （2）方案二、为VPC扩展IP地址并配置EKS Pod使用独立的IP地址段

VPC和EKS都支持使用扩展地址段。在此方案下，继续使用EKS默认的VPC CNI，首先为现有VPC扩展IP地址，并配置EKS使用扩展IP地址。本方案影响较小，过度平滑，不需要额外创建VPC，也不需要重新部署EKS网络CNI。需要注意的是，扩展IP地址存在范围限制，并不是任意IP都可以添加到VPC的扩展范围内，请注意参考[这里](https://docs.aws.amazon.com/zh_cn/vpc/latest/userguide/configure-your-vpc.html#add-cidr-block-restrictions)文档描述的限制范围。如果此IP段不可接受，则因考虑其他方案。

#### （3）方案三、更换Kubenetus社区的CNI并配置EKS Pod使用非VPC IP地址

如果希望EKS上的Pod完全不使用本VPC的IP地址，这可以更换EKS的CNI网络插件，官方文档[这里](https://docs.aws.amazon.com/zh_cn/eks/latest/userguide/alternate-cni-plugins.html)做了介绍。在集群创建后，可删除默认的AWS VPC CNI，然后安装WeaveNet等插件。此

本文描述方案二，即为VPC扩展IP。

## 二、为VPC添加第二IP地址段

### 1、为VPC添加IP地址

首先查看当前VPC的IP范围，并查看AWS[官方文档](https://docs.aws.amazon.com/zh_cn/vpc/latest/userguide/configure-your-vpc.html#add-cidr-block-restrictions)描述的可扩充IP范围的限制。

首先进入VPC界面，选择要添加IP地址的VPC，点击右上角的操作，选择修改CIDR。如下截图。

![](https://myworkshop.bitipcman.com/eks101/ip/pod01.png)

进入添加IP地址段界面，添加上第二个地址段，例如`100.64.0.0/16`，然后点击右侧的分配按钮，再点击下方的保存。如下截图。

![](https://myworkshop.bitipcman.com/eks101/ip/pod02.png)

### 2、为第二IP地址段创建子网

进入创建子网界面，选择对应的VPC，创建新的子网，并使用刚才新添加的IP地址段。例如本例中`100.64.0.0/16`被添加到VPC中，那么子网可采用`100.64.1.0/24`、`100.64.2.0/24`、`100.64.3.0/24`分别对应三个AZ。

如此分别为3个AZ都创建好对应的Pod使用的子网。如下截图。

![](https://myworkshop.bitipcman.com/eks101/ip/pod05.png)

操作完成。

### 3、为新增加的子网配置路由表

新创建好的子网会绑定到VPC默认路由表，因此还需要将新创建的子网绑定到和Node节点同一个路由表。进入路由表界面，查看Node所在的private subnet的路由表，可以看到当前只关联了三个Node子网。点击编辑按钮。如下截图。

![](https://myworkshop.bitipcman.com/eks101/ip/pod06.png)

将新创建的Pod子网关联到Node所在的Private子网的路由表上。如下截图。

![](https://myworkshop.bitipcman.com/eks101/ip/pod07.png)

添加子网完成后，确认下Node所在的子网和Pod所在的子网，所对应的路由表的下一跳是NAT Gateway。这是因为这两个子网都是私有子网，没有Elastic IP，因此默认网关下一跳都必须是NAT Gateway。如下截图。

![](https://myworkshop.bitipcman.com/eks101/ip/pod08.png)

备注：如果您使用了Gateway Load Balancer做的集中网络流量检测方案，那么这里的默认网关下一跳应该是TGW。如果您没有使用Gateway Load Balancer，默认下一跳都是NAT Gateway。

至此VPC配置完毕。

## 三、配置EKS集群

### 1、检查确认集群版本和VPC CNI版本（可跳过）

使用附加IP地址段要求AWS VPC CNI的版本大于1.6.3。本文在EKS 1.22中国区（宁夏ZHY）上使用VPC CNI 1.10版本测试通过。

执行如下命令查看版本：

```
kubectl describe daemonset aws-node --namespace kube-system | grep Image
```

返回结果如下：

```
961992271922.dkr.ecr.cn-northwest-1.amazonaws.com.cn/amazon-k8s-cni:v1.10.1-eksbuild.1
```

这表示当前AWS VPC CNI的版本是1.10，符合使用扩展IP段的最低版本要求。

### 2、配置ENIConfig

首先从子网界面查看子网信息，获得可用区ID和子网ID。将三个Pod子网的信息分别复制下来。如下截图。

![](https://myworkshop.bitipcman.com/eks101/ip/pod09.png)

用文本编辑器编辑如下文件，替换其中的可用区ID和子网ID，然后保存为`eniconfig.yaml`文件。

```
apiVersion: crd.k8s.amazonaws.com/v1alpha1
kind: ENIConfig
metadata: 
  name: cn-northwest-1a
spec: 
  subnet: subnet-0212576e31c02c077
---
apiVersion: crd.k8s.amazonaws.com/v1alpha1
kind: ENIConfig
metadata: 
  name: cn-northwest-1b
spec: 
  subnet: subnet-002bfe02b7bfa7ba4
---
apiVersion: crd.k8s.amazonaws.com/v1alpha1
kind: ENIConfig
metadata: 
  name: cn-northwest-1c
spec: 
  subnet: subnet-08cb25ce86ab2a4cs
```

将以上配置文件保存为`eniconfig.yaml`文件。然后执行如下命令：

```
# 启用自定义网络
kubectl set env daemonset aws-node -n kube-system AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG=true
# 加载ENIConfig
kubectl apply -f eniconfig.yaml
# 节点标签设置
kubectl set env daemonset aws-node -n kube-system ENI_CONFIG_LABEL_DEF=topology.kubernetes.io/zone
```

### 3、重新创建节点组

在修改配置完毕后，需要重新创建节点组。如果在当前节点组上继续启动任务，那么Pod将继续使用现有Node所在的子网，不会使用新扩展的子网。

请参考之前变更节点组规格的说明，重新创建新的Nodegroup。然后删除旧的节点组。

## 四、测试应用

按照正常的方式启动应用。启用应用的yaml不需要额外特殊配置。

启动完成后，查看所有pod的IP，可发现除默认负责网络转发的kube-proxy和aws-node（VPC CNI）还运行在Node所在的Subnet上之外，新创建的应用都会运行在新的子网和IP地址段上。如下截图。

![](https://myworkshop.bitipcman.com/eks101/ip/pod10.png)

## 五、参考文档

Github上的AWS VPC CNI代码和文档

[https://github.com/aws/amazon-vpc-cni-k8s](https://github.com/aws/amazon-vpc-cni-k8s)

使用CNI自定义网络

[https://docs.aws.amazon.com/zh_cn/eks/latest/userguide/cni-custom-network.html](https://docs.aws.amazon.com/zh_cn/eks/latest/userguide/cni-custom-network.html)