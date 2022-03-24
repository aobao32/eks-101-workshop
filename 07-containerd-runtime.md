# 六、在EKS 1.21版本上创建NodeGroup使用Containerd替代Docker

## 一、创建集群

EKS 1.21版本和1.22版本继续使用Docker作为默认容器运行时，如果需要使用Containerd作为默认运行时，则需要在创建节点组时候额外加参数进行配置。

编辑配置文件，替换其中的信息包括集群名称、区域、AMI的ID等，请注意有多处eksworkshop的需要替换。例如在ZHY区域替换如下：

```
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: eksworkshop
  region: cn-northwest-1

managedNodeGroups:
  - name: ctd
    labels:
      Name: ctd
    instanceType: t3.xlarge
    minSize: 2
    desiredCapacity: 2
    maxSize: 3
    privateNetworking: true
    volumeType: gp3
    volumeSize: 50
    tags:
      nodegroup-name: ctd
    ami: ami-03359a0e76c5425c5
    iam:
      withAddonPolicies:
        imageBuilder: true
        autoScaler: true
        certManager: true
        efs: true
        albIngress: true
        xRay: true
        cloudWatch: true
    overrideBootstrapCommand: |
      #!/bin/bash
      /etc/eks/bootstrap.sh eksworkshop --container-runtime containerd
```

将以上配置保存为`newnodegroup.yaml`。启动新的node group：

```
eksctl create nodegroup -f newnodegroup.yaml
```

## 二、启动容器

当通过ALB Ingress能正常访问到运行时为containerd的Node节点上运行的pod的时候，就表示pod工作正常。可使用EC2 Connect功能，借助Session Manager会话管理器登录到Node节点。然后执行如下命令：

```
systemctl status containerd.service
```

如果可以看到服务的状态是`Active(running)`，则表示启动正常。同时也可以通过查看服务日志确认运行正常。

```
journalctl -u containerd
```

执行如下命令查看Namespace名为`k8s.io`下的container。

```
ctr -n k8s.io c ls
```

## 三、参考资料

Docker弃用说明

[https://docs.aws.amazon.com/zh_cn/eks/latest/userguide/dockershim-deprecation.html](https://docs.aws.amazon.com/zh_cn/eks/latest/userguide/dockershim-deprecation.html)



