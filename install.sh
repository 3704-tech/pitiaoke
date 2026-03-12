#!/bin/bash

# ========================================
# PMail 自动化安装脚本
# 功能：一键部署 PMail 邮件服务器
# 作者：Assistant
# 版本：2.0
# ========================================

set -euo pipefail  # 严格模式：遇到错误立即退出

# ==================== 颜色定义 ====================
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
NC='\033[0m'  # No Color

# ==================== 常量定义 ====================
CLOUD_REGION="ap-northeast-1"
COMPOSE_VERSION="v2.20.5"
DOCKER_MIRROR="https://registry.docker-cn.com"

# ==================== 全局变量 ====================
PMAIL_IP=""
DOMAIN=""
PASSWORD=""
ACCESS_KEY=""
ACCESS_SECRET=""

# ==================== 日志函数 ====================
log_info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# ==================== 参数校验 ====================
check_parameters() {
    if [[ $# -lt 5 ]]; then
        log_error "缺少必要参数"
        echo "用法: $0 <IP地址> <域名> <密码> <ACCESS_KEY> <ACCESS_SECRET>"
        echo "示例: $0 192.168.1.100 example.com MyPass123 LTAI5txxx xxx"
        exit 1
    fi
    
    PMAIL_IP="$1"
    DOMAIN="$2"
    PASSWORD="$3"
    ACCESS_KEY="$4"
    ACCESS_SECRET="$5"
    
    # 验证 IP 格式
    if [[ ! "$PMAIL_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "IP地址格式不正确: $PMAIL_IP"
        exit 1
    fi
    
    # 验证域名格式
    if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}$ ]]; then
        log_error "域名格式不正确: $DOMAIN"
        exit 1
    fi
    
    log_info "参数校验通过"
    log_info "IP: $PMAIL_IP | 域名: $DOMAIN"
}

# ==================== 权限校验 ====================
check_root_permission() {
    if [[ $EUID -ne 0 ]]; then
        log_error "必须使用 root 权限运行此脚本"
        echo "请使用: sudo $0 $*"
        exit 1
    fi
    log_success "Root 权限验证通过"
}

# ==================== 依赖检测函数 ====================

# 检测 Docker 是否已安装
check_docker_installed() {
    log_info "[依赖检测] Docker"
    if command -v docker &>/dev/null; then
        local version=$(docker --version | awk '{print $3}' | tr -d ',')
        log_success "Docker 已安装 (版本：$version)"
        return 0
    else
        log_warn "Docker 未安装"
        return 1
    fi
}

# 检测 Docker Compose 是否已安装
check_docker_compose() {
    log_info "[依赖检测] Docker Compose"
    if command -v docker-compose &>/dev/null || docker compose version &>/dev/null; then
        log_success "Docker Compose 已安装"
        return 0
    else
        log_warn "Docker Compose 未安装"
        return 1
    fi
}

# 检测 jq 是否已安装
check_jq_installed() {
    log_info "[依赖检测] jq"
    if command -v jq &>/dev/null; then
        log_success "jq 已安装 ($(jq --version))"
        return 0
    else
        log_warn "jq 未安装"
        return 1
    fi
}

# 检测 Aliyun CLI 是否已安装
check_aliyun_cli_installed() {
    log_info "[依赖检测] Aliyun CLI"
    if command -v aliyun &>/dev/null; then
        local version=$(aliyun version 2>/dev/null || echo "未知")
        log_success "Aliyun CLI 已安装 (版本：$version)"
        return 0
    else
        log_warn "Aliyun CLI 未安装"
        return 1
    fi
}

# ==================== 安装函数 ====================

# 安装 Docker
install_docker() {
    log_info "开始安装 Docker..."
    
    # 使用国内镜像源加速
    curl -fsSL https://get.docker.com | sh -s -- --mirror Aliyun
    
    if ! command -v docker &>/dev/null; then
        log_error "Docker 安装失败"
        exit 1
    fi
    
    log_success "Docker 安装完成"
}

# Docker 安装后配置
configure_docker() {
    log_info "配置 Docker..."
    
    # 配置镜像加速
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << EOF
{
    "registry-mirrors": ["$DOCKER_MIRROR"],
    "exec-opts": ["native.cgroupdriver=systemd"],
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "100m",
        "max-file": "3"
    }
}
EOF

    # 配置用户组
    if [[ -n "${SUDO_USER:-}" ]]; then
        usermod -aG docker "$SUDO_USER"
        log_info "已将用户 $SUDO_USER 加入 docker 组"
    fi

    # 重启服务
    systemctl daemon-reload
    systemctl enable docker
    systemctl restart docker

    # 验证安装
    if docker run --rm hello-world &>/dev/null; then
        local version=$(docker --version | awk '{print $3}' | tr -d ',')
        log_success "Docker 配置完成 (版本：$version)"
    else
        log_error "Docker 配置验证失败"
        exit 1
    fi
}

