#!/bin/bash
#=============================================================================
#  Telegram MTProto 代理 一键部署脚本 (增强版)
#  适用系统: Ubuntu 18.04+ / Debian 10+ / CentOS 7+
#  用法: bash mtproto-proxy-setup.sh
#  特性: 自动安装 Docker、防火墙配置、密钥生成、健康检查
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
DOCKER_COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
CONFIG_FILE="$INSTALL_DIR/proxy-secret"
SERVICE_NAME="mtproto-proxy"
PORT_RANGE_START=1443
PORT_RANGE_END=1543

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

    # Docker Compose 兜底
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

generate_mtg_secret() {
    # 方式一：用 mtg 容器生成 dd 开头的 TLS 伪装密钥
    local secret=""
    local err_output
    
    # 先确保镜像存在
    err_output=$(docker pull 9seconds/mtg:latest 2>&1)
    if [[ $? -eq 0 ]]; then
        secret=$(docker run --rm 9seconds/mtg:latest generate-secret --tls 2>/dev/null) || true
    fi
    
    # 方式二：如果 mtg 生成失败，用 openssl 手动构造 dd 密钥
    # dd + 32字节随机hex = 正确的 mtg TLS 伪装密钥
    if [[ -z "$secret" ]]; then
        warn "mtg 密钥生成失败，使用 openssl 兜底..."
        local random_hex
        random_hex=$(openssl rand -hex 32)
        secret="dd${random_hex}"
    fi
    
    echo "$secret"
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

    local secret
    info "正在生成代理密钥..."
    secret=$(generate_mtg_secret)
    info "已生成代理密钥: ${secret:0:6}...${secret: -4}"

    local port="${MTG_PORT:-$PORT_RANGE_START}"
    if [[ -t 0 ]]; then
        read -rp "请设置代理端口 (默认 $port): " input_port
        port=${input_port:-$port}
    else
        info "使用默认端口: $port"
    fi

    local server_ip
    server_ip=$(get_server_ip)
    info "服务器 IP: ${BOLD}$server_ip${NC}"

    mkdir -p "$INSTALL_DIR"

    # ========== 9seconds/mtg: Go 实现，兼容新版 Telegram ==========
    cat > "$DOCKER_COMPOSE_FILE" <<EOF
version: '3.8'

services:
  mtproto-proxy:
    image: 9seconds/mtg:latest
    container_name: mtproto-proxy
    restart: always
    network_mode: host
    command: run ${secret} --port ${port}
    volumes:
      - proxy-data:/var/lib/mtproto-proxy
    healthcheck:
      test: ["CMD", "nc", "-z", "127.0.0.1", "${port}"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s

volumes:
  proxy-data:
    name: mtproto-proxy-data
EOF

    echo "$secret" > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    configure_firewall "$port"

    divider
    info "正在拉取镜像并启动代理..."
    divider

    # 先停掉可能存在的旧容器
    docker stop mtproto-proxy 2>/dev/null || true
    docker rm mtproto-proxy 2>/dev/null || true

    cd "$INSTALL_DIR"
    docker compose up -d

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

    # tg:// 格式的链接 (Telegram 客户端直接识别)
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
    echo -e "  在 Telegram 中发送此链接并点击: ${CYAN}${tg_link}${NC}"
    echo ""
    echo -e "  ${YELLOW}方式三: HTTPS 伪装链接${NC}"
    echo -e "  在 Telegram 中发送并点击: ${CYAN}https://t.me/proxy?server=${server_ip}&port=${port}&secret=${secret}${NC}"
    echo ""
    divider
    echo -e "${YELLOW}💡 常用管理命令:${NC}"
    echo -e "  查看状态:  ${CYAN}docker ps -f name=mtproto-proxy${NC}"
    echo -e "  查看日志:  ${CYAN}docker logs -f mtproto-proxy${NC}"
    echo -e "  停止代理:  ${CYAN}docker stop mtproto-proxy${NC}"
    echo -e "  启动代理:  ${CYAN}docker start mtproto-proxy${NC}"
    echo -e "  重启代理:  ${CYAN}docker restart mtproto-proxy${NC}"
    echo -e "  卸载代理:  ${CYAN}bash $0 --uninstall${NC}"
    echo -e "  查看连接信息: ${CYAN}bash $0 --info${NC}"
    divider

    cat > "$INSTALL_DIR/connection-info.txt" <<EOF
==========================================
  Telegram MTProto 代理连接信息
==========================================
服务器: $server_ip
端口:   $port
密钥:   $secret

快速连接链接:
$tg_link
https://t.me/proxy?server=${server_ip}&port=${port}&secret=${secret}

生成时间: $(date '+%Y-%m-%d %H:%M:%S')
==========================================
EOF
    success "连接信息已保存到 $INSTALL_DIR/connection-info.txt"
}

show_info() {
    if [[ ! -f "$INSTALL_DIR/connection-info.txt" ]]; then
        error "未找到代理配置信息，请先部署"
        exit 1
    fi
    cat "$INSTALL_DIR/connection-info.txt"
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

    cd "$INSTALL_DIR" 2>/dev/null || true
    docker compose down --volumes --rmi local 2>/dev/null || \
    docker-compose down --volumes --rmi local 2>/dev/null || \
    docker stop mtproto-proxy 2>/dev/null && docker rm mtproto-proxy 2>/dev/null

    rm -rf "$INSTALL_DIR"
    docker volume rm mtproto-proxy-data 2>/dev/null || true

    success "MTProto 代理已完全卸载"
}

reconfigure_proxy() {
    if [[ ! -f "$DOCKER_COMPOSE_FILE" ]]; then
        error "未找到代理配置，请先部署"
        exit 1
    fi

    divider
    info "重新配置 MTProto 代理..."
    divider

    info "正在生成新密钥..."
    local new_secret
    new_secret=$(generate_mtg_secret)
    if [[ -z "$new_secret" ]]; then
        error "密钥生成失败"
        exit 1
    fi

    cd "$INSTALL_DIR"
    sed -i "s|command: run .* --port|command: run ${new_secret} --port|" "$DOCKER_COMPOSE_FILE"
    echo "$new_secret" > "$CONFIG_FILE"

    docker compose down
    docker compose up -d

    sleep 3

    if docker ps --filter "name=mtproto-proxy" --filter "status=running" -q | grep -q .; then
        success "代理已重新配置并启动"
        echo ""
        echo -e "  ${BOLD}新密钥:${NC} ${GREEN}${new_secret}${NC}"
        local server_ip
        server_ip=$(get_server_ip)
        local port
        port=$(grep -E '^\s+- "[0-9]+' "$DOCKER_COMPOSE_FILE" | grep -oE '[0-9]+' | head -1)
        echo -e "  ${BOLD}连接链接:${NC} ${CYAN}tg://proxy?server=${server_ip}&port=${port}&secret=${new_secret}${NC}"
    else
        error "代理重启失败"
        docker logs mtproto-proxy 2>&1 | tail -10
    fi
}

show_help() {
    echo ""
    divider
    echo -e "${CYAN}${BOLD}  Telegram MTProto 代理 一键部署脚本 (增强版)${NC}"
    divider
    echo ""
    echo -e "  ${BOLD}用法:${NC} bash $0 [选项]"
    echo ""
    echo -e "  ${BOLD}选项:${NC}"
    echo -e "    (无参数)      一键部署 MTProto 代理"
    echo -e "    --info        查看代理连接信息"
    echo -e "    --uninstall   卸载 MTProto 代理"
    echo -e "    --reconfig    重新生成密钥并重启代理"
    echo -e "    --help        显示帮助信息"
    echo ""
    echo -e "  ${BOLD}环境变量:${NC}"
    echo -e "    MTG_PORT=端口号    自定义代理端口 (默认 1443)"
    echo ""
    divider
}

#======================= 主流程 ========================
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
        --reconfig)
            check_root
            reconfigure_proxy
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
    echo "  ║   9seconds/mtg · 兼容新版 Telegram  ║"
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
