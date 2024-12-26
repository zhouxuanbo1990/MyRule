#!/bin/sh

#################################################
# 描述: OpenWrt sing-box Tun模式 配置脚本
# 版本: 1.0.0
# 作者: Youtube: 七尺宇
# 用途: 配置和启动 sing-box Tun模式 代理服务
#################################################

# 配置参数
BACKEND_URL="http://192.168.2.1:5000"  # 转换后端地址
SUBSCRIPTION_URL=""  # 订阅地址
TEMPLATE_URL=""  # 配置文件（规则模板)
MAX_RETRIES=3  # 最大重试次数
RETRY_DELAY=3  # 重试间隔时间（秒）
CONFIG_FILE="/etc/sing-box/config.json"
CONFIG_BACKUP="/etc/sing-box/configbackup.json"

# 默认日志文件路径
LOG_FILE="${LOG_FILE:-/var/log/sing-box-config.log}"

# 重定向输出到日志文件
exec > >(tee -a "$LOG_FILE") 2>&1

# 获取当前时间
timestamp() {
    date +"%Y-%m-%d %H:%M:%S"
}

# 错误处理函数
error_exit() {
    echo "$(timestamp) 错误: $1" >&2
    exit "${2:-1}"
}

# 捕获中断信号以进行清理
trap 'error_exit "脚本被中断"' INT TERM

# 检查命令是否存在
check_command() {
    local cmd=$1
    if ! command -v "$cmd" >/dev/null 2>&1; then
        error_exit "$cmd 未安装，请安装后再运行此脚本"
    fi
}

# 停止 sing-box 服务
stop_sing_box() {
    if killall sing-box 2>/dev/null; then
        echo "$(timestamp) 已停止现有 sing-box 服务"
    else
        echo "$(timestamp) 没有运行中的 sing-box 服务"
    fi
}

# 清理缓存
clear_cache() {
    if [ -f "/etc/sing-box/cache.db" ]; then
        rm -f /etc/sing-box/cache.db
    fi
}

# 检查网络连接
check_network() {
    local ping_count=3
    local test_host="223.5.5.5"
    
    echo "$(timestamp) 检查网络连接..."
    if ! ping -c $ping_count $test_host >/dev/null 2>&1; then
        error_exit "网络连接失败，请检查网络设置"
    fi
}

# 下载配置文件
download_config() {
    local retry=0
    local url="$1"
    local output_file="$2"
    
    while [ $retry -lt $MAX_RETRIES ]; do
        if curl -L --connect-timeout 10 --max-time 30 -v "$url" -o "$output_file"; then
            echo "$(timestamp) 配置文件下载成功"
            return 0
        fi
        retry=$((retry + 1))
        echo "$(timestamp) 下载失败，第 $retry 次重试..."
        sleep $RETRY_DELAY
    done
    return 1
}

# 备份配置文件
backup_config() {
    local config_file="$1"
    local backup_file="$2"
    
    if [ -f "$config_file" ]; then
        cp "$config_file" "$backup_file"
        echo "$(timestamp) 已备份当前配置"
    fi
}

# 还原配置文件
restore_config() {
    local backup_file="$1"
    local config_file="$2"
    
    if [ -f "$backup_file" ]; then
        cp "$backup_file" "$config_file"
        echo "$(timestamp) 已还原至备份配置"
    fi
}

# 启动 sing-box 服务
start_sing_box() {
    local config_file="$1"
    echo "$(timestamp) 启动 sing-box 服务..."
    sing-box run -c "$config_file" >/dev/null 2>&1 &

    # 检查服务状态
    sleep 2
    if pgrep -x "sing-box" > /dev/null; then
        echo "$(timestamp) sing-box 启动成功"
    else
        error_exit "sing-box 启动失败，请检查日志"
    fi
}

# 检查是否以 root 权限运行
if [ "$(id -u)" != "0" ]; then
    error_exit "此脚本需要 root 权限运行"
fi

# 检查必要命令是否安装
check_command "sing-box"
check_command "curl"
check_command "nft"
check_command "ip"
check_command "ping"
check_command "netstat"

# 检查网络连接
check_network

# 创建配置目录
mkdir -p /etc/sing-box

# 备份当前配置
backup_config "$CONFIG_FILE" "$CONFIG_BACKUP"

# 下载新配置
echo "$(timestamp) 开始下载配置文件..."
FULL_URL="${BACKEND_URL}/config/${SUBSCRIPTION_URL}&file=${TEMPLATE_URL}"

if ! download_config "$FULL_URL" "$CONFIG_FILE"; then
    error_exit "配置文件下载失败，已重试 $MAX_RETRIES 次"
fi

# 停止 sing-box 服务
stop_sing_box

# 验证配置
if ! sing-box check -c "$CONFIG_FILE"; then
    echo "$(timestamp) 配置文件验证失败，正在还原备份"
    restore_config "$CONFIG_BACKUP" "$CONFIG_FILE"

    # 恢复配置后验证
    if ! sing-box check -c "$CONFIG_FILE"; then
        error_exit "配置验证失败，恢复后配置依然无效"
    fi
    echo "$(timestamp) 配置验证通过，重新启动 sing-box 服务..."
fi

# 启动 sing-box 服务，使用恢复后的配置
start_sing_box "$CONFIG_FILE"
