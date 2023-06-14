# 实验五、使用私有子网创建EKS

## 一、背景

在EKS教程和实验手册中，使用eksctl工具创建集群，可以在几分钟内配置好一个EKS集群。但是，默认情况下，eksctl将会通过Cloudformation创建一个全新的VPC，默认使用192.168.0.0/16的子网掩码且Nodegroup位于Public Subnet。由此，Nodegroup和pod并未能落在现有VPC内，也未能使用Private Subnet。

因此，在这种场景下，可使用指定子网的方式，要求EKS在现有VPC的特定子网创建集群。

## 二、操作方法

本文的内容已经在[《创建EKS集群》](https://github.com/aobao32/eks-101-workshop/blob/main/01-create-cluster.md)的章节三中第二个小标题做了介绍，因此这里不再赘述。请跳转阅读。