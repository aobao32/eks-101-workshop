# 在没有外部网络权限的内部子网使用EKS服务时需要额外配置的VPC Endpoint

本文介绍如何在没有外部网络连接的内部子网使用EKS服务。

## 一、背景

### 1、为何需要VPC Endpoint

在使用EKS服务时候，EKS集群的Node节点需要连接EC2、ECR、ELB等若干AWS服务，进行Node节点创建、镜像管理等操作，而这一步是依赖外网访问权限的。在没有外部网络权限的内部子网使用EKS服务时，因为没有外网权限，无法连接到AWS位于互联网上的服务端点，因此会遇到错误导致节点不能正常拉起。

由于内部网络不能提供对外路由，因此对这几个AWS服务的API调用需要配置VPC Endpoint来实现。在内部网络使用EKS需要配置EC2、ECR、S3、ELB、CloudWatch、STS等基础（X-ray根据实际情况配置）。

### 2、需要哪几种VPC Endpoint

需要配置的清单参考本文末尾的官方文档，这里概括其名称和如下。

|服务|创建Endpoint界面搜索的服务名称|类型|EC2使用VPC默认DNS时候<br>Endpoint是否自动解析|EC2使用自建DNS<br>是否需要配置|
|---|---|---|---|---|
|EC2|com.amazonaws.ap-southeast-1.ec2|Interface|是|是|
|ECR|com.amazonaws.ap-southeast-1.ecr.api|Interface|是|是|
|ECR|com.amazonaws.ap-southeast-1.ecr.dkr|Interface|是|是|
|ELB|com.amazonaws.ap-southeast-1.elasticloadbalancing|Interface|是|是|
|CloudWatch|com.amazonaws.ap-southeast-1.logs|Interface|是|是|
|STS|com.amazonaws.ap-southeast-1.sts|Interface|是|是|
|S3|com.amazonaws.ap-southeast-1.s3|Gateway|不需要解析|不需要解析|

### 3、VPC Endpoint的域名解析

在配置好VPC Endpoint后，位于内网的节点、服务、代码就可以通过显式声明，即添加`--endpoint-url https://xxxx/`的形式来访问以上服务。对于无法显式添加Endpoint的场景，以前需要使用Route 53 Private Zone为本VPC提供特殊的解析，将原先的Endpoint域名默认解析到公网，通过CNAME的方式解析到VPC内网新创建的这几个Endpoint上，即可让相关服务无缝调用。如今，目前VPC Endpoint已经集成了这个功能，在创建时候可以自动开启提供解析，因此无须额外创建Route 53 Private Zone了。

如果当前环境的EC2修改了默认DNS，即没有使用AWS VPC的DNS而是自建DNS Server的场景，那么还需要手工额外配置解析。

为保证操作精准，以英文菜单为例进行交互。点击界面上方区域代号边上的齿轮按钮，可以切换AWS Console的语言。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/endpoint/pe-00.png)

## 二、配置EC2服务的VPC Endpoint

类型为Interface的VPC Endpoint包括上表中的EC2、ECR、ELB、CloudWatch、STS服务。

### 1、创建VPC Endpoint

VPC Endpoint是区域（Regional）级别的服务，因此必须准确选择区域。例如服务部署在新加坡区域，后续所有操作都是新加坡区域，界面上会显示代号`ap-southeast-1`，注意查看。

进入VPC服务界面，从左侧菜单中点击`Endpoint`，点击右上角的`Create endpoint`。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/endpoint/pe-01.png)

在名称位置输入`ec2`,在服务类型位置选择`AWS Service`，在查找框中输入关键字`ec2`，然后选中第一项`com.amazonaws.ap-southeast-1.ec2`。注意这里一定要精确选择，搜索会出现名称相似的，包括带有后缀的，这里一定看仔细选择。继续向下滚动页面。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/endpoint/pe-02.png)

选择服务完毕后，选择VPC。有多个VPC时候注意选择正确的VPC。接下来选中可用区。如果VPC是两个子网的，那么这里就选两个子网。如果VPC是三个子网的，那么这里就选三个可用。每个可用区后边的Subnet下拉框，点击后可选择私有子网。推荐选择到EKS Node节点EC2所在的纯内部子网，三个AZ都是这样操作。继续向下滚动页面。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/endpoint/pe-03.png)

接下来继续配置。点击展开高级配置，确认其中的`Enable DNS name`的选项是默认选中的状态。由此本VPC内的服务访问将自动被解析到Endpoint。在IP地址类型位置默认选择`IPv4`。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/endpoint/pe-03-dns.png)

