# 使用Karpenter+HPA实现平滑的集群扩展

## 一、背景

EKS的弹性有两种方式：

- 1、单个应用的Deployment的replica扩容
- 2、Node节点的扩容

对于第一种扩容，常用的方式是Horizontal Pod Autoscaler (HPA)，通过metrics server，监控CPU负载等指标，然后发起对deployment的replica的变化。此配置会调整Pod数量，但不会调整节点数量。

对于第二种扩容，之前常用的方式是Cluster Autoscaler (CA)对NodeGroup节点组的EC2进行扩容，但是其扩展生效速度较慢。本文使用新的Karpenter组件对Nodegroup进行扩容。Karpenter不需要创建新的NodeGroup，而是直接根据匹配情况自动选择On-demand或者Spot类型的实例。

本实验流程如下：

- 1、部署一个Nginx应用
- 2、手工修改replica参数，测试Karpenter对节点的扩容和Spot节点的使用
- 3、配置HPA，施加访问压力，触发HPA对应用deployment的replica自动扩容，并由Karpenter触发新的Spot节点扩容

## 二、环境准备

使用默认配置创建一个EKS集群，网络方面使用新的VPC的配置，简化实验过程。

## 三、部署Karpenter负责并使用Spot节点

### 1、安装Karpenter



### 2、部署测试应用

构建如下测试应用，保存为`demo-nginx-nlb-karpenter.yaml`文件：

```
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-nginx-nlb-karpenter
  labels:
    app: demo-nginx-nlb-karpenter
spec:
  replicas: 3
  selector:
    matchLabels:
      app: demo-nginx-nlb-karpenter
  template:
    metadata:
      labels:
        app: demo-nginx-nlb-karpenter
    spec:
      nodeSelector:
        intent: apps
      containers:
      - name: demo-nginx-nlb-karpenter
        image: public.ecr.aws/nginx/nginx:1.23-alpine
        ports:
        - containerPort: 80
        resources:
          limits:
            cpu: "1"
            memory: 2G
---
apiVersion: v1
kind: Service
metadata:
  name: "demo-nginx-nlb-karpenter"
  annotations:
        service.beta.kubernetes.io/aws-load-balancer-type: nlb
spec:
  selector:
    app: demo-nginx-nlb-karpenter
  type: LoadBalancer
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
```

执行如下命令启动这个应用：

```
kubectl apply -f demo-nginx-nlb-karpenter.yaml
```

执行如下命令查看访问入口：

```
kubectl get service
```

从返回的多条结果中，查找名为`demo-nginx-nlb-karpenter`的应用对应的ALB，例如如下：

```
NAME                       TYPE           CLUSTER-IP    EXTERNAL-IP                                                                          PORT(S)        AGE
demo-nginx-nlb-karpenter   LoadBalancer   10.50.0.58    a59b500e279d94b2880502c8782ad6dc-bf2ef05babf12887.elb.ap-southeast-1.amazonaws.com   80:31157/TCP   104s
demo-nginx-on-demand       LoadBalancer   10.50.0.35    adc375ee9dc9d4705bca9642986c3d2b-712c38519c0e4303.elb.ap-southeast-1.amazonaws.com   80:30338/TCP   83m
kubernetes                 ClusterIP      10.50.0.1     <none>                                                                               443/TCP        5d1h
php-apache                 ClusterIP      10.50.0.207   <none>                                                                               80/TCP         26h
```

使用curl或者浏览器访问NLB地址，可看到访问成功。

### 3、修改部署扩容

执行如下命令：

```
kubectl scale deployment demo-nginx-nlb-karpenter --replicas 6
```

### 4、查看集群扩容生效

在执行了上一步扩容后，立刻去查看Pod和Node，可以发现Karpenter已经对其进行了扩展。

执行如下命令可查看所有Pod：

```
kubectl get pods -A
```

执行如下命令可通过指定标签方式，查看本应用所对应的Pod：

```
kubectl get pod -l app=demo-nginx-nlb-karpenter
```

执行如下命令可查看Node：

```
kubectl get nodes
```

### 5、查看Karpenter日志（可选）

执行如下命令可查看Karpenter控制器的日子：

```
kubectl logs -f deployment/karpenter -n karpenter controller
```

执行如下命令，可查看Karpenter控制器的配置，包括日志级别等信息：

```
kubectl describe configmap config-logging -n karpenter
```

执行如下命令，可调整Karpenter日志级别：

```
kubectl patch configmap config-logging -n karpenter --patch '{"data":{"loglevel.controller":"debug"}}'
```

