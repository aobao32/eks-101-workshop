# 复制ECR上的镜像并指定新的Tag标签

## 一、背景

ECR上的镜像仓库有个选项叫做`Tag immutability`，可以要求指定唯一的标签，以避免版本冲突。有时候需要对当前镜像新生成一个新的标签做测试，且生成新的标签的过程不希望下载、构建、打包、上传等过程，只是希望复制一份，重新生成一个标签。此时可以用本文的方法操作。

## 二、操作步骤

### 1、获取当前ECR上镜像和标签

登录到AWS控制台，查看当前的标签。如下截图。

![](https://blogimg.bitipcman.com/workshop/eks101/ecr-new-tag/t-01.png)

获得的ECR仓库名称和版本号如下：

```
133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/phpdemo:20230823V1
```

接下来我们要将其标签复制为新的版本`20230823V2`。

### 2、在脚本运行环境安装AWSCLI工具并登录到EC2

请从官网[这里](https://aws.amazon.com/cn/cli/)下载AWSCLI工具。

安装完毕后参考[这篇](https://blog.bitipcman.com/aws-iam-new-interface-create-access-key/)文章获取AKSK和对应的Region。

### 3、登录到ECR服务

使用AWSCLI配置的AKSK密钥登录到AWS ECR容器镜像仓库服务，执行入下命令。请替换其中的容器服务地址中的AWS账号（12位数字）和Region为对应的区域。

```
aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com
```

返回`Login Succeeded`表示登录成功。

### 4、生成现有镜像的manifest文件

注意，执行此步骤的前提是完成了AWSCLI的认证，否则这里会报告`no basic auth credentials`没有权限。

执行如下命令，请替换容器镜像仓库地址和版本为本文第一步获取的旧的标签。

```
docker manifest inspect 133129065110.dkr.ecr.ap-southeast-1.amazonaws.com/phpdemo:20230823V1 > manifest.json
```

由此在本机上获得了manifest文件。

### 5、调用ECR的API生成新的标签

执行如下命令创建新的标签。请替换仓库名为ECR上的仓库名（本例为phpdemo），请替换版本为新的版本，并指定上一步生成的`manifest.json`所在的路径（本例就在当前目录）。

```
aws ecr put-image \
    --repository-name phpdemo \
    --image-tag 20230823V2 \
    --image-manifest file://manifest.json
```

新标签上传成功，返回如下结果：

```

    "image": {
        "registryId": "133129065110",
        "repositoryName": "phpdemo",
        "imageId": {
            "imageDigest": "sha256:93f8dc91bc094de30359209c1bdeaefef336691f48015b40abae12b25986d26b",
            "imageTag": "20230823V2"
        },
        "imageManifest": "{\n\t\"schemaVersion\": 2,\n\t\"mediaType\": \"application/vnd.docker.distribution.manifest.v2+json\",\n\t\"config\": {\n\t\t\"mediaType\": \"application/vnd.docker.container.image.v1+json\",\n\t\t\"size\": 3968,\n\t\t\"digest\": \"sha256:68478d6ddf95a11ce7c217acae552046b85f007795e2d16c2d0f09ae4b7a46d8\"\n\t},\n\t\"layers\": [\n\t\t{\n\t\t\t\"mediaType\": \"application/vnd.docker.image.rootfs.diff.tar.gzip\",\n\t\t\t\"size\": 64129772,\n\t\t\t\"digest\": \"sha256:322949bc3f462f25edd57d234e2687af2a359a973c83b2d139df37b10dda65be\"\n\t\t},\n\t\t{\n\t\t\t\"mediaType\": \"application/vnd.docker.image.rootfs.diff.tar.gzip\",\n\t\t\t\"size\": 149852141,\n\t\t\t\"digest\": \"sha256:f0f27e5a3108c81e40c6e446023edb411c1ec5cbe5ebb1cfd3cb1d1ff1a0643a\"\n\t\t},\n\t\t{\n\t\t\t\"mediaType\": \"application/vnd.docker.image.rootfs.diff.tar.gzip\",\n\t\t\t\"size\": 4861,\n\t\t\t\"digest\": \"sha256:7b44be6eb9ecdf142d533d79d168712f1efa04e40e6f286f09499dbbe13d2c2a\"\n\t\t},\n\t\t{\n\t\t\t\"mediaType\": \"application/vnd.docker.image.rootfs.diff.tar.gzip\",\n\t\t\t\"size\": 215,\n\t\t\t\"digest\": \"sha256:7a2a3387c4572060617660964d7af033b8a56f8d5fd1509951dbaa0eaa03d36f\"\n\t\t},\n\t\t{\n\t\t\t\"mediaType\": \"application/vnd.docker.image.rootfs.diff.tar.gzip\",\n\t\t\t\"size\": 279,\n\t\t\t\"digest\": \"sha256:6dca416adca342fd508bff891e98337b45aecaa1b077eb5b6a3f088cc8eb0e85\"\n\t\t},\n\t\t{\n\t\t\t\"mediaType\": \"application/vnd.docker.image.rootfs.diff.tar.gzip\",\n\t\t\t\"size\": 311,\n\t\t\t\"digest\": \"sha256:63aa093aeafbfe5364bfd718697a240ab525ac695351c822985685bfead13b2f\"\n\t\t},\n\t\t{\n\t\t\t\"mediaType\": \"application/vnd.docker.image.rootfs.diff.tar.gzip\",\n\t\t\t\"size\": 214,\n\t\t\t\"digest\": \"sha256:a24c3091e38d289ae6b5cb8d88262267c8f394c005047cfa64f0d51e7e536466\"\n\t\t}\n\t]\n}\n\n",
        "imageManifestMediaType": "application/vnd.docker.distribution.manifest.v2+json"
    }
}
```

### 6、在AWS控制台上查看结果

通过ECR界面，可以看到新的镜像已经复制好了，其标签是手工指定的，大小与之前的完全一样。整个操作过程不需要下载、上传镜像，只是在云端的版本变化操作。

![](https://blogimg.bitipcman.com/workshop/eks101/ecr-new-tag/t-02.png)


至此创建标签完成。

## 三、参考文档

Inspect a manifest list

[https://docs.docker.com/engine/reference/commandline/manifest/]()

Creates or updates the image manifest and tags associated with an image.

[https://docs.aws.amazon.com/cli/latest/reference/ecr/put-image.html]()