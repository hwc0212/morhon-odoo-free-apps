#!/bin/bash

# Odoo VPS 管理脚本 - Ubuntu增强版
# 支持外贸专用版Odoo，使用sudo用户运行
# 版本: 4.0

set -e

# 配置变量
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="/etc/odoo-manager"
INSTANCES_BASE="/opt"
BACKUP_DIR="/var/backups/odoo"
LOG_DIR="/var/log/odoo-manager"
DOCKER_NETWORK="odoo-network"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 日志函数
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | sudo tee -a "$LOG_DIR/odoo-manager.log"
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | sudo tee -a "$LOG_DIR/odoo-manager.log" >&2
}

log_warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1" | sudo tee -a "$LOG_DIR/odoo-manager.log"
}

log_info() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] INFO:${NC} $1" | sudo tee -a "$LOG_DIR/odoo-manager.log"
}

# 检查是否为sudo用户
check_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        log_warn "检测到以root用户运行，建议使用sudo用户运行"
        read -p "是否继续使用root用户运行？(y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "请使用sudo用户重新运行脚本: sudo -u $(logname) $0"
            exit 1
        fi
        log_warn "继续以root用户运行"
    elif ! sudo -n true 2>/dev/null; then
        echo "此脚本需要sudo权限，请输入密码:"
        if ! sudo -v; then
            echo "无法获取sudo权限，请确保您有sudo权限"
            exit 1
        fi
    fi
}

# 检测Ubuntu版本
detect_ubuntu_version() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" = "ubuntu" ]; then
            log "检测到 Ubuntu $VERSION_ID"
            return 0
        else
            log_warn "当前系统不是Ubuntu，但将继续尝试执行"
            return 1
        fi
    else
        log_error "无法检测操作系统"
        exit 1
    fi
}

# 获取系统信息
get_system_info() {
    log_info "获取系统信息..."
    
    # CPU信息
    CPU_CORES=$(nproc)
    CPU_MODEL=$(lscpu | grep "Model name" | cut -d':' -f2 | sed 's/^[ \t]*//' | head -1)
    
    # 内存信息
    TOTAL_MEM=$(free -g | awk '/^Mem:/{print $2}')
    AVAILABLE_MEM=$(free -g | awk '/^Mem:/{print $7}')
    
    # 磁盘信息
    DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
    DISK_AVAILABLE=$(df -h / | awk 'NR==2 {print $4}')
    
    log "系统信息:"
    log "  CPU核心: $CPU_CORES ($CPU_MODEL)"
    log "  总内存: ${TOTAL_MEM}GB (可用: ${AVAILABLE_MEM}GB)"
    log "  磁盘空间: ${DISK_TOTAL} (可用: ${DISK_AVAILABLE})"
    
    # 根据系统资源计算优化参数
    calculate_optimization_params
}

# 计算优化参数
calculate_optimization_params() {
    # 计算workers数量 (基于CPU核心数)
    if [ $CPU_CORES -ge 8 ]; then
        WORKERS=8
        MAX_CRON_THREADS=4
    elif [ $CPU_CORES -ge 4 ]; then
        WORKERS=6
        MAX_CRON_THREADS=3
    elif [ $CPU_CORES -ge 2 ]; then
        WORKERS=4
        MAX_CRON_THREADS=2
    else
        WORKERS=2
        MAX_CRON_THREADS=1
    fi
    
    # 计算内存限制 (基于可用内存)
    if [ $TOTAL_MEM -ge 32 ]; then
        LIMIT_MEMORY_HARD="8192M"
        LIMIT_MEMORY_SOFT="6144M"
        DB_SHARED_BUFFERS="2GB"
        DB_EFFECTIVE_CACHE_SIZE="6GB"
        DB_WORK_MEM="64MB"
        DB_MAINTENANCE_WORK_MEM="512MB"
    elif [ $TOTAL_MEM -ge 16 ]; then
        LIMIT_MEMORY_HARD="4096M"
        LIMIT_MEMORY_SOFT="3072M"
        DB_SHARED_BUFFERS="1GB"
        DB_EFFECTIVE_CACHE_SIZE="3GB"
        DB_WORK_MEM="32MB"
        DB_MAINTENANCE_WORK_MEM="256MB"
    elif [ $TOTAL_MEM -ge 8 ]; then
        LIMIT_MEMORY_HARD="2048M"
        LIMIT_MEMORY_SOFT="1536M"
        DB_SHARED_BUFFERS="512MB"
        DB_EFFECTIVE_CACHE_SIZE="1536MB"
        DB_WORK_MEM="16MB"
        DB_MAINTENANCE_WORK_MEM="128MB"
    elif [ $TOTAL_MEM -ge 4 ]; then
        LIMIT_MEMORY_HARD="1024M"
        LIMIT_MEMORY_SOFT="768M"
        DB_SHARED_BUFFERS="256MB"
        DB_EFFECTIVE_CACHE_SIZE="768MB"
        DB_WORK_MEM="8MB"
        DB_MAINTENANCE_WORK_MEM="64MB"
    else
        LIMIT_MEMORY_HARD="512M"
        LIMIT_MEMORY_SOFT="384M"
        DB_SHARED_BUFFERS="128MB"
        DB_EFFECTIVE_CACHE_SIZE="384MB"
        DB_WORK_MEM="4MB"
        DB_MAINTENANCE_WORK_MEM="32MB"
    fi
    
    # 计算CPU限制
    if [ $CPU_CORES -ge 4 ]; then
        CPU_LIMIT="2.0"
    elif [ $CPU_CORES -ge 2 ]; then
        CPU_LIMIT="1.0"
    else
        CPU_LIMIT="0.5"
    fi
    
    log_info "优化参数计算完成:"
    log "  Workers数量: $WORKERS"
    log "  Cron线程: $MAX_CRON_THREADS"
    log "  内存限制: $LIMIT_MEMORY_SOFT (软) / $LIMIT_MEMORY_HARD (硬)"
    log "  CPU限制: $CPU_LIMIT"
    log "  数据库缓存: $DB_SHARED_BUFFERS"
}

# 初始化环境
init_environment() {
    log "初始化环境..."
    
    detect_ubuntu_version
    
    # 创建必要的目录
    sudo mkdir -p "$CONFIG_DIR"
    sudo mkdir -p "$INSTANCES_BASE"
    sudo mkdir -p "$BACKUP_DIR"
    sudo mkdir -p "$LOG_DIR"
    
    # 更新系统
    log "更新系统包..."
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update
    sudo apt-get upgrade -y
    
    # 安装系统依赖
    log "安装系统依赖..."
    sudo apt-get install -y \
        curl \
        wget \
        git \
        unzip \
        tar \
        gzip \
        python3 \
        python3-pip \
        python3-venv \
        postgresql-client \
        certbot \
        python3-certbot-nginx \
        nginx \
        ufw \
        fail2ban \
        htop \
        net-tools \
        software-properties-common \
        apt-transport-https \
        ca-certificates \
        gnupg \
        lsb-release
    
    # 安装中文字体
    log "安装中文字体..."
    sudo apt-get install -y \
        fonts-wqy-zenhei \
        fonts-wqy-microhei \
        fonts-noto-cjk \
        fonts-arphic-uming \
        fonts-arphic-ukai \
        ttf-mscorefonts-installer
    
    # 安装Docker（如果不存在）
    if ! command -v docker &> /dev/null; then
        log "安装Docker..."
        # 添加Docker官方GPG密钥
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        
        # 将当前用户添加到docker组
        sudo usermod -aG docker $(whoami) || true
    fi
    
    # 安装Docker Compose（独立版本）
    if ! command -v docker-compose &> /dev/null; then
        log "安装Docker Compose..."
        sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
    fi
    
    # 下载微软雅黑字体（解决PDF中文问题）
    log "下载额外中文字体..."
    sudo mkdir -p /usr/share/fonts/truetype/custom
    if [ ! -f "/usr/share/fonts/truetype/custom/msyh.ttf" ]; then
        sudo wget -q -O /tmp/msyh.ttf https://github.com/adobe-fonts/source-han-sans/raw/release/OTF/SimplifiedChinese/SourceHanSansSC-Regular.otf
        sudo mv /tmp/msyh.ttf /usr/share/fonts/truetype/custom/
    fi
    
    if [ ! -f "/usr/share/fonts/truetype/custom/simhei.ttf" ]; then
        sudo wget -q -O /tmp/simhei.ttf https://github.com/be5invis/source-han-sans-ttf/raw/main/SubsetOTF/CN/SourceHanSansCN-Normal.ttf
        sudo mv /tmp/simhei.ttf /usr/share/fonts/truetype/custom/
    fi
    
    # 更新字体缓存
    sudo fc-cache -fv
    
    # 创建docker网络（如果不存在）
    if ! sudo docker network ls | grep -q "$DOCKER_NETWORK"; then
        sudo docker network create "$DOCKER_NETWORK"
    fi
    
    # 配置防火墙
    configure_firewall
    
    # 优化系统参数
    optimize_system
    
    # 优化Docker配置
    optimize_docker
    
    # 配置Nginx
    configure_nginx
    
    # 设置权限
    sudo chmod 755 "$INSTANCES_BASE"
    sudo chmod 755 "$BACKUP_DIR"
    
    # 为当前用户设置适当的权限
    CURRENT_USER=$(whoami)
    sudo chown -R $CURRENT_USER:$CURRENT_USER "$INSTANCES_BASE" 2>/dev/null || true
    sudo chown -R $CURRENT_USER:$CURRENT_USER "$BACKUP_DIR" 2>/dev/null || true
    sudo chown -R $CURRENT_USER:$CURRENT_USER "$LOG_DIR" 2>/dev/null || true
    
    log "环境初始化完成"
}

