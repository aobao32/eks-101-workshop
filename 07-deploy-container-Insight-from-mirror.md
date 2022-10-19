# 解决AWS中国区的EKS部署Container Insight无法从海外拉取镜像的问题

## 一、背景

EKS的Container Insight的配置过程可参考官方[文档](https://docs.aws.amazon.com/zh_cn/AmazonCloudWatch/latest/monitoring/Container-Insights-setup-EKS-quickstart.html)。在配置过程中，分别面临github的raw文件服务器无法下载，以及Docker Hub官方的镜像仓库无法拉取的问题。

由此，可分别在中国区部署对应的资源。

## 二、获得CloudWatch Agent镜像

Cloudwatch Agent官方公开的Github代码在[这里](https://github.com/aws/amazon-cloudwatch-agent/)。Dockerfile上官方的容器仓库在[这里](https://hub.docker.com/r/amazon/cloudwatch-agent)。

由于默认的安装方法四冲DockerHub直接下载，在中国区特别是宁夏区域经常会下载失败，因此可采用如下的两种办法：

- 方法1: 从官方下载[Docker File](https://github.com/aws/amazon-cloudwatch-agent/tree/master/amazon-cloudwatch-container-insights/cloudwatch-agent-dockerfile)可以自己build容器镜像。构建完成后，再上传到用户自己的账号内的ECR镜像仓库中
- 方法2: 使用AWS ECR Public的镜像仓库。此镜像仓库地址在[这里](https://gallery.ecr.aws/cloudwatch-agent/cloudwatch-agent)。这个地址不同于DockerHub，下载速度和成功率较高。

本文选择方法2。从AWS ECR Public官方获取的地址如下：

```
public.ecr.aws/cloudwatch-agent/cloudwatch-agent:latest
```

## 三、获得FluentBit镜像

官方Github地址见[这里](https://github.com/aws/aws-for-fluent-bit)。

在配置好AWSCLI的客户端执行如下命令：

```
aws ssm get-parameters --names /aws/service/aws-for-fluent-bit/stable
```

即可获得返回结果如下。

```
{
    "Parameters": [
        {
            "Name": "/aws/service/aws-for-fluent-bit/stable",
            "Type": "String",
            "Value": "128054284489.dkr.ecr.cn-northwest-1.amazonaws.com.cn/aws-for-fluent-bit:2.21.3",
            "Version": 5,
            "LastModifiedDate": "2021-12-08T09:08:55.664000+08:00",
            "ARN": "arn:aws-cn:ssm:cn-northwest-1::parameter/aws/service/aws-for-fluent-bit/stable",
            "DataType": "text"
        }
    ],
    "InvalidParameters": []
}
(END)
```

其中可看到Value就是在中国区可用的镜像。地址如下：

```
128054284489.dkr.ecr.cn-northwest-1.amazonaws.com.cn/aws-for-fluent-bit:2.21.3
```

复制下来，后文会使用。

## 四、构建中国区使用的Yaml配置文件

使用能访问Github的域名RAW文件服务器的客户端，从如下网址获取配置文件：

```
https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/quickstart/cwagent-fluent-bit-quickstart.yaml
```

下载到本地后，用文本编辑器打开，替换其中的地址。找到CloudWatch Agent一行，原始内容如下：

```
image: amazon/cloudwatch-agent:1.247350.0b251780
```

将其替换为：

```
public.ecr.aws/cloudwatch-agent/cloudwatch-agent:latest
```

再找到fluent-bit的如下一行：

```
image: amazon/aws-for-fluent-bit:2.10.0
```

替换为如下：

```
128054284489.dkr.ecr.cn-northwest-1.amazonaws.com.cn/aws-for-fluent-bit:2.21.3
```

将替换完毕的配置文件保存到某个S3存储桶内，或者能使用Http下载访问的服务器上。记录下网址。

## 五、启动服务

这里提供一个已经修改好的配置文件，且位于可在中国区访问下载的地址上。运行如下命令启动服务。

注意替换其中的Region和集群名称。

```
ClusterName=eksworkshop
RegionName=cn-northwest-1
FluentBitHttpPort='2020'
FluentBitReadFromHead='Off'
[[ ${FluentBitReadFromHead} = 'On' ]] && FluentBitReadFromTail='Off'|| FluentBitReadFromTail='On'
[[ -z ${FluentBitHttpPort} ]] && FluentBitHttpServer='Off' || FluentBitHttpServer='On'
curl https://myworkshop.bitipcman.com/eks101/cwagent-fluent-bit-quickstart-cn.yaml | sed 's/{{cluster_name}}/'${ClusterName}'/;s/{{region_name}}/'${RegionName}'/;s/{{http_server_toggle}}/"'${FluentBitHttpServer}'"/;s/{{http_server_port}}/"'${FluentBitHttpPort}'"/;s/{{read_from_head}}/"'${FluentBitReadFromHead}'"/;s/{{read_from_tail}}/"'${FluentBitReadFromTail}'"/' | kubectl apply -f - 
```

部署完成。

进入Cloudwatch对应region界面，从左侧选择Container Insight，从右侧选择`View performance dashboards `，即可进入Container Insight。
