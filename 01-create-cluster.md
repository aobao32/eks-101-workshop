# 实验一、创建EKS集群

EKS 1.30版本 @2024-07 AWS Global区域测试通过

## 一、AWSCLI安装和AKSK准备

### 1、客户端下载

本步骤对所有操作系统下都需要安装。请到[这里](https://aws.amazon.com/cli/)下载对应的操作系统的安装包。

### 2、配置AKSK和区域

配置进入AWS控制台，创建IAM用户，附加`AdministratorAccess`的IAM Policy，最后给这个用户生成AKSK密钥。

在安装好AWSCLI的客户端上，进入命令行窗口，执行`aws configure`，然后填写正确的AKSK。同时，在命令的最后一步配置region的时候，设置region为本次实验的`ap-southeast-1`。

请注意：如果是通过Workshop Studio自动创建的实验环境，在Workshop Studio界面上会提供一套默认的AKSK密钥，且这套AKSK需要搭配SessionToken使用。这套默认的密钥权限是不足以完成EKS集群创建的。因此，必须按照本文要求，重新创建一个新的管理员用户，然后新创建一个AKSK附加到本用户，才可以进行后续实验。

## 二、安装EKS客户端和Kubectl客户端（三个OS类型根据实验者选择其一）

请注意，eksctl版本和创建EKS的版本有对应关系，因此请升级您的客户端的eksctl到最新版本。

### 1、Windows下安装eksctl和kubectl工具

eksctl的安装可通过choco包管理工具进行。先使用管理员权限打开powershell，执行如下命令安装好choco工具：

```
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
```

即可安装好choco。然后在cmd下用管理员权限安装eksctl和jq工具（本步骤需要管理员权限）：

```
choco install -y eksctl kubernetes-cli kubernetes-helm k9s jq curl wget vim 7zip
```

即可安装好所有EKS管理工具。此外很多日常软件都可以后续执行`choco install`安装。

### 2、Linux下安装eksctl和kubectl工具

在Linux下安装eks工具，包括eksctl和kubectl两个。

使用X86_64架构的执行如下命令：

```
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /bin
curl -O https://s3.us-west-2.amazonaws.com/amazon-eks/1.30.0/2024-05-12/bin/linux/amd64/kubectl
chmod 755 kubectl
sudo mv kubectl /bin
eksctl version
```

使用Graviton处理器的ARM架构的Linux执行如下命令：

```
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_arm64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /bin
curl -O https://s3.us-west-2.amazonaws.com/amazon-eks/1.30.0/2024-05-12/bin/linux/arm64/kubectl
chmod 755 kubectl
sudo mv kubectl /bin
eksctl version
```

安装完毕后即可看到eksctl版本，同时kubectl也下载完毕。

### 3、MacOS下安装eksctl和kubectl工具

先安装homebrew包管理工具。这一步需要从Github下载，因此最好能使用国外VPN确保安装成功。

```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install.sh)"
```

然后使用brew工具即可安装eksctl。这里需要安装最新版本的eksctl，旧版本的不能创建最新EKS集群。

```
brew install helm
brew upgrade eksctl && { brew link --overwrite eksctl; } || { brew tap weaveworks/tap; brew install weaveworks/tap/eksctl; }
eksctl version
```

最后安装kubectl工具，也使用brew安装：

```
brew reinstall kubernetes-cli 
```

客户端准备完毕。

## 三、创建EKS集群的配置文件（两种场景二选一）

EKS集群分成EC2模式和无EC2的Fargate模式。本文为有EC2模式的配置，有关Fargate配置将在后续实验中讲解。在接下来的网络模式又有两种：

- 创建集群时候，如果不指定参数，那么eksctl默认会自动生成一个全新的VPC、子网并使用192.168的网段，然后在其中创建nodegroup节点组。此时如果希望位于默认VPC的现有业务系统与EKS互通，那么需要配置VPC Peering才可以打通网络；如果需求是此场景，请参考下述第一个章节所介绍的方式创建配置文件；
- 如果希望EKS使用现有VPC和子网，例如一个包含有Public Subnet/Private Subnet和NAT Gateway的VPC，那么请使用第二个章节所介绍的方式创建配置文件。

### 1、创建全新VPC

执行如下命令。注意如果是多人在同一个账号内实验，需要更改EKS集群的名字避免冲突。如果多人在不同账号内做实验，无需修改名称，默认的名称即可。

编辑配置文件`newvpc.yaml`，内容如下：

```
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: eksworkshop
  region: ap-southeast-1
  version: "1.30"

vpc:
  clusterEndpoints:
    publicAccess:  true
    privateAccess: true

kubernetesNetworkConfig:
  serviceIPv4CIDR: 10.50.0.0/24

managedNodeGroups:
  - name: managed-ng
    labels:
      Name: managed-ng
    instanceType: t3.2xlarge
    minSize: 3
    desiredCapacity: 3
    maxSize: 6
    volumeType: gp3
    volumeSize: 100
    volumeIOPS: 3000
    volumeThroughput: 125
    tags:
      nodegroup-name: ng1
    iam:
      withAddonPolicies:
        imageBuilder: true
        autoScaler: true
        externalDNS: true
        certManager: true
        efs: true
        ebs: true
        fsx: true
        albIngress: true
        awsLoadBalancerController: true
        xRay: true
        cloudWatch: true

cloudWatch:
  clusterLogging:
    enableTypes: ["api", "audit", "authenticator", "controllerManager", "scheduler"]
    logRetentionInDays: 30
```

请替换以上配置文件中集群名称、region为实际使用的地区。

执行如下命令创建集群。

```
eksctl create cluster -f newvpc.yaml
```

创建完成。

### 2、使用现有VPC的子网

#### （1）给EKS要使用的Subnet子网打标签

请确保本子网已经设置了正确的路由表，且VPC内包含NAT Gateway可以提供外网访问能力。然后接下来为其打标签。

找到当前的VPC，找到有EIP和NAT Gateway的Public Subnet，为其添加标签：

- 标签名称：`kubernetes.io/role/elb`，值：`1`

接下来进入Private subnet，为其添加标签：

- 标签名称：`kubernetes.io/role/internal-elb`，值：`1`

接下来请重复以上工作，三个AZ的子网都实施相同的配置，注意第一项标签值都是1。

请不要跳过以上步骤，否则后续使用ELB会遇到错误。

#### （2）要求EKS Nodegroup使用特定的Subnet

编辑配置文件`existingsubnet.yaml`，内容如下：

```
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: eksworkshop
  region: ap-southeast-1
  version: "1.30"

vpc:
  clusterEndpoints:
    publicAccess:  true
    privateAccess: true
  subnets:
    private:
      ap-southeast-1a: { id: subnet-04a7c6e7e1589c953 }
      ap-southeast-1b: { id: subnet-031022a6aab9b9e70 }
      ap-southeast-1c: { id: subnet-0eaf9054aa6daa68e }

kubernetesNetworkConfig:
  serviceIPv4CIDR: 10.50.0.0/24

managedNodeGroups:
  - name: managed-ng
    labels:
      Name: managed-ng
    instanceType: t3.2xlarge
    minSize: 3
    desiredCapacity: 3
    maxSize: 6
    privateNetworking: true
    subnets:
      - subnet-04a7c6e7e1589c953
      - subnet-031022a6aab9b9e70
      - subnet-0eaf9054aa6daa68e
    volumeType: gp3
    volumeSize: 100
    volumeIOPS: 3000
    volumeThroughput: 125
    tags:
      nodegroup-name: managed-ng
    iam:
      withAddonPolicies:
        imageBuilder: true
        autoScaler: true
        externalDNS: true
        certManager: true
        efs: true
        ebs: true
        fsx: true
        albIngress: true
        awsLoadBalancerController: true
        xRay: true
        cloudWatch: true
        
cloudWatch:
  clusterLogging:
    enableTypes: ["api", "audit", "authenticator", "controllerManager", "scheduler"]
    logRetentionInDays: 30
```

请替换以上配置文件中集群名称、region、子网ID为实际使用的地区。

执行如下命令创建集群。

```
eksctl create cluster -f existingsubnet.yaml
```

创建完成。

## 四、查看创建结果

此过程需要10-15分钟才可以创建完毕。执行如下命令查询节点。

```
kubectl get node
```

返回节点如下表示正常。

```
NAME                                                STATUS   ROLES    AGE     VERSION
ip-192-168-0-22.ap-southeast-1.compute.internal     Ready    <none>   8m12s   v1.30.0-eks-036c24b
ip-192-168-42-0.ap-southeast-1.compute.internal     Ready    <none>   8m14s   v1.30.0-eks-036c24b
ip-192-168-93-206.ap-southeast-1.compute.internal   Ready    <none>   8m17s   v1.30.0-eks-036c24b
```

## 五、创建集群并配置Dashboard图形界面（本章节可选）

本章节可跳过不影响后续实验。

### 1、部署K8S原生控制面板

以前部署K8S原生的Dashboard是从Github上拉取Yaml部署的，如今官方已经使用Helm作为唯一的部署方式。

前文在安装`eksctl`命令时候，已经在MacOS和Windows上安装helm。如果还没安装，那么在MacOS上执行`brew install helm`可安装好helm，在Windows上执行`choco install kubernetes-helm`可安装好helm。

```
helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/
helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard --create-namespace --namespace kubernetes-dashboard
```

返回结果如下：

```
Release "kubernetes-dashboard" does not exist. Installing it now.
NAME: kubernetes-dashboard
LAST DEPLOYED: Tue Jul  2 23:51:31 2024
NAMESPACE: kubernetes-dashboard
STATUS: deployed
REVISION: 1
TEST SUITE: None
NOTES:
*************************************************************************************************
*** PLEASE BE PATIENT: Kubernetes Dashboard may need a few minutes to get up and become ready ***
*************************************************************************************************

Congratulations! You have just installed Kubernetes Dashboard in your cluster.

To access Dashboard run:
  kubectl -n kubernetes-dashboard port-forward svc/kubernetes-dashboard-kong-proxy 8443:443

NOTE: In case port-forward command does not work, make sure that kong service name is correct.
      Check the services in Kubernetes Dashboard namespace using:
        kubectl -n kubernetes-dashboard get svc

Dashboard will be available at:
  https://localhost:8443
```

注意此窗口执行之后不要关闭，因为这个命令会转发Dashboard的443端口到本机的8443端口。

### 2、生成用户和Token

新开一个命令行，执行如下命令生成个用户并获取Token：

```
kubectl -n kubernetes-dashboard create serviceaccount admin
kubectl -n kubernetes-dashboard create token admin
```

返回结果如下：

```
eyJhbGciOiJSUzI1NiIsImtpZCI6IjVmOTNlYjFlMDUwOGFhYjE2M2Q4YzcwM2U5MjZlOTRjMzlmNDNkMDcifQ.eyJhdWQiOlsizHR0cHM6Ly9rdWJlcm5ldGVzLmRlZmF1bHQuc3ZjIl0sImV4cCI6MTcxOTkzOTUxMiwiaWF0IjoxNzE5OTM1OTEyLCJpc3MiOiJodHRwczovL29pZGMuZWtzLmFwLXNvdXRoZWFzdC0xLmFtYXpvbmF3cy5jb20vaWQvMUI0MjE1QUE3RDY1MUY1QjMyMTMwMjY0NUMyRjdERTUiLCJqdGkiOiJmNGI3N2I4Ny0wOTQ0LTQ0MjYtOGNiYy1hOWI3MmI2M2ZmZGQiLCJrdWJlcm5ldGVzLmlvIjp7Im5hbWVzcGFjZSI6Imt1YmVybmV0ZXMtZGFzaGJvYXJkIiwic2VydmljZWFjY291bnQiOnsibmFtZSI4ImFkbWluIiwidWlkIjoiY2NlNDc4YzUtMjY5ZS00MDMyLWEwYTMtOTg4MzJlNDc1YzVlIn19LCJuYmYiOjE3MTk5MzU5MTIsInN1YiI6InN5c3RlbTpzZXJ2aWNlYWNjb3VudDprdWJlcm5ldGVzLWRhc2hib2FyZDphZG1pbiJ9.LXMF3t3vaSgby4FMH9wG612EI6j__1ng-G8sdL2dqalQUyLuDBZMsD8fSDJmqrk5xIbxNi8NzVyqLsYmbM4IqukXAC1YpG3BIBQy7dv5mB04xea8ttzioSABEFeYREoycptmfvCrJ95Z5MhUy3wqMia6D8Up838P6q5iG9kSB7wd3CCcQAJXDUTWgIBVr8uhVGzEZvo72T9YsTCkwQPx30mj0lPXwBDA_HHCMNOBW-Kt26jMZFPHUFeINEFkQKSY_Fp2Xx23P05ZczkNFN0WkCcVp7zCtzEqiDz-o5pdztpNkvZD-6fTuupUUBb3HTtzjve_scz6vO-7RqS6NWh02Q
```

### 3、登陆Dashboard

在实验者的本机上访问如下地址：

```
https://127.0.0.1:8443/#/login
```

登录页面打开后，在`Bearer token`位置输入上一步获取的token，即可访问dashboard.

至此Dashboard配置完成。
 
### 4、删除Dashboard服务（可选）

测试完成后，如果需要删除Dashboard，执行如下命令。

```
helm uninstall kubernetes-dashboard -n kubernetes-dashboard
```

本命令为可选，可保留Dashboard，在后续实验中也可以继续通过Dashboard做监控。

## 六、部署Nginx测试应用并使用NodePort+NLB模式对外暴露服务

### 1、创建服务

这个测试应用将在当前集群的node上创建nginx应用pod，并使用default namespace运行Service，然后通过NodePort模式和NLB对外发布在80端口。

内容如下：

```
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
  labels:
    app: nginx
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: public.ecr.aws/nginx/nginx:1.27-alpine-slim
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: "service-nginx"
  annotations:
        service.beta.kubernetes.io/aws-load-balancer-type: nlb
spec:
  selector:
    app: nginx
  type: LoadBalancer
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
```

执行如下命令。

```
kubectl apply -f nginx-nlb.yaml
```

### 2、检查部署结果

查看创建出来的pod，执行如下命令。

```
kubectl get pods
```

返回结果如下Running表示运行正常。

```
NAME                               READY   STATUS    RESTARTS   AGE
nginx-deployment-559547759-4k82p   1/1     Running   0          12s
nginx-deployment-559547759-9wrsd   1/1     Running   0          12s
nginx-deployment-559547759-wm5mp   1/1     Running   0          12s
```

### 3、测试从浏览器访问

本实验使用的是NLB，创建NLB过程需要3-5分钟。此时可以通过AWS EC2控制台，进入Load Balance负载均衡界面，可以看到NLB处于Provisioning创建中的状态。等待其变成Active状态。

接下来进入NLB的listener界面，可以看到NLB将来自80端口的流量转发到了k8s-default-servicen这个target group。点击进入Target Group，可以看到当前两个node的状态是initial，等待其健康检查完成，变成healthy状态，即可访问。

查看运行中的Service，执行如下命令。

```
kubectl get service service-nginx -o wide 
```

返回结果如下。其中的ELB域名地址就是对外访问入口。其中的CLUSTER-IP即可看到是创建集群时候指定的IP范围。

```
NAME            TYPE           CLUSTER-IP    EXTERNAL-IP                                                                          PORT(S)        AGE     SELECTOR
service-nginx   LoadBalancer   10.50.0.119   aaa836fe8800b4b1db39802cc604d650-7b3437ed776ea80d.elb.ap-southeast-1.amazonaws.com   80:32253/TCP   2m39s   app=nginx
```

用浏览器访问ELB地址，即可验证应用启动结果。

### 3、测试从命令行访问（可选）

也可以在命令行上通过curl命令访问。

#### Linux和MacOS操作系统如下命令是通过命令行访问：

在Linux的bash/sh/zsh上执行如下脚本，可获取NLB地址并通过curl访问：

```
NLB=$(kubectl get service service-nginx -o json | jq -r '.status.loadBalancer.ingress[].hostname')
echo $NLB
curl -m3 -v $NLB
```

#### Windows操作系统如下命令是通过命令行访问：

获取NLB地址：

```
kubectl get service service-nginx -o json | jq -r .status.loadBalancer.ingress[].hostname
```

通过CURL验证访问：

```
curl -m3 -v 上文获取到的NLB入口地址
```

由此即可访问到测试应用，看到 Welcome to nginx! 即表示访问成功。 

### 4、删除服务（可选）

执行如下命令：

```
kubectl delete -f nginx-nlb.yaml
```

至此服务删除完成。

## 七、参考文档

K8S的Dashboard安装：

[https://kubernetes.io/docs/tasks/access-application-cluster/web-ui-dashboard/]()