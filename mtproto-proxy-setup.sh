#!/bin/bash
#=============================================================================
#  Telegram MTProto 代理 一键部署脚本 (增强版 v2)
#  适用系统: Ubuntu 18.04+ / Debian 10+ / CentOS 7+
#  用法: bash mtproto-proxy-setup.sh
#  基于 nineseconds/mtg (Go 实现，兼容新版 Telegram)
#=============================================================================

set -eo pipefail

#======================= 颜色定义 =======================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

#======================= 配置变量 =======================
INSTALL_DIR="/opt/mtproto-proxy"
CONFIG_FILE="$INSTALL_DIR/config.toml"
CONNECTION_FILE="$INSTALL_DIR/connection-info.txt"
PORT_RANGE_START=1443
DOCKER_IMAGE="nineseconds/mtg:2"

#======================= 工具函数 =======================
info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${GREEN}✅${NC} $1"; }
divider() { echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请使用 root 用户运行此脚本"
        echo -e "  ${CYAN}sudo bash $0${NC}"
        exit 1
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    elif command -v lsb_release &>/dev/null; then
        OS=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
        OS_VERSION=$(lsb_release -rs)
    else
        error "无法检测操作系统类型"
        exit 1
    fi
    info "检测到系统: ${BOLD}$OS $OS_VERSION${NC}"
}

check_docker() {
    if command -v docker &>/dev/null; then
        local docker_ver
        docker_ver=$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        info "Docker 已安装: ${BOLD}v$docker_ver${NC}"
        DOCKER_INSTALLED=1
    else
        DOCKER_INSTALLED=0
        warn "Docker 未安装"
    fi

    if command -v docker-compose &>/dev/null || docker compose version &>/dev/null 2>&1; then
        info "Docker Compose 已安装"
        COMPOSE_INSTALLED=1
    else
        COMPOSE_INSTALLED=0
        warn "Docker Compose 未安装"
    fi
}

install_docker() {
    if [[ $DOCKER_INSTALLED -eq 1 ]] && [[ $COMPOSE_INSTALLED -eq 1 ]]; then
        return 0
    fi

    divider
    info "正在安装 Docker 和 Docker Compose..."
    divider

    if [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "rocky" || "$OS" == "almalinux" ]]; then
        install_docker_centos
    elif [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        install_docker_debian
    else
        error "不支持的系统: $OS，请手动安装 Docker"
        exit 1
    fi

    systemctl enable docker
    systemctl start docker

    if ! command -v docker &>/dev/null; then
        error "Docker 安装失败，请手动安装后重试"
        exit 1
    fi

    info "Docker 版本: $(docker --version)"

    if ! docker compose version &>/dev/null 2>&1; then
        warn "Docker Compose 插件未安装，正在安装独立版..."
        local compose_arch
        compose_arch=$(uname -m)
        case "$compose_arch" in
            x86_64)  compose_arch="x86_64" ;;
            aarch64) compose_arch="aarch64" ;;
            *)       compose_arch="x86_64" ;;
        esac
        mkdir -p /usr/local/lib/docker/cli-plugins
        curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${compose_arch}" \
            -o /usr/local/lib/docker/cli-plugins/docker-compose
        chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
        info "Docker Compose (standalone) 安装完成"
    fi

    success "Docker 和 Docker Compose 安装完成"
}

install_docker_centos() {
    info "使用 yum 安装 Docker (CentOS/RHEL)..."

    yum remove -y docker docker-client docker-client-latest \
        docker-common docker-latest docker-latest-logrotate \
        docker-logrotate docker-engine podman runc >/dev/null 2>&1 || true

    yum install -y -q yum-utils device-mapper-persistent-data lvm2
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo >/dev/null 2>&1

    if [[ "$OS" == "centos" && "${OS_VERSION%%.*}" -eq 7 ]]; then
        if ! grep -q "vault.centos.org" /etc/yum.repos.d/CentOS-Base.repo 2>/dev/null; then
            info "CentOS 7 已 EOL，切换到 vault 源..."
            sed -i 's|^mirrorlist=|#mirrorlist=|g' /etc/yum.repos.d/CentOS-*.repo 2>/dev/null || true
            sed -i 's|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*.repo 2>/dev/null || true
        fi
        info "CentOS 7 安装 Docker 20.10.x（兼容版本）..."
        yum install -y -q docker-ce-20.10.* docker-ce-cli-20.10.* containerd.io
    else
        yum install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi

    success "Docker 安装完成"
}