# 安装 Docker Compose
install_docker_compose() {
    log_info "开始安装 Docker Compose..."
    
    local arch=$(uname -m)
    local compose_url="https://ghproxy.com/https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-${arch}"
    
    curl -sSL "$compose_url" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    
    # 验证安装
    if command -v docker-compose &>/dev/null; then
        log_success "Docker Compose 安装完成"
    else
        log_error "Docker Compose 安装失败"
        exit 1
    fi
}

# 安装 jq
install_jq() {
    log_info "开始安装 jq..."
    
    if [[ -f /etc/redhat-release ]]; then
        # CentOS/RHEL
        yum install -y epel-release && yum install -y jq
    elif [[ -f /etc/debian_version ]]; then
        # Debian/Ubuntu
        apt-get update -qq && apt-get install -y jq
    else
        # 二进制安装
        local tmp_dir="/tmp/jq_install_$$"
        mkdir -p "$tmp_dir"
        curl -sSL "https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64" -o "$tmp_dir/jq"
        chmod +x "$tmp_dir/jq"
        mv "$tmp_dir/jq" /usr/local/bin/jq
        rm -rf "$tmp_dir"
    fi
    
    if command -v jq &>/dev/null; then
        log_success "jq 安装完成 ($(jq --version))"
    else
        log_error "jq 安装失败"
        exit 1
    fi
}

# 安装 Aliyun CLI
install_aliyun_cli() {
    log_info "开始安装 Aliyun CLI..."
    
    local tmp_dir="/tmp/aliyun_install_$$"
    mkdir -p "$tmp_dir"
    
    curl -sSL "https://aliyuncli.alicdn.com/aliyun-cli-linux-latest-amd64.tgz" -o "$tmp_dir/aliyun-cli.tgz"
    cd "$tmp_dir" && tar xzvf aliyun-cli.tgz
    mv aliyun /usr/local/bin/
    
    cd /
    rm -rf "$tmp_dir"
    
    # 配置 Aliyun CLI
    aliyun configure set \
        --profile AkProfile1 \
        --mode AK \
        --access-key-id "$ACCESS_KEY" \
        --access-key-secret "$ACCESS_SECRET" \
        --region "$CLOUD_REGION"
    
    if command -v aliyun &>/dev/null; then
        log_success "Aliyun CLI 安装完成"
    else
        log_error "Aliyun CLI 安装失败"
        exit 1
    fi
}

# ==================== 服务检测函数 ====================

# 检测 PMail 服务是否可访问
ping_pmail_service() {
    local url="$1"
    local timeout="${2:-300}"      # 默认 300 秒超时
    local interval="${3:-5}"        # 默认 5 秒检测间隔
    
    log_info "开始检测 PMail 服务 (超时: ${timeout}秒)..."
    
    local start_time=$(date +%s)
    
    while true; do
        # 执行 HTTP 检测
        local http_code
        http_code=$(curl -sIL -w "%{http_code}" -m 8 -o /dev/null "$url" 2>/dev/null || echo "000")
        
        # 检查是否成功 (2xx 或 3xx 都算成功)
        if [[ "$http_code" =~ ^([23][0-9]{2})$ ]]; then
            local end_time=$(date +%s)
            local total_time=$((end_time - start_time))
            log_success "PMail 已可访问 (HTTP: $http_code, 耗时: ${total_time}秒)"
            return 0
        fi
        
        # 计算已耗时
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        # 显示进度
        if [[ "$http_code" == "000" ]]; then
            log_info "等待服务启动... (已耗时: ${elapsed}秒, 状态码: 连接失败)"
        else
            log_info "等待服务启动... (已耗时: ${elapsed}秒, 状态码: $http_code)"
        fi
        
        # 检查是否超时
        if [[ $elapsed -ge $timeout ]]; then
            log_error "PMail 服务检测超时 (${timeout}秒)，请检查服务状态"
            return 1
        fi
        
        sleep "$interval"
    done
}