# 配置防火墙
configure_firewall() {
    log "配置防火墙..."
    
    # 启用UFW
    sudo ufw --force enable
    
    # 允许SSH
    sudo ufw allow 22/tcp
    
    # 允许HTTP/HTTPS
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
    
    # 允许必要的端口范围（用于Odoo实例）
    sudo ufw allow 8069:8100/tcp
    
    log "防火墙配置完成"
}

# 优化系统参数
optimize_system() {
    log "优化系统参数..."
    
    # 创建sysctl优化配置
    sudo tee /etc/sysctl.d/99-odoo-optimization.conf > /dev/null << EOF
# Odoo优化设置
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.overcommit_memory = 1

# 网络优化
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 262144
net.core.rmem_default = 8388608
net.core.rmem_max = 16777216
net.core.wmem_default = 8388608
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mem = 8388608 12582912 16777216
net.ipv4.tcp_max_syn_backlog = 262144
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_max_tw_buckets = 6000000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_tw_recycle = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.ip_local_port_range = 1024 65535

# 文件系统优化
fs.file-max = 2097152
fs.nr_open = 2097152
EOF
    
    # 应用sysctl配置
    sudo sysctl -p /etc/sysctl.d/99-odoo-optimization.conf
    
    # 创建limits优化配置
    sudo tee /etc/security/limits.d/99-odoo.conf > /dev/null << EOF
* soft nofile 65535
* hard nofile 65535
* soft nproc 65535
* hard nproc 65535
root soft nofile 65535
root hard nofile 65535
EOF
    
    # 创建systemd服务优化配置
    if [ -f /etc/systemd/system.conf ]; then
        sudo sed -i 's/^#DefaultLimitNOFILE=/DefaultLimitNOFILE=65535/' /etc/systemd/system.conf
        sudo sed -i 's/^#DefaultLimitNPROC=/DefaultLimitNPROC=65535/' /etc/systemd/system.conf
    fi
    
    log "系统参数优化完成"
}

# 优化Docker配置
optimize_docker() {
    log "优化Docker配置..."
    
    # 备份原有配置
    if [ -f /etc/docker/daemon.json ]; then
        sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
    fi
    
    # 创建优化配置
    sudo tee /etc/docker/daemon.json > /dev/null << EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "storage-opts": [
    "overlay2.override_kernel_check=true"
  ],
  "live-restore": true,
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 65535,
      "Soft": 65535
    },
    "nproc": {
      "Name": "nproc",
      "Hard": 65535,
      "Soft": 65535
    }
  },
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-level": "warn",
  "registry-mirrors": [
    "https://docker.mirrors.ustc.edu.cn",
    "https://hub-mirror.c.163.com"
  ],
  "dns": ["8.8.8.8", "8.8.4.4"]
}
EOF
    
    # 重启Docker
    sudo systemctl restart docker
    
    log "Docker配置优化完成"
}

# 配置Nginx
configure_nginx() {
    log "配置Nginx..."
    
    # 备份原始配置
    sudo cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup
    
    # 创建优化的nginx配置
    sudo tee /etc/nginx/nginx.conf > /dev/null << EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
    multi_accept on;
    use epoll;
}

http {
    # 基本设置
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;
    
    # MIME类型
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    # 日志格式
    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for"';
    
    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log warn;
    
    # 限制请求大小
    client_max_body_size 100M;
    client_body_timeout 120s;
    
    # 缓存设置
    open_file_cache max=1000 inactive=20s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;
    
    # Gzip压缩
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_min_length 1000;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/json
        application/javascript
        application/xml+rss
        application/atom+xml
        image/svg+xml;
    
    # SSL设置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;
    
    # 包含其他配置
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
    
    # 创建站点目录
    sudo mkdir -p /etc/nginx/sites-available
    sudo mkdir -p /etc/nginx/sites-enabled
    
    # 测试配置
    sudo nginx -t
    
    # 重启Nginx
    sudo systemctl restart nginx
    
    log "Nginx配置完成"
}

# 检查端口是否可用
check_port() {
    local port="$1"
    if sudo ss -tuln | grep -q ":$port "; then
        return 1
    fi
    return 0
}

# 生成实例名称（从域名）
generate_instance_name() {
    local domain="$1"
    # 移除协议前缀
    domain=$(echo "$domain" | sed -e 's|^[^/]*//||' -e 's|/.*$||')
    # 替换点为减号，移除非法字符
    local instance_name=$(echo "$domain" | sed 's/[^a-zA-Z0-9.-]/-/g' | sed 's/\./-/g')
    echo "$instance_name"
}

# 选择Odoo镜像
select_odoo_image() {
    echo "选择Odoo版本:"
    echo "1) Odoo 17 (odoo:17.0)"
    echo "2) Odoo 18 (odoo:18.0)"
    echo "3) 外贸专用版Odoo (registry.cn-hangzhou.aliyuncs.com/morhon_hub/mh_odoosaas_v17:latest)"
    echo "4) 自定义镜像"
    echo "5) 企业版 (需要许可证)"
    
    read -p "选择 (1-5) [默认: 1]: " version_choice
    version_choice=${version_choice:-1}
    
    case $version_choice in
        1)
            ODOO_IMAGE="odoo:17.0"
            POSTGRES_IMAGE="postgres:15"
            ODOO_VERSION="17.0"
            ;;
        2)
            ODOO_IMAGE="odoo:18.0"
            POSTGRES_IMAGE="postgres:15"
            ODOO_VERSION="18.0"
            ;;
        3)
            ODOO_IMAGE="registry.cn-hangzhou.aliyuncs.com/morhon_hub/mh_odoosaas_v17:latest"
            POSTGRES_IMAGE="registry.cn-hangzhou.aliyuncs.com/morhon_hub/postgres:latest"
            ODOO_VERSION="17.0-外贸专用版"
            log "选择外贸专用版Odoo"
            log "  Odoo镜像: $ODOO_IMAGE"
            log "  PostgreSQL镜像: $POSTGRES_IMAGE"
            ;;
        4)
            read -p "输入自定义Odoo镜像 (例如: odoo:17.0-custom): " custom_image
            if [[ -z "$custom_image" ]]; then
                log_error "镜像不能为空"
                return 1
            fi
            ODOO_IMAGE="$custom_image"
            POSTGRES_IMAGE="postgres:15"
            
            # 尝试从镜像名称提取版本
            if [[ "$custom_image" == *"17"* ]]; then
                ODOO_VERSION="17.0"
            elif [[ "$custom_image" == *"18"* ]]; then
                ODOO_VERSION="18.0"
            else
                ODOO_VERSION="custom"
            fi
            ;;
        5)
            log_warn "企业版需要许可证，请确保您有合法的许可证"
            ODOO_IMAGE="odoo:17.0"
            POSTGRES_IMAGE="postgres:15"
            ODOO_VERSION="17.0-enterprise"
            ;;
        *)
            log_error "无效选择"
            return 1
            ;;
    esac
    
    log "选择的Odoo镜像: $ODOO_IMAGE"
    log "选择的PostgreSQL镜像: $POSTGRES_IMAGE"
    return 0
}

