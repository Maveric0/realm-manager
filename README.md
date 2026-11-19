# realm-manager

[realm](https://github.com/zhboner/realm) 端口转发的一键安装与规则管理脚本。

## 安装

在服务器上以 root 执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Maveric0/realm-manager/main/realm.sh)
```

Alpine 默认没有 bash 和 curl，先装上再执行：

```bash
apk add --no-cache bash curl
bash <(curl -fsSL https://raw.githubusercontent.com/Maveric0/realm-manager/main/realm.sh)
```

安装完成后，以后 SSH 登录直接输入 `realm` 就能进入管理菜单，可以增删改查规则、查看日志、检查更新和卸载。

支持使用 systemd 的 Linux（Debian、Ubuntu、RHEL 系等）和使用 OpenRC 的 Alpine，架构为 x86_64、aarch64、armv7。

## 规则怎么写

- 监听：`10000`，或指定地址 `1.2.3.4:10000`。只写端口时同时监听 IPv4 和 IPv6
- 目标：`1.2.3.4:443`、`example.com:443`、`[2001:db8::1]:443`
- 协议：TCP+UDP、TCP、UDP

## 更新规则为什么不用重启

realm 本身不支持热重载，所以每条规则都运行一个独立的 realm 进程（systemd 实例 `realm-rule@<ID>`，Alpine 上是 OpenRC 服务 `realm-rule.<ID>`）：

| 操作 | 影响范围 |
| --- | --- |
| 添加规则 | 只启动新进程，已有规则不受影响 |
| 删除规则 | 只停止这条规则，其他规则不受影响 |
| 修改监听、目标或协议 | 只重启这条规则，它自身的现有连接会断开，其他规则不受影响 |
| 只改备注 | 不重启任何进程 |

添加和修改后，脚本会检查规则是否真正开始监听。启动失败时自动撤销，修改失败时自动恢复原配置。

## 开机自启

每条规则在添加时就已设为开机自启（systemd 下是 `systemctl enable`，Alpine 下是 `rc-update add ... default`），服务器重启后会自动恢复全部转发，不需要再登录操作。

- 开机时如果监听地址还没就绪，realm 会每 3 秒重试一次，直到启动成功，不会重试几次就放弃
- 每次进入 `realm` 菜单时，脚本会检查所有规则：没有设为自启的补上，没在运行的启动起来，并提示处理了哪几条

想自己确认，可以看某条规则（比如规则 1）的状态：

```bash
systemctl is-enabled realm-rule@1
```

Alpine 上是：

```bash
rc-update show default | grep realm-rule
```

## 已安装的服务器怎么更新

SSH 登录后输入 `realm`，选 `5. 检查更新`。脚本更新完会自动重新进入菜单，这时服务模板和自启设置就已经是新的了。整个过程不会重启正在运行的规则，现有连接不受影响。

Alpine 上的旧版本有个问题：如果一口气连着添加多条规则（比如把输入整段粘贴进去），后加的规则可能在服务器重启后不启动。更新后进入菜单时会自动把这类规则启动起来，以后重启也不会再漏。

重新执行一遍上面的安装命令效果相同，已有的规则会保留。

## 文件位置

| 路径 | 用途 |
| --- | --- |
| `/usr/local/bin/realm` | 管理脚本 |
| `/opt/realm-manager/realm` | realm 程序 |
| `/etc/realm-manager/rules/<ID>.toml` | 每条规则的配置 |
| `/etc/systemd/system/realm-rule@.service` | systemd 模板 |

Alpine (OpenRC) 上服务和日志的位置不同：

| 路径 | 用途 |
| --- | --- |
| `/etc/init.d/realm-rule` | OpenRC 服务脚本，每条规则是一个指向它的软链接 `realm-rule.<ID>` |
| `/var/log/realm-manager/<ID>.log` | 每条规则的日志 |
| `/etc/periodic/daily/realm-manager` | 每天把超过 1MB 的日志截短（依赖 crond），规则每次启动时也会截一次 |

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
