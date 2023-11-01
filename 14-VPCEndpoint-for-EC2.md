# 在没有外部网络权限的内部子网使用EKS服务时需要额外配置的VPC Endpoint

## 一、背景

在使用EKS服务时候，EKS集群的Node节点需要连接EC2、ECR、ELB等若干AWS服务，进行Node节点创建、镜像管理等操作，而这一步是依赖外网访问权限的。

在没有外部网络权限的内部子网使用EKS服务时，因为没有外网权限，无法连接到AWS位于互联网上的服务节点，因此会遇到错误，导致节点不能正常拉起。此时，需要额外配置的VPC Endpoint。需要额外配置的包括EC2、ECR、S3、ELB、CloudWatch、STS等（X-ray根据实际情况配置）。需要配置的清单参考本文默认的官方文档。

在配置好VPC Endpoint后，位于内网的节点、服务、代码就可以通过显式声明，即添加`--endpoint-url https://xxxx/`的形式来访问以上服务。但是，EKS相关系统服务是自动触发调用的，不是用户手工开发的代码，因此无法显式添加`--endpoint-url https://xxxx/`的参数。这时候，可以使用Route 53 Private Zone为本VPC提供特殊的解析，将原先的Endpoint域名默认解析到公网，通过CNAME的方式解析到VPC内网新创建的这几个Endpoint上，即可让相关服务无缝调用。对于修改了EC2默认DNS，即没有使用AWS VPC的DNS而是自建DNS Server的场景，也可适用。

本文以配置EC2为例讲解VPC Endpoint和Route 53 Private Zone配置，其他服务流程相同。

为保证操作精准，以英文菜单为例进行交互。在界面中点击齿轮按钮，可以切换AWS Console的语言。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/endpoint/pe-00.png)

## 二、配置VPC Endpoint

### 1、创建VPC Endpoint

VPC Endpoint是区域（Regional）级别的服务，因此必须准确选择区域。例如服务部署在新加坡区域，后续所有操作都是新加坡区域，界面上会显示代号`ap-southeast-1`，注意查看。

进入VPC服务界面，从左侧菜单中点击`Endpoint`，点击右上角的`Create endpoint`。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/endpoint/pe-01.png)

在名称位置输入`ec2`,在服务类型位置选择`AWS Service`，在查找框中输入关键字`ec2`，然后选中第一项`com.amazonaws.ap-southeast-1.ec2`。注意这里一定要精确选择，搜索会出现名称相似的，包括带有后缀的，这里一定看自己选择。继续向下滚动页面。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/endpoint/pe-02.png)

选择服务完毕后，选择VPC，有多个VPC时候注意选择正确的VPC。接下来选中可用区。如果VPC是两个子网的，那么这里就选两个子网。如果VPC是三个子网的，那么这里就选三个可用。每个可用区后边的Subnet，选择私有子网。可以选择是EKS Node节点EC2所在的纯内部子网。继续向下滚动页面。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/endpoint/pe-03.png)

接下来继续配置。在IP地址类型位置默认选择`IPv4`，在安全规则组位置，需要给Endpoint选择一个安全组。这里如果没有事先创建好合适的安全组，可去创建一个新的安全组，名字叫VPCEndpoint，放行范围是允许来自本VPC的CIDR范围（一般不要写`0.0.0.0/0`）的地址授权允许入站访问443端口。然后在安全组这一步，绑定安全组。页面再下方的Policy位置，选择默认的`Full access`。继续向下滚动页面。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/endpoint/pe-04.png)

最后在界面右下角，点击创建`Create`按钮，完成VPC Endpoint的创建。

创建需要3-5分钟，请等待界面上变成绿色的可用。

![](https://blogimg.bitipcman.com/workshop/eks101/endpoint/pe-05.png)

### 2、查看VPC Endpoint

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

在最右侧，还有一个域名`ec2.ap-southeast-1.amazonaws.com`，这个域名下一步是要添加Route 53 Private Zone私有解析，或者使用自建DNS来解析的域名。本文下一章节会描述如何配置。

接下来还可以查看这些Endpoint域名背后的IP地址。在刚才的VPC Endpoint界面，点击第二个标签页子网`Subnets`，即可看到这些信息。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/endpoint/pe-07.png)

出于自动管理和高可用角度，不建议在代码中hardcode写入IP地址，建议代码和系统调用还是用AWS自动生成的域名。

### 3、测试VPC Endpoint工作正常

根据本文上一步，我们选择VPC全局可用的入口的域名（多AZ的别名），然后将其放到AWSCLI脚本中，显式声明通过这个入口来调用，测试是否正常。

登录到位于内网的EKS节点上，使用AWSCLI（事先配置好AKSK），构建如下命令来查询当前Region的EC2清单：

```shell
aws ec2 describe-instances --endpoint-url https://vpce-03f7e3e94e933f477-jzzbvb9s.ec2.ap-southeast-1.vpce.amazonaws.com/
```

这里即可看到访问成功。

![](https://blogimg.bitipcman.com/workshop/eks101/endpoint/pe-08.png)

如果本EC2所在是纯内部网络，没有外网出口路由，也没有显示指定Endpoint，那么这个命令是会报错的，提示无法连接到EC2服务。

验证VPC Endpoint工作正常后，接下来配置解析。

## 三、使用Route 53 Private Zone提供私有解析

待更新。

## 四、其他EKS需要的Endpoint

待更新。

## 五、参考文档

Private cluster requirements

[https://docs.aws.amazon.com/eks/latest/userguide/private-clusters.html]()