# 等待 Docker 服务就绪
wait_for_docker() {
    log_info "等待 Docker 服务就绪..."
    
    local retries=30
    local count=0
    
    while [[ $count -lt $retries ]]; do
        if docker info &>/dev/null; then
            log_success "Docker 服务已就绪"
            return 0
        fi
        count=$((count + 1))
        log_info "等待 Docker 启动... ($count/$retries)"
        sleep 2
    done
    
    log_error "Docker 服务启动超时"
    return 1
}

# ==================== 业务函数 ====================

# 生成 docker-compose.yml
generate_compose_file() {
    log_info "生成 PMail docker-compose.yml..."
    
    mkdir -p ~/pmail/{config,ssl}
    cd ~/pmail
    
    cat > docker-compose.yml << EOF
version: '3.9'
services:
  pmail:
    container_name: pmail
    image: ghcr.io/jinnrry/pmail:latest
    environment:
      - TZ=Asia/Shanghai
    ports:
      - "25:25"      # SMTP 标准端口
      - "465:465"    # SMTPS 加密端口
      - "80:80"      # HTTP 端口
      - "443:443"    # HTTPS 端口
      - "995:995"    # POP3S 端口
      - "993:993"    # IMAPS 端口
    volumes:
      - ./config:/work/config
      - ./ssl:/work/ssl
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:80/api/health"]
      interval: 30s
      timeout: 10s
      retries: 3
EOF

    log_success "docker-compose.yml 生成完成"
}

# 清理旧容器
cleanup_old_containers() {
    log_info "清理旧容器..."
    
    cd ~/pmail 2>/dev/null || true
    
    docker compose down 2>/dev/null || true
    docker ps -aq --filter "name=pmail" | xargs -r docker rm -f 2>/dev/null || true
    
    log_info "清理完成"
}

# 启动 PMail 服务
start_pmail_service() {
    log_info "启动 PMail 服务..."
    
    cd ~/pmail
    
    if docker compose up -d; then
        log_success "PMail 容器启动成功"
    else
        log_error "PMail 容器启动失败"
        docker compose logs
        exit 1
    fi
}

# 配置 PMail 数据库
configure_database() {
    local api_url="http://${PMAIL_IP}/api/setup"
    
    log_info "配置 PMail 数据库..."
    
    local response
    response=$(curl -sSf -X POST \
        -H "Content-Type: application/json;charset=UTF-8" \
        -H "Lang: zhCn" \
        --data-raw '{"action":"set","step":"database","db_type":"sqlite","db_dsn":"/work/config/pmail.db"}' \
        "$api_url" 2>&1) || {
        log_error "数据库配置失败"
        return 1
    }
    
    log_success "数据库配置完成"
}

# 配置 PMail 管理员账号
configure_admin_account() {
    local api_url="http://${PMAIL_IP}/api/setup"
    
    log_info "配置管理员账号..."
    
    local json_data
    json_data=$(jq -n --arg pwd "$PASSWORD" \
        '{action: "set", step: "password", account: "admin", password: $pwd}')
    
    local response
    response=$(curl -sSf -X POST \
        -H "Content-Type: application/json;charset=UTF-8" \
        -H "Lang: zhCn" \
        --data-raw "$json_data" \
        "$api_url" 2>&1) || {
        log_error "管理员账号配置失败"
        return 1
    }
    
    log_success "管理员账号配置完成"
    log_info "账号: admin | 密码: $PASSWORD"
}

# 配置 PMail 域名
configure_domain() {
    local api_url="http://${PMAIL_IP}/api/setup"
    
    log_info "配置 PMail 域名..."
    
    local web_domain="mail.${DOMAIN}"
    local smtp_domain="${DOMAIN}"
    
    local json_data
    json_data=$(jq -n \
        --arg web "$web_domain" \
        --arg smtp "$smtp_domain" \
        '{action: "set", step: "domain", web_domain: $web, smtp_domain: $smtp, multi_domain: ""}')
    
    local response
    response=$(curl -sSf -X POST \
        -H "Content-Type: application/json;charset=UTF-8" \
        -H "Lang: zhCn" \
        --data-raw "$json_data" \
        "$api_url" 2>&1) || {
        log_error "域名配置失败"
        return 1
    }
    
    log_success "域名配置完成"
    log_info "Web域名: $web_domain | SMTP域名: $smtp_domain"
}

