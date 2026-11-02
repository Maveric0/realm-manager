# realm-manager

[realm](https://github.com/zhboner/realm) 端口转发的一键安装与规则管理脚本。

## 安装

在服务器上以 root 执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Maveric0/realm-manager/main/realm.sh)
```

安装完成后，以后 SSH 登录直接输入 `realm` 就能进入管理菜单，可以增删改查规则、查看日志、检查更新和卸载。

支持使用 systemd 的 Linux，架构为 x86_64、aarch64、armv7。

## 规则怎么写

- 监听：`10000`，或指定地址 `1.2.3.4:10000`。只写端口时同时监听 IPv4 和 IPv6
- 目标：`1.2.3.4:443`、`example.com:443`、`[2001:db8::1]:443`
- 协议：TCP+UDP、TCP、UDP

## 更新规则为什么不用重启

realm 本身不支持热重载，所以每条规则都运行一个独立的 realm 进程（systemd 实例 `realm-rule@<ID>`）：

| 操作 | 影响范围 |
| --- | --- |
| 添加规则 | 只启动新进程，已有规则不受影响 |
| 删除规则 | 只停止这条规则，其他规则不受影响 |
| 修改监听、目标或协议 | 只重启这条规则，它自身的现有连接会断开，其他规则不受影响 |
| 只改备注 | 不重启任何进程 |

添加和修改后，脚本会检查规则是否真正开始监听。启动失败时自动撤销，修改失败时自动恢复原配置。

## 文件位置

| 路径 | 用途 |
| --- | --- |
| `/usr/local/bin/realm` | 管理脚本 |
| `/opt/realm-manager/realm` | realm 程序 |
| `/etc/realm-manager/rules/<ID>.toml` | 每条规则的配置 |
| `/etc/systemd/system/realm-rule@.service` | systemd 模板 |

`realm` 命令已被管理脚本占用，带参数调用时会转交给 realm 程序，比如 `realm -v`、`realm -c config.toml` 都能照常使用。如果服务器上已有 `/usr/local/bin/realm`，安装时会备份到 `/opt/realm-manager/realm.orig`，卸载时恢复。

## GitHub 访问受限的服务器

设置 `GH_PROXY` 后，脚本会经镜像下载 realm 和自身：

```bash
curl -fsSL https://你的镜像/https://raw.githubusercontent.com/Maveric0/realm-manager/main/realm.sh -o realm.sh
GH_PROXY=https://你的镜像/ bash realm.sh
```

realm 官方发布没有校验文件，镜像给什么二进制就会以 root 运行什么，请只用自己信任的镜像。

## 防火墙

脚本不会修改防火墙。添加规则后，如果检测到 ufw 或 firewalld 已启用，会提示放行命令；云服务商的安全组需要自行放行。
