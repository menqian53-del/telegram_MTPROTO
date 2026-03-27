# Telegram MTProto 代理 一键部署脚本

🚀 基于 Docker 的一键部署 Telegram MTProto 代理，支持自动安装 Docker、防火墙配置、密钥生成。

## 快速使用

```bash
# 一键部署
sudo bash mtproto-proxy-setup.sh

# 查看连接信息
sudo bash mtproto-proxy-setup.sh --info

# 重新生成密钥
sudo bash mtproto-proxy-setup.sh --reconfig

# 完全卸载
sudo bash mtproto-proxy-setup.sh --uninstall
```

## 适用系统

- Ubuntu 18.04+
- Debian 10+
- CentOS 7+

## 功能特性

- ✅ 自动安装 Docker 和 Docker Compose
- ✅ 自动配置防火墙（ufw / firewalld / iptables）
- ✅ OpenSSL 生成安全密钥
- ✅ 部署完成生成 Telegram 快速连接链接
- ✅ Docker Volume 数据持久化
- ✅ 健康检查 + 自动重启

## 部署完成后

脚本会输出连接链接，在 Telegram 中打开即可连接：

```
https://t.me/proxy?server=你的IP&port=端口&secret=密钥
```

## ⚠️ 注意

- 服务器需要有公网 IP
- 建议使用海外服务器（香港、日本、新加坡等）
