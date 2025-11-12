# Killer 最轻量的Agent

**注意：当前只兼容MacOS，其它系统还在兼容中...**

大道至简，有时候Agent就是那么简单

智谱编程套餐，20元/月，可爽用

直达链接：https://www.bigmodel.cn/claude-code?ic=QCAXERIWNF

你也可以选择使用支持OpenAI Chat Completions API的任意供应商模型，在配置时提供即可

## 快速安装

```shell
curl -fsSL https://raw.githubusercontent.com/cwb660/killer/main/install.sh | bash
```

## 直接开整

首次启动跟随指引配置你的API Key，如果使用编程套餐只提供这个即可，其它回车

```shell
killer "帮我评估一下系统状况生成一份报告文件给我"
```

## 高级用法

克隆仓库，然后定制它

### 定制你的tool

打开任意一个AI IDE或插件，直接对着tools目录创建你想要的工具，当然，你也可以让killer自己造给你

### 定制你的prompt

打开prompts目录，创建你想要的prompt，然后直接用，就像下面这样

```shell
killer [prompt-name] [query]
```
