这里将发布来自茂亨科技开发的odoo免费插件，主要是针对国内在使用odoo管理外贸业务时遇到的一些问题。
如果需要部署定制开发odoo或使用我们已经针对外贸完善后的odoo saas可以访问https://morhon.com

以下是插件介绍：

Mail By Company
这个插件主要是用来解决Odoo国内邮箱无法发送邮件以及多公司多域名的问题。可以让不同公司用不同的域名收发邮件。
Odoo第三方应用商店地址：https://apps.odoo.com/apps/modules/14.0/mail_by_company/

odoo-manager.sh可实现用docker部署odoo包括外贸专用版odoo
使用说明
1. 快速本地部署（无需域名）
bash
# 下载脚本
curl -o odoo-manager.sh https://raw.githubusercontent.com/example/odoo-manager/main/odoo-manager.sh
chmod +x odoo-manager.sh

# 初始化环境
./odoo-manager.sh init

# 快速本地部署（只需实例名称）
./odoo-manager.sh deploy my-odoo
2. 交互式部署（支持两种模式）
bash
# 交互式部署
./odoo-manager.sh deploy

# 然后选择:
# 1) 域名模式 (需要域名)
# 2) 本地模式 (无需域名)
3. 本地模式部署示例
text
开始部署Odoo实例...
选择部署模式:
1) 域名模式 (需要域名，配置HTTPS)
2) 本地模式 (无需域名，通过IP访问)
选择部署模式 (1-2) [默认: 1]: 2

输入实例名称（例如: my-odoo）: test-odoo

本地部署模式访问方式:
1) 通过Nginx代理访问 (推荐，更安全)
2) 直接通过IP:端口访问 (简单，但安全性较低)
选择访问方式 (1-2) [默认: 1]: 2

开始部署 Odoo 实例...
部署模式: local
实例名称: test-odoo
允许IP访问: yes
端口: 8069
访问地址: http://192.168.1.100:8069
4. 智能镜像源示例
text
检测网络连通性...
Docker官方仓库可达: https://hub.docker.com
将优先使用Docker官方镜像源

预拉取Docker镜像...
拉取Docker镜像: postgres:15
镜像拉取成功: postgres:15
拉取Docker镜像: odoo:17.0
镜像拉取成功: odoo:17.0
5. 管理命令
bash
# 查看所有实例
ls /opt/

# 查看实例状态
cd /opt/my-odoo && docker-compose ps

# 查看日志
./odoo-manager.sh logs

# 备份恢复
./odoo-manager.sh backup
./odoo-manager.sh restore
