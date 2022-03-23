# 六、在EKS 1.21版本上创建NodeGroup使用Containerd替代Docker

## 一、创建集群

EKS 1.21版本和1.22版本继续使用Docker作为默认容器运行时，如果需要使用Containerd作为默认运行时，则需要在创建节点组时候额外加参数进行配置。

编辑配置文件：

```
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: eksworkshop
  region: cn-northwest-1

nodeGroups:
  - name: containerd
    labels: { Name: EKScontainerd }
    instanceType: t3.xlarge
    desiredCapacity: 3
    privateNetworking: true
    volumeType: gp3
    volumeSize: 50
```

替换其中的信息包括集群名称、区域、AMI的ID等，例如在ZHY区域替换如下：

```
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: eksworkshop
  region: cn-northwest-1
managedNodeGroups:
  - name: eksworkshop
    ami: ami-03359a0e76c5425c5
    overrideBootstrapCommand: |
      #!/bin/bash
      /etc/eks/bootstrap.sh my-cluster --container-runtime containerd
```

启动新的node group：

```
eksctl create nodegroup -f nodegroup.yaml
```

## 二、拉取镜像



## 三、参考资料

Docker弃用说明

[https://docs.aws.amazon.com/zh_cn/eks/latest/userguide/dockershim-deprecation.html](https://docs.aws.amazon.com/zh_cn/eks/latest/userguide/dockershim-deprecation.html)



