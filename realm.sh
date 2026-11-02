#!/usr/bin/env bash
# realm-manager: realm 一键安装与转发规则管理
# https://github.com/Maveric0/realm-manager
#
# realm 本身不支持热重载，这里让每条规则独立运行一个 realm 进程
# (systemd 实例 realm-rule@<ID>)，增删改只影响对应规则，其他规则的连接不中断。

set -uo pipefail

SCRIPT_URL=https://raw.githubusercontent.com/Maveric0/realm-manager/main/realm.sh
REALM_REPO=https://github.com/zhboner/realm
GH_PROXY=${GH_PROXY:-}

APP_DIR=/opt/realm-manager
BIN=$APP_DIR/realm
CONF_DIR=/etc/realm-manager
RULE_DIR=$CONF_DIR/rules
CMD=/usr/local/bin/realm
UNIT_FILE=/etc/systemd/system/realm-rule@.service
MARKER='# realm-manager'

if [[ -t 1 ]]; then
    C_ACCENT=$'\033[36m' C_OK=$'\033[32m' C_ERR=$'\033[31m' C_DIM=$'\033[2m' C_RESET=$'\033[0m'
else
    C_ACCENT='' C_OK='' C_ERR='' C_DIM='' C_RESET=''
fi

ok() { printf '%s%s%s\n' "$C_OK" "$*" "$C_RESET"; }
err() { printf '%s%s%s\n' "$C_ERR" "$*" "$C_RESET" >&2; }
hint() { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
die() {
    err "$*"
    exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }

# 读取一行输入到 REPLY，回车取默认值；输入流结束时退出，避免菜单空转
ask() {
    local prompt=$1 default=${2-}
    [[ -n $default ]] && prompt+=" [$default]"
    IFS= read -r -p "$prompt: " REPLY || {
        echo
        exit 0
    }
    REPLY=${REPLY//$'\r'/}
    REPLY=${REPLY#"${REPLY%%[![:space:]]*}"}
    REPLY=${REPLY%"${REPLY##*[![:space:]]}"}
    REPLY=${REPLY:-$default}
}

confirm() {
    ask "$1 (y/N)"
    [[ $REPLY == [yY] || $REPLY == [yY][eE][sS] ]]
}

# ---------- 安装 ----------

TMP_DIR=''
cleanup() { [[ -n $TMP_DIR ]] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

make_tmp() {
    [[ -n $TMP_DIR ]] || TMP_DIR=$(mktemp -d) || die "无法创建临时目录"
}

ensure_deps() {
    have systemctl && [[ -d /run/systemd/system ]] || die "本脚本依赖 systemd，当前系统不支持"

    local need=()
    have curl || need+=(curl)
    have tar || need+=(tar)
    if have apt-get; then
        have ss || need+=(iproute2)
        ((${#need[@]} == 0)) && return
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}"
    elif have dnf || have yum; then
        have ss || need+=(iproute)
        ((${#need[@]} == 0)) && return
        if have dnf; then dnf install -y -q "${need[@]}"; else yum install -y -q "${need[@]}"; fi
    else
        have ss || need+=(iproute2)
        ((${#need[@]} == 0)) && return
        die "缺少依赖：${need[*]}，请手动安装后重试"
    fi
    have curl && have tar && have ss || die "依赖安装失败：${need[*]}"
}

realm_targets() {
    case $(uname -m) in
    x86_64 | amd64) echo x86_64-unknown-linux-gnu-glibc2.28 x86_64-unknown-linux-musl ;;
    aarch64 | arm64) echo aarch64-unknown-linux-gnu-glibc2.28 aarch64-unknown-linux-musl ;;
    armv7l) echo armv7-unknown-linux-gnueabihf-glibc2.28 armv7-unknown-linux-musleabihf ;;
    *) return 1 ;;
    esac
}

# 依次尝试 glibc 版和静态 musl 版，取第一个能在本机运行的
download_realm() {
    local targets target url
    targets=$(realm_targets) || die "不支持的架构：$(uname -m)"
    make_tmp
    for target in $targets; do
        url="${GH_PROXY}${REALM_REPO}/releases/latest/download/realm-${target}.tar.gz"
        hint "下载 $url"
        curl -fL --connect-timeout 15 --retry 2 -# -o "$TMP_DIR/realm.tar.gz" "$url" || continue
        tar -xzf "$TMP_DIR/realm.tar.gz" -C "$TMP_DIR" realm 2>/dev/null || continue
        chmod 755 "$TMP_DIR/realm"
        "$TMP_DIR/realm" --version >/dev/null 2>&1 || continue
        # 同目录下改名替换，运行中的规则进程不受影响
        mkdir -p "$APP_DIR"
        cp "$TMP_DIR/realm" "$BIN.new" && mv -f "$BIN.new" "$BIN" || return 1
        have restorecon && restorecon -F "$BIN" 2>/dev/null
        return 0
    done
    return 1
}

install_unit() {
    cat >"$UNIT_FILE" <<EOF
[Unit]
Description=Realm forward rule %i
Documentation=https://github.com/Maveric0/realm-manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN -c $RULE_DIR/%i.toml
Restart=always
RestartSec=3
LimitNOFILE=524288
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_SYS_RESOURCE

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

fetch_script() {
    make_tmp
    curl -fsSL --connect-timeout 15 --retry 2 -o "$TMP_DIR/realm.sh" "${GH_PROXY}${SCRIPT_URL}" &&
        bash -n "$TMP_DIR/realm.sh"
}

place_script() { # <脚本路径>
    [[ $1 -ef $CMD ]] && return 0
    # 已有的 realm 二进制留作备份，卸载时恢复
    if [[ -e $CMD ]] && ! grep -qs "^$MARKER" "$CMD"; then
        mv -f "$CMD" "$APP_DIR/realm.orig"
    fi
    cp "$1" "$CMD.new" && chmod 755 "$CMD.new" && mv -f "$CMD.new" "$CMD"
}

# 经 curl 运行时 $0 不是普通文件，需要重新下载一份
install_self() {
    if [[ -f $0 ]]; then
        place_script "$0"
    else
        fetch_script && place_script "$TMP_DIR/realm.sh"
    fi
}

is_installed() { [[ -x $BIN && -f $UNIT_FILE ]] && grep -qs "^$MARKER" "$CMD"; }

install_all() {
    ensure_deps
    mkdir -p "$APP_DIR" "$RULE_DIR"
    if [[ ! -x $BIN ]]; then
        download_realm || die "下载 realm 失败。若服务器访问 GitHub 受限，可设置镜像后重试，例如：GH_PROXY=https://你的镜像/ bash realm.sh"
    fi
    install_unit
    install_self || die "安装 $CMD 失败"
    ok "安装完成，以后直接输入 realm 即可进入管理菜单"
}

# ---------- 规则文件 ----------

rule_file() { printf '%s/%s.toml' "$RULE_DIR" "$1"; }
unit_of() { printf 'realm-rule@%s.service' "$1"; }

rule_ids() {
    local f
    for f in "$RULE_DIR"/*.toml; do
        [[ -e $f ]] || continue
        f=${f##*/}
        echo "${f%.toml}"
    done | sort -n
}

next_id() {
    local max
    max=$(rule_ids | tail -n1)
    echo $((${max:-0} + 1))
}

rule_exists() { [[ $1 =~ ^[0-9]+$ && -f $(rule_file "$1") ]]; }
rule_listen() { sed -n 's/^listen = "\(.*\)"$/\1/p' "$(rule_file "$1")"; }
rule_remote() { sed -n 's/^remote = "\(.*\)"$/\1/p' "$(rule_file "$1")"; }
rule_remark() { sed -n 's/^# remark: //p' "$(rule_file "$1")"; }

rule_proto() {
    local f
    f=$(rule_file "$1")
    if grep -q '^no_tcp = true' "$f"; then
        echo udp
    elif grep -q '^use_udp = true' "$f"; then
        echo tcp+udp
    else
        echo tcp
    fi
}

write_rule() { # <文件> <监听> <目标> <协议> <备注>
    local no_tcp=false use_udp=true
    case $4 in
    tcp) use_udp=false ;;
    udp) no_tcp=true ;;
    esac
    cat >"$1" <<EOF
$MARKER
# remark: $5

[log]
level = "warn"

[network]
no_tcp = $no_tcp
use_udp = $use_udp

[[endpoints]]
listen = "$2"
remote = "$3"
EOF
}

# ---------- 输入校验 ----------

valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }

valid_ipv4() {
    [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local i
    for i in 1 2 3 4; do
        ((10#${BASH_REMATCH[i]} <= 255)) || return 1
    done
}

valid_ipv6_bracket() { [[ $1 =~ ^\[[0-9a-fA-F:.]+\]$ && $1 == *:* ]]; }

valid_domain() { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]]; }

default_bind() {
    if [[ -e /proc/net/if_inet6 ]]; then echo '[::]'; else echo 0.0.0.0; fi
}

# 接受 “端口” 或 “IP:端口”，规范化后写入 LISTEN
parse_listen() {
    local input=$1 host port
    if [[ $input =~ ^[0-9]+$ ]]; then
        host=$(default_bind)
        port=$input
    else
        host=${input%:*}
        port=${input##*:}
        [[ $input == *:* ]] || return 1
        valid_ipv4 "$host" || valid_ipv6_bracket "$host" || return 1
    fi
    valid_port "$port" || return 1
    LISTEN="$host:$((10#$port))"
}

# 接受 “IPv4:端口”“域名:端口”“[IPv6]:端口”，规范化后写入 REMOTE
parse_remote() {
    local input=$1 host port
    [[ $input == *:* ]] || return 1
    host=${input%:*}
    port=${input##*:}
    valid_port "$port" || return 1
    if [[ $host == \[* ]]; then
        valid_ipv6_bracket "$host" || return 1
    else
        valid_domain "$host" || return 1
        if [[ $host =~ ^[0-9.]+$ ]]; then valid_ipv4 "$host" || return 1; fi
    fi
    REMOTE="$host:$((10#$port))"
}

pick_proto() { # 默认协议写入 PROTO
    local current=$1 default=1
    case $current in
    tcp) default=2 ;;
    udp) default=3 ;;
    esac
    while :; do
        ask "协议 1.TCP+UDP 2.TCP 3.UDP" "$default"
        case $REPLY in
        1) PROTO=tcp+udp ;;
        2) PROTO=tcp ;;
        3) PROTO=udp ;;
        *)
            err "请输入 1、2 或 3"
            continue
            ;;
        esac
        return
    done
}

listening() { # <tcp|udp> <端口>
    local flag=-ltn
    [[ $1 == udp ]] && flag=-lun
    ss "$flag" 2>/dev/null | awk -v p="$2" 'NR>1 { n=split($4, a, ":"); if (a[n] == p) { found=1 } } END { exit !found }'
}

# 检查端口冲突，self 为正在修改的规则 ID。冲突时打印原因并返回 1
check_port() { # <端口> <协议> [self]
    local port=$1 proto=$2 self=${3-} t id
    local self_port='' self_proto=''
    if [[ -n $self ]]; then
        self_port=$(rule_listen "$self")
        self_port=${self_port##*:}
        self_proto=$(rule_proto "$self")
    fi
    for t in tcp udp; do
        [[ $proto == *$t* ]] || continue
        for id in $(rule_ids); do
            [[ $id == "$self" ]] && continue
            local other
            other=$(rule_listen "$id")
            if [[ ${other##*:} == "$port" && $(rule_proto "$id") == *$t* ]]; then
                err "${t^^} 端口 $port 已被规则 $id 使用"
                return 1
            fi
        done
        # 这条规则自己占着的端口不算冲突
        [[ $self_port == "$port" && $self_proto == *$t* ]] && continue
        if listening "$t" "$port"; then
            err "${t^^} 端口 $port 已被其他程序占用"
            return 1
        fi
    done
}

# 无默认值时回车表示取消，返回 1
ask_listen() { # <默认值>，结果写入 LISTEN
    while :; do
        ask "监听端口 (端口 或 IP:端口)" "$1"
        [[ -z $REPLY ]] && return 1
        parse_listen "$REPLY" && return
        err "格式不对，示例：10000、1.2.3.4:10000、[::1]:10000"
    done
}

ask_remote() {
    while :; do
        ask "转发目标 (地址:端口)" "$1"
        [[ -z $REPLY ]] && return 1
        parse_remote "$REPLY" && return
        err "格式不对，示例：1.2.3.4:443、example.com:443、[2001:db8::1]:443"
    done
}

ask_remark() {
    ask "备注 (可留空，输入 - 清空)" "$1"
    [[ $REPLY == - ]] && REPLY=''
    REMARK=$(printf '%s' "$REPLY" | tr -d '[:cntrl:]')
    # realm 读取非 UTF-8 的配置会直接崩溃，GBK 终端输入的中文要过滤掉
    if have iconv; then
        REMARK=$(printf '%s' "$REMARK" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null)
    fi
}

# ---------- 规则生效 ----------

# 等待规则在所有协议上真正开始监听：realm 只绑定失败一个协议时进程不会退出
wait_rule() { # <ID> <端口> <协议>
    local id=$1 port=$2 proto=$3 i t ready
    for ((i = 0; i < 25; i++)); do
        ready=1
        systemctl is-active --quiet "$(unit_of "$id")" || ready=0
        for t in tcp udp; do
            [[ $proto == *$t* ]] || continue
            listening "$t" "$port" || ready=0
        done
        ((ready)) && return 0
        sleep 0.2
    done
    return 1
}

show_failure() {
    err "规则 $1 启动失败，最近日志："
    journalctl -u "$(unit_of "$1")" -n 8 --no-pager -o cat 2>/dev/null | sed 's/^/  /' >&2
}

firewall_hint() { # <端口> <协议>
    local port=$1 proto=$2 t
    if have ufw && LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'; then
        for t in tcp udp; do
            [[ $proto == *$t* ]] && hint "ufw 已启用，如未放行请执行：ufw allow $port/$t"
        done
    elif have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        for t in tcp udp; do
            [[ $proto == *$t* ]] && hint "firewalld 已启用，如未放行请执行：firewall-cmd --permanent --add-port=$port/$t && firewall-cmd --reload"
        done
    fi
}

show_rule_summary() { # <ID>
    local proto
    proto=$(rule_proto "$1")
    printf '规则 %s：%s -> %s (%s)\n' "$1" "$(rule_listen "$1")" "$(rule_remote "$1")" "${proto^^}"
}

# ---------- 增删改查 ----------

list_rules() {
    local ids id proto state remark
    ids=$(rule_ids)
    if [[ -z $ids ]]; then
        hint "暂无规则"
        return
    fi
    printf '%-4s %-24s %-28s %-8s %s\n' ID LISTEN REMOTE PROTO '状态  备注'
    for id in $ids; do
        proto=$(rule_proto "$id")
        if systemctl is-active --quiet "$(unit_of "$id")"; then
            state="${C_OK}运行${C_RESET}"
        else
            state="${C_ERR}停止${C_RESET}"
        fi
        remark=$(rule_remark "$id")
        printf '%-4s %-24s %-28s %-8s %s  %s\n' "$id" "$(rule_listen "$id")" "$(rule_remote "$id")" "${proto^^}" "$state" "$remark"
    done
}

add_rule() {
    local id port file
    hint "直接回车取消"
    ask_listen '' || return
    port=${LISTEN##*:}
    ask_remote '' || return
    pick_proto tcp+udp
    check_port "$port" "$PROTO" || return
    ask_remark ''

    id=$(next_id)
    file=$(rule_file "$id")
    write_rule "$file" "$LISTEN" "$REMOTE" "$PROTO" "$REMARK"
    if systemctl enable --now "$(unit_of "$id")" >/dev/null 2>&1 && wait_rule "$id" "$port" "$PROTO"; then
        ok "已添加，其他规则未受影响"
        show_rule_summary "$id"
        firewall_hint "$port" "$PROTO"
    else
        show_failure "$id"
        systemctl disable --now "$(unit_of "$id")" >/dev/null 2>&1
        rm -f "$file"
        err "已撤销这条规则"
    fi
}

pick_rule() { # 选中的规则写入 RULE_ID
    local ids
    ids=$(rule_ids)
    if [[ -z $ids ]]; then
        hint "暂无规则"
        return 1
    fi
    ask "规则 ID (回车取消)"
    [[ -z $REPLY ]] && return 1
    if ! rule_exists "$REPLY"; then
        err "规则 $REPLY 不存在"
        return 1
    fi
    RULE_ID=$((10#$REPLY))
}

edit_rule() {
    pick_rule || return
    local id=$RULE_ID file old_listen old_remote old_proto port backup
    file=$(rule_file "$id")
    old_listen=$(rule_listen "$id")
    old_remote=$(rule_remote "$id")
    old_proto=$(rule_proto "$id")

    hint "直接回车保留当前值"
    ask_listen "$old_listen"
    port=${LISTEN##*:}
    ask_remote "$old_remote"
    pick_proto "$old_proto"
    check_port "$port" "$PROTO" "$id" || return
    ask_remark "$(rule_remark "$id")"

    if [[ $LISTEN == "$old_listen" && $REMOTE == "$old_remote" && $PROTO == "$old_proto" ]]; then
        write_rule "$file" "$LISTEN" "$REMOTE" "$PROTO" "$REMARK"
        ok "转发配置未变，无需重启"
        return
    fi

    make_tmp
    backup=$TMP_DIR/rule-$id.toml
    cp "$file" "$backup"
    write_rule "$file" "$LISTEN" "$REMOTE" "$PROTO" "$REMARK"
    if systemctl restart "$(unit_of "$id")" 2>/dev/null && wait_rule "$id" "$port" "$PROTO"; then
        ok "已更新，只有规则 $id 自身的连接被重置"
        show_rule_summary "$id"
        firewall_hint "$port" "$PROTO"
    else
        show_failure "$id"
        cp "$backup" "$file"
        systemctl restart "$(unit_of "$id")" 2>/dev/null
        err "修改未生效，规则 $id 已恢复原配置"
    fi
}

delete_rule() {
    pick_rule || return
    local id=$RULE_ID
    show_rule_summary "$id"
    confirm "确认删除" || return
    systemctl disable --now "$(unit_of "$id")" >/dev/null 2>&1
    systemctl reset-failed "$(unit_of "$id")" >/dev/null 2>&1
    rm -f "$(rule_file "$id")"
    ok "已删除，其他规则未受影响"
}

show_logs() {
    pick_rule || return
    journalctl -u "$(unit_of "$RULE_ID")" -n 30 --no-pager
}

# ---------- 维护 ----------

realm_version() { "$BIN" --version 2>/dev/null | awk '{ print $2; exit }'; }

latest_version() {
    local url
    url=$(curl -fsSLI --connect-timeout 15 -o /dev/null -w '%{url_effective}' "${GH_PROXY}${REALM_REPO}/releases/latest") || return 1
    url=${url##*/}
    [[ $url =~ ^v[0-9] ]] && echo "${url#v}"
}

# exec 不会触发 EXIT trap，先清理临时目录
reload_menu() {
    cleanup
    exec "$CMD"
}

update_all() {
    local current latest id
    current=$(realm_version)
    latest=$(latest_version) || latest=''
    if fetch_script && place_script "$TMP_DIR/realm.sh"; then
        ok "管理脚本已更新"
    else
        err "下载管理脚本失败，保留当前版本"
    fi
    if [[ -n $latest && $latest == "$current" ]]; then
        ok "realm 已是最新版本 $current"
        reload_menu
    fi
    download_realm || {
        err "下载 realm 失败"
        return
    }
    ok "realm 已更新：$current -> $(realm_version)"
    hint "运行中的规则继续使用旧版本，直到各自重启"
    if [[ -n $(rule_ids) ]] && confirm "现在重启全部规则以使用新版本？所有连接会短暂中断"; then
        for id in $(rule_ids); do
            systemctl restart "$(unit_of "$id")"
        done
        ok "已重启全部规则"
    fi
    reload_menu
}

uninstall() {
    confirm "确认卸载？全部规则会被删除，转发立即停止" || return
    local id
    for id in $(rule_ids); do
        systemctl disable --now "$(unit_of "$id")" >/dev/null 2>&1
        systemctl reset-failed "$(unit_of "$id")" >/dev/null 2>&1
    done
    rm -f "$UNIT_FILE" "$CMD"
    systemctl daemon-reload
    [[ -f $APP_DIR/realm.orig ]] && mv -f "$APP_DIR/realm.orig" "$CMD"
    rm -rf "$APP_DIR" "$CONF_DIR"
    ok "已卸载"
    exit 0
}

menu() {
    while :; do
        echo
        printf '%sRealm 转发管理%s  %sv%s%s\n\n' "$C_ACCENT" "$C_RESET" "$C_DIM" "$(realm_version)" "$C_RESET"
        list_rules
        echo
        echo "1. 添加规则    2. 修改规则    3. 删除规则    4. 查看日志"
        echo "5. 检查更新    6. 卸载        0. 退出"
        echo
        ask "请选择"
        case $REPLY in
        1) add_rule ;;
        2) edit_rule ;;
        3) delete_rule ;;
        4) show_logs ;;
        5) update_all ;;
        6) uninstall ;;
        0 | q | exit) exit 0 ;;
        '') ;;
        *) err "无效选项" ;;
        esac
    done
}

main() {
    # 带参数时当作 realm 本体调用，如 realm -v、realm -c config.toml
    if (($# > 0)) && [[ -x $BIN ]]; then
        exec "$BIN" "$@"
    fi

    if ((EUID != 0)); then
        [[ -f $0 ]] && have sudo && exec sudo bash "$0"
        die "请使用 root 运行"
    fi

    # curl | bash 时标准输入是脚本本身，交互要改从终端读
    if [[ ! -t 0 && ! -f $0 ]] && { : </dev/tty; } 2>/dev/null; then
        exec </dev/tty
    fi

    # 经一键命令重新运行时顺带刷新已安装的脚本
    if ! is_installed || [[ ! $0 -ef $CMD ]]; then
        install_all
    fi
    menu
}

# 写在同一行：标准输入换成终端后 bash 不能再往下读脚本
main "$@"; exit $?