当执行扩容的时候，日志中包含如下一段信息，表示扩容正常：

```
2022-10-19T14:13:07.480Z	DEBUG	controller.provisioning	16 out of 375 instance types were excluded because they would breach provisioner limits	{"commit": "639756a"}
2022-10-19T14:13:07.486Z	INFO	controller.provisioning	Found 3 provisionable pod(s)	{"commit": "639756a"}
2022-10-19T14:13:07.486Z	INFO	controller.provisioning	Computed 1 new node(s) will fit 3 pod(s)	{"commit": "639756a"}
2022-10-19T14:13:07.486Z	INFO	controller.provisioning	Launching node with 3 pods requesting {"cpu":"3825m","memory":"6166575Ki","pods":"7"} from types c6g.2xlarge, t4g.2xlarge, c5a.2xlarge, c6gd.2xlarge, t3a.2xlarge and 249 other(s)	{"commit": "639756a", "provisioner": "default"}
2022-10-19T14:13:07.803Z	DEBUG	controller.provisioning.cloudprovider	Discovered ami-02b94a304b3bfa084 for query "/aws/service/eks/optimized-ami/1.23/amazon-linux-2-arm64/recommended/image_id"	{"commit": "639756a", "provisioner": "default"}
2022-10-19T14:13:07.829Z	DEBUG	controller.provisioning.cloudprovider	Discovered ami-06f260a58e539402d for query "/aws/service/eks/optimized-ami/1.23/amazon-linux-2/recommended/image_id"	{"commit": "639756a", "provisioner": "default"}
2022-10-19T14:13:07.970Z	DEBUG	controller.provisioning.cloudprovider	Created launch template, Karpenter-eksworkshop-17123065573808364729	{"commit": "639756a", "provisioner": "default"}
2022-10-19T14:13:08.185Z	DEBUG	controller.provisioning.cloudprovider	Created launch template, Karpenter-eksworkshop-3756467097324561401	{"commit": "639756a", "provisioner": "default"}
2022-10-19T14:13:10.414Z	INFO	controller.provisioning.cloudprovider	Launched instance: i-00a5ed6da4aebca0f, hostname: ip-192-168-129-22.ap-southeast-1.compute.internal, type: t4g.2xlarge, zone: ap-southeast-1a, capacityType: spot	{"commit": "639756a", "provisioner": "default"}
```

以上的信息中，可以看到，备选机型主要是`c6g.2xlarge, t4g.2xlarge, c5a.2xlarge, c6gd.2xlarge, t3a.2xlarge`等机型。最后实际在`ap-southeast-1a`以`Spot`方式生成了 `t4g.2xlarge`实例，其EC2 ID是`i-00a5ed6da4aebca0f`，主机名叫做`ip-192-168-129-22.ap-southeast-1.compute.internal`。

关于Karpenter Provsioner对机型配置的选择，请参考有关配置文件修改说明。

由此，Karpenter配置完成，工作正常。最后执行如下命令将应用搜索回到1个Pod，便于后续实验发起压力扩容。

```
kubectl scale deployment demo-nginx-nlb-karpenter --replicas 1
```

## 四、部署HPA

接下来部署HPA过程中，将继续使用上文配置Karpenter的应用作为被测试的用例。先

### 1、部署Metrics Server

执行以下命令部署metrics server。

```
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# 备选旧版本
# kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.5.0/components.yaml
```

### 2、确认Metrics Server运行正常

在前一步的部署完成后，还需要等待一段时间让服务启动。然后执行如下命令：

```
kubectl get apiservice v1beta1.metrics.k8s.io -o json | jq '.status'
```

如果返回结果如下，则表示部署完成。

```
{
  "conditions": [
    {
      "lastTransitionTime": "2022-10-18T06:52:14Z",
      "message": "all checks passed",
      "reason": "Passed",
      "status": "True",
      "type": "Available"
    }
  ]
}
```

如果没有获得以上结果，那么需要继续等待启动完成。

### 3、调低当前部署测试应用的CPU性能，以更快触发负载

执行如下命令，请替换其中的deployment名称：

```
kubectl set resources deploy demo-nginx-nlb-karpenter --requests=cpu=200m
```

### 4、配置性能监控并设置HPA弹性阈值

执行如下命令。其中`min=1`表示最小1个pod，`max=10`表示最大10个pod。同时还需要替换其中的deployment名称：

```
kubectl autoscale deployment demo-nginx-nlb-karpenter --cpu-percent=50 --min=1 --max=10
```

配置完毕后，可通过如下命令查看HPA的信息：

```
kubectl get hpa
```

### 5、施加负载



## 五、