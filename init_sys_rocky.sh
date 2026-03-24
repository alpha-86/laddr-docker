#!/bin/bash
set -e

# 检查是否为root用户
if [[ $EUID -ne 0 ]]; then
   echo "此脚本需要root权限运行"
   exit 1
fi

#添加 work组
if ! getent group work > /dev/null 2>&1; then
    groupadd work
    echo "work组已创建"
else
    echo "work组已存在，跳过"
fi

#添加work用户
if ! id work > /dev/null 2>&1; then
    useradd -g work work -m -s /bin/bash
    echo "work用户已创建"
else
    echo "work用户已存在，跳过"
fi

#修改密码 - 由用户在终端输入
read -s -p "请为work用户设置密码: " work_password
echo
if [[ -z "$work_password" ]]; then
    echo "密码不能为空，退出"
    exit 1
fi
echo work:$work_password | chpasswd
echo "密码已设置"

#修改主机名 - 由用户在终端输入
read -p "请输入主机名: " host_name
if [[ -z "$host_name" ]]; then
    echo "主机名不能为空，退出"
    exit 1
fi
hostnamectl set-hostname $host_name --static
echo "主机名已设置为: $host_name"
hostnamectl

#rocky install tools
dnf check-update
dnf install -y dnf-utils epel-release
dnf install -y wget vim zip unzip tar net-tools git firewalld

#rocky install docker
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io

#rocky only - SSH key配置
mkdir -p /home/work/.ssh/
if [[ -f ~/.ssh/authorized_keys ]]; then
    cp ~/.ssh/authorized_keys /home/work/.ssh/
    chown -R work:work /home/work/.ssh
    chmod 700 /home/work/.ssh
    chmod 600 /home/work/.ssh/authorized_keys
    echo "SSH公钥已配置"
else
    echo "警告: ~/.ssh/authorized_keys 不存在，跳过SSH公钥配置"
fi

systemctl start docker
systemctl status docker
systemctl enable docker
usermod -aG docker work

#修改sshd配置 - 检查配置项是否存在（包括注释行）
SSHD_CONFIG="/etc/ssh/sshd_config"

# 配置项修改函数
# 用法: sshd_config_set "配置项名称" "配置值" [追加的值]
# 会处理：未注释的配置、注释的配置（取消注释）、不存在的配置（添加）
sshd_config_set() {
    local key="$1"
    local value="$2"
    local append_value="$3"

    # 检查是否有未注释的配置行（如 "PasswordAuthentication yes"）
    if grep -qE "^[^#]*\s*${key}\s+" "$SSHD_CONFIG" 2>/dev/null; then
        # 取消注释并修改值
        sed -i "s/^[^#]*\s*\(${key}\s\+.*\)/\1/" "$SSHD_CONFIG"
        sed -i "s/^\s*${key}\s\+.*/${key} ${value}/" "$SSHD_CONFIG"
        echo "${key} 已修改为 ${value}"
    # 检查是否有注释的配置行（如 "#PasswordAuthentication yes"）
    elif grep -qE "^\s*#\s*${key}\s+" "$SSHD_CONFIG" 2>/dev/null; then
        # 取消注释并修改值
        sed -i "s/^\s*#\s*\(${key}\s\+.*\)/\1/" "$SSHD_CONFIG"
        sed -i "s/^\s*${key}\s\+.*/${key} ${value}/" "$SSHD_CONFIG"
        echo "${key} 已取消注释并修改为 ${value}"
    # 检查是否有裸关键字无值（如 "PasswordAuthentication" 单独一行）
    elif grep -qE "^${key}\s*$" "$SSHD_CONFIG" 2>/dev/null; then
        sed -i "s/^${key}\s*$/${key} ${value}/" "$SSHD_CONFIG"
        echo "${key} 已设置值为 ${value}"
    else
        # 配置项不存在，添加新行
        if [[ -n "$append_value" ]]; then
            echo "${key} ${append_value}" >> "$SSHD_CONFIG"
            echo "${key} ${append_value} 已添加"
        else
            echo "${key} ${value}" >> "$SSHD_CONFIG"
            echo "${key} ${value} 已添加"
        fi
    fi
}