# 生成 DNS 记录
generate_dns_records() {
    local api_url="http://${PMAIL_IP}/api/setup"
    
    log_info "获取 DNS 记录配置..."
    
    local response
    response=$(curl -sSf -X POST \
        -H "Content-Type: application/json;charset=UTF-8" \
        -H "Lang: zhCn" \
        --data-raw '{"action":"get","step":"dns"}' \
        "$api_url" 2>&1) || {
        log_error "获取 DNS 记录失败"
        return 1
    }
    
    # 解析并生成阿里云 CLI 命令
    echo "$response" | jq -r --arg domain "$DOMAIN" '
        .data | to_entries[] | 
        "aliyun alidns AddDomainRecord --profile AkProfile1 --region cn-zhangjiakou " +
        "--Type " + (.value.type) + 
        " --Value \"" + (.value.value) + "\" " +
        "--TTL 600 --Priority 1 " +
        "--DomainName \"" + ($domain) + "\" " +
        "--RR \"" + (.value.host) + "\""
    ' | while read -r cmd; do
        log_info "执行: $cmd"
        eval "$cmd" && log_success "DNS 记录添加成功" || log_warn "DNS 记录添加失败"
    done
    
    log_success "DNS 记录配置完成"
}

# 配置 SSL
configure_ssl() {
    local api_url="http://${PMAIL_IP}/api/setup"
    
    log_info "配置 SSL..."
    
    local json_data
    json_data=$(jq -n \
        --arg key "./config/ssl/private.key" \
        --arg crt "./config/ssl/public.crt" \
        '{action: "set", step: "ssl", ssl_type: "0", key_path: $key, crt_path: $crt}')
    
    local response
    response=$(curl -sSf -X POST \
        -H "Content-Type: application/json;charset=UTF-8" \
        -H "Lang: zhCn" \
        --data-raw "$json_data" \
        "$api_url" 2>&1) || {
        log_error "SSL 配置失败"
        return 1
    }
    
    log_success "SSL 配置完成"
}

# 设置系统 hostname
set_hostname() {
    log_info "设置系统 hostname..."
    
    local hostname="smtp.${DOMAIN}"
    hostnamectl set-hostname "$hostname"
    
    # 更新 /etc/hosts
    if ! grep -q "$hostname" /etc/hosts; then
        echo "127.0.0.1 $hostname" >> /etc/hosts
    fi
    
    log_success "Hostname 设置完成: $hostname"
}

# ==================== 主流程 ====================

main() {
    echo -e "\n${CYAN}========================================${NC}"
    echo -e "${CYAN}       PMail 自动化安装脚本 v2.0        ${NC}"
    echo -e "${CYAN}========================================${NC}\n"
    
    # 1. 基础检查
    check_root_permission
    check_parameters "$@"
    
    # 2. 安装依赖
    log_info "========== 检查并安装依赖 =========="
    
    if ! check_docker_installed; then
        install_docker
        configure_docker
    fi
    
    wait_for_docker
    
    if ! check_docker_compose; then
        install_docker_compose
    fi
    
    if ! check_jq_installed; then
        install_jq
    fi
    
    if ! check_aliyun_cli_installed; then
        install_aliyun_cli
    fi
    
    # 3. 启动 PMail 服务
    log_info "========== 部署 PMail 服务 =========="
    
    generate_compose_file
    cleanup_old_containers
    start_pmail_service
    
    # 4. 等待服务就绪
    log_info "========== 等待服务就绪 =========="
    
    if ! ping_pmail_service "http://${PMAIL_IP}/" 300 10; then
        log_error "PMail 服务未能正常启动，请检查日志"
        docker compose logs
        exit 1
    fi
    
    # 5. 配置 PMail
    log_info "========== 配置 PMail =========="
    
    configure_database
    sleep 2
    
    configure_admin_account
    sleep 2
    
    configure_domain
    sleep 2
    
    generate_dns_records
    sleep 2
    
    configure_ssl
    sleep 2
    
    # 6. 完成配置
    log_info "========== 完成配置 =========="
    
    set_hostname
    
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}       PMail 安装配置完成！            ${NC}"
    echo -e "${GREEN}========================================${NC}\n"
    
    echo -e "${CYAN}服务信息:${NC}"
    echo -e "  Web 访问: ${YELLOW}http://mail.${DOMAIN}${NC}"
    echo -e "  管理员账号: ${YELLOW}admin${NC}"
    echo -e "  管理员密码: ${YELLOW}${PASSWORD}${NC}"
    echo -e ""
    echo -e "${CYAN}常用命令:${NC}"
    echo -e "  查看日志: ${YELLOW}cd ~/pmail && docker compose logs -f${NC}"
    echo -e "  重启服务: ${YELLOW}cd ~/pmail && docker compose restart${NC}"
    echo -e "  停止服务: ${YELLOW}cd ~/pmail && docker compose down${NC}"
}

# 执行主函数
main "$@"
