在EKS教程和实验手册中，使用eksctl工具创建集群，可以在几分钟内配置好一个EKS集群。但是，默认情况下，eksctl将会通过Cloudformation创建一个全新的VPC，默认使用192.168.0.0/16的子网掩码，而且Nodegroup还是位于Public Subnet。由此，并未能落在现有VPC内，也未能使用Private Subnet。因此，在这种场景下，可使用如下方法。

## 一、VPC网络准备

如果希望使用现有VPC的Private子网，请确保本子网已经设置了正确的路由表，且VPC内包含NAT Gateway可以提供外网访问能力。此部分工作需要手工配置。

## 二、为使用ALB Ingress作准备打标签

如果跳过本步骤，虽然集群可以创建，但是后续在创建ALB作为Ingress时候会提示找不到Subnet。因此需要事先手工配置好。

找到当前的VPC，找到有EIP和NAT Gateway的Public Subnet，为其添加标签：

- 标签名称：kubernetes.io/role/elb，值：1
- 标签名称：kubernetes.io/cluster/eksworkshop，值：shared

接下来进入Private subnet，为其添加标签：

- 标签名称：kubernetes.io/role/internal-elb，值：1
- 标签名称：kubernetes.io/cluster/eksworkshop，值：shared

接下来请重复以上工作，三个AZ的子网都实施相同的配置，注意三个子网第一项标签值都是1。

## 三、创建集群

准备如下一段命令，分别替换集群版本、集群名称、子网名称等信息。然后在配置好AWSCLI的MacOS或Linux上运行如下命令创建集群。如果是Windows，则需要去掉如下命令中每行末尾`\`换行符即可。

```
eksctl create cluster \
--name=eksworkshop \
--version=1.22 \
--nodegroup-name=nodegroup1 \
--nodes=3 \
--nodes-min=3 \
--nodes-max=6 \
--node-volume-size=100 \
--node-volume-type=gp3 \
--node-type=m5.2xlarge \
--managed \
--alb-ingress-access \
--full-ecr-access \
--vpc-private-subnets=subnet-0af2e9fc3c3ab08b4,subnet-0bb5aa110443670a1,subnet-008bcabf73bea7e58 \
--node-private-networking \
--region=cn-northwest-1
```

请替换以上命令中`--vpc-private-subnets=`后的子网ID。需要部署3AZ就写3个子网，需要2AZ就写两个子网。

等待10分钟左右，集群即可创建完成。