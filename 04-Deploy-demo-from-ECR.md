# 实验四、使用ECR上镜像和ALB Ingress部署应用

## 一、确认ECR上镜像URI

进入ECR界面，新建一个镜像仓库名为phpdemo，并复制其URI地址是：

```
461072029761.dkr.ecr.ap-southeast-1.amazonaws.com/phpdemo
```

注意，不同region的名称不一样，以及最后要包含tag版本号。

将本地名为phpdocker的image的最新版本打上tag，ECR上版本号定为1。

```
docker tag phpdocker:latest 420029960748.dkr.ecr.cn-northwest-1.amazonaws.com.cn/phpdocker:1
```

将Image版本号为1的镜像push到ECR上：

```
docker push 420029960748.dkr.ecr.cn-northwest-1.amazonaws.com.cn/phpdocker:1
```

发布完成。

## 二、编写yaml文件

格式如下。注意替换里边的region名称。

```
---
apiVersion: v1
kind: Namespace
metadata:
  name: mydemo
---
apiVersion: apps/v1
kind: Deployment
metadata:
  namespace: mydemo
  name: phpdocker
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: phpdocker
  replicas: 3
  template:
    metadata:
      labels:
        app.kubernetes.io/name: phpdocker
    spec:
      containers:
      - image: 461072029761.dkr.ecr.ap-southeast-1.amazonaws.com/phpdemo:1
        imagePullPolicy: Always
        name: phpdocker
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  namespace: mydemo
  name: phpdocker
spec:
  ports:
    - port: 80
      targetPort: 80
      protocol: TCP
  type: NodePort
  selector:
    app.kubernetes.io/name: phpdocker
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  namespace: mydemo
  name: ingress-phpdocker
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
spec:
  rules:
    - http:
        paths:
        - path: /
          pathType: Prefix
          backend:
            service:
              name: phpdocker
              port:
                number: 80
```

请替换以上yaml文件中，namespace、deployment、image、service、alb ingress等可替换为自己的标识。

将以上文件保存为phpdocker.yaml，然后从本地启动部署。

## 三、启动环境

执行如下命令：

```
kubectl apply -f phpdocker.yaml
```

## 四、访问环境

执行如下命令检查pod运行状态：

```
kubectl get pods -n mydemo
```

返回结果：

```
NAME                         READY   STATUS    RESTARTS   AGE
phpdocker-69d447587b-fxjv5   1/1     Running   0          10m
phpdocker-69d447587b-kgklt   1/1     Running   0          10m
phpdocker-69d447587b-kk6th   1/1     Running   0          10m
```

执行如下命令查看ALB Ingress入口：

```
kubectl get ingress -n mydemo
```

返回结果：

```
NAME                CLASS    HOSTS   ADDRESS                                                                     PORTS   AGE
ingress-phpdocker   <none>   *       k8s-mydemo-ingressp-d0c41bb86f-601116587.ap-southeast-1.elb.amazonaws.com   80      71s
```

使用浏览器访问上述ALB地址即可访问成功。

## 五、删除实验环境

如果从本地启动的，则执行如下命令：

```
kubectl delete -f phpdocker
```

实验完成。