# PermitRootLogin
sshd_config_set "PermitRootLogin" "no"

# PasswordAuthentication
sshd_config_set "PasswordAuthentication" "no"

# AllowUsers - 特殊处理（列表性质，需要追加）
# 检查未注释的 AllowUsers 行
if grep -qE "^[^#]*\s*AllowUsers\s+" "$SSHD_CONFIG" 2>/dev/null; then
    # 检查是否已包含work用户
    if grep -E "^[^#]*\s*AllowUsers\s+" "$SSHD_CONFIG" | grep -qw "work"; then
        echo "AllowUsers 中已包含 work 用户，跳过"
    else
        # 在现有 AllowUsers 行追加 work
        sed -i 's/^\([^#]*\s*AllowUsers\s\+.*\)/\1 work/' "$SSHD_CONFIG"
        echo "AllowUsers 已追加 work 用户"
    fi
# 检查注释的 AllowUsers 行
elif grep -qE "^\s*#\s*AllowUsers\s+" "$SSHD_CONFIG" 2>/dev/null; then
    # 取消注释并添加 work
    sed -i 's/^\s*#\s*\(AllowUsers\s\+.*\)/\1/' "$SSHD_CONFIG"
    sed -i 's/^\s*AllowUsers\s\+.*/AllowUsers work/' "$SSHD_CONFIG"
    echo "AllowUsers 已取消注释并设置为 work"
# 检查裸关键字 AllowUsers
elif grep -qE "^AllowUsers\s*$" "$SSHD_CONFIG" 2>/dev/null; then
    sed -i 's/^AllowUsers\s*$/AllowUsers work/' "$SSHD_CONFIG"
    echo "AllowUsers 已设置为 work"
else
    echo "AllowUsers work" >> "$SSHD_CONFIG"
    echo "AllowUsers work 已添加"
fi

#sudoers - 检查配置是否已存在
if ! grep -q "^work\s\+ALL=(ALL)" /etc/sudoers; then
    echo "work	ALL=(ALL) 	ALL" >> /etc/sudoers
    echo "sudoers: work用户已添加ALL权限"
else
    echo "sudoers: work用户ALL权限已存在，跳过"
fi

if ! grep -q "^work\s\+ALL=(ALL)\s*NOPASSWD:\s*/usr/bin/dnf" /etc/sudoers; then
    echo "work	ALL=(ALL) NOPASSWD: /usr/bin/dnf" >> /etc/sudoers
    echo "sudoers: work用户已添加dnf免密权限"
else
    echo "sudoers: work用户dnf免密权限已存在，跳过"
fi

#centos/rocky firewalld配置
systemctl enable firewalld
systemctl start firewalld
firewall-cmd --zone=public --add-port=80/tcp --permanent
firewall-cmd --zone=public --add-port=443/tcp --permanent
firewall-cmd --reload
firewall-cmd --list-all

systemctl restart docker

# 克隆 laddr-docker 项目到 work 用户目录
echo ""
echo "正在克隆 laddr-docker 项目到 /home/work/ 目录..."
if [[ -d /home/work/laddr-docker ]]; then
    echo "laddr-docker 目录已存在，跳过克隆"
else
    su - work -c "git clone -b b1 https://github.com/alpha-86/laddr-docker.git /home/work/laddr-docker"
    echo "laddr-docker 项目已克隆到 /home/work/laddr-docker"
fi

echo ""
echo "=== 系统初始化完成 ==="
echo "主机名: $host_name"
echo "work用户已创建并配置完成"
echo "Docker已安装并启动"
echo "SSH已配置: PermitRootLogin=no, PasswordAuthentication=no, AllowUsers=work"
