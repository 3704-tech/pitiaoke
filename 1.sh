#!/bin/bash

# 权限校验（需root权限）
if [[ $EUID -ne 0 ]]; then
    echo -e "\033[31m错误：必须使用root权限运行此脚本\033[0m" >&2
    exit 1
fi

# 参数校验
if [[ $# -lt 5 ]]; then
    echo -e "\033[31m错误：缺少必要参数\033[0m"
    echo "用法: install.sh <IP地址> <域名> <密码> <ACCECSS_KEY> <ACCECSS_SECRET>"
    exit 1
fi

DOCKER_KEYRING="/usr/share/keyrings/docker-archive-keyring.gpg"
CLOUD_REGION="ap-northeast-1"

PMAIL_IP=$1
DOMAIN=$2
PASSWORD=$3
ACCECSS_KEY=$4
ACCECSS_SECRET=$5

# ==================== 设置主机名 ====================
echo -e "\n\033[36m设置主机名为 smtp.$DOMAIN ...\033[0m"
sudo hostnamectl set-hostname smtp.$DOMAIN
export HOSTNAME=$(hostname)
echo -e "\033[32m主机名已设置为：$(hostname)\033[0m"

# 检测Docker是否已安装
check_docker_installed() {
    echo -e "\033[32m[依赖检测] Docker\033[0m"
    if command -v docker &>/dev/null; then
        docker_version=$(docker --version | awk '{print $3}' | tr -d ',')
        echo -e "\033[32m ✔  Docker已安装 (版本：$docker_version)\033[0m"
        return 0
    else
        echo -e "\033[33m ✘ Docker未安装\033[0m"
        return 1
    fi
}

check_aliyun_cli_installed() {
    echo -e "\033[32m[依赖检测] Aliyun CLI\033[0m"
    if command -v aliyun &>/dev/null; then
        aliyun_cli_version=$(aliyun version)
        echo -e "\033[32m ✔  Aliyun CLI已安装 (版本：$aliyun_cli_version)\033[0m"
        return 0
    else
        echo -e "\033[33m ✘ Aliyun CLI未安装\033[0m"
        return 1
    fi
}

# 用官方脚本安装 Docker
install_docker() {
    echo "开始安装 Docker..."
    curl -fsSL https://get.docker.com | sudo sh
    if [ $? -ne 0 ]; then
        echo -e "\033[31m ✘ Docker 安装失败\033[0m" >&2
        exit 1
    fi
    echo -e "\033[32m ✔ Docker 安装完成\033[0m"
}

# 安装后配置
post_install() {
    echo -e "\033[33m 配置镜像加速...\033[0m"
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << EOF
{
    "registry-mirrors": ["https://registry.docker-cn.com"],
    "exec-opts": ["native.cgroupdriver=systemd"]
}
EOF
    usermod -aG docker $SUDO_USER
    echo -e "\033[33m 提示：当前用户已加入docker组\033[0m"
    echo -e "\033[33m 等待Docker重启...\033[0m"
    systemctl daemon-reload
    systemctl restart docker
    if docker run --rm hello-world &>/dev/null; then
        echo -e "\033[32m ✔ Docker安装验证通过\033[0m"
    else
        echo -e "\033[31m ✘ Docker安装验证失败\033[0m" >&2
        exit 1
    fi
    docker_version=$(docker --version | awk '{print $3}' | tr -d ',')
    echo -e "\n\033[36m[操作完成]！Docker安装完成 (版本：$docker_version)\033[0m"
}

# 检测Docker Compose是否已安装
check_docker_compose() {
    echo -e "\033[32m[依赖检测] Docker Compose\033[0m"
    if command -v docker-compose &> /dev/null || docker compose version &> /dev/null; then
        echo -e "\033[32m ✔ Docker Compose已安装\033[0m"
        return 0
    else
        echo -e "\033[33m ✘ Docker Compose未安装\033[0m"
        return 1
    fi
}

check_and_install_jq() {
    echo -e "\033[32m[依赖检测] jq\033[0m"
    if command -v jq &> /dev/null; then
        echo -e "\033[32m ✔ jq已安装 $(jq --version)\033[0m"
        return 0
    fi

    echo -e "\033[33m ✘ jq未安装\033[0m"
    echo -e "\033[33m 开始安装 jq 工具...\033[0m"
    
    if [[ -f /etc/redhat-release ]]; then
        sudo yum install -q -y epel-release && sudo yum install -q -y jq
    elif [[ -f /etc/lsb-release ]] || [[ -f /etc/debian_version ]]; then
        sudo apt-get update -qq && sudo apt-get install -qq -y jq
    else
        tmp_dir="/tmp/jq_install_$(date +%s)"
        mkdir -p "$tmp_dir"
        curl -sSL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o "$tmp_dir/jq"
        chmod +x "$tmp_dir/jq"
        export PATH="$tmp_dir:$PATH"
    fi

    if ! command -v jq &> /dev/null; then
        echo -e "\033[31m ✘ jq安装失败！\033[0m" >&2
        exit 1
    fi
    echo -e "\033[32m ✔jq 安装成功 $(jq --version)\033[0m"
}

##################################################
if check_docker_installed; then
    echo " 跳过安装步骤，直接使用现有Docker环境"
else
    install_docker
    post_install
fi
##################################################
if check_docker_compose; then
    echo " 跳过安装步骤，开始配置环境..."
else
    echo " 开始安装Docker Compose..."
    curl -sSL "https://ghproxy.com/https://github.com/docker/compose/releases/download/v2.20.5/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi

if grep -q docker /etc/group; then
    echo -e "\033[33m 正在激活docker组权限...\033[0m"
    newgrp docker <<EOF
    echo " 权限已激活"
EOF
fi

if check_aliyun_cli_installed; then
    echo " 跳过安装步骤，直接使用现有Aliyun CLI环境"
else
    echo " 开始安装Aliyun CLI..."
    tmp_dir="/tmp/aliyun_install_$(date +%s)"
    mkdir -p "$tmp_dir"
    curl -sSL "https://aliyuncli.alicdn.com/aliyun-cli-linux-latest-amd64.tgz?spm=a2c4g.11186623.0.0.5893478dPU6YhK&file=aliyun-cli-linux-latest-amd64.tgz" -o "$tmp_dir/aliyun-cli-linux-latest-amd64.tgz"
    cd "$tmp_dir" && tar xzvf aliyun-cli-linux-latest-amd64.tgz
    echo "export PATH=$PATH:$tmp_dir" >> ~/.bash_profile
    source ~/.bash_profile

    if command -v aliyun &>/dev/null; then
        aliyun_cli_version=$(aliyun version)
        echo -e "\033[32m ✔ Aliyun CLI安装验证通过 (版本：$aliyun_cli_version)\033[0m"
        aliyun configure set \
          --profile AkProfile1 \
          --mode AK \
          --access-key-id $ACCECSS_KEY \
          --access-key-secret $ACCECSS_SECRET \
          --region $CLOUD_REGION
    else
        echo -e "\033[31m ✘ Aliyun CLI安装失败\033[0m" >&2
        exit 1
    fi
fi

check_and_install_jq
##########################################################################

echo -e "\n\033[36m开始生成PMail配置文件...\033[0m"
mkdir -p ~/pmail/{config,ssl} && cd ~/pmail

echo " 生成PMail docker文件"
cat << EOF > docker-compose.yml
version: '3.9'
services:
  pmail:
    container_name: pmail
    image: ghcr.io/jinnrry/pmail:latest
    environment:
      - TZ=Asia/Shanghai
    ports:
      - "25:25"
      - "465:465"
      - "80:80"
      - "443:443"
      - "995:995"
      - "993:993"
    restart: unless-stopped
EOF
echo " PMail配置完成"

echo -e "\n\033[33m停止并删除PMail服务...\033[0m"
docker compose down
docker ps -aq | xargs -r docker rm -f
docker ps -a
docker network list
netstat -anpto | grep 25

echo -e "\n\033[36m安装并启动PMail服务...\033[0m"
if docker compose up -d; then
    echo -e "\033[33mPMail启动成功！\033[0m"
else
    echo -e "\033[31mPMail启动失败，请检查日志\033[0m" >&2
    exit 1
fi

ping_pmail_service(){
    URL="$1"
    TIMEOUT=120
    INTERVAL=5

    start_time=$(date +%s)
    while true; do
        http_code=$(curl -sIL -w "%{http_code}" -m 5 -o /dev/null "$URL")
        
        if [[ "$http_code" =~ ^2 ]]; then
            echo -e "\n\033[36m[$(date)] PMail 已可访问\033[0m"
            return 0
        fi
        
        current_time=$(date +%s)
        elapsed=$((current_time - start_time))
        
        if [ $elapsed -ge $TIMEOUT ]; then
            echo -e "\033[31m[$(date)] PMail超时（${TIMEOUT}秒）未访问成功，退出程序，请重新处理\033[0m"
            exit 1
        fi
        
        sleep $INTERVAL
    done
}

# ==================== 函数定义 ====================
fetch_and_process_json() {
    if [[ $# -lt 4 ]]; then
        echo -e "\033[31m错误：缺少必要参数\033[0m"
        echo "用法: fetch_and_process_json <说明> <IP地址> <JSON数据> <parse模式>"
        echo "parse模式: 1-执行阿里云解析，0-仅保存JSON"
        return 1
    fi

    local title="$1"
    local target_ip="$2"
    local json_data="$3"
    local parse_mode="$4"
    local api_url="http://${target_ip}/api/setup"

    echo -e "\n\033[36m$title\033[0m"
    local http_response
    http_response=$(curl -sSf -X POST \
        -H "Accept: application/json, text/plain, */*" \
        -H "Accept-Language: zh-CN,zh;q=0.9" \
        -H "Connection: keep-alive" \
        -H "Content-Type: application/json;charset=UTF-8;" \
        -H "Lang: zhCn" \
        -H "Origin: http://${target_ip}" \
        -H "Referer: http://${target_ip}/" \
        -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36" \
        --data-raw "$json_data" \
        --insecure \
        "$api_url" 2>&1)

    local curl_exit_code=$?
    if [ $curl_exit_code -ne 0 ]; then
        echo -e "\033[31m请求失败，错误代码：$curl_exit_code\033[0m"
        echo "详细错误：$http_response"
        return 2
    fi

    if [ "$parse_mode" -eq 1 ]; then
        echo "$http_response" | jq -r '
          .data | keys[] as $domain |
          .[$domain] | to_entries | map(
             "aliyun alidns DeleteSubDomainRecords --profile AkProfile1 --region cn-zhangjiakou " +
             "--Type \(.value.type) " +
             "--DomainName \"\($domain | @sh)\" " +
              "--RR \"\(.value.host | @sh)\" " +
             " && " +
             "aliyun alidns AddDomainRecord --profile AkProfile1 --region cn-zhangjiakou " +
                "--Type \(.value.type) " +
                "--Value \"\(.value.value | @sh)\" " +
                "--TTL 600 --Priority 1 " +
                "--DomainName \"\($domain | @sh)\" " +
                "--RR \"\(.value.host | @sh)\""
          ) | join("\n")
        ' | xargs -I{} sh -c '
        set -e
        max_retries=3
        base_delay=2
        attempt=1
        last_exit=0
        cmd="{}"
        
        GREEN="\033[32m"
        RED="\033[31m"
        YELLOW="\033[33m"
        NC="\033[0m"
        
        until [ $attempt -gt $max_retries ]; do
            echo "▶▶ 执行命令: $cmd (尝试 $attempt/$max_retries)"
            
            if eval "$cmd"; then
                echo -e "${GREEN}✔ 阿里云DNS记录操作成功${NC}"
                last_exit=0
                break
            else
                last_exit=$?
                case $last_exit in
                    94|255)
                        retry_type="可重试错误"
                        ;;
                    *)
                        retry_type="致命错误"
                        attempt=$max_retries  
                        ;;
                esac
                
                echo -e "${YELLOW}⚠ ${retry_type}[CODE:$last_exit] 将在退避后重试...${NC}"
                sleep $((base_delay*2**(attempt-1)+RANDOM%3))
                ((attempt++))
            fi
        done
        
        if [ $last_exit -ne 0 ]; then
            echo -e "${RED}✖ 已达最大重试次数，最终失败！错误码：$last_exit${NC}"
            exit $last_exit
        fi'
    else
        local output_file="response_$(date +%s).json"
        echo "$http_response" > "$output_file"
        echo -e "\033[32m响应已保存至：$output_file\033[0m"
    fi
    return 0
}
 
echo -e "\n\033[36m检测PMail服务是否正常...\033[0m"
ping_pmail_service "http://$PMAIL_IP/"

fetch_and_process_json "配置PMail数据库..." $PMAIL_IP '{"action":"set","step":"database","db_type":"sqlite","db_dsn":"/work/./config/pmail.db"}' 0
ACCOUNT_DATA=$(jq -n --arg pwd "$PASSWORD" '{action: "set", step: "password", account: "admin", "password": $pwd}')
fetch_and_process_json "配置PMail账号密码..." $PMAIL_IP "$ACCOUNT_DATA" 0
echo -e "\n\033[36mPMail账号: admin, 密码: $PASSWORD \033[0m" 
JSON_DATA=$(jq -n --arg web "mail.$DOMAIN" --arg smtp "$DOMAIN" '{action: "set", step: "domain", web_domain: $web, smtp_domain: $smtp, multi_domain: ""}')
fetch_and_process_json "配置PMail域名..." $PMAIL_IP "$JSON_DATA" 0

fetch_and_process_json "生成DNS记录..." $PMAIL_IP '{"action":"get","step":"dns"}' 1

# 额外添加DMARC记录 - 这是正确的写法
echo -e "\n\033[36m添加DMARC记录...\033[0m"
aliyun alidns DeleteSubDomainRecords --profile AkProfile1 --region cn-zhangjiakou \
  --Type TXT \
  --DomainName "$DOMAIN" \
  --RR "_dmarc"

aliyun alidns AddDomainRecord --profile AkProfile1 --region cn-zhangjiakou \
  --Type TXT \
  --Value "v=DMARC1; p=none" \
  --TTL 600 \
  --Priority 1 \
  --DomainName "$DOMAIN" \
  --RR "_dmarc"

fetch_and_process_json "SSL配置..." $PMAIL_IP '{"action":"set","step":"ssl","ssl_type":"0","key_path":"./config/ssl/private.key","crt_path":"./config/ssl/public.crt"}' 0

echo -e "\n\033[36m主机名已设置为: $(hostname)\033[0m"