在安全规则组位置，需要给Endpoint选择一个安全组。这里如果没有事先创建好合适的安全组，可去创建一个新的安全组，名字叫VPCEndpoint，放行范围是允许来自本VPC的CIDR范围（一般不要写`0.0.0.0/0`）的地址授权允许入站访问443端口。然后在安全组这一步，绑定安全组。页面下方的Policy位置，选择默认的`Full access`。继续向下滚动页面。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/endpoint/pe-04.png)

最后在界面右下角，点击创建`Create`按钮，完成VPC Endpoint的创建。

创建需要3-5分钟，请等待界面上`Statis`状态指示变成绿色的可用。

![](https://blogimg.bitipcman.com/workshop/eks101/endpoint/pe-05.png)

### 2、查看VPC Endpoint地址

在VPC Endpoint界面，选中刚才创建的EC2 Endpoint，然后查看Detail，可看到下方有如下数个域名。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/endpoint/pe-06.png)

这些域名讲解如下：

VPC全局可用的入口的域名（多AZ的别名）：

- vpce-03f7e3e94e933f477-jzzbvb9s.ec2.ap-southeast-1.vpce.amazonaws.com

访问这个地址，即可自动解析到某个AZ的Endpoint。

单个AZ的Endpoint的入口域名（只解析到本AZ）：

- vpce-03f7e3e94e933f477-jzzbvb9s-ap-southeast-1a.ec2.ap-southeast-1.vpce.amazonaws.com
- vpce-03f7e3e94e933f477-jzzbvb9s-ap-southeast-1b.ec2.ap-southeast-1.vpce.amazonaws.com
- vpce-03f7e3e94e933f477-jzzbvb9s-ap-southeast-1c.ec2.ap-southeast-1.vpce.amazonaws.com

在以上域名中可看到其中包含`-1a`、`-1b`、`-1c`，这就表示三个AZ各自的Endpoint入口。如果上一步创建的是两个AZ，那么这里就是只有2个AZ的地址。

在最右侧，还有一个域名`ec2.ap-southeast-1.amazonaws.com`，这个域名在使用自建DNS时候要配置解析。后续章节会描述。

接下来还可以查看这些Endpoint域名背后的IP地址。在刚才的VPC Endpoint界面，点击第二个标签页子网`Subnets`，即可看到这些信息。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/endpoint/pe-07.png)

从自动管理和高可用的角度，不建议在代码中hardcode写入IP地址，建议代码和系统调用还是用AWS自动生成的域名。

### 3、显式声明VPC Endpoint地址确认工作正常（可选测试）

根据本文上一步截图中，我们选择VPC全局可用的入口的域名（多AZ的别名），然后将其放到AWSCLI脚本中，显式声明通过这个入口来调用，测试是否正常。

登录到位于内网的EKS节点上，使用AWSCLI（事先配置好AKSK），构建如下命令来查询当前Region的EC2清单：

```shell
aws ec2 describe-instances --endpoint-url https://vpce-03f7e3e94e933f477-jzzbvb9s.ec2.ap-southeast-1.vpce.amazonaws.com/
```

这里即可看到访问成功。

