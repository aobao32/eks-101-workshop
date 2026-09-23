# 收集EKS Node节点日志用于Support排查

> 更新到 EKS 1.36版本

## 一、背景

当遇到EKS问题时候，可能需要创建Support Case并与Support一起排查问题。此时需要采集EKS运行环境的日志，主要是Node节点的日志。

此时可使用如下工具：

[https://github.com/awslabs/amazon-eks-ami/tree/main/log-collector-script/linux]()

这个工具需要在EKS Node节点上执行。当前EKS 1.36的托管节点默认使用Amazon Linux 2023操作系统，容器运行时为containerd，脚本可直接在该环境运行。

## 二、使用方法

采集脚本需要登录到Node节点上执行。登录方式有两种：一种是使用SSH密钥直接连接（要求节点位于可达的网络位置并放行22端口）；另一种是使用AWS Systems Manager的Session Manager功能，通过浏览器直接打开节点的终端，无需开放入站端口，也无需管理SSH密钥。EKS 1.36的Amazon Linux 2023托管节点默认已安装SSM Agent，只要节点绑定的实例角色包含`AmazonSSMManagedInstanceCore`权限，并且能够访问SSM相关服务端点，即可使用Session Manager连接。下面介绍在EC2控制台使用Session Manager连接到节点的操作步骤。

1. 登录AWS控制台，进入EC2服务，在左侧菜单中点击`Instances`，进入实例列表。

2. 在实例列表中定位到目标Node节点。EKS托管节点组创建的实例带有`eks:cluster-name`标签，其值为集群名称（本文为`eksworkshop`），可据此辨认；也可以在实例名称或标签中查找对应的节点组名称。勾选目标实例前的复选框。

3. 点击列表右上方的`Connect`按钮，进入`Connect to instance`页面。

4. 在该页面顶部的连接方式标签中，选择`Session Manager`标签页。如果该标签页提示无法连接，通常是实例角色缺少`AmazonSSMManagedInstanceCore`权限，或节点无法访问SSM服务端点，需要先补齐权限与网络路径。

5. 点击页面右下角的`Connect`按钮，浏览器会新开一个页面并打开该节点的终端会话。

6. Session Manager建立的会话默认以`ssm-user`身份登录，该用户具备sudo权限。因此在后续执行采集脚本时，命令前需要加`sudo`（本文的命令已包含`sudo`）。如果希望切换到root用户操作，可执行`sudo su -`。

连接建立后，即可在会话终端中执行下面的采集命令。

执行如下命令：

```shell
curl -O https://raw.githubusercontent.com/awslabs/amazon-eks-ami/main/log-collector-script/linux/eks-log-collector.sh
sudo bash eks-log-collector.sh
```

在EKS 1.36的Amazon Linux 2023节点上执行，其效果如下：

```shell
	This is version 0.7.9. New versions can be found at https://github.com/awslabs/amazon-eks-ami/blob/main/log-collector-script/
Trying to collect common operating system logs...
Trying to collect kernel logs...
Trying to collect modinfo... Trying to collect mount points and volume information...
Trying to collect SELinux status...
Trying to collect iptables information... Trying to collect ipvs information...
Trying to collect installed packages...
Trying to collect active system services... eks-log-collector.sh: line 839: /proc/10/environ: No such process
eks-log-collector.sh: line 839: /proc/13/environ: No such process
（此处省略若干条相同格式的提示，为扫描进程环境变量时进程已退出所致，属正常现象，不影响采集结果）
Trying to Collect Containerd daemon information...
Trying to Collect Containerd running information...
Trying to collect containerd snapshotter information...
Trying to Collect Docker daemon information...

	Warning: The Docker daemon is not running.

Trying to collect kubelet information...
Trying to collect nodeadm information...
Trying to collect L-IPAMD introspection information... Trying to collect L-IPAMD prometheus metrics... Trying to collect L-IPAMD checkpoint...
Trying to collect Multus logs if they exist...
Trying to collect sysctls information...
Trying to collect networking infomation... conntrack v1.4.6 (conntrack-tools): 353 flow entries have been shown.
Trying to collect CNI configuration information...
Trying to collect CNI Configuration Variables from Docker...

	Warning: The Docker daemon is not running.
Trying to collect CNI Configuration Variables from Containerd... time="2026-09-23T10:04:36Z" level=warning msg="DEPRECATION: The `bin_dir` property of `[plugins.\"io.containerd.cri.v1.runtime\".cni`] is deprecated since containerd v2.1 and will be removed in containerd v2.3. Use `bin_dirs` in the same section instead."
Trying to collect network policy ebpf loaded data...
Trying to collect Docker daemon logs...
Trying to Collect sandbox-image daemon information...
Trying to Collect CPU Throttled Process Information...
Trying to Collect IO Throttled Process Information...
Trying to Collect reboot history...
Trying to Collect Nvidia Bug report... No Nvidia drivers found, nothing to do.
Trying to archive gathered information...

	Done... your bundled logs are located in /var/log/eks_i-00c1b0a868824b4b2_2026-09-23_1004-UTC_0.7.9.tar.gz
****************************************************************************************
* WARNING: The log bundle collected by this script may contain sensitive information.  *
*                                                                                      *
* Please review the contents of the log bundle carefully and redact or obfuscate       *
* any information you do not wish to be accessible before sharing it with others.      *
****************************************************************************************
```

回显中的几点说明：脚本版本为0.7.9；采集"active system services"阶段出现的`/proc/<pid>/environ: No such process`提示，是脚本读取进程环境变量时该进程恰好已退出所致，属于正常现象，不影响日志采集；containerd相关的`bin_dir`弃用告警来自containerd v2.1，是运行时自身的版本提示，同样不影响采集；由于Amazon Linux 2023节点不运行Docker，`The Docker daemon is not running`为预期结果。脚本执行完毕后会给出一段提示，说明日志包可能包含敏感信息，在提交给Support或对外分享前请自行检查并脱敏。

由此可以看到，日志被采集到`/var/log/eks_i-00c1b0a868824b4b2_2026-09-23_1004-UTC_0.7.9.tar.gz`。文件名中包含实例ID、采集时间与脚本版本号，实际以您环境中生成的文件名为准。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/eks-log.png)

现在就可以将这个文件通过scp命令复制出来。在能够通过ssh连接的机器上执行：

```shell
scp -i 证书名.pem ec2-user@nodeip:/var/log/eks_i-00c1b0a868824b4b2_2026-09-23_1004-UTC_0.7.9.tar.gz .
```

即可把日志复制到本地。

日志是tar.gz的压缩包，解压后可看到里边按组件分目录存放了EKS运行环境的日志。查看其顶层目录的命令与结果如下：

```shell
tar -xzf eks_i-00c1b0a868824b4b2_2026-09-23_1004-UTC_0.7.9.tar.gz
ls -d */
```

```shell
cni/            kernel/         nodeadm/        sysctls/
containerd/     kubelet/        sandbox-image/  system/
docker/         modinfo/        storage/        var_log/
gpu/            networking/
ipamd/
```

其中`nodeadm`目录对应Amazon Linux 2023节点的引导程序nodeadm的日志，`gpu`目录用于收集GPU相关信息（本例节点无GPU，回显中提示未发现Nvidia驱动，未采集到相关内容），二者是较新版本脚本在Amazon Linux 2023环境下新增的采集项。其余目录如`containerd`、`kubelet`、`ipamd`、`networking`等分别对应容器运行时、kubelet、VPC CNI的IP地址管理组件以及网络配置等信息。

接下来查找对应组件的目录中的日志内容，即可开始调查问题。

## 三、参考文档

Amazon EKS AMI日志采集脚本（amazon-eks-ami仓库log-collector-script目录）：

[https://github.com/awslabs/amazon-eks-ami/tree/main/log-collector-script/linux]()

在EC2控制台使用Session Manager连接到实例：

[https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/connect-with-systems-manager-session-manager.html]()

AWS Systems Manager Session Manager功能说明：

[https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html]()
