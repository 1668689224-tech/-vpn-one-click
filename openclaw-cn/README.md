# OpenClaw 中文社区安装脚本（自存镜像）

- 原出处：https://clawd.org.cn/install.sh （OpenClaw 中文社区）
- 镜像日期：2026-10-28
- 原文件 SHA256：4c7c90df10266618bc03e11b38275f91f41df6bd2797698486faef68afd93d70
- 本镜像仅把脚本内的自引用地址由 clawd.org.cn 改为本仓库 raw 地址，其余内容与原版一致；脚本安装的仍是 npm 包 `openclaw-cn`（走 npm 源）。

## 一键安装（走自己的仓库）

```bash
curl -fsSL https://raw.githubusercontent.com/1668689224-tech/-vpn-one-click/main/openclaw-cn/install.sh | bash -s -- --registry https://registry.npmmirror.com
```