![](https://blogimg.bitipcman.com/workshop/eks101/endpoint/pe-08.png)

### 4、EC2使用VPC默认DNS场景 - VPC自动提供Endpoint的解析

如果按照前文步骤，创建VPC Endpoint时候打开了VPC支持，那么不需要显式声明`--endpoint-url`，就可正常工作。

执行域名查询命令，确认其解析有效。命令如下。

```shell
nslookup ec2.ap-southeast-1.amazonaws.com
```

当配置正确时候，返回3个结果如下：

```shell
[root@ip-172-31-1-79 ~]# nslookup ec2.ap-southeast-1.amazonaws.com
Server:         172.31.0.2
Address:        172.31.0.2#53

Non-authoritative answer:
Name:   ec2.ap-southeast-1.amazonaws.com
Address: 172.31.78.156
Name:   ec2.ap-southeast-1.amazonaws.com
Address: 172.31.86.228
Name:   ec2.ap-southeast-1.amazonaws.com
Address: 172.31.56.201

[root@ip-172-31-1-79 ~]#
```

以上返回的三个地址就是VPC Endpoint在本VPC内的入口域名对应的IP地址。此处与上一步查看的IP可以对照确认匹配。

这个时候执行AWSCLI对EC2服务发起查询操作刚才的命令：

```shell
aws ec2 describe-instances
```

就可以看到执行正常。此时查询已经是通过Endpoint完成的了。

### 5、EC2使用自建DNS场景

如果EC2没有使用AWS VPC内自带的DNS，而是自己搭建了DNS，那么需要自己添加解析。

- 记录名称：`ec2.ap-southeast-1.amazonaws.com`
- 记录类型：`CNAME``
- 解析值：`vpce-03f7e3e94e933f477-jzzbvb9s.ec2.ap-southeast-1.vpce.amazonaws.com`
- TTL：一般为60秒或300秒即可

配置完毕后，等待1分钟（TTL周期）生效。

登录到EC2上，通过`nslookup`命令确认其解析VPC Endpoint成功。然后再次执行`aws ec2 describe-instances`命令测试访问即可。

## 三、配置ECR、ELB、CloudWatch、STS等类型也是Interface类型的VPC Endpoint

由于ECR和ELB类型也是Interface VPC Endpoint，配置全流程不再赘述。这里只附上关键的搜索名称：

- com.amazonaws.ap-southeast-1.ecr.api
- com.amazonaws.ap-southeast-1.ecr.dkr
- com.amazonaws.ap-southeast-1.elasticloadbalancing
- com.amazonaws.ap-southeast-1.logs
- com.amazonaws.ap-southeast-1.sts

配置好后效果如下：

![](https://blogimg.bitipcman.com/workshop/eks101/endpoint/pe-21.png)

接下来配置S3的Endpoint。

## 四、配置类型为Gateway的S3 VPC Endpoint

首先确认本VPC是否有已经存在的S3 VPC Endpoint。

### 1、本VPC已经存在S3 VPC Endpoint时候的路由表配置

在创建VPC时候，创建VPC向导界面会询问是否创建类型为Gateway的S3 VPC Endpoint。当时无论是否选中，创建VPC都会成功。因此在给VPC创建S3 VPC Endpoint之前，先查询下是否有已经存在的S3 VPC Endpoint。同一个VPC，只能有一个S3 VPC Endpoint。

进入VPC Endpoint界面，搜索关键词`com.amazonaws.ap-southeast-1.s3`，如果能搜索出来，表示创建VPC时候已经创建了Endpoint。那么接下来就是将S3 VPC Endpoint绑定到所有的路由表。点击第二个标签页路由表，点击右侧的编辑按钮。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/endpoint/pe-22.png)

进入编辑界面，选中本VPC所有子网（包括有EIP的外部子网，也包括没有外部网络的内部子网）。然后点击修改路由表保存生效。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/endpoint/pe-23.png)

修改需要3-5分钟生效。

生效的最终确认方式是：点击进入到内部子网使用的路由表上，查看其中包含类似`pl-6fa54006`的条目，目标地址是`vpce-0014aadb62f662d16`。如果存在这样的条目，就表示Gateway Endpoint配置生效。如果不存在，则上一步操作完毕后，等待几分钟，就会出现这个条目。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/endpoint/pe-24.png)

### 2、本VPC没有S3 VPC Endpoint时候新建配置

进入VPC服务界面，搜索S3服务，选择类型为Gateway的Endpoint。在搜索条件位置，输入`com.amazonaws.ap-southeast-1.s3`作为搜索条件。然后在查询出来的Endpoint服务中，选择类型是`Gateway`的。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/endpoint/pe-25.png)

继续向下滚动页面。选择Endpoint要绑定的VPC。在路由表中，选择本VPC所有的路由表。注意此时右侧的一列`Associated Ids`可显示本路由表绑定了多少个子网，用于配置参考提示之用。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/endpoint/pe-26.png)

继续向下滚动页面。选择Policy是`Full access`。最后点击右下角创建按钮。

![](https://blogimg.bitipcman.com/workshop/eks101/endpoint/pe-27.png)

创建S3 VPC Endpoint需要3-5分钟生效。

### 3、验证S3 VPC Endpoint工作正常

S3 Gateway Endpoint不依赖DNS解析，它的工作方式是基于路由表。因此即便EC2使用的是自建DNS，也不需要添加解析记录。

登录到位于内网的EC2上，事先配置好AKSK密钥，然后执行S3相关命令，能正常工作就表示S3 VPC Endpoint正常。例如查询存储桶清单命令。

```
aws s3 ls
```

至此EKS工作在内部网络所需要的VPC Endpoint全部配置完毕。

## 五、参考文档

Private cluster requirements

[https://docs.aws.amazon.com/eks/latest/userguide/private-clusters.html]()