install_docker_debian() {
    info "使用 apt 安装 Docker (Ubuntu/Debian)..."

    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
        apt-get remove -y "$pkg" >/dev/null 2>&1 || true
    done

    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg lsb-release

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$OS/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    success "Docker 安装完成"
}

get_server_ip() {
    local ip
    ip=$(curl -s4 --max-time 5 ip.sb 2>/dev/null) || \
    ip=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null) || \
    ip=$(curl -s4 --max-time 5 ipinfo.io/ip 2>/dev/null) || \
    ip=$(curl -s4 --max-time 5 icanhazip.com 2>/dev/null) || \
    ip="YOUR_SERVER_IP"

    if [[ "$ip" == "YOUR_SERVER_IP" ]]; then
        warn "无法自动获取公网 IP，请手动输入"
        read -rp "请输入服务器公网 IP: " ip < /dev/tty 2>/dev/null || true
    fi
    echo "$ip"
}

configure_firewall() {
    divider
    info "配置防火墙规则..."
    divider

    local port=$1

    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw allow "$port/tcp" >/dev/null 2>&1
        info "UFW: 已放行端口 $port"
    fi

    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="$port/tcp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        info "firewalld: 已放行端口 $port"
    fi

    if command -v iptables &>/dev/null; then
        iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || \
        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
        info "iptables: 已放行端口 $port"
    fi

    success "防火墙配置完成"
}

deploy_proxy() {
    divider
    echo -e "${CYAN}${BOLD}       🚀 部署 Telegram MTProto 代理${NC}"
    divider

    # 获取端口
    local port="${MTG_PORT:-$PORT_RANGE_START}"
    if [[ -t 0 ]]; then
        read -rp "请设置代理端口 (默认 $port): " input_port
        port=${input_port:-$port}
    else
        info "使用默认端口: $port"
    fi

    # 获取服务器 IP
    local server_ip
    server_ip=$(get_server_ip)
    info "服务器 IP: ${BOLD}$server_ip${NC}"

    # 创建安装目录
    mkdir -p "$INSTALL_DIR"

    # ========== 拉取镜像 ==========
    divider
    info "正在拉取镜像 ${DOCKER_IMAGE}..."
    divider

    if ! docker pull "$DOCKER_IMAGE" 2>&1; then
        error "镜像拉取失败，请检查网络或手动执行: docker pull $DOCKER_IMAGE"
        exit 1
    fi
    success "镜像拉取完成"

    # ========== 生成密钥 ==========
    info "正在生成代理密钥..."
    local secret
    secret=$(docker run --rm "$DOCKER_IMAGE" generate-secret --hex www.google.com 2>/dev/null) || true

    if [[ -z "$secret" ]]; then
        warn "容器生成密钥失败，使用 openssl 兜底..."
        local random_b64
        random_b64=$(openssl rand -base64 24 | tr '+/' '-_' | tr -d '=')
        secret="ee${random_b64}$(printf '%s' 'www.google.com' | base64 | tr '+/' '-_' | tr -d '=')"
    fi

    info "已生成密钥: ${secret:0:8}...${secret: -8}"

    # ========== 生成配置文件 ==========
    cat > "$CONFIG_FILE" <<EOF
secret = "${secret}"
bind-to = "0.0.0.0:${port}"
EOF

    chmod 600 "$CONFIG_FILE"

    # 配置防火墙
    configure_firewall "$port"

    # ========== 启动代理 ==========
    divider
    info "正在启动代理..."
    divider

    # 停掉可能存在的旧容器
    docker stop mtproto-proxy 2>/dev/null || true
    docker rm mtproto-proxy 2>/dev/null || true

    docker run -d \
        --name mtproto-proxy \
        --restart unless-stopped \
        -p "${port}:${port}" \
        -v "$CONFIG_FILE":/config.toml:ro \
        "$DOCKER_IMAGE"

    # 等待容器启动
    echo -n "等待代理启动"
    for i in $(seq 1 20); do
        if docker ps --filter "name=mtproto-proxy" --filter "status=running" -q | grep -q .; then
            break
        fi
        echo -n "."
        sleep 1
    done
    echo ""

    if ! docker ps --filter "name=mtproto-proxy" --filter "status=running" -q | grep -q .; then
        error "代理启动失败，请检查日志:"
        docker logs mtproto-proxy 2>&1 | tail -30
        exit 1
    fi

    success "代理启动成功"

    # ========== 显示结果 ==========
    local tg_link="tg://proxy?server=${server_ip}&port=${port}&secret=${secret}"

    divider
    echo -e "${GREEN}${BOLD}       ✅ MTProto 代理部署成功！${NC}"
    divider
    echo ""
    echo -e "${CYAN}📋 代理连接信息:${NC}"
    echo ""
    echo -e "  ${BOLD}服务器地址:${NC}  ${GREEN}$server_ip${NC}"
    echo -e "  ${BOLD}端口:${NC}        ${GREEN}$port${NC}"
    echo -e "  ${BOLD}密钥 (Secret):${NC}${GREEN}$secret${NC}"
    echo ""
    echo -e "${CYAN}📱 客户端配置:${NC}"
    echo ""
    echo -e "  ${YELLOW}方式一: Telegram 内置代理（推荐）${NC}"
    echo -e "  1. 打开 Telegram 设置 → 数据和存储 → 代理设置"
    echo -e "  2. 点击「添加代理」"
    echo -e "  3. 选择「MTProto 代理」"
    echo -e "  4. 填入以下信息:"
    echo -e "     服务器: ${GREEN}${server_ip}${NC}"
    echo -e "     端口:   ${GREEN}${port}${NC}"
    echo -e "     密钥:   ${GREEN}${secret}${NC}"
    echo ""
    echo -e "  ${YELLOW}方式二: 快速链接${NC}"
    echo -e "  在 Telegram 中发送此消息并点击: ${CYAN}${tg_link}${NC}"
    echo ""
    divider
    echo -e "${YELLOW}💡 常用管理命令:${NC}"
    echo -e "  查看状态:  ${CYAN}docker ps -f name=mtproto-proxy${NC}"
    echo -e "  查看日志:  ${CYAN}docker logs -f mtproto-proxy${NC}"
    echo -e "  停止代理:  ${CYAN}docker stop mtproto-proxy${NC}"
    echo -e "  启动代理:  ${CYAN}docker start mtproto-proxy${NC}"
    echo -e "  重启代理:  ${CYAN}docker restart mtproto-proxy${NC}"
    echo -e "  卸载代理:  ${CYAN}bash $0 --uninstall${NC}"
    echo -e "  查看信息:  ${CYAN}bash $0 --info${NC}"
    divider

    # 保存连接信息
    cat > "$CONNECTION_FILE" <<EOF
==========================================
  Telegram MTProto 代理连接信息
==========================================
服务器: $server_ip
端口:   $port
密钥:   $secret

快速连接:
$tg_link

生成时间: $(date '+%Y-%m-%d %H:%M:%S')
==========================================
EOF
    success "连接信息已保存到 $CONNECTION_FILE"
}

