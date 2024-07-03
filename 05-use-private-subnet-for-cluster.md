# 实验五、使用私有子网创建EKS

## 一、背景

在EKS教程和实验手册中，使用eksctl工具创建集群可以在几分钟内配置好一个EKS集群。但是默认情况下，eksctl将会通过Cloudformation创建一个全新的VPC，使用192.168.0.0/16的子网掩码，且Nodegroup位于Public Subnet公有子网。Nodegroup和pod并未能落在现有VPC内，也未能使用Private Subnet。这样很可能不符合架构要求。

因此，在这种场景下，可在使用eksctl创建集群时候，增加参数使用EKS的Nodegroup创建在某几个私有子网。

## 二、操作方法

本文的内容已经在《EKS 101 动手实验（一）创建EKS集群》的章节三中第2个小标题做了介绍，因此这里不再赘述。请跳转[这里]()阅读。