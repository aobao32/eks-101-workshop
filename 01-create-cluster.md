# 实验一、创建EKS集群

EKS 1.36版本 @2026 AWS Global区域测试通过

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
curl -O https://s3.us-west-2.amazonaws.com/amazon-eks/1.36.2/2026-07-05/bin/linux/amd64/kubectl
chmod 755 kubectl
sudo mv kubectl /bin
eksctl version
```

使用Graviton处理器的ARM架构的Linux执行如下命令：

```
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_arm64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /bin
curl -O https://s3.us-west-2.amazonaws.com/amazon-eks/1.36.2/2026-07-05/bin/linux/arm64/kubectl
chmod 755 kubectl
sudo mv kubectl /bin
eksctl version
```

安装完毕后即可看到eksctl版本，同时kubectl也下载完毕。

注意：上述kubectl下载路径中的补丁版本号与日期会随EKS版本的迭代而持续更新，读者应以AWS官方安装文档所列出的实际补丁版本与日期为准进行替换，以免因路径不存在而导致下载失败。

[AWS官方kubectl安装文档](https://docs.aws.amazon.com/eks/latest/userguide/install-kubectl.html)

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

注意：本文下述两个配置文件均已适配EKS 1.36版本，`metadata.version`字段设置为`"1.36"`。同时`iam.withAddonPolicies`代码块中已移除`albIngress: true`一行。原因在于`albIngress`参数在新版本中已被废弃，其功能由`awsLoadBalancerController`取代，二者语义重叠，若继续保留`albIngress`会导致配置冗余或校验告警，因此仅保留`awsLoadBalancerController: true`。

注意：EKS 1.36默认启用了StrictIPCIDRValidation（严格IP与CIDR校验）机制，IP地址与CIDR不再接受带前导零的非规范写法（例如`010.000.000.005`），也不再接受主机位非零的非规范CIDR（例如`192.168.0.5/24`应改写为规范形式`192.168.0.0/24`）。本文配置中的`serviceIPv4CIDR: 10.50.0.0/24`已是规范写法，可以直接保留。读者在自定义Service网段或其他CIDR参数时，必须使用规范的CIDR写法，否则集群创建会因校验失败而中止。

注意：gitRepo卷类型在EKS 1.36中被永久移除，kubelet将拒绝运行挂载了该卷类型的Pod。若既有工作负载依赖gitRepo卷从Git仓库拉取内容，需迁移到init container在启动阶段克隆仓库，或采用git-sync sidecar容器持续同步的方式替代。

备注：cgroup v1的退役分为两个阶段。自EKS 1.35起，cgroup v1进入弃用阶段，kubelet默认拒绝在仍使用cgroup v1的节点上启动；至EKS 1.36正式移除对cgroup v1的支持。与此同时，容器运行时containerd推荐升级到2.0版本以获得完整的cgroup v2支持。本文所使用的节点默认基于AL2023镜像，其默认已启用cgroup v2，因此通常不受该变更影响。

### 1、创建全新VPC

执行如下命令。注意如果是多人在同一个账号内实验，需要更改EKS集群的名字避免冲突。如果多人在不同账号内做实验，无需修改名称，默认的名称即可。

编辑配置文件`newvpc.yaml`，内容如下：

```
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
  version: "1.36"

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
ip-192-168-0-22.ap-southeast-1.compute.internal     Ready    <none>   8m12s   v1.36.3-eks-cb19647
ip-192-168-42-0.ap-southeast-1.compute.internal     Ready    <none>   8m14s   v1.36.3-eks-cb19647
ip-192-168-93-206.ap-southeast-1.compute.internal   Ready    <none>   8m17s   v1.36.3-eks-cb19647
```

上述VERSION列中的补丁版本号会随EKS版本迭代而变化，读者以实际返回值为准。

注意：在`eksctl`已经输出集群创建完成之后的数分钟内，部分节点可能出现`NotReady`状态，此时执行`kubectl describe node`可以看到节点状态为`Ready=False`，原因是`KubeletNotReady`，消息内容为`node is shutting down`。这属于AL2023镜像节点在首次引导阶段的一次性重启，通过`kubectl get events`可以观察到对应的`Rebooted`事件与变更后的boot id，而在EC2控制台上可以确认实例始终处于`running`状态且未被替换。该现象通常在2至3分钟内自动恢复，无需人工干预，也不需要重建节点组。同时`kube-system`命名空间内会残留若干`Completed`状态的CoreDNS与metrics-server旧副本，属于该重启周期的产物，可以忽略。

关于上述现象，实测中还有两点需要补充。第一点是该现象的出现时间并不固定，可能延后到集群创建完成之后的4至8分钟才发生，因此在`eksctl`执行结束时立即检查得到全部节点`Ready`的结果，并不代表已经规避，建议在部署业务负载前再复查一次节点状态。第二点是除`Rebooted`事件之外，还会伴随出现`NodeShutdown`类型的告警事件，其消息内容为`Pod was rejected as the node is shutting down`，表示该节点在重启窗口内拒绝了新Pod的调度。执行如下命令可以集中查看这两类事件：

```
kubectl get events -A --sort-by=.lastTimestamp | grep -iE "reboot|shutting"
```

若节点重启发生在已经部署工作负载之后，受影响节点上的Pod会被重建，原Pod则以`Completed`状态残留。由于本文第五章的端口转发指向的是Service而非具体Pod，Headlamp在其Pod被重建后仍可通过原有转发继续访问，无需重新执行`port-forward`命令。

## 五、创建集群并配置Headlamp图形界面（本章节可选）

本章节可跳过不影响后续实验。

注意：本章节在EKS 1.36版本的更新中由Kubernetes Dashboard整体替换为Headlamp。原因是Kubernetes Dashboard项目已于2026年1月21日归档，仓库迁移至`kubernetes-retired/dashboard`并转为只读，其GitHub Pages所承载的Helm仓库随之下线，继续执行原先的`helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/`会返回`404 Not Found`错误。归档后的Dashboard虽然在既有集群中仍可运行，但不再接收安全补丁、缺陷修复与功能更新，因此不应继续用于生产环境。Kubernetes官方在归档说明中指定的继任者是Headlamp。

Headlamp目前托管在`kubernetes-sigs`组织下，由Kubernetes SIG UI维护，采用Apache 2.0许可，同时是CNCF Sandbox项目，其容器镜像发布在ghcr.io。相比原Dashboard，Headlamp在能力上的差异如下表所示。

|对比|Kubernetes Dashboard（已归档）|Headlamp|
|---|---|---|
|维护状态|不再提供安全更新|由SIG UI持续维护|
|部署形态|仅支持集群内部署，依赖Kong网关的多容器架构|支持集群内部署，也可作为桌面应用本地运行|
|集群范围|单集群|多集群，可在同一界面内切换|
|认证方式|仅ServiceAccount Token|ServiceAccount、kubeconfig、OIDC|
|扩展性|无插件机制|提供插件系统，可为CRD定制视图|
|权限模型|遵循RBAC|遵循RBAC，且界面控件按用户权限动态收敛|

需要区分的是，AWS控制台中另有一项名为Amazon EKS Dashboard的原生功能，其定位是跨账号与跨区域聚合集群清单、Kubernetes版本分布、扩展支持状态以及Add-on版本等治理信息，仅可从AWS Organizations管理账号或EKS委派管理员账号访问，并不提供集群内Pod与Deployment层面的浏览与操作能力。该功能与本章节所部署的Headlamp是互补关系而非替代关系。

### 1、部署Headlamp控制面板

前文在安装`eksctl`命令时候，已经在MacOS和Windows上安装helm。如果还没安装，那么在MacOS上执行`brew install helm`可安装好helm，在Windows上执行`choco install kubernetes-helm`可安装好helm。Headlamp同样以Helm作为集群内部署的唯一方式。

执行如下命令添加仓库并完成部署：

```
helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/
helm upgrade --install headlamp headlamp/headlamp --create-namespace --namespace kubernetes-dashboard
```

返回结果如下：

```
Release "headlamp" does not exist. Installing it now.
NAME: headlamp
LAST DEPLOYED: Thu Sep 17 19:45:16 2026
NAMESPACE: kubernetes-dashboard
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
TEST SUITE: None
NOTES:
1. Get the application URL by running these commands:
  export POD_NAME=$(kubectl get pods --namespace kubernetes-dashboard -l "app.kubernetes.io/name=headlamp,app.kubernetes.io/instance=headlamp" -o jsonpath="{.items[0].metadata.name}")
  export CONTAINER_PORT=$(kubectl get pod --namespace kubernetes-dashboard $POD_NAME -o jsonpath="{.spec.containers[0].ports[0].containerPort}")
  echo "Visit http://127.0.0.1:8080 to use your application"
  kubectl --namespace kubernetes-dashboard port-forward $POD_NAME 8080:$CONTAINER_PORT
2. Get the token using
  kubectl create token headlamp --namespace kubernetes-dashboard
```

备注：上述命令沿用了`kubernetes-dashboard`作为命名空间名称，目的是与本文后续的清理步骤保持一致。该名称并无特殊含义，读者可自行替换为`headlamp`等其他名称，但需注意本章节后续所有命令中的命名空间参数需同步修改。

执行如下命令确认Pod已经正常启动：

```
kubectl get pods -n kubernetes-dashboard
```

返回结果如下Running表示运行正常。

```
NAME                        READY   STATUS    RESTARTS   AGE
headlamp-56bb65b857-d9zf7   1/1     Running   0          34s
```

接下来执行如下命令，将集群内的Headlamp服务转发到本机端口：

```
kubectl --namespace kubernetes-dashboard port-forward svc/headlamp 8080:80
```

注意此窗口执行之后不要关闭，因为这个命令会转发Headlamp Service的80端口到本机的8080端口。此处与原Dashboard的差异在于，原Dashboard经由Kong网关暴露HTTPS的443端口并转发到本机8443端口，而Headlamp直接暴露HTTP的80端口并转发到本机8080端口，因此后续访问地址的协议与端口都随之变化。

### 2、生成用户和Token

新开一个命令行获取Token。这里有两种方式，推荐使用第一种。

方式一是直接使用Headlamp自带的ServiceAccount。Headlamp的Helm chart在安装时已经创建了名为`headlamp`的ServiceAccount，并通过名为`headlamp-admin`的ClusterRoleBinding将其绑定到`cluster-admin`角色，因此该ServiceAccount开箱即具备完整的集群读写权限，执行如下命令即可获取可用的Token：

```
kubectl create token headlamp --namespace kubernetes-dashboard
```

方式二是自行创建ServiceAccount。此时必须同时创建ClusterRoleBinding，否则该ServiceAccount不具备任何权限。执行如下三条命令：

```
kubectl -n kubernetes-dashboard create serviceaccount admin
kubectl create clusterrolebinding admin-cluster-admin --clusterrole=cluster-admin --serviceaccount=kubernetes-dashboard:admin
kubectl -n kubernetes-dashboard create token admin
```

请不要省略中间那条创建ClusterRoleBinding的命令。Headlamp完全依据Kubernetes的RBAC进行鉴权，仅执行`create serviceaccount`而不做角色绑定时，生成的Token虽然可以通过登录校验，但登录后界面将无法列出任何集群资源。该权限状态可以通过如下命令验证：

```
kubectl auth can-i get pods -A --as=system:serviceaccount:kubernetes-dashboard:admin
```

未绑定角色时返回`no`，完成绑定后返回`yes`。

注意：`cluster-admin`是集群的最高权限角色，上述用法仅适用于本文的实验环境。生产环境中应按最小权限原则，为图形界面使用者单独定义仅包含所需资源与动词的ClusterRole，避免直接授予`cluster-admin`。

获取Token的返回结果如下：

```
eyJhbGciOiJSUzI1NiIsImtpZCI6IjVmOTNlYjFlMDUwOGFhYjE2M2Q4YzcwM2U5MjZlOTRjMzlmNDNkMDcifQ.eyJhdWQiOlsizHR0cHM6Ly9rdWJlcm5ldGVzLmRlZmF1bHQuc3ZjIl0sImV4cCI6MTcxOTkzOTUxMiwiaWF0IjoxNzE5OTM1OTEyLCJpc3MiOiJodHRwczovL29pZGMuZWtzLmFwLXNvdXRoZWFzdC0xLmFtYXpvbmF3cy5jb20vaWQvMUI0MjE1QUE3RDY1MUY1QjMyMTMwMjY0NUMyRjdERTUiLCJqdGkiOiJmNGI3N2I4Ny0wOTQ0LTQ0MjYtOGNiYy1hOWI3MmI2M2ZmZGQiLCJrdWJlcm5ldGVzLmlvIjp7Im5hbWVzcGFjZSI6Imt1YmVybmV0ZXMtZGFzaGJvYXJkIiwic2VydmljZWFjY291bnQiOnsibmFtZSI4ImFkbWluIiwidWlkIjoiY2NlNDc4YzUtMjY5ZS00MDMyLWEwYTMtOTg4MzJlNDc1YzVlIn19LCJuYmYiOjE3MTk5MzU5MTIsInN1YiI6InN5c3RlbTpzZXJ2aWNlYWNjb3VudDprdWJlcm5ldGVzLWRhc2hib2FyZDphZG1pbiJ9.LXMF3t3vaSgby4FMH9wG612EI6j__1ng-G8sdL2dqalQUyLuDBZMsD8fSDJmqrk5xIbxNi8NzVyqLsYmbM4IqukXAC1YpG3BIBQy7dv5mB04xea8ttzioSABEFeYREoycptmfvCrJ95Z5MhUy3wqMia6D8Up838P6q5iG9kSB7wd3CCcQAJXDUTWgIBVr8uhVGzEZvo72T9YsTCkwQPx30mj0lPXwBDA_HHCMNOBW-Kt26jMZFPHUFeINEFkQKSY_Fp2Xx23P05ZczkNFN0WkCcVp7zCtzEqiDz-o5pdztpNkvZD-6fTuupUUBb3HTtzjve_scz6vO-7RqS6NWh02Q
```

### 3、登陆Headlamp

在实验者的本机上访问如下地址。请注意这里是HTTP协议的8080端口，而非原Dashboard使用的HTTPS协议8443端口：

```
http://127.0.0.1:8080
```

登录页面打开后，在`Bearer token`位置输入上一步获取的token，即可访问Headlamp。如果登录成功但界面中看不到任何集群资源，说明所用Token对应的ServiceAccount缺少角色绑定，请回到上一节按方式二补全ClusterRoleBinding。

至此Headlamp配置完成。
 
### 4、删除Headlamp服务（可选）

测试完成后，如果需要删除Headlamp，执行如下命令。

```
helm uninstall headlamp -n kubernetes-dashboard
kubectl delete namespaces kubernetes-dashboard
```

本命令为可选，可保留Headlamp，在后续实验中也可以继续通过Headlamp做监控。

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

### 4、测试从命令行访问（可选）

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

### 5、删除服务（可选）

执行如下命令：

```
kubectl delete -f nginx-nlb.yaml
```

至此服务删除完成。请注意在删除整个集群之前，务必先执行本命令删除Service，以确保NLB及其自动创建的安全组被Kubernetes正常回收。若跳过此步直接删除集群，残留的ENI会导致VPC删除失败。

## 七、参考文档

Kubernetes官方博客关于从Kubernetes Dashboard迁移到Headlamp的说明：

[https://kubernetes.io/blog/2026/06/01/dashboard-to-headlamp/](https://kubernetes.io/blog/2026/06/01/dashboard-to-headlamp/)

Kubernetes官方工具参考页面中的Headlamp条目：

[https://kubernetes.io/docs/reference/tools/](https://kubernetes.io/docs/reference/tools/)

Headlamp项目仓库，位于kubernetes-sigs组织下：

[https://github.com/kubernetes-sigs/headlamp](https://github.com/kubernetes-sigs/headlamp)

已归档的Kubernetes Dashboard仓库及其继任说明：

[https://github.com/kubernetes-retired/dashboard](https://github.com/kubernetes-retired/dashboard)

AWS官方kubectl安装文档：

[https://docs.aws.amazon.com/eks/latest/userguide/install-kubectl.html](https://docs.aws.amazon.com/eks/latest/userguide/install-kubectl.html)

Amazon EKS Dashboard官方文档，用于区分同名但定位不同的AWS原生功能：

[https://docs.aws.amazon.com/eks/latest/userguide/cluster-dashboard.html](https://docs.aws.amazon.com/eks/latest/userguide/cluster-dashboard.html)