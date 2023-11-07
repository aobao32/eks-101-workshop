# 收集EKS Node节点日志用于Support排查

## 一、背景

当遇到EKS问题时候，可能需要创建Support Case并与Support一起排查问题。此时需要采集EKS运行环境的日志，主要是Node节点的日志。

此时可使用如下工具：

[https://github.com/awslabs/amazon-eks-ami/tree/master/log-collector-script/linux]()

这个工具需要在EKS Node节点上执行。

## 二、使用方法

通过SSH或者EC2 Connect的Session Manager功能登录到Node节点。

执行如下命令：

```shell
curl -O https://raw.githubusercontent.com/awslabs/amazon-eks-ami/master/log-collector-script/linux/eks-log-collector.sh
sudo bash eks-log-collector.sh
```

其效果如下

```shell
        This is version 0.7.6. New versions can be found at https://github.com/awslabs/amazon-eks-ami/blob/master/log-collector-script/

Trying to collect common operating system logs...
Trying to collect kernel logs...
Trying to collect modinfo... Trying to collect mount points and volume information...
Trying to collect SELinux status...
Trying to collect iptables information...
Trying to collect installed packages...
Trying to collect active system services...
Trying to Collect Containerd daemon information...
Trying to Collect Containerd running information...
Trying to Collect Docker daemon information...

        Warning: The Docker daemon is not running.

Trying to collect kubelet information...
Trying to collect L-IPAMD introspection information... Trying to collect L-IPAMD prometheus metrics... Trying to collect L-IPAMD checkpoint...
Trying to collect Multus logs if they exist...
Trying to collect sysctls information...
Trying to collect networking infomation... conntrack v1.4.4 (conntrack-tools): 98 flow entries have been shown.

Trying to collect CNI configuration information...
Trying to collect CNI Configuration Variables from Docker...

        Warning: The Docker daemon is not running.
Trying to collect CNI Configuration Variables from Containerd...
Trying to collect Docker daemon logs...
Trying to Collect sandbox-image daemon information...
Trying to Collect CPU Throttled Process Information...
Trying to Collect IO Throttled Process Information...
Trying to archive gathered information...

        Done... your bundled logs are located in /var/log/eks_i-091b361f59c1ee174_2023-11-03_0412-UTC_0.7.6.tar.gz

[root@ip-192-168-82-173 ~]#
```

由此可以看到，日志被采集到`/var/log/eks_i-091b361f59c1ee174_2023-11-03_0412-UTC_0.7.6.tar.gz`。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/eks-log.png)

现在就可以将这个文件通过scp命令复制出来。在能够通过ssh连接的机器上执行：

```shell
scp -i 证书名.pem ec2-users@nodeip:/var/log/eks_i-091b361f59c1ee174_2023-11-03_0412-UTC_0.7.6.tar.gz .
```

即可把日志复制到本地。

日志是tar.gz的压缩包，打开这个压缩包，可看到里边包含了EKS各组件的日志：

```shell
 ~/D/eks_i-064f96b0dd6d7dcc6_2023-11-03_0213-UTC_0.7.6  ls -l                                                       12:27:26
total 0
drwxr-xr-x@  4 lxy  staff  128 Nov  3 10:16 cni/
drwxr-xr-x@ 11 lxy  staff  352 Nov  3 10:14 containerd/
drwxr-xr-x@  3 lxy  staff   96 Nov  3 10:16 docker/
drwxr-xr-x@  9 lxy  staff  288 Nov  3 10:15 ipamd/
drwxr-xr-x@  6 lxy  staff  192 Nov  3 10:13 kernel/
drwxr-xr-x@  5 lxy  staff  160 Nov  3 10:15 kubelet/
drwxr-xr-x@  3 lxy  staff   96 Nov  3 10:13 modinfo/
drwxr-xr-x@ 17 lxy  staff  544 Nov  3 10:16 networking/
drwxr-xr-x@  3 lxy  staff   96 Nov  3 10:16 sandbox-image/
drwxr-xr-x@ 10 lxy  staff  320 Nov  3 10:14 storage/
drwxr-xr-x@  3 lxy  staff   96 Nov  3 10:15 sysctls/
drwxr-xr-x@ 17 lxy  staff  544 Nov  3 10:16 system/
drwxr-xr-x@ 15 lxy  staff  480 Nov  3 10:13 var_log/
 ~/D/eks_i-064f96b0dd6d7dcc6_2023-11-03_0213-UTC_0.7.6
```

接下来查找对应组件的目录中的日志问题，即可开始调查问题。