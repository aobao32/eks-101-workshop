# 测试EKS服务上Pod使用VPC CNI对网络吞吐性能的影响

> EKS 1.36 版本 @2026-09 AWS Global 区域（ap-southeast-1）实测通过，VPC CNI 测试版本为 `v1.22.4-eksbuild.3` 与 `v1.23.1-eksbuild.1`。

## 一、背景

在EC2的网络优化机型上，例如c6in.8xlarge（32vCPU/64GB），其网络带宽标称值为50Gbps。在没有容器环境的情况下，两台EC2之间使用iperf2测试可获得约49.7Gbps的吞吐，相当于标称值的99.4%，考虑统计差异，可认为几乎没有损耗。测试过程和方法参考[这篇](https://blog.bitipcman.com/ec2-ena-iperf-networking-performance/)博客。

当场景来到EKS上，Pod的所有流量都经由Node节点上的AWS VPC CNI（Amazon VPC Container Network Interface）插件配置的虚拟网卡对（veth pair）与策略路由，再通过节点的弹性网卡（ENI，Elastic Network Interface）进出VPC。本文将压力测试的一端设置为非容器化的EC2，另一端设置为EKS上的Pod容器，分别在EKS 1.36默认的VPC CNI版本与最新版本下进行双向吞吐测试，以验证VPC CNI转发路径是否会造成可观测的性能衰减。

## 二、实验环境

基础环境：

- Time: UTC 11:30-12:30, Sep 24, 2026
- Region: ap-southeast-1, AZ: ap-southeast-1b（AZ ID为`apse1-az1`）

EC2一侧：

- EC2: c6in.8xlarge
- OS: Amazon Linux 2023.12.20260918
- Kernel: 6.18.48-109.150.amzn2023.x86_64
- ENA Driver: 2.17.2g, /lib/modules/6.18.48-109.150.amzn2023.x86_64/kernel/drivers/amazon/net/ena/ena.ko（系统自带）
- iperf2: iperf version 2.1.9 (14 March 2023) pthreads

EKS容器一侧的Node节点：

- EKS版本：1.36，kubelet版本`v1.36.4-eks-a887778`
- Node类型：Managed node group
- EC2: c6in.8xlarge
- OS: Amazon Linux 2023.12.20260918
- Kernel: 6.18.48-107.148.amzn2023.x86_64
- ENA Driver: 2.17.2g, /lib/modules/6.18.48-107.148.amzn2023.x86_64/kernel/drivers/amazon/net/ena/ena.ko（系统自带）
- Container Runtime: containerd 2.2.7
- CNI: AWS VPC CNI，分别测试了EKS 1.36的默认版本`v1.22.4-eksbuild.3`与截至测试时的最新版本`v1.23.1-eksbuild.1`

EKS上Pod：

- OS: Amazon Linux 2023.12.20260918（基础镜像`public.ecr.aws/amazonlinux/amazonlinux:2023`）
- iperf2: iperf version 2.1.9 (14 March 2023) pthreads

需要说明的是，本次测试所用集群沿用了实验八配置的VPC CNI自定义网络（Custom Networking），Pod地址来自`100.64.0.0/16`辅助网段中的独立子网，由节点上额外挂载的弹性网卡承载。未启用自定义网络的集群中，Pod地址与节点位于同一子网，二者的数据路径同为VPC CNI经由节点弹性网卡转发，本文的测试方法与结论同样适用。

## 三、环境搭建

### 1、创建EKS集群

准备如下配置文件，保存为`newvpc-c6in.yaml`（本仓库`18/newvpc-c6in.yaml`为同一文件）。

```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: eksworkshop
  region: ap-southeast-1
  version: "1.36"

vpc:
  clusterEndpoints:
    publicAccess:  true
    privateAccess: true

kubernetesNetworkConfig:
  serviceIPv4CIDR: 10.50.0.0/24

managedNodeGroups:
  - name: perf-ng
    labels:
      Name: perf-ng
    instanceType: c6in.8xlarge
    availabilityZones: ["ap-southeast-1b"]
    minSize: 2
    desiredCapacity: 2
    maxSize: 2
    volumeType: gp3
    volumeSize: 100
    volumeIOPS: 3000
    volumeThroughput: 125
    tags:
      nodegroup-name: perf-ng
    iam:
      withAddonPolicies:
        imageBuilder: true
        autoScaler: true
        certManager: true
        efs: true
        ebs: true
        awsLoadBalancerController: true
        xRay: true
        cloudWatch: true

cloudWatch:
  clusterLogging:
    enableTypes: ["api", "audit", "authenticator", "controllerManager", "scheduler"]
    logRetentionInDays: 30
```

在以上配置文件中，指定了两台`c6in.8xlarge`作为节点组`perf-ng`，并通过`availabilityZones`将节点组限定在`ap-southeast-1b`单一可用区。这样做有两个原因：一是压测EC2与Pod所在节点位于同一可用区，可排除跨可用区时延对测试结果的干扰；二是50Gbps的压测每10秒即产生约58GB流量，跨可用区传输会按GB产生数据传输费用，同可用区使用私有IP通信则不产生该费用。节点标签`Name: perf-ng`用于后续将测试Pod调度到该节点组。

创建前，先执行如下命令进行只读校验。该命令不会创建任何资源：

```shell
eksctl create cluster -f newvpc-c6in.yaml --dry-run
```

校验通过后，执行如下命令创建EKS集群：

```shell
eksctl create cluster -f newvpc-c6in.yaml
```

EKS集群会在一个新的VPC中创建好，与现有VPC无冲突。

如果已经按照实验一创建了名为`eksworkshop`的集群，则无需新建集群，执行如下命令只在现有集群中新增`perf-ng`节点组即可：

```shell
eksctl create nodegroup -f newvpc-c6in.yaml
```

返回结果如下（节选）：

```
2026-09-24 19:39:13 [ℹ]  nodegroup "perf-ng" has 2 node(s)
2026-09-24 19:39:13 [ℹ]  node "ip-192-168-75-168.ap-southeast-1.compute.internal" is ready
2026-09-24 19:39:13 [ℹ]  node "ip-192-168-93-157.ap-southeast-1.compute.internal" is ready
2026-09-24 19:39:13 [✔]  created 1 managed nodegroup(s) in cluster "eksworkshop"
2026-09-24 19:39:16 [ℹ]  checking security group configuration for all nodegroups
2026-09-24 19:39:16 [ℹ]  all nodegroups have up-to-date cloudformation templates
```

执行如下命令确认节点状态：

```shell
kubectl get node -l Name=perf-ng -o wide
```

返回结果如下：

```
NAME                                                STATUS   ROLES    AGE    VERSION               INTERNAL-IP      EXTERNAL-IP    OS-IMAGE                        KERNEL-VERSION                            CONTAINER-RUNTIME
ip-192-168-75-168.ap-southeast-1.compute.internal   Ready    <none>   3m6s   v1.36.4-eks-a887778   192.168.75.168   47.129.50.81   Amazon Linux 2023.12.20260918   6.18.48-107.148.amzn2023.x86_64 (amd64)   containerd://2.2.7+unknown
ip-192-168-93-157.ap-southeast-1.compute.internal   Ready    <none>   3m7s   v1.36.4-eks-a887778   192.168.93.157   3.1.205.86     Amazon Linux 2023.12.20260918   6.18.48-107.148.amzn2023.x86_64 (amd64)   containerd://2.2.7+unknown
```

注意：`c6in.8xlarge`在新加坡区域的按需价格为每小时2.0832美元（本文编写时通过AWS Pricing API查询），两台节点加一台压测EC2合计每小时约6.25美元，测试完成后请按第五章末尾的步骤及时清理。

### 2、压力测试用EC2

压测EC2需要与节点组位于同一VPC、同一可用区。首先执行如下命令查询集群的VPC与集群安全组，并找到`ap-southeast-1b`可用区中的公有子网：

```shell
aws eks describe-cluster --name eksworkshop --region ap-southeast-1 \
  --query 'cluster.resourcesVpcConfig.[vpcId,clusterSecurityGroupId]' --output text
aws ec2 describe-subnets --region ap-southeast-1 \
  --filters Name=vpc-id,Values=<vpc-id> Name=availability-zone,Values=ap-southeast-1b Name=map-public-ip-on-launch,Values=true \
  --query 'Subnets[].[SubnetId,CidrBlock]' --output text
```

返回结果如下，第一行为VPC ID与集群安全组ID，第二行为该可用区的公有子网：

```
vpc-0a69fad178fdc8284	sg-0bc05dc2178acff1d
subnet-0fcbf89630d3c64b3	192.168.64.0/19
```

然后执行如下命令创建EC2。操作系统使用最新的Amazon Linux 2023 AMI，通过公共SSM参数获取AMI ID；实例配置文件（Instance Profile）需要包含`AmazonSSMManagedInstanceCore`权限，以便通过Session Manager登录：

```shell
AMI_ID=$(aws ssm get-parameter --region ap-southeast-1 \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text)

aws ec2 run-instances --region ap-southeast-1 \
  --image-id $AMI_ID \
  --instance-type c6in.8xlarge \
  --subnet-id <public-subnet-id-in-ap-southeast-1b> \
  --security-group-ids <cluster-security-group-id> \
  --iam-instance-profile Name=<ssm-instance-profile-name> \
  --associate-public-ip-address \
  --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=30,VolumeType=gp3}' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=iperf2-ec2-perftest}]' \
  --query 'Instances[0].[InstanceId,PrivateIpAddress,Placement.AvailabilityZone]' --output text
```

返回结果如下：

```
i-0a9dc6a21e74f42f9	192.168.64.189	ap-southeast-1b
```

登录EC2后，执行如下命令安装iperf2。Amazon Linux 2023自带软件源中只有iperf3，这里使用预先编译的iperf2 RPM包：

```shell
sudo dnf install -y https://blogimg.bitipcman.com/workshop/EC2-iperf2/iperf-2.1.9-1.amzn2023.x86_64.rpm
iperf -v
modinfo ena | grep -E '^(filename|version)'
```

返回结果如下：

```
iperf version 2.1.9 (14 March 2023) pthreads
filename:       /lib/modules/6.18.48-109.150.amzn2023.x86_64/kernel/drivers/amazon/net/ena/ena.ko
version:        2.17.2g
```

在标称内网规格是50Gbps的场景下，不需要Placement group即可达到50Gbps的性能。如果需要更高，建议考虑使用EC2 Placement group以聚合EC2的物理位置从而实现更高性能。

### 3、设置EC2和EKS Node使用同一个安全组且允许互相访问

关于安全规则组，确保服务器和客户端二者互相授权，允许客户端访问服务器端的TCP和UDP协议的所有端口。这是由于iperf调用的端口较多，虽然可以通过`-p`参数指定端口，但是相对麻烦。

这里推荐将EC2和EKS的Node节点绑定同一个安全规则组，然后在这个安全规则组中加入一条规则，允许所有流量访问并限定来源是本安全组。这样即可允许绑定这个安全组的两个机器之间完全互信。

使用eksctl创建的托管节点组，其节点默认绑定EKS自动生成的集群安全组（名称形如`eks-cluster-sg-eksworkshop-<随机数字>`），该安全组已内置一条“允许所有流量、来源为本安全组”的规则。因此上一步创建EC2时直接指定该集群安全组，即可满足互信要求，无需新建安全组。执行如下命令可确认该规则存在：

```shell
aws ec2 describe-security-groups --region ap-southeast-1 --group-ids <cluster-security-group-id> \
  --query "SecurityGroups[0].IpPermissions[?IpProtocol=='-1'].UserIdGroupPairs[].GroupId" --output text
```

返回结果如下：

```
sg-0bc05dc2178acff1d	sg-084cf498aece02823
```

返回结果中包含集群安全组自身的ID（本例为第一个ID）即表示规则有效，另一个ID是eksctl创建的节点共享安全组。如果集群启用了VPC CNI自定义网络，Pod流量经由ENIConfig中指定的安全组进出，此时还需确认ENIConfig的`securityGroups`同样为该集群安全组，执行如下命令查看：

```shell
kubectl get eniconfig -o custom-columns='NAME:.metadata.name,SUBNET:.spec.subnet,SG:.spec.securityGroups'
```

注意：该安全组同时承担节点与控制平面之间的通信，向其中加入压测EC2只适用于临时测试环境。生产环境中应为压测机单独创建安全组，并仅放行所需端口。

### 4、构建容器并拉起容器

准备如下Dockerfile文件（本仓库`18/Dockerfile`为同一文件）。镜像以Amazon Linux 2023为基础，安装iperf2及常用网络排查工具，容器启动后以前台方式运行`iperf -s`作为服务器端：

```dockerfile
FROM public.ecr.aws/amazonlinux/amazonlinux:2023

# Install iperf2 (prebuilt RPM for Amazon Linux 2023 x86_64) and network troubleshooting tools
RUN dnf install -y \
    https://blogimg.bitipcman.com/workshop/EC2-iperf2/iperf-2.1.9-1.amzn2023.x86_64.rpm \
    iproute \
    ethtool \
    procps-ng \
 && dnf clean all

# iperf2 listens on TCP/UDP 5001 by default
EXPOSE 5001/tcp
EXPOSE 5001/udp

# Run iperf2 as server in foreground
CMD ["iperf", "-s"]
```

由于iperf2的RPM包与`c6in`机型均为x86_64架构，构建主机也需要是x86_64架构。执行如下命令创建ECR仓库、登录ECR、构建并推送镜像：

```shell
aws ecr create-repository --repository-name iperf2 --region ap-southeast-1
aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin <account-id>.dkr.ecr.ap-southeast-1.amazonaws.com
docker build -t iperf2:2.1.9 .
docker run --rm iperf2:2.1.9 iperf -v
docker tag iperf2:2.1.9 <account-id>.dkr.ecr.ap-southeast-1.amazonaws.com/iperf2:2.1.9
docker push <account-id>.dkr.ecr.ap-southeast-1.amazonaws.com/iperf2:2.1.9
```

返回结果如下（节选）：

```
iperf version 2.1.9 (14 March 2023) pthreads
922d316c3330: Pushed
3ee87b1055c5: Pushed
2.1.9: digest: sha256:54e9925a4ba50ea19c1e2f8c602eb44545c1356bf38ca247b527045a17e1b07e size: 855
```

准备如下容器应用配置文件，保存为`iperf2.yaml`（本仓库`18/iperf2.yaml`为同一文件），将其中的`<account-id>`替换为实际的账号ID。`nodeSelector`用于将Pod调度到`perf-ng`节点组。测试在VPC内部通过Pod IP直连完成，因此无需创建Service或负载均衡器：

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: iperf2
  labels:
    app: iperf2
spec:
  replicas: 1
  selector:
    matchLabels:
      app: iperf2
  template:
    metadata:
      labels:
        app: iperf2
    spec:
      nodeSelector:
        Name: perf-ng
      containers:
      - name: iperf2
        image: <account-id>.dkr.ecr.ap-southeast-1.amazonaws.com/iperf2:2.1.9
        ports:
        - containerPort: 5001
          protocol: TCP
        - containerPort: 5001
          protocol: UDP
```

执行如下命令拉起应用，获得测试用容器：

```shell
kubectl apply -f iperf2.yaml
kubectl get pods -l app=iperf2 -o wide
kubectl logs -l app=iperf2
```

返回结果如下：

```
deployment.apps/iperf2 created
NAME                      READY   STATUS    RESTARTS   AGE   IP           NODE                                                NOMINATED NODE   READINESS GATES
iperf2-75486787bd-pbwwn   1/1     Running   0          33s   100.64.2.7   ip-192-168-75-168.ap-southeast-1.compute.internal   <none>           <none>
------------------------------------------------------------
Server listening on TCP port 5001
TCP window size:  128 KByte (default)
------------------------------------------------------------
```

返回结果中的`IP`列即为Pod IP，后续作为EC2发起压力时的目标地址。下面进入测试流程。

## 四、测试流程

### 1、iperf2工具使用方法

压力测试iperf工具命令和方法参考[这篇](https://blog.bitipcman.com/ec2-ena-iperf-networking-performance/)博客。

服务器端：

```shell
iperf -s
```

客户端：

```shell
iperf -c <server-ip> --parallel 32 -i 1
```

其中`--parallel 32`表示32个并发流，与`c6in.8xlarge`的32个vCPU相对应；`-i 1`表示每秒打印一次统计；在不添加其他参数的情况下，默认使用TCP协议，持续10秒。

本文的Pod镜像已将`iperf -s`作为容器启动命令，因此EC2发起压力、Pod承接的场景下，直接在EC2上执行客户端命令即可，目标地址为上一章查询到的Pod IP：

```shell
iperf -c 100.64.2.7 --parallel 32 -i 1
```

### 2、登录到pod内的shell发起交互式命令

Pod发起压力、EC2承接的场景下，需要先在EC2上启动服务器端`iperf -s`，然后登录到Pod的shell环境中执行客户端命令。

首先查看测试Pod：

```shell
kubectl get pods -l app=iperf2
```

返回结果如下：

```
NAME                      READY   STATUS    RESTARTS   AGE
iperf2-7ff6f56754-m8zg4   1/1     Running   0          104s
```

复制Pod名称，拼接如下命令登录到容器：

```shell
kubectl exec --stdin --tty iperf2-7ff6f56754-m8zg4 -- /bin/bash
```

登录后，在容器内执行如下命令，目标地址为压测EC2的私有IP：

```shell
iperf -c 192.168.64.189 --parallel 32 -i 1
```

这个过程也可以使用其他容器管理工具例如`k9s`完成，在`k9s`中选中该Pod后按`s`键即可进入shell。

### 3、客户端和服务器端调换位置的测试

发起测试后，记录结果。EC2发起压力、Pod承接的一次测试结果如下：

```
------------------------------------------------------------
Client connecting to 100.64.2.7, TCP port 5001
TCP window size: 20.0 KByte (default)
------------------------------------------------------------
[  8] local 192.168.64.189 port 49914 connected with 100.64.2.7 port 5001 (icwnd/mss/irtt=87/8949/1394)
[  3] local 192.168.64.189 port 50068 connected with 100.64.2.7 port 5001 (icwnd/mss/irtt=87/8949/1451)

# 此处省略若干行...

[  1] 0.00-10.02 sec   854 MBytes   715 Mbits/sec
[ 17] 0.00-10.02 sec  4.33 GBytes  3.71 Gbits/sec
[ 23] 0.00-10.02 sec   543 MBytes   454 Mbits/sec
[ 21] 0.00-10.02 sec   256 MBytes   214 Mbits/sec
[ 30] 0.00-10.02 sec  1.82 GBytes  1.56 Gbits/sec
[  3] 0.00-10.02 sec   308 MBytes   258 Mbits/sec
[ 24] 0.00-10.02 sec  2.53 GBytes  2.17 Gbits/sec
[ 25] 0.00-10.02 sec   256 MBytes   214 Mbits/sec
[ 22] 0.00-10.02 sec   586 MBytes   490 Mbits/sec
[ 20] 0.00-10.02 sec  2.20 GBytes  1.88 Gbits/sec
[ 27] 0.00-10.02 sec  1.54 GBytes  1.32 Gbits/sec
[ 18] 0.00-10.02 sec  1.34 GBytes  1.15 Gbits/sec
[ 16] 0.00-10.02 sec  1.89 GBytes  1.62 Gbits/sec
[SUM] 0.00-10.00 sec  58.0 GBytes  49.8 Gbits/sec
```

回显中`mss`为8949，说明EC2与Pod之间的路径使用了9001字节的巨型帧（Jumbo Frame）。各并发流之间的吞吐分布并不均匀，但`[SUM]`行的合计值稳定在标称带宽附近，评估时以`[SUM]`行为准。

然后将服务器端和客户端的位置对换，再次执行测试。Pod发起压力、EC2承接的一次测试结果如下：

```
------------------------------------------------------------
Client connecting to 192.168.64.189, TCP port 5001
TCP window size: 20.0 KByte (default)
------------------------------------------------------------
[ 22] local 100.64.2.7 port 51540 connected with 192.168.64.189 port 5001 (icwnd/mss/irtt=87/8949/207)

# 此处省略若干行...

[ 24] 0.00-10.03 sec  1.24 GBytes  1.06 Gbits/sec
[  3] 0.00-10.03 sec   398 MBytes   333 Mbits/sec
[ 15] 0.00-10.01 sec  3.27 GBytes  2.80 Gbits/sec
[ 20] 0.00-10.01 sec  9.77 GBytes  8.38 Gbits/sec
[ 27] 0.00-10.01 sec  4.76 GBytes  4.09 Gbits/sec
[ 17] 0.00-10.03 sec  2.75 GBytes  2.36 Gbits/sec
[SUM] 0.00-10.00 sec  58.1 GBytes  49.8 Gbits/sec
```

### 4、升级EKS的VPC CNI到最新版本再进行测试

前边测试完成后，升级EKS的AWS VPC CNI版本，重复测试。

首先执行如下命令查看当前版本：

```shell
kubectl describe daemonset aws-node --namespace kube-system | grep amazon-k8s-cni: | cut -d : -f 3
```

返回结果如下：

```
v1.22.4-eksbuild.3
```

执行如下命令查询EKS 1.36下VPC CNI的可用版本，其中第二列为`True`的是该EKS版本的默认版本：

```shell
aws eks describe-addon-versions --addon-name vpc-cni --kubernetes-version 1.36 --region ap-southeast-1 \
  --query 'addons[0].addonVersions[].[addonVersion,compatibilities[0].defaultVersion]' --output text | head -4
```

返回结果如下：

```
v1.23.1-eksbuild.1	False
v1.23.0-eksbuild.1	False
v1.22.4-eksbuild.3	True
v1.22.3-eksbuild.1	False
```

执行如下命令将VPC CNI升级到最新版本`v1.23.1-eksbuild.1`。`--resolve-conflicts OVERWRITE`表示以托管Addon的配置覆盖集群中被修改过的字段；命令中未传入`--configuration-values`时，Addon已有的配置值（例如自定义网络的环境变量）会被保留：

```shell
aws eks update-addon --cluster-name eksworkshop --addon-name vpc-cni \
  --addon-version v1.23.1-eksbuild.1 --resolve-conflicts OVERWRITE --region ap-southeast-1
```

大约1分钟后，执行如下命令确认升级完成：

```shell
aws eks describe-addon --cluster-name eksworkshop --addon-name vpc-cni --region ap-southeast-1 \
  --query 'addon.[addonVersion,status,configurationValues]' --output text
kubectl rollout status ds/aws-node -n kube-system
```

返回结果如下：

```
v1.23.1-eksbuild.1	ACTIVE	{"env":{"AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG":"true","ENI_CONFIG_LABEL_DEF":"topology.kubernetes.io/zone"}}
daemon set "aws-node" successfully rolled out
```

也可以通过EKS控制台的Add-ons界面完成升级，操作方法请参考本仓库的[实验十七](https://github.com/aobao32/eks-101-workshop/blob/main/17-EKS-addon.md)。

升级VPC CNI只会滚动重建`aws-node` DaemonSet，已经运行的Pod网络不受影响，仍保持由旧版本CNI创建时的网络配置。为使测试Pod的网络由新版本CNI配置，执行如下命令重建测试Pod：

```shell
kubectl rollout restart deploy/iperf2
kubectl rollout status deploy/iperf2
kubectl get pods -l app=iperf2 -o wide
```

返回结果如下：

```
deployment.apps/iperf2 restarted
deployment "iperf2" successfully rolled out
NAME                      READY   STATUS    RESTARTS   AGE   IP            NODE                                                NOMINATED NODE   READINESS GATES
iperf2-7ff6f56754-m8zg4   1/1     Running   0          4s    100.64.2.74   ip-192-168-93-157.ap-southeast-1.compute.internal   <none>           <none>
```

重建后Pod IP与所在节点可能发生变化，需以新的Pod IP作为EC2发起压力时的目标地址。然后按本章第1至3节的方法再次进行双向测试，并观察测试结果。

## 五、测试数据和小结

|对比|CNI版本<br>v1.22.4-eksbuild.3（EKS 1.36默认）|CNI版本<br>v1.23.1-eksbuild.1（最新）|
|---|---|---|
|EC2发起压力<br>Pod承接|49.8Gbps|49.8Gbps|
|Pod发起压力<br>EC2承接|49.8Gbps|49.9Gbps|

每个组合重复执行3次测试，`[SUM]`合计吞吐均在49.8Gbps和49.9Gbps之间抖动，表中取中位数。

结论：与之前[这篇](https://blog.bitipcman.com/ec2-ena-iperf-networking-performance/)博客中两端都是EC2的测试相比，将压力测试的一端放到EKS上的Pod、并通过AWS VPC CNI提供网络接入后，在EKS 1.36默认版本与最新版本的VPC CNI下均没有观测到性能衰减，吞吐达到`c6in.8xlarge`标称50Gbps的99.6%至99.8%，两个CNI版本之间的差异处于测试抖动范围之内，可放心使用。

测试完成后，执行如下命令清理测试资源，避免`c6in.8xlarge`持续计费。如果是新建的测试集群，直接删除整个集群即可；如果是在实验一集群中新增的节点组，则只删除该节点组：

```shell
kubectl delete -f iperf2.yaml
aws ec2 terminate-instances --instance-ids <iperf2-ec2-instance-id> --region ap-southeast-1
aws ecr delete-repository --repository-name iperf2 --force --region ap-southeast-1
eksctl delete nodegroup --cluster eksworkshop --name perf-ng --region ap-southeast-1 --wait
```

## 参考文档

使用 iperf2 测试 EC2 网络优化型实例内网吞吐性能的方法，以及 Amazon Linux 2023 上 iperf2 RPM 包的构建过程：

[https://blog.bitipcman.com/ec2-ena-iperf-networking-performance/](https://blog.bitipcman.com/ec2-ena-iperf-networking-performance/)

Amazon EC2 实例网络带宽说明，包括多流与单流带宽限制、放置组与 ENA Express 对单流带宽的影响：

[https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-network-bandwidth.html](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-network-bandwidth.html)

Amazon EC2 计算优化型实例规格，包括 C6in 各规格的网络带宽标称值：

[https://aws.amazon.com/ec2/instance-types/compute-optimized/](https://aws.amazon.com/ec2/instance-types/compute-optimized/)

以 EKS 托管 Addon 方式升级 Amazon VPC CNI 的官方步骤：

[https://docs.aws.amazon.com/eks/latest/userguide/vpc-add-on-update.html](https://docs.aws.amazon.com/eks/latest/userguide/vpc-add-on-update.html)

EKS 托管 Addon 的版本兼容与升级约束（每次只能升级一个次版本）：

[https://docs.aws.amazon.com/eks/latest/userguide/workloads-add-ons-available-eks.html](https://docs.aws.amazon.com/eks/latest/userguide/workloads-add-ons-available-eks.html)

本仓库实验十七，使用 EKS 控制台的 Addon 功能升级 VPC CNI：

[https://github.com/aobao32/eks-101-workshop/blob/main/17-EKS-addon.md](https://github.com/aobao32/eks-101-workshop/blob/main/17-EKS-addon.md)