# 生成docker-compose文件
generate_docker_compose() {
    local instance_name="$1"
    local domain="$2"
    local odoo_image="$3"
    local postgres_image="$4"
    local odoo_version="$5"
    local port="$6"
    
    local instance_dir="$INSTANCES_BASE/$instance_name"
    
    # 创建目录结构
    mkdir -p "$instance_dir/addons"
    mkdir -p "$instance_dir/config"
    mkdir -p "$instance_dir/data"
    mkdir -p "$instance_dir/postgres_data"
    mkdir -p "$instance_dir/backups"
    mkdir -p "$instance_dir/logs/odoo"
    mkdir -p "$instance_dir/logs/postgres"
    
    # 创建字体目录并复制字体
    mkdir -p "$instance_dir/fonts"
    sudo cp /usr/share/fonts/truetype/custom/* "$instance_dir/fonts/" 2>/dev/null || true
    sudo cp /usr/share/fonts/truetype/wqy/* "$instance_dir/fonts/" 2>/dev/null || true
    
    # 创建odoo配置文件
    cat > "$instance_dir/config/odoo.conf" << EOF
[options]
; 数据库设置
db_host = db
db_port = 5432
db_user = odoo
db_password = \${DB_PASSWORD}
db_name = odoo_${instance_name}
db_template = template0
dbfilter = ^odoo_${instance_name}\$
list_db = False

; 安全设置
admin_passwd = \${ADMIN_PASSWORD}
proxy_mode = True
without_demo = all
x_sendfile = True

; 性能优化
workers = ${WORKERS}
max_cron_threads = ${MAX_CRON_THREADS}
limit_memory_hard = ${LIMIT_MEMORY_HARD}
limit_memory_soft = ${LIMIT_MEMORY_SOFT}
limit_time_cpu = 900
limit_time_real = 1800
limit_request = 8192

; 日志设置
logfile = /var/log/odoo/odoo.log
log_level = warn
log_handler = :INFO
log_db = False
log_db_level = warning

; 邮件设置
email_from = odoo@${domain}
smtp_server = localhost
smtp_port = 25
smtp_ssl = False

; PDF设置（解决中文显示问题）
pdfkit_path = /usr/bin/wkhtmltopdf
reportgz = False

; 缓存设置
proxy_mode = True
server_wide_modules = base,web

; 其他设置
data_dir = /var/lib/odoo
addons_path = /mnt/extra-addons,/mnt/odoo/addons
EOF
    
    # 创建PostgreSQL优化配置
    cat > "$instance_dir/config/postgresql.conf" << EOF
# PostgreSQL优化配置
listen_addresses = '*'
max_connections = 100
shared_buffers = ${DB_SHARED_BUFFERS}
effective_cache_size = ${DB_EFFECTIVE_CACHE_SIZE}
maintenance_work_mem = ${DB_MAINTENANCE_WORK_MEM}
checkpoint_completion_target = 0.9
wal_buffers = 16MB
default_statistics_target = 100
random_page_cost = 1.1
effective_io_concurrency = 200
work_mem = ${DB_WORK_MEM}
min_wal_size = 1GB
max_wal_size = 4GB
max_worker_processes = ${CPU_CORES}
max_parallel_workers_per_gather = ${CPU_CORES}
max_parallel_workers = ${CPU_CORES}
log_destination = 'stderr'
logging_collector = on
log_directory = '/var/log/postgresql'
log_filename = 'postgresql-%Y-%m%d_%H%M%S.log'
log_truncate_on_rotation = on
log_rotation_age = 1d
log_rotation_size = 10MB
log_min_duration_statement = 1000
log_checkpoints = on
log_connections = on
log_disconnections = on
log_lock_waits = on
log_temp_files = 0
log_autovacuum_min_duration = 0
EOF
    
    # 创建docker-compose.yml
    cat > "$instance_dir/docker-compose.yml" << EOF
version: '3.8'

services:
  db:
    image: ${postgres_image}
    container_name: ${instance_name}-db
    restart: always
    environment:
      POSTGRES_DB: odoo_${instance_name}
      POSTGRES_USER: odoo
      POSTGRES_PASSWORD: \${DB_PASSWORD}
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - ${instance_dir}/postgres_data:/var/lib/postgresql/data/pgdata
      - ${instance_dir}/config/postgresql.conf:/etc/postgresql/postgresql.conf
      - ${instance_dir}/backups:/backups
      - ${instance_dir}/logs/postgres:/var/log/postgresql
    command: >
      postgres 
      -c config_file=/etc/postgresql/postgresql.conf
      -c shared_preload_libraries='pg_stat_statements'
    networks:
      - odoo-network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U odoo"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    deploy:
      resources:
        limits:
          cpus: '${CPU_LIMIT}'
          memory: ${LIMIT_MEMORY_HARD}
        reservations:
          memory: ${LIMIT_MEMORY_SOFT}

  odoo:
    image: ${odoo_image}
    container_name: ${instance_name}-odoo
    restart: always
    depends_on:
      db:
        condition: service_healthy
    environment:
      HOST: db
      PORT: 5432
      USER: odoo
      PASSWORD: \${DB_PASSWORD}
      DB_NAME: odoo_${instance_name}
      ADMIN_PASSWORD: \${ADMIN_PASSWORD}
    ports:
      - "${port}:8069"
    volumes:
      - ${instance_dir}/config/odoo.conf:/etc/odoo/odoo.conf
      - ${instance_dir}/addons:/mnt/extra-addons
      - ${instance_dir}/data:/var/lib/odoo
      - ${instance_dir}/logs/odoo:/var/log/odoo
      - ${instance_dir}/fonts:/usr/share/fonts/truetype/custom
    networks:
      - odoo-network
    command: >
      odoo
      --config=/etc/odoo/odoo.conf
      --update=all
      --without-demo=all
      --db-filter=^odoo_${instance_name}\$
    deploy:
      resources:
        limits:
          cpus: '${CPU_LIMIT}'
          memory: ${LIMIT_MEMORY_HARD}
        reservations:
          memory: ${LIMIT_MEMORY_SOFT}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8069/web/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s

networks:
  odoo-network:
    external: true
    name: ${DOCKER_NETWORK}
EOF
    
    # 创建环境变量文件
    cat > "$instance_dir/.env" << EOF
# Odoo实例环境变量
# 实例: ${instance_name}
# 域名: ${domain}
# Odoo镜像: ${odoo_image}
# PostgreSQL镜像: ${postgres_image}
# 版本: ${odoo_version}
# 部署时间: $(date '+%Y-%m-%d %H:%M:%S')

# 数据库设置
DB_PASSWORD=$(openssl rand -base64 32)
ADMIN_PASSWORD=$(openssl rand -base64 24)

# 实例信息
INSTANCE_NAME=${instance_name}
DOMAIN=${domain}
ODOO_IMAGE=${odoo_image}
POSTGRES_IMAGE=${postgres_image}
ODOO_VERSION=${odoo_version}
PORT=${port}

# 系统优化参数
CPU_CORES=${CPU_CORES}
TOTAL_MEM=${TOTAL_MEM}GB
WORKERS=${WORKERS}
MAX_CRON_THREADS=${MAX_CRON_THREADS}
LIMIT_MEMORY_HARD=${LIMIT_MEMORY_HARD}
LIMIT_MEMORY_SOFT=${LIMIT_MEMORY_SOFT}
CPU_LIMIT=${CPU_LIMIT}
EOF
    
    # 创建Nginx站点配置
    create_nginx_site_config "$instance_name" "$domain" "$port"
    
    # 设置目录权限
    CURRENT_USER=$(whoami)
    sudo chown -R $CURRENT_USER:$CURRENT_USER "$instance_dir"
    
    # 但数据库目录需要特定权限
    sudo chown -R 999:999 "$instance_dir/postgres_data" 2>/dev/null || true
    
    # 创建数据库初始化脚本
    cat > "$instance_dir/init-db.sh" << EOF
#!/bin/bash
# 数据库初始化脚本
docker exec -i ${instance_name}-db psql -U odoo -d odoo_${instance_name} << EOSQL
-- 创建pg_stat_statements扩展
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- 创建监控用户
CREATE USER monitor WITH PASSWORD '$(openssl rand -base64 16)';
GRANT pg_monitor TO monitor;

-- 创建备份用户
CREATE USER backup WITH PASSWORD '$(openssl rand -base64 16)';
GRANT CONNECT ON DATABASE odoo_${instance_name} TO backup;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO backup;

-- 优化数据库配置
ALTER DATABASE odoo_${instance_name} SET random_page_cost = 1.1;
ALTER DATABASE odoo_${instance_name} SET effective_io_concurrency = 200;
ALTER DATABASE odoo_${instance_name} SET maintenance_work_mem = '${DB_MAINTENANCE_WORK_MEM}';
ALTER DATABASE odoo_${instance_name} SET work_mem = '${DB_WORK_MEM}';
EOSQL
EOF
    
    chmod +x "$instance_dir/init-db.sh"
    
    # 创建数据库备份脚本
    cat > "$instance_dir/backup-db.sh" << EOF
#!/bin/bash
# 数据库备份脚本
BACKUP_DIR="${instance_dir}/backups"
BACKUP_FILE="odoo_${instance_name}_\$(date +%Y%m%d_%H%M%S).sql.gz"
docker exec ${instance_name}-db pg_dump -U odoo odoo_${instance_name} | gzip > "\$BACKUP_DIR/\$BACKUP_FILE"
find "\$BACKUP_DIR" -name "*.sql.gz" -mtime +7 -delete
echo "备份完成: \$BACKUP_FILE"
EOF
    
    chmod +x "$instance_dir/backup-db.sh"
    
    # 创建日志清理脚本
    cat > "$instance_dir/clean-logs.sh" << EOF
#!/bin/bash
# 日志清理脚本
find "${instance_dir}/logs" -name "*.log" -type f -mtime +30 -delete
find "${instance_dir}/logs" -name "*.log.*" -type f -mtime +7 -delete
docker exec ${instance_name}-odoo find /var/log/odoo -name "*.log.*" -type f -mtime +7 -delete
echo "日志清理完成"
EOF
    
    chmod +x "$instance_dir/clean-logs.sh"
    
    # 创建重启脚本
    cat > "$instance_dir/restart.sh" << EOF
#!/bin/bash
# 重启脚本
cd "$instance_dir"
docker-compose restart
echo "实例已重启"
EOF
    
    chmod +x "$instance_dir/restart.sh"
    
    log "为实例 $instance_name 生成配置文件"
}

# 创建Nginx站点配置
create_nginx_site_config() {
    local instance_name="$1"
    local domain="$2"
    local port="$3"
    
    local config_file="/etc/nginx/sites-available/${instance_name}"
    
    sudo tee "$config_file" > /dev/null << EOF
# Odoo实例: ${instance_name}
# 域名: ${domain}

# HTTP重定向到HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name ${domain} www.${domain};
    
    # 安全头部
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    
    # Certbot验证
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    
    # 重定向到HTTPS
    location / {
        return 301 https://\$server_name\$request_uri;
    }
    
    access_log /var/log/nginx/${instance_name}-access.log;
    error_log /var/log/nginx/${instance_name}-error.log;
}

# HTTPS服务器
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${domain} www.${domain};
    
    # SSL证书
    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    
    # SSL优化
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_trusted_certificate /etc/letsencrypt/live/${domain}/chain.pem;
    resolver 8.8.8.8 8.8.4.4 valid=300s;
    resolver_timeout 5s;
    
    # 安全头部
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Content-Security-Policy "default-src 'self' https: data: 'unsafe-inline' 'unsafe-eval';" always;
    
    # 代理设置
    proxy_connect_timeout 600s;
    proxy_send_timeout 600s;
    proxy_read_timeout 600s;
    proxy_buffers 16 64k;
    proxy_buffer_size 128k;
    
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header Host \$host;
    
    # 禁止访问敏感路径
    location ~* /(web|api)/database/ {
        deny all;
        return 403;
    }
    
    location ~* /web/database/manager {
        deny all;
        return 403;
    }
    
    location ~* /(README|CHANGELOG|COPYING|LICENSE|\.git) {
        deny all;
        return 403;
    }
    
    # 长轮询请求
    location /longpolling {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    
    # 静态文件 - 带缓存
    location ~* /web/static/ {
        proxy_cache_valid 200 60m;
        proxy_cache_valid 404 1m;
        proxy_buffering on;
        expires 864000;
        proxy_pass http://127.0.0.1:${port};
        
        # 缓存配置
        proxy_cache static_cache;
        proxy_cache_key \$scheme\$proxy_host\$request_uri;
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
        proxy_cache_background_update on;
        proxy_cache_lock on;
        add_header X-Cache-Status \$upstream_cache_status;
    }
    
    # WebSocket支持
    location /websocket {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # 主请求
    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_redirect off;
        proxy_buffering off;
    }
    
    # 错误页面
    error_page 500 502 503 504 /50x.html;
    location = /50x.html {
        root /usr/share/nginx/html;
    }
    
    access_log /var/log/nginx/${instance_name}-ssl-access.log;
    error_log /var/log/nginx/${instance_name}-ssl-error.log;
}
EOF
    
    # 启用站点
    sudo ln -sf "$config_file" "/etc/nginx/sites-enabled/"
    
    log "Nginx站点配置创建完成: $config_file"
}

# 获取SSL证书
get_ssl_certificate() {
    local domain="$1"
    
    log "获取SSL证书..."
    
    # 创建Certbot目录
    sudo mkdir -p /var/www/certbot
    
    # 临时配置Nginx用于证书验证
    local temp_config="/tmp/nginx-certbot.conf"
    
    cat > "$temp_config" << EOF
server {
    listen 80;
    server_name ${domain} www.${domain};
    
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    
    location / {
        return 404;
    }
}
EOF
    
    # 使用临时配置获取证书
    if sudo certbot certonly --webroot \
        -w /var/www/certbot \
        -d "$domain" \
        -d "www.$domain" \
        --non-interactive \
        --agree-tos \
        --email "admin@$domain"; then
        log "SSL证书获取成功"
        return 0
    else
        log_warn "无法获取SSL证书，将继续使用HTTP"
        return 1
    fi
}

# 部署Odoo实例
deploy_odoo() {
    log "开始部署Odoo实例..."
    
    # 获取系统信息
    get_system_info
    
    # 输入域名
    read -p "输入域名（例如: example.com）: " domain
    
    if [[ -z "$domain" ]]; then
        log_error "域名不能为空"
        return 1
    fi
    
    # 生成实例名称
    instance_name=$(generate_instance_name "$domain")
    
    # 检查实例是否已存在
    if [ -d "$INSTANCES_BASE/$instance_name" ]; then
        log_warn "实例 '$instance_name' 已存在"
        read -p "是否要重新部署？这将删除现有数据！(y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log "取消部署"
            return 1
        fi
        # 停止并删除现有实例
        cd "$INSTANCES_BASE/$instance_name" 2>/dev/null && docker-compose down -v 2>/dev/null || true
        sudo rm -rf "$INSTANCES_BASE/$instance_name"
        
        # 删除Nginx配置
        sudo rm -f "/etc/nginx/sites-available/$instance_name"
        sudo rm -f "/etc/nginx/sites-enabled/$instance_name"
    fi
    
    # 选择Odoo镜像
    select_odoo_image
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # 检查端口
    default_port="8069"
    read -p "输入HTTP端口 [默认: $default_port]: " port
    port=${port:-$default_port}
    
    if ! check_port "$port"; then
        log_error "端口 $port 已被占用"
        read -p "是否自动分配可用端口？(Y/n): " auto_port
        if [[ "$auto_port" =~ ^[Nn]$ ]]; then
            return 1
        fi
        
        # 自动寻找可用端口
        for p in {8070..8100}; do
            if check_port "$p"; then
                port="$p"
                log "使用端口: $port"
                break
            fi
        done
    fi
    
    log "开始部署 Odoo 实例..."
    log "域名: $domain"
    log "实例名称: $instance_name"
    log "Odoo镜像: $ODOO_IMAGE"
    log "PostgreSQL镜像: $POSTGRES_IMAGE"
    log "端口: $port"
    log "实例目录: $INSTANCES_BASE/$instance_name"
    
    # 生成配置文件
    generate_docker_compose "$instance_name" "$domain" "$ODOO_IMAGE" "$POSTGRES_IMAGE" "$ODOO_VERSION" "$port"
    
    local instance_dir="$INSTANCES_BASE/$instance_name"
    
    # 获取SSL证书
    get_ssl_certificate "$domain"
    
    # 启动Docker容器
    log "启动Docker容器..."
    cd "$instance_dir"
    docker-compose up -d
    
    # 等待服务启动
    log "等待服务启动..."
    sleep 30
    
    # 初始化数据库
    log "初始化数据库..."
    "$instance_dir/init-db.sh"
    
    # 重启Nginx以应用配置
    log "重启Nginx..."
    sudo nginx -t && sudo systemctl restart nginx
    
    # 设置cron作业
    setup_cron_jobs "$instance_name"
    
    log "部署完成！"
    log "========================================="
    log "Odoo实例信息:"
    log "  访问地址: https://$domain"
    log "  管理员密码: 查看 $instance_dir/.env 文件"
    log "  实例目录: $instance_dir"
    log "  数据目录: $instance_dir/data"
    log "  备份目录: $instance_dir/backups"
    log "  日志目录: $instance_dir/logs"
    log "========================================="
    log ""
    log "管理命令:"
    log "  启动: cd $instance_dir && docker-compose start"
    log "  停止: cd $instance_dir && docker-compose stop"
    log "  重启: cd $instance_dir && docker-compose restart"
    log "  查看日志: cd $instance_dir && docker-compose logs -f"
    log "  备份数据库: $instance_dir/backup-db.sh"
    log ""
    log "重要: 首次登录后请立即修改管理员密码！"
}

# 设置cron作业
setup_cron_jobs() {
    local instance_name="$1"
    local instance_dir="$INSTANCES_BASE/$instance_name"
    
    # 添加数据库备份任务（每天凌晨2点）
    (crontab -l 2>/dev/null | grep -v "$instance_dir/backup-db.sh"; echo "0 2 * * * $instance_dir/backup-db.sh >> $instance_dir/logs/backup.log 2>&1") | crontab -
    
    # 添加日志清理任务（每周一凌晨3点）
    (crontab -l 2>/dev/null | grep -v "$instance_dir/clean-logs.sh"; echo "0 3 * * 1 $instance_dir/clean-logs.sh >> $instance_dir/logs/cleanup.log 2>&1") | crontab -
    
    # 添加SSL证书续期检查（每天中午12点）
    (crontab -l 2>/dev/null | grep -v "certbot renew"; echo "0 12 * * * sudo certbot renew --quiet --post-hook \"sudo systemctl reload nginx\" >> $instance_dir/logs/certbot.log 2>&1") | crontab -
    
    log "Cron作业设置完成"
}

# 备份实例
backup_instance() {
    log "备份Odoo实例..."
    
    # 查找所有实例
    local instances=($(ls -d $INSTANCES_BASE/*/ 2>/dev/null | xargs -n1 basename))
    
    if [ ${#instances[@]} -eq 0 ]; then
        log_error "未找到任何Odoo实例"
        return 1
    fi
    
    echo "可用的实例:"
    for i in "${!instances[@]}"; do
        echo "$((i+1))) ${instances[$i]}"
    done
    
    read -p "选择要备份的实例编号 [默认: 1]: " instance_choice
    instance_choice=${instance_choice:-1}
    local instance_index=$((instance_choice-1))
    
    if [ $instance_index -lt 0 ] || [ $instance_index -ge ${#instances[@]} ]; then
        log_error "无效选择"
        return 1
    fi
    
    local instance_name="${instances[$instance_index]}"
    local instance_dir="$INSTANCES_BASE/$instance_name"
    
    log "正在备份实例: $instance_name"
    
    # 创建备份目录
    local backup_timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_name="${instance_name}_${backup_timestamp}"
    local backup_path="$BACKUP_DIR/$backup_name"
    
    sudo mkdir -p "$backup_path"
    sudo chown $(whoami):$(whoami) "$backup_path"
    
    # 停止服务
    log "停止服务..."
    cd "$instance_dir"
    docker-compose stop
    
    # 备份数据库
    log "备份数据库..."
    docker-compose exec -T db pg_dump -U odoo "odoo_${instance_name}" | gzip > "$backup_path/database.sql.gz"
    
    # 备份文件存储
    log "备份文件存储..."
    tar -czf "$backup_path/filestore.tar.gz" -C "$instance_dir/data" .
    
    # 备份插件
    log "备份插件..."
    tar -czf "$backup_path/addons.tar.gz" -C "$instance_dir/addons" .
    
    # 备份配置文件
    log "备份配置文件..."
    cp -r "$instance_dir/config" "$backup_path/"
    cp "$instance_dir/docker-compose.yml" "$backup_path/"
    cp "$instance_dir/.env" "$backup_path/"
    
    # 备份Nginx配置
    if [ -f "/etc/nginx/sites-available/$instance_name" ]; then
        sudo cp "/etc/nginx/sites-available/$instance_name" "$backup_path/nginx-site.conf"
    fi
    
    # 启动服务
    log "启动服务..."
    docker-compose start
    
    # 创建恢复脚本
    cat > "$backup_path/restore.sh" << EOF
#!/bin/bash
# Odoo实例恢复脚本
# 实例: $instance_name
# 备份时间: $backup_timestamp

set -e

echo "正在恢复Odoo实例: $instance_name"
echo "备份时间: $backup_timestamp"

# 检查是否具有sudo权限
if ! sudo -n true 2>/dev/null; then
    echo "此脚本需要sudo权限"
    exit 1
fi

# 设置变量
BACKUP_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
INSTANCE_NAME="$instance_name"
INSTANCE_DIR="/opt/\$INSTANCE_NAME"

echo "恢复目录: \$INSTANCE_DIR"

# 停止现有实例（如果存在）
if [ -d "\$INSTANCE_DIR" ]; then
    echo "停止现有实例..."
    cd "\$INSTANCE_DIR" && docker-compose down -v 2>/dev/null || true
fi

# 创建目录
echo "创建目录..."
mkdir -p "\$INSTANCE_DIR/addons"
mkdir -p "\$INSTANCE_DIR/config"
mkdir -p "\$INSTANCE_DIR/data"
mkdir -p "\$INSTANCE_DIR/postgres_data"
mkdir -p "\$INSTANCE_DIR/backups"
mkdir -p "\$INSTANCE_DIR/logs"
mkdir -p "\$INSTANCE_DIR/fonts"

# 恢复文件
echo "恢复文件..."
tar -xzf "\$BACKUP_DIR/filestore.tar.gz" -C "\$INSTANCE_DIR/data"
tar -xzf "\$BACKUP_DIR/addons.tar.gz" -C "\$INSTANCE_DIR/addons"
cp -r "\$BACKUP_DIR/config" "\$INSTANCE_DIR/"
cp "\$BACKUP_DIR/docker-compose.yml" "\$INSTANCE_DIR/"
cp "\$BACKUP_DIR/.env" "\$INSTANCE_DIR/"

# 恢复Nginx配置
if [ -f "\$BACKUP_DIR/nginx-site.conf" ]; then
    echo "恢复Nginx配置..."
    sudo cp "\$BACKUP_DIR/nginx-site.conf" "/etc/nginx/sites-available/\$INSTANCE_NAME"
    sudo ln -sf "/etc/nginx/sites-available/\$INSTANCE_NAME" "/etc/nginx/sites-enabled/"
fi

# 恢复数据库
echo "恢复数据库..."
cd "\$INSTANCE_DIR"
docker-compose up -d db
sleep 10
gunzip -c "\$BACKUP_DIR/database.sql.gz" | docker-compose exec -T db psql -U odoo

# 启动所有服务
echo "启动所有服务..."
docker-compose up -d

# 重启Nginx
sudo systemctl restart nginx

# 设置权限
CURRENT_USER=\$(whoami)
sudo chown -R \$CURRENT_USER:\$CURRENT_USER "\$INSTANCE_DIR"
sudo chown -R 999:999 "\$INSTANCE_DIR/postgres_data"

echo ""
echo "恢复完成！"
echo "实例信息:"
echo "  目录: \$INSTANCE_DIR"
echo "  启动命令: cd \$INSTANCE_DIR && docker-compose up -d"
echo "  查看日志: cd \$INSTANCE_DIR && docker-compose logs -f"
echo ""
echo "注意: 请检查 \$INSTANCE_DIR/.env 文件中的配置"
EOF
    
    chmod +x "$backup_path/restore.sh"
    
    # 创建压缩备份包
    log "创建压缩备份包..."
    cd "$BACKUP_DIR"
    tar -czf "${backup_name}.tar.gz" "$backup_name"
    sudo rm -rf "$backup_path"
    
    log "备份完成！"
    log "备份文件: $BACKUP_DIR/${backup_name}.tar.gz"
    log "大小: $(du -h "$BACKUP_DIR/${backup_name}.tar.gz" | cut -f1)"
}

# 恢复实例
restore_instance() {
    log "恢复Odoo实例..."
    
    # 列出备份文件
    local backups=($(ls -1t "$BACKUP_DIR"/*.tar.gz 2>/dev/null))
    
    if [ ${#backups[@]} -eq 0 ]; then
        log_error "未找到备份文件"
        return 1
    fi
    
    echo "可用的备份:"
    for i in "${!backups[@]}"; do
        local backup_name=$(basename "${backups[$i]}" .tar.gz)
        local backup_date=$(echo "$backup_name" | grep -o '[0-9]\{8\}_[0-9]\{6\}')
        local readable_date=$(echo "$backup_date" | sed 's/\(....\)\(..\)\(..\)_\(..\)\(..\)\(..\)/\1年\2月\3日 \4时\5分\6秒/')
        echo "$((i+1))) $backup_name ($readable_date)"
    done
    
    read -p "选择要恢复的备份编号 [默认: 1]: " backup_choice
    backup_choice=${backup_choice:-1}
    local backup_index=$((backup_choice-1))
    
    if [ $backup_index -lt 0 ] || [ $backup_index -ge ${#backups[@]} ]; then
        log_error "无效选择"
        return 1
    fi
    
    local backup_file="${backups[$backup_index]}"
    local backup_name=$(basename "$backup_file" .tar.gz)
    local temp_dir="/tmp/odoo_restore_$(date '+%Y%m%d_%H%M%S')"
    
    log "正在恢复备份: $backup_name"
    
    # 解压备份
    mkdir -p "$temp_dir"
    tar -xzf "$backup_file" -C "$temp_dir"
    
    # 查找恢复脚本
    local restore_script=$(find "$temp_dir" -name "restore.sh" -type f | head -1)
    
    if [ ! -f "$restore_script" ]; then
        log_error "未找到恢复脚本"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # 运行恢复脚本
    log "运行恢复脚本..."
    chmod +x "$restore_script"
    "$restore_script"
    
    # 清理临时文件
    rm -rf "$temp_dir"
    
    log "恢复完成！"
    log "请检查实例配置并启动服务"
}

# 查看日志
view_logs() {
    log "查看Odoo日志..."
    
    # 查找所有实例
    local instances=($(ls -d $INSTANCES_BASE/*/ 2>/dev/null | xargs -n1 basename))
    
    if [ ${#instances[@]} -eq 0 ]; then
        log_error "未找到任何Odoo实例"
        return 1
    fi
    
    echo "可用的实例:"
    for i in "${!instances[@]}"; do
        echo "$((i+1))) ${instances[$i]}"
    done
    
    read -p "选择实例编号 [默认: 1]: " instance_choice
    instance_choice=${instance_choice:-1}
    local instance_index=$((instance_choice-1))
    
    if [ $instance_index -lt 0 ] || [ $instance_index -ge ${#instances[@]} ]; then
        log_error "无效选择"
        return 1
    fi
    
    local instance_name="${instances[$instance_index]}"
    local instance_dir="$INSTANCES_BASE/$instance_name"
    
    echo "选择日志类型:"
    echo "1) Odoo应用日志"
    echo "2) PostgreSQL数据库日志"
    echo "3) Nginx访问日志"
    echo "4) Nginx错误日志"
    echo "5) 所有日志（实时跟踪）"
    read -p "选择 (1-5) [默认: 1]: " log_choice
    log_choice=${log_choice:-1}
    
    cd "$instance_dir"
    
    case $log_choice in
        1)
            docker-compose logs -f odoo
            ;;
        2)
            docker-compose logs -f db
            ;;
        3)
            sudo tail -f "/var/log/nginx/${instance_name}-ssl-access.log"
            ;;
        4)
            sudo tail -f "/var/log/nginx/${instance_name}-ssl-error.log"
            ;;
        5)
            docker-compose logs -f
            ;;
        *)
            log_error "无效选择"
            return 1
            ;;
    esac
}

# 分析日志
analyze_logs() {
    log "分析Odoo日志..."
    
    # 查找所有实例
    local instances=($(ls -d $INSTANCES_BASE/*/ 2>/dev/null | xargs -n1 basename))
    
    if [ ${#instances[@]} -eq 0 ]; then
        log_error "未找到任何Odoo实例"
        return 1
    fi
    
    echo "可用的实例:"
    for i in "${!instances[@]}"; do
        echo "$((i+1))) ${instances[$i]}"
    done
    
    read -p "选择实例编号 [默认: 1]: " instance_choice
    instance_choice=${instance_choice:-1}
    local instance_index=$((instance_choice-1))
    
    if [ $instance_index -lt 0 ] || [ $instance_index -ge ${#instances[@]} ]; then
        log_error "无效选择"
        return 1
    fi
    
    local instance_name="${instances[$instance_index]}"
    local instance_dir="$INSTANCES_BASE/$instance_name"
    
    echo "选择分析类型:"
    echo "1) 错误和警告统计"
    echo "2) 慢请求分析"
    echo "3) 数据库查询分析"
    echo "4) 内存使用分析"
    echo "5) 访问量统计"
    read -p "选择 (1-5) [默认: 1]: " analysis_choice
    analysis_choice=${analysis_choice:-1}
    
    case $analysis_choice in
        1)
            echo "=== 错误和警告统计 ==="
            echo ""
            echo "最近24小时的错误:"
            docker-compose logs --since 24h odoo 2>/dev/null | grep -i "error\|exception\|traceback" | tail -20
            
            echo ""
            echo "最近24小时的警告:"
            docker-compose logs --since 24h odoo 2>/dev/null | grep -i "warning" | tail -20
            ;;
        2)
            echo "=== 慢请求分析 ==="
            echo ""
            echo "处理时间超过2秒的请求:"
            docker-compose logs --since 24h odoo 2>/dev/null | grep "INFO.*req.*RUN.*time=" | awk -F'time=' '{print $2}' | awk '{if($1>2000) print $1 "ms"}' | sort -n | tail -20
            ;;
        3)
            echo "=== 数据库查询分析 ==="
            echo ""
            echo "最耗时的SQL查询:"
            docker-compose exec db psql -U odoo -d "odoo_${instance_name}" -c "
                SELECT query, calls, total_time, mean_time,
                       rows, 100.0 * shared_blks_hit / nullif(shared_blks_hit + shared_blks_read, 0) AS hit_percent
                FROM pg_stat_statements 
                ORDER BY total_time DESC 
                LIMIT 10;
            " 2>/dev/null || echo "需要启用pg_stat_statements扩展"
            ;;
        4)
            echo "=== 内存使用分析 ==="
            echo ""
            echo "容器内存使用:"
            docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" $(docker-compose ps -q)
            
            echo ""
            echo "系统内存使用:"
            free -h
            ;;
        5)
            echo "=== 访问量统计 ==="
            echo ""
            echo "最近1小时的访问统计:"
            if [ -f "/var/log/nginx/${instance_name}-ssl-access.log" ]; then
                sudo awk -vDate="$(date -d'1 hour ago' '+[%d/%b/%Y:%H:%M:%S')" '$4 > Date {print $1}' "/var/log/nginx/${instance_name}-ssl-access.log" | sort | uniq -c | sort -rn | head -10 | awk '{print $2 " - " $1 " 次访问"}'
            else
                echo "访问日志文件不存在"
            fi
            ;;
        *)
            log_error "无效选择"
            return 1
            ;;
    esac
}

# 启动实例
start_instance() {
    log "启动Odoo实例..."
    
    # 查找所有实例
    local instances=($(ls -d $INSTANCES_BASE/*/ 2>/dev/null | xargs -n1 basename))
    
    if [ ${#instances[@]} -eq 0 ]; then
        log_error "未找到任何Odoo实例"
        return 1
    fi
    
    echo "可用的实例:"
    for i in "${!instances[@]}"; do
        echo "$((i+1))) ${instances[$i]}"
    done
    
    read -p "选择实例编号 [默认: 1]: " instance_choice
    instance_choice=${instance_choice:-1}
    local instance_index=$((instance_choice-1))
    
    if [ $instance_index -lt 0 ] || [ $instance_index -ge ${#instances[@]} ]; then
        log_error "无效选择"
        return 1
    fi
    
    local instance_name="${instances[$instance_index]}"
    local instance_dir="$INSTANCES_BASE/$instance_name"
    
    log "启动实例: $instance_name"
    cd "$instance_dir"
    docker-compose start
    
    log "实例 $instance_name 已启动"
}

# 停止实例
stop_instance() {
    log "停止Odoo实例..."
    
    # 查找所有实例
    local instances=($(ls -d $INSTANCES_BASE/*/ 2>/dev/null | xargs -n1 basename))
    
    if [ ${#instances[@]} -eq 0 ]; then
        log_error "未找到任何Odoo实例"
        return 1
    fi
    
    echo "可用的实例:"
    for i in "${!instances[@]}"; do
        echo "$((i+1))) ${instances[$i]}"
    done
    
    read -p "选择实例编号 [默认: 1]: " instance_choice
    instance_choice=${instance_choice:-1}
    local instance_index=$((instance_choice-1))
    
    if [ $instance_index -lt 0 ] || [ $instance_index -ge ${#instances[@]} ]; then
        log_error "无效选择"
        return 1
    fi
    
    local instance_name="${instances[$instance_index]}"
    local instance_dir="$INSTANCES_BASE/$instance_name"
    
    log "停止实例: $instance_name"
    cd "$instance_dir"
    docker-compose stop
    
    log "实例 $instance_name 已停止"
}

# 重启实例
restart_instance() {
    log "重启Odoo实例..."
    
    # 查找所有实例
    local instances=($(ls -d $INSTANCES_BASE/*/ 2>/dev/null | xargs -n1 basename))
    
    if [ ${#instances[@]} -eq 0 ]; then
        log_error "未找到任何Odoo实例"
        return 1
    fi
    
    echo "可用的实例:"
    for i in "${!instances[@]}"; do
        echo "$((i+1))) ${instances[$i]}"
    done
    
    read -p "选择实例编号 [默认: 1]: " instance_choice
    instance_choice=${instance_choice:-1}
    local instance_index=$((instance_choice-1))
    
    if [ $instance_index -lt 0 ] || [ $instance_index -ge ${#instances[@]} ]; then
        log_error "无效选择"
        return 1
    fi
    
    local instance_name="${instances[$instance_index]}"
    local instance_dir="$INSTANCES_BASE/$instance_name"
    
    log "重启实例: $instance_name"
    cd "$instance_dir"
    docker-compose restart
    
    log "实例 $instance_name 已重启"
}

# 删除实例
delete_instance() {
    log "删除Odoo实例..."
    
    # 查找所有实例
    local instances=($(ls -d $INSTANCES_BASE/*/ 2>/dev/null | xargs -n1 basename))
    
    if [ ${#instances[@]} -eq 0 ]; then
        log_error "未找到任何Odoo实例"
        return 1
    fi
    
    echo "可用的实例:"
    for i in "${!instances[@]}"; do
        echo "$((i+1))) ${instances[$i]}"
    done
    
    read -p "选择实例编号: " instance_choice
    local instance_index=$((instance_choice-1))
    
    if [ $instance_index -lt 0 ] || [ $instance_index -ge ${#instances[@]} ]; then
        log_error "无效选择"
        return 1
    fi
    
    local instance_name="${instances[$instance_index]}"
    local instance_dir="$INSTANCES_BASE/$instance_name"
    
    read -p "确定要删除实例 '$instance_name' 吗？这将删除所有数据！(输入 'yes' 确认): " confirm
    
    if [ "$confirm" != "yes" ]; then
        log "取消删除"
        return
    fi
    
    log "删除实例: $instance_name"
    
    # 停止并删除容器
    cd "$instance_dir"
    docker-compose down -v 2>/dev/null || true
    
    # 删除目录
    sudo rm -rf "$instance_dir"
    
    # 删除Nginx配置
    sudo rm -f "/etc/nginx/sites-available/$instance_name"
    sudo rm -f "/etc/nginx/sites-enabled/$instance_name"
    
    # 删除cron作业
    crontab -l 2>/dev/null | grep -v "$instance_dir" | crontab -
    
    # 重启Nginx
    sudo systemctl reload nginx
    
    log "实例 $instance_name 已删除"
}

# 系统监控
system_monitor() {
    log "系统监控信息:"
    echo ""
    echo "========================================="
    echo "1. 系统资源使用:"
    echo "-----------------------------------------"
    echo "CPU使用率:"
    top -bn1 | grep "Cpu(s)" | awk '{print "  用户: " $2 "%", "系统: " $4 "%", "空闲: " $8 "%"}'
    
    echo ""
    echo "内存使用:"
    free -h | awk 'NR==1{print "         总量     已用     空闲     共享  缓冲/缓存  可用"}
                   NR==2{printf "内存: %6s %6s %6s %6s %6s %6s\n", $2, $3, $4, $5, $6, $7}'
    
    echo ""
    echo "磁盘使用:"
    df -h / | awk 'NR==1{print "文件系统   容量  已用  可用 使用% 挂载点"}
                   NR==2{print $1, $2, $3, $4, $5, $6}'
    
    echo ""
    echo "2. Docker容器状态:"
    echo "-----------------------------------------"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | head -20
    
    echo ""
    echo "3. Odoo实例状态:"
    echo "-----------------------------------------"
    local instances=($(ls -d $INSTANCES_BASE/*/ 2>/dev/null | xargs -n1 basename))
    if [ ${#instances[@]} -gt 0 ]; then
        for instance in "${instances[@]}"; do
            local instance_dir="$INSTANCES_BASE/$instance"
            if [ -f "$instance_dir/docker-compose.yml" ]; then
                cd "$instance_dir"
                echo "实例: $instance"
                docker-compose ps --services | while read service; do
                    status=$(docker-compose ps $service | tail -1)
                    echo "  $service: $status"
                done
                echo ""
            fi
        done
    else
        echo "未找到Odoo实例"
    fi
    
    echo "4. 网络连接:"
    echo "-----------------------------------------"
    echo "监听端口:"
    sudo ss -tuln | grep LISTEN | awk '{print "  " $5 " -> " $1}' | head -10
    
    echo ""
    echo "5. 最近错误日志:"
    echo "-----------------------------------------"
    tail -5 "$LOG_DIR/odoo-manager.log" | grep -i "error\|warning" || echo "  无错误或警告"
    
    echo "========================================="
}

# 优化检查
optimization_check() {
    log "系统优化检查..."
    echo ""
    
    echo "1. 系统参数检查:"
    echo "-----------------------------------------"
    local sysctl_params=("vm.swappiness" "vm.vfs_cache_pressure" "net.core.somaxconn")
    for param in "${sysctl_params[@]}"; do
        value=$(sudo sysctl -n $param 2>/dev/null || echo "未设置")
        echo "  $param = $value"
    done
    
    echo ""
    echo "2. Docker配置检查:"
    echo "-----------------------------------------"
    if [ -f "/etc/docker/daemon.json" ]; then
        echo "  Docker配置文件存在"
        docker info 2>/dev/null | grep -i "storage\|log" | head -5
    else
        echo "  Docker配置文件不存在"
    fi
    
    echo ""
    echo "3. 字体安装检查:"
    echo "-----------------------------------------"
    local fonts=("wqy-zenhei" "wqy-microhei" "noto-cjk")
    for font in "${fonts[@]}"; do
        if fc-list | grep -i "$font" >/dev/null; then
            echo "  $font: 已安装"
        else
            echo "  $font: 未安装"
        fi
    done
    
    echo ""
    echo "4. 服务状态检查:"
    echo "-----------------------------------------"
    local services=("docker" "nginx")
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service"; then
            echo "  $service: 运行中"
        else
            echo "  $service: 未运行"
        fi
    done
    
    echo ""
    echo "5. 证书状态检查:"
    echo "-----------------------------------------"
    local instances=($(ls -d $INSTANCES_BASE/*/ 2>/dev/null | xargs -n1 basename))
    for instance in "${instances[@]}"; do
        if [ -f "$INSTANCES_BASE/$instance/.env" ]; then
            domain=$(grep "DOMAIN=" "$INSTANCES_BASE/$instance/.env" 2>/dev/null | cut -d'=' -f2)
            if [ -n "$domain" ] && [ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]; then
                expiry=$(sudo openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$domain/fullchain.pem" | cut -d'=' -f2)
                echo "  $instance ($domain): 证书有效至 $expiry"
            fi
        fi
    done
}

# 显示菜单
show_menu() {
    clear
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}      Odoo VPS 管理脚本 v4.0${NC}"
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${GREEN}1) 初始化环境${NC}"
    echo -e "${GREEN}2) 部署Odoo实例${NC}"
    echo -e "${YELLOW}3) 备份实例${NC}"
    echo -e "${YELLOW}4) 恢复实例${NC}"
    echo -e "${CYAN}5) 查看日志${NC}"
    echo -e "${CYAN}6) 分析日志${NC}"
    echo -e "${PURPLE}7) 启动实例${NC}"
    echo -e "${PURPLE}8) 停止实例${NC}"
    echo -e "${PURPLE}9) 重启实例${NC}"
    echo -e "${RED}10) 删除实例${NC}"
    echo -e "${BLUE}11) 系统监控${NC}"
    echo -e "${BLUE}12) 优化检查${NC}"
    echo -e "${RED}13) 退出${NC}"
    echo -e "${BLUE}=========================================${NC}"
    
    local instances=($(ls -d $INSTANCES_BASE/*/ 2>/dev/null | xargs -n1 basename))
    if [ ${#instances[@]} -gt 0 ]; then
        echo -e "${GREEN}当前实例:${NC}"
        for instance in "${instances[@]}"; do
            echo "  - $instance"
        done
    else
        echo -e "${YELLOW}暂无Odoo实例${NC}"
    fi
    echo -e "${BLUE}=========================================${NC}"
}

# 快速部署函数（只需要域名）
quick_deploy() {
    local domain="$1"
    
    if [[ -z "$domain" ]]; then
        log_error "域名不能为空"
        return 1
    fi
    
    log "快速部署 Odoo 实例: $domain"
    
    # 检查是否已初始化
    if [ ! -f "$CONFIG_DIR/initialized" ]; then
        log "系统未初始化，正在初始化..."
        init_environment
        sudo touch "$CONFIG_DIR/initialized"
    fi
    
    # 获取系统信息
    get_system_info
    
    # 生成实例名称
    instance_name=$(generate_instance_name "$domain")
    
    # 检查实例是否已存在
    if [ -d "$INSTANCES_BASE/$instance_name" ]; then
        log_error "实例 '$instance_name' 已存在"
        return 1
    fi
    
    # 使用默认Odoo 17镜像
    ODOO_IMAGE="odoo:17.0"
    POSTGRES_IMAGE="postgres:15"
    ODOO_VERSION="17.0"
    
    # 自动分配端口
    for port in {8069..8100}; do
        if check_port "$port"; then
            break
        fi
    done
    
    log "使用配置:"
    log "  域名: $domain"
    log "  实例名称: $instance_name"
    log "  Odoo镜像: $ODOO_IMAGE"
    log "  PostgreSQL镜像: $POSTGRES_IMAGE"
    log "  端口: $port"
    
    # 生成配置文件
    generate_docker_compose "$instance_name" "$domain" "$ODOO_IMAGE" "$POSTGRES_IMAGE" "$ODOO_VERSION" "$port"
    
    local instance_dir="$INSTANCES_BASE/$instance_name"
    
    # 获取SSL证书
    get_ssl_certificate "$domain"
    
    # 启动Docker容器
    cd "$instance_dir"
    docker-compose up -d
    
    # 等待服务启动
    sleep 30
    
    # 初始化数据库
    "$instance_dir/init-db.sh"
    
    # 重启Nginx
    sudo nginx -t && sudo systemctl restart nginx
    
    # 设置cron作业
    setup_cron_jobs "$instance_name"
    
    log "快速部署完成！"
    log "访问地址: https://$domain"
    log "管理员密码: 查看 $instance_dir/.env 文件"
}

# 主函数
main() {
    # 检查sudo权限
    check_sudo
    
    # 确保日志目录存在
    sudo mkdir -p "$LOG_DIR"
    sudo chown $(whoami):$(whoami) "$LOG_DIR" 2>/dev/null || true
    
    # 处理命令行参数
    if [ $# -ge 1 ]; then
        case "$1" in
            "init")
                init_environment
                sudo touch "$CONFIG_DIR/initialized"
                exit 0
                ;;
            "deploy")
                if [ $# -ge 2 ]; then
                    quick_deploy "$2"
                else
                    deploy_odoo
                fi
                exit 0
                ;;
            "backup")
                backup_instance
                exit 0
                ;;
            "restore")
                restore_instance
                exit 0
                ;;
            "logs")
                view_logs
                exit 0
                ;;
            "analyze")
                analyze_logs
                exit 0
                ;;
            "start")
                start_instance
                exit 0
                ;;
            "stop")
                stop_instance
                exit 0
                ;;
            "restart")
                restart_instance
                exit 0
                ;;
            "delete")
                delete_instance
                exit 0
                ;;
            "monitor")
                system_monitor
                exit 0
                ;;
            "optimize")
                optimization_check
                exit 0
                ;;
            "help"|"--help"|"-h")
                echo "用法: $0 [命令] [参数]"
                echo ""
                echo "命令:"
                echo "  init                  初始化环境"
                echo "  deploy [域名]         部署Odoo实例（可指定域名快速部署）"
                echo "  backup                备份实例"
                echo "  restore               恢复实例"
                echo "  logs                  查看日志"
                echo "  analyze               分析日志"
                echo "  start                 启动实例"
                echo "  stop                  停止实例"
                echo "  restart               重启实例"
                echo "  delete                删除实例"
                echo "  monitor               系统监控"
                echo "  optimize              优化检查"
                echo "  help                  显示帮助"
                echo ""
                echo "示例:"
                echo "  $0 init               初始化环境"
                echo "  $0 deploy example.com 快速部署example.com"
                echo "  $0 deploy             交互式部署"
                echo ""
                echo "注意: 脚本需要sudo权限，建议使用sudo用户运行"
                echo "      避免直接使用root用户，以增强安全性"
                exit 0
                ;;
        esac
    fi
    
    # 主循环（交互式菜单）
    while true; do
        show_menu
        echo ""
        read -p "请选择操作 (1-13): " choice
        
        case $choice in
            1)
                init_environment
                sudo touch "$CONFIG_DIR/initialized"
                ;;
            2)
                deploy_odoo
                ;;
            3)
                backup_instance
                ;;
            4)
                restore_instance
                ;;
            5)
                view_logs
                ;;
            6)
                analyze_logs
                ;;
            7)
                start_instance
                ;;
            8)
                stop_instance
                ;;
            9)
                restart_instance
                ;;
            10)
                delete_instance
                ;;
            11)
                system_monitor
                ;;
            12)
                optimization_check
                ;;
            13)
                log "退出脚本"
                exit 0
                ;;
            *)
                log_error "无效选择，请重新输入"
                ;;
        esac
        
        echo ""
        read -p "按回车键继续..."
    done
}

# 运行主函数
main "$@"