show_info() {
    if [[ ! -f "$CONNECTION_FILE" ]]; then
        error "未找到代理配置信息，请先部署"
        exit 1
    fi
    cat "$CONNECTION_FILE"
}

uninstall_proxy() {
    divider
    warn "即将卸载 MTProto 代理..."
    divider
    read -rp "确认卸载？(y/N): " confirm < /dev/tty 2>/dev/null || confirm="y"
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        info "已取消卸载"
        exit 0
    fi

    docker stop mtproto-proxy 2>/dev/null || true
    docker rm mtproto-proxy 2>/dev/null || true
    rm -rf "$INSTALL_DIR"

    success "MTProto 代理已完全卸载"
}

show_help() {
    echo ""
    divider
    echo -e "${CYAN}${BOLD}  Telegram MTProto 代理 一键部署脚本 (增强版 v2)${NC}"
    divider
    echo ""
    echo -e "  ${BOLD}用法:${NC} bash $0 [选项]"
    echo ""
    echo -e "  ${BOLD}选项:${NC}"
    echo -e "    (无参数)      一键部署 MTProto 代理"
    echo -e "    --info        查看代理连接信息"
    echo -e "    --uninstall   卸载 MTProto 代理"
    echo -e "    --help        显示帮助信息"
    echo ""
    echo -e "  ${BOLD}环境变量:${NC}"
    echo -e "    MTG_PORT=端口号    自定义代理端口 (默认 1443)"
    echo ""
    divider
}

#======================= 主流程 =======================
main() {
    case "${1:-}" in
        --info)
            show_info
            exit 0
            ;;
        --uninstall)
            check_root
            uninstall_proxy
            exit 0
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        "")
            ;;
        *)
            error "未知选项: $1"
            show_help
            exit 1
            ;;
    esac

    clear
    echo ""
    divider
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║   Telegram MTProto 代理 一键部署     ║"
    echo "  ║   nineseconds/mtg · 兼容新版 TG     ║"
    echo "  ╚══════════════════════════════════════╝"
    echo -e "${NC}"
    divider
    echo ""

    check_root
    detect_os
    check_docker
    install_docker
    deploy_proxy
}

main "$@"
