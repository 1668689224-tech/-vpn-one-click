#!/bin/bash
set -euo pipefail

# OpenClaw 中文社区 安装脚本 (macOS 和 Linux)
# 用法: curl -fsSL https://raw.githubusercontent.com/1668689224-tech/-vpn-one-click/main/openclaw-cn/install.sh | bash

BOLD='\033[1m'
ACCENT='\033[38;2;255;90;45m'
INFO='\033[38;2;255;138;91m'
SUCCESS='\033[38;2;47;191;113m'
WARN='\033[38;2;255;176;32m'
ERROR='\033[38;2;226;61;45m'
MUTED='\033[38;2;139;127;119m'
NC='\033[0m'

DEFAULT_TAGLINE="所有聊天，一个 OpenClaw。"

TMPFILES=()
cleanup_tmpfiles() {
    local f
    for f in "${TMPFILES[@]:-}"; do
        rm -f "$f" 2>/dev/null || true
    done
}
trap cleanup_tmpfiles EXIT

mktempfile() {
    local f
    f="$(mktemp)"
    TMPFILES+=("$f")
    echo "$f"
}

DOWNLOADER=""
detect_downloader() {
    if command -v curl &> /dev/null; then
        DOWNLOADER="curl"
        return 0
    fi
    if command -v wget &> /dev/null; then
        DOWNLOADER="wget"
        return 0
    fi
    echo -e "${ERROR}错误: 缺少下载工具 (需要 curl 或 wget)${NC}"
    exit 1
}

# 一些系统/终端默认不是 UTF-8（例如某些精简 Linux、部分云主机、Docker/WSL 环境），会导致中文输出乱码。
# 这里尽量将 locale 调整为 UTF-8（如果系统提供了相应 locale）。
ensure_utf8_locale() {
    if ! command -v locale &> /dev/null; then
        return 0
    fi

    local charmap=""
    charmap="$(locale charmap 2>/dev/null || true)"
    case "${charmap}" in
        UTF-8|utf-8) return 0 ;;
    esac

    local candidates=("C.UTF-8" "en_US.UTF-8" "zh_CN.UTF-8")
    local available
    available="$(locale -a 2>/dev/null || true)"

    local c
    for c in "${candidates[@]}"; do
        if echo "$available" | grep -qx "$c"; then
            export LC_ALL="$c"
            export LANG="$c"
            echo -e "${WARN}[!]${NC} 检测到当前 locale 非 UTF-8（${charmap:-unknown}），已尝试切换为 ${ACCENT}${c}${NC}"
            return 0
        fi
    done

    echo -e "${WARN}[!]${NC} 检测到当前 locale 非 UTF-8（${charmap:-unknown}），可能导致中文输出乱码。"
    echo -e "${INFO}建议在终端中设置 UTF-8，例如：${NC}"
    echo -e "  ${ACCENT}export LANG=C.UTF-8${NC}"
    echo -e "  ${ACCENT}export LC_ALL=C.UTF-8${NC}"
}

preflight_checks() {
    ensure_utf8_locale
}

cleanup_npm_openclaw_paths() {
    local npm_root=""
    npm_root="$(npm root -g 2>/dev/null || true)"
    if [[ -z "$npm_root" || "$npm_root" != *node_modules* ]]; then
        return 1
    fi
    rm -rf "$npm_root"/.openclaw-* "$npm_root"/openclaw-cn 2>/dev/null || true
}

install_openclaw_npm() {
    local spec="$1"
    local log
    local registry_args=()
    local npm_exit_code=0
    log="$(mktempfile)"

    if [[ -n "${NPM_REGISTRY:-}" ]]; then
        registry_args=(--registry "$NPM_REGISTRY")
    fi

    # 部分依赖需要从 GitHub 拉取源码，某些用户的 git 配置会将 HTTPS 重写为 SSH，
    # 导致安装时提示输入 git@github.com 密码。这里临时禁用该重写。
    local git_rewrite_backup=""
    git_rewrite_backup="$(git config --global --get url."git@github.com:".insteadOf 2>/dev/null || true)"
    if [[ -n "$git_rewrite_backup" ]]; then
        git config --global --unset url."git@github.com:".insteadOf 2>/dev/null || true
    fi

    # 使用 pipefail 确保捕获 npm 的退出码而不是 tee 的
    # 临时禁用 errexit，以便捕获错误并进行处理
    set +e
    set -o pipefail
    SHARP_IGNORE_GLOBAL_LIBVIPS="$SHARP_IGNORE_GLOBAL_LIBVIPS" npm --loglevel "$NPM_LOGLEVEL" ${NPM_SILENT_FLAG:+$NPM_SILENT_FLAG} --no-fund --no-audit ${registry_args[@]+"${registry_args[@]}"} install -g "$spec" 2>&1 | tee "$log"
    npm_exit_code=$?
    set +o pipefail
    set -e

    if [[ "$npm_exit_code" -ne 0 ]]; then
        # 恢复 git URL 重写配置
        if [[ -n "$git_rewrite_backup" ]]; then
            git config --global url."git@github.com:".insteadOf "$git_rewrite_backup" 2>/dev/null || true
        fi
        if grep -q "ENOTEMPTY: directory not empty, rename .*openclaw" "$log"; then
            echo -e "${WARN}→${NC} npm 留下了残留目录；正在清理并重试..."
            cleanup_npm_openclaw_paths
            SHARP_IGNORE_GLOBAL_LIBVIPS="$SHARP_IGNORE_GLOBAL_LIBVIPS" npm --loglevel "$NPM_LOGLEVEL" ${NPM_SILENT_FLAG:+$NPM_SILENT_FLAG} --no-fund --no-audit ${registry_args[@]+"${registry_args[@]}"} install -g "$spec"
            return $?
        fi

        # 常见失败原因提示
        if grep -Eqi "(git: not found|ENOENT.*git|not found: git)" "$log"; then
            echo -e "${WARN}[!]${NC} 检测到错误信息中包含 ${ACCENT}git${NC}，你的系统可能缺少 git。"
            echo -e "${INFO}请先安装 git 后重试（macOS: xcode-select --install；Ubuntu: sudo apt-get install -y git）。${NC}"
        fi

        if grep -Eqi "(EACCES|permission denied)" "$log"; then
            echo -e "${WARN}[!]${NC} 似乎是权限问题导致全局安装失败（EACCES/permission denied）。"
            echo -e "${INFO}可以尝试使用 sudo 运行，或配置 npm 全局目录到用户目录后再安装。${NC}"
        fi

        if grep -Eqi "(node-gyp|gyp ERR|C\+\+ compiler|make: )" "$log"; then
            echo -e "${WARN}[!]${NC} 可能缺少编译依赖（node-gyp/build tools）。"
            echo -e "${INFO}macOS: xcode-select --install${NC}"
            echo -e "${INFO}Ubuntu/Debian: sudo apt-get install -y build-essential python3 make g++${NC}"
        fi

        echo -e "${ERROR}安装失败（以下为 npm 输出末尾，便于排查）：${NC}"
        if [[ -s "$log" ]]; then
            tail -n 40 "$log" 2>/dev/null || true
        else
            echo -e "${MUTED}(无 npm 输出，尝试使用 --verbose 重新运行以查看详细信息)${NC}"
            echo -e "${INFO}提示: curl -fsSL https://raw.githubusercontent.com/1668689224-tech/-vpn-one-click/main/openclaw-cn/install.sh | bash -s -- --verbose --registry $NPM_REGISTRY${NC}"
        fi

        return 1
    fi

    # 恢复 git URL 重写配置
    if [[ -n "$git_rewrite_backup" ]]; then
        git config --global url."git@github.com:".insteadOf "$git_rewrite_backup" 2>/dev/null || true
    fi
    return 0
}

TAGLINES=()
TAGLINES+=("你的终端长出了钳子——输入命令，让机器人帮你处理琐事。")
TAGLINES+=("欢迎来到命令行：梦想在这里编译，自信在这里崩溃。")
TAGLINES+=("我靠咖啡因、JSON5 和"在我机器上能跑"的勇气运行。")
TAGLINES+=("网关已上线——请确保手脚和附肢都在 shell 里。")
TAGLINES+=("一个 CLI 统治一切，再重启一次因为你改了端口。")
TAGLINES+=("如果能跑，那就是自动化；如果崩了，那就是"学习机会"。")
TAGLINES+=("配对码存在是因为机器人也相信同意——以及良好的安全习惯。")
TAGLINES+=("你的 .env 露出来了；别担心，我假装没看到。")
TAGLINES+=("我来做无聊的事，你可以戏剧性地盯着日志看像在看电影。")
TAGLINES+=("自信地输入命令——如果需要，大自然会提供堆栈跟踪。")
TAGLINES+=("我不评判，但你缺失的 API 密钥绝对在评判你。")
TAGLINES+=("配置热重载，部署冷汗。")
TAGLINES+=("我是你的终端要求的助手，不是你的睡眠时间要求的那个。")
TAGLINES+=("带钳子的自动化：最小的麻烦，最大的效率。")
TAGLINES+=("如果迷路了，运行 doctor；如果勇敢，运行 prod；如果明智，运行 tests。")
TAGLINES+=("我修不了你的代码品味，但我能修你的构建和积压任务。")
TAGLINES+=("给我一个工作区，我会给你更少的标签页和更多的氧气。")
TAGLINES+=("我读日志，这样你就可以继续假装不用读。")
TAGLINES+=("因为给自己发提醒短信太 2024 了。")
TAGLINES+=("WhatsApp，但让它✨工程化✨。")
TAGLINES+=("你联系人里唯一一个你真正想收到消息的螃蟹。🦞")
TAGLINES+=("因为 Siri 凌晨 3 点不接电话。")
TAGLINES+=("UNIX 哲学遇上你的私信。")

HOLIDAY_NEW_YEAR="元旦快乐：新年，新配置——还是老样子的端口冲突，但这次我们像成年人一样解决它。"
HOLIDAY_LUNAR_NEW_YEAR="春节快乐：愿你的构建幸运，分支繁荣，合并冲突被烟花赶走。🧧"

append_holiday_taglines() {
    local month_day
    month_day="$(date -u +%m-%d 2>/dev/null || date +%m-%d)"
    local today
    today="$(date -u +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)"

    case "$month_day" in
        "01-01") TAGLINES+=("$HOLIDAY_NEW_YEAR") ;;
    esac

    case "$today" in
        "2025-01-29"|"2026-02-17"|"2027-02-06") TAGLINES+=("$HOLIDAY_LUNAR_NEW_YEAR") ;;
    esac
}

pick_tagline() {
    append_holiday_taglines
    local count=${#TAGLINES[@]}
    if [[ "$count" -eq 0 ]]; then
        echo "$DEFAULT_TAGLINE"
        return
    fi
    local idx=$((RANDOM % count))
    echo "${TAGLINES[$idx]}"
}

TAGLINE=$(pick_tagline)

NO_ONBOARD=${CLAWDBOT_NO_ONBOARD:-0}
NO_PROMPT=${CLAWDBOT_NO_PROMPT:-0}
DRY_RUN=${CLAWDBOT_DRY_RUN:-0}
CLAWDBOT_VERSION=${CLAWDBOT_VERSION:-latest}
USE_BETA=${CLAWDBOT_BETA:-0}
SHARP_IGNORE_GLOBAL_LIBVIPS="${SHARP_IGNORE_GLOBAL_LIBVIPS:-1}"
# 默认使用 warn 级别，显示安装进度
NPM_LOGLEVEL="${CLAWDBOT_NPM_LOGLEVEL:-warn}"
NPM_SILENT_FLAG=""
# 使用官方 npm 源（可通过 CLAWDBOT_NPM_REGISTRY 覆盖）
NPM_REGISTRY="${CLAWDBOT_NPM_REGISTRY:-https://registry.npmjs.org}"
VERBOSE="${CLAWDBOT_VERBOSE:-0}"
CLAWDBOT_BIN=""
HELP=0

print_usage() {
    cat <<EOF
OpenClaw 中文社区 安装脚本 (macOS + Linux)

用法:
  curl -fsSL https://raw.githubusercontent.com/1668689224-tech/-vpn-one-click/main/openclaw-cn/install.sh | bash -s -- [选项]

选项:
  --version <版本|标签>    npm 安装版本 (默认: latest)
  --beta                   使用 beta 版本（如可用）
  --registry <url>         npm 安装源 (默认: https://registry.npmjs.org)
  --no-onboard             跳过引导配置 (非交互式)
  --no-prompt              禁用提示 (CI/自动化必需)
  --dry-run                打印将要执行的操作 (不做更改)
  --verbose                打印调试输出
  --help, -h               显示此帮助

环境变量:
  CLAWDBOT_VERSION=latest|beta|<版本号>
  CLAWDBOT_BETA=0|1
  CLAWDBOT_NO_PROMPT=1
  CLAWDBOT_DRY_RUN=1
  CLAWDBOT_NO_ONBOARD=1
  CLAWDBOT_VERBOSE=1
  CLAWDBOT_NPM_REGISTRY=<url>    npm 安装源（默认: https://registry.npmjs.org）

示例:
  curl -fsSL https://raw.githubusercontent.com/1668689224-tech/-vpn-one-click/main/openclaw-cn/install.sh | bash
  curl -fsSL https://raw.githubusercontent.com/1668689224-tech/-vpn-one-click/main/openclaw-cn/install.sh | bash -s -- --registry https://registry.npmmirror.com
  curl -fsSL https://raw.githubusercontent.com/1668689224-tech/-vpn-one-click/main/openclaw-cn/install.sh | bash -s -- --no-onboard
  CLAWDBOT_VERSION=beta bash -c "\$(curl -fsSL https://raw.githubusercontent.com/1668689224-tech/-vpn-one-click/main/openclaw-cn/install.sh)"
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            HELP=1
            shift
            ;;
        --version)
            CLAWDBOT_VERSION="$2"
            shift 2
            ;;
        --beta)
            USE_BETA=1
            shift
            ;;
        --no-onboard)
            NO_ONBOARD=1
            shift
            ;;
        --no-prompt)
            NO_PROMPT=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --verbose)
            VERBOSE=1
            shift
            ;;
        --registry)
            NPM_REGISTRY="$2"
            shift 2
            ;;
        *)
            echo -e "${ERROR}未知选项: $1${NC}"
            print_usage
            exit 1
            ;;
    esac
done

if [[ "$HELP" -eq 1 ]]; then
    print_usage
    exit 0
fi

if [[ "$VERBOSE" -eq 1 ]]; then
    set -x
    NPM_LOGLEVEL="verbose"
    NPM_SILENT_FLAG=""
fi

print_banner() {
    echo ""
    echo -e "${ACCENT}  ╭──────────────────────────────────────╮${NC}"
    echo -e "${ACCENT}  │${NC}       ${BOLD}🧡 OpenClaw 中文社区 安装程序${NC}       ${ACCENT}│${NC}"
    echo -e "${ACCENT}  ╰──────────────────────────────────────╯${NC}"
    echo ""
    echo -e "  ${MUTED}${TAGLINE}${NC}"
    echo ""
}

print_banner

# 检测操作系统
OS=""
detect_os() {
    case "$(uname -s)" in
        Darwin*)
            OS="macos"
            echo -e "${SUCCESS}[✓]${NC} 检测到 macOS"
            ;;
        Linux*)
            OS="linux"
            echo -e "${SUCCESS}[✓]${NC} 检测到 Linux"
            ;;
        *)
            echo -e "${ERROR}错误: 不支持的操作系统${NC}"
            echo -e "${INFO}此脚本支持 macOS 和 Linux。Windows 用户请使用 install.ps1${NC}"
            exit 1
            ;;
    esac
}

detect_os
preflight_checks

# 检查 Node.js
check_node() {
    if command -v node &> /dev/null; then
        local version
        version=$(node -v | sed 's/v//' | cut -d. -f1)
        if [[ "$version" -ge 22 ]]; then
            echo -e "${SUCCESS}[✓]${NC} Node.js $(node -v) 已安装"
            return 0
        else
            echo -e "${WARN}[!]${NC} Node.js $(node -v) 已安装，但需要 v22+"
            return 1
        fi
    else
        echo -e "${WARN}[!]${NC} 未找到 Node.js"
        return 1
    fi
}

# 安装 Node.js
install_node() {
    echo -e "${INFO}[*]${NC} 正在安装 Node.js..."
    
    if [[ "$OS" == "macos" ]]; then
        if command -v brew &> /dev/null; then
            echo -e "  使用 Homebrew..."
            if [[ "$DRY_RUN" -eq 1 ]]; then
                echo -e "  ${MUTED}[dry-run] brew install node${NC}"
            else
                brew install node
            fi
            echo -e "${SUCCESS}[✓]${NC} Node.js 已通过 Homebrew 安装"
            return 0
        fi
    fi
    
    if [[ "$OS" == "linux" ]]; then
        if command -v apt-get &> /dev/null; then
            echo -e "  使用 apt (NodeSource)..."
            if [[ "$DRY_RUN" -eq 1 ]]; then
                echo -e "  ${MUTED}[dry-run] 安装 NodeSource 仓库并安装 nodejs${NC}"
            else
                curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
                sudo apt-get install -y nodejs
            fi
            return 0
        fi
        
        if command -v dnf &> /dev/null; then
            echo -e "  使用 dnf (NodeSource)..."
            if [[ "$DRY_RUN" -eq 1 ]]; then
                echo -e "  ${MUTED}[dry-run] 安装 NodeSource 仓库并安装 nodejs${NC}"
            else
                curl -fsSL https://rpm.nodesource.com/setup_22.x | sudo bash -
                sudo dnf install -y nodejs
            fi
            return 0
        fi
    fi
    
    echo ""
    echo -e "${ERROR}错误: 无法自动安装 Node.js${NC}"
    echo ""
    echo -e "${INFO}请手动安装 Node.js 22+:${NC}"
    echo -e "  ${ACCENT}https://nodejs.org/zh-cn/download/${NC}"
    echo ""
    exit 1
}

# 检查并安装 Node.js
if ! check_node; then
    if [[ "$NO_PROMPT" -eq 1 ]]; then
        install_node
    else
        echo ""
        if [[ -r /dev/tty ]]; then
            read -p "是否安装 Node.js? [Y/n] " -n 1 -r < /dev/tty
        else
            read -p "是否安装 Node.js? [Y/n] " -n 1 -r
        fi
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
            install_node
        else
            echo -e "${ERROR}需要 Node.js 22+ 才能继续${NC}"
            exit 1
        fi
    fi
    
    if ! check_node; then
        echo -e "${ERROR}Node.js 安装失败${NC}"
        exit 1
    fi
fi

# 检查 npm 全局安装权限
check_npm_permissions() {
    local npm_prefix
    npm_prefix="$(npm config get prefix 2>/dev/null || echo '')"
    
    if [[ -z "$npm_prefix" ]]; then
        return 0  # 无法获取，跳过检查
    fi
    
    local npm_modules="$npm_prefix/lib/node_modules"
    
    # macOS 的 Homebrew 通常不需要 sudo
    if [[ "$OS" == "macos" ]] && [[ "$npm_prefix" == "/opt/homebrew"* || "$npm_prefix" == "/usr/local"* ]]; then
        if [[ -w "$npm_modules" ]] || [[ -w "$npm_prefix" ]]; then
            return 0
        fi
    fi
    
    # 检查是否有写入权限
    if [[ -d "$npm_modules" ]]; then
        if [[ ! -w "$npm_modules" ]]; then
            return 1
        fi
    elif [[ -d "$npm_prefix" ]]; then
        if [[ ! -w "$npm_prefix" ]]; then
            return 1
        fi
    fi
    
    return 0
}

# 检测旧包是否已安装
check_legacy_packages() {
    local legacy_packages=("clawdbot-cn" "clawbot-cn")
    local installed_packages=()
    
    for pkg in "${legacy_packages[@]}"; do
        if npm list -g "$pkg" >/dev/null 2>&1; then
            installed_packages+=("$pkg")
        fi
    done
    
    if [[ ${#installed_packages[@]} -gt 0 ]]; then
        echo -e "${WARN}[!]${NC} 发现旧包: ${ACCENT}${installed_packages[*]}${NC}"
        echo -e "${INFO}提示:${NC} 这是 OpenClaw 的旧版本包名，需要先卸载。"
        
        if [[ "$NO_PROMPT" -eq 1 ]]; then
            # 非交互模式下自动卸载
            uninstall_legacy_packages "${installed_packages[@]}"
        else
            read -p "是否卸载旧包? [Y/n] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
                uninstall_legacy_packages "${installed_packages[@]}"
            else
                echo -e "${WARN}注意:${NC} 不卸载旧包可能会导致安装冲突。"
            fi
        fi
    fi
}

# 卸载旧包
uninstall_legacy_packages() {
    local packages=()
    while [[ $# -gt 0 ]]; do
        packages+=("$1")
        shift
    done
    
    echo -e "${INFO}[*]${NC} 正在卸载旧包..."
    
    for pkg in "${packages[@]}"; do
        # 先尝试应用层卸载
        echo -e "${INFO}[*]${NC} 执行应用层卸载: $pkg"
        if command -v npx &> /dev/null; then
            npx -y "$pkg" uninstall --all --yes --non-interactive 2>/dev/null || true
        fi
        
        # 再卸载npm包
        echo -e "${INFO}[*]${NC} 卸载npm包: $pkg"
        npm uninstall -g "$pkg" 2>/dev/null || {
            echo -e "${WARN}[!]${NC} 普通卸载失败，尝试强制卸载: $pkg"
            npm uninstall -g --force "$pkg" 2>/dev/null || {
                echo -e "${ERROR}[✗]${NC} 强制卸载失败: $pkg"
            }
        }
        
        # 清理可能残留的可执行文件
        local npm_bin_dir
        npm_bin_dir="$(npm bin -g 2>/dev/null || true)"
        if [[ -n "$npm_bin_dir" && -d "$npm_bin_dir" ]]; then
            rm -f "$npm_bin_dir/$pkg" "$npm_bin_dir/$pkg.cmd" "$npm_bin_dir/$pkg.ps1" 2>/dev/null || true
        fi
    done
    
    echo -e "${SUCCESS}[✓]${NC} 旧包卸载完成"
}

# 检查 Git 是否安装
check_git() {
    if command -v git &> /dev/null; then
        echo -e "${SUCCESS}[✓]${NC} Git 已安装 ($(git --version | cut -d' ' -f3))"
        return 0
    else
        echo -e "${WARN}[!]${NC} 未检测到 Git"
        return 1
    fi
}

# 安装 Git
install_git() {
    echo -e "${INFO}[*]${NC} 正在安装 Git..."
    
    if [[ "$OS" == "macos" ]]; then
        if command -v brew &> /dev/null; then
            echo -e "  使用 Homebrew..."
            if [[ "$DRY_RUN" -eq 1 ]]; then
                echo -e "  ${MUTED}[dry-run] brew install git${NC}"
            else
                brew install git
            fi
        else
            echo -e "${INFO}提示:${NC} macOS 上需要先安装 Homebrew: /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
            echo -e "${ERROR}错误:${NC} 请先安装 Homebrew 再继续。"
            exit 1
        fi
    elif [[ "$OS" == "linux" ]]; then
        if command -v apt-get &> /dev/null; then
            echo -e "  使用 apt..."
            if [[ "$DRY_RUN" -eq 1 ]]; then
                echo -e "  ${MUTED}[dry-run] sudo apt-get install -y git${NC}"
            else
                sudo apt-get update && sudo apt-get install -y git
            fi
        elif command -v yum &> /dev/null; then
            echo -e "  使用 yum..."
            if [[ "$DRY_RUN" -eq 1 ]]; then
                echo -e "  ${MUTED}[dry-run] sudo yum install -y git${NC}"
            else
                sudo yum install -y git
            fi
        elif command -v dnf &> /dev/null; then
            echo -e "  使用 dnf..."
            if [[ "$DRY_RUN" -eq 1 ]]; then
                echo -e "  ${MUTED}[dry-run] sudo dnf install -y git${NC}"
            else
                sudo dnf install -y git
            fi
        elif command -v pacman &> /dev/null; then
            echo -e "  使用 pacman..."
            if [[ "$DRY_RUN" -eq 1 ]]; then
                echo -e "  ${MUTED}[dry-run] sudo pacman -S --noconfirm git${NC}"
            else
                sudo pacman -S --noconfirm git
            fi
        else
            echo -e "${ERROR}错误:${NC} 未找到可用的包管理器来安装 Git。请手动安装 Git。"
            exit 1
        fi
    fi
    
    echo -e "${SUCCESS}[✓]${NC} Git 安装完成"
}

# 检查并修复 Git GitHub 配置问题
fix_git_github_config() {
    local github_ssh_config
    github_ssh_config="$(git config --global --get url."git@github.com:".insteadOf 2>/dev/null || true)"
    
    if [[ -n "$github_ssh_config" ]]; then
        echo -e "${WARN}[!]${NC} 检测到 Git 全局 GitHub 配置: ${ACCENT}$github_ssh_config${NC}"
        echo -e "${INFO}提示:${NC} 此配置可能导致 SSH 连接 GitHub 失败。"
        
        if [[ "$NO_PROMPT" -eq 1 ]]; then
            # 非交互模式下自动修复
            echo -e "${INFO}[*]${NC} 自动临时禁用 GitHub SSH 配置..."
            temp_disable_git_github_config
        else
            read -p "是否临时禁用此配置以避免安装失败? [Y/n] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
                temp_disable_git_github_config
            else
                echo -e "${WARN}注意:${NC} 保持配置可能导致安装失败。"
            fi
        fi
    fi
}

# 恢复 Git GitHub 配置（全局定义，确保在脚本退出时能被调用）
restore_git_github_config() {
    local backup_value="$GIT_CONFIG_BACKUP_VALUE"
    if [[ -n "$backup_value" ]]; then
        git config --global url."git@github.com:".insteadOf "$backup_value" 2>/dev/null || true
        echo -e "${SUCCESS}[✓]${NC} 已恢复 Git GitHub 配置"
    fi
}

# 临时禁用 Git GitHub 配置
temp_disable_git_github_config() {
    local backup_value
    backup_value="$(git config --global --get url."git@github.com:".insteadOf 2>/dev/null || true)"
    
    if [[ -n "$backup_value" ]]; then
        git config --global --unset url."git@github.com:".insteadOf 2>/dev/null || true
        # 保存备份值到全局变量，供恢复函数使用
        export GIT_CONFIG_BACKUP_VALUE="$backup_value"
        trap restore_git_github_config EXIT
    fi
}

# 显示权限解决方案
show_permission_help() {
    local npm_prefix
    npm_prefix="$(npm config get prefix 2>/dev/null || echo '/usr/lib')"
    
    echo ""
    echo -e "${WARN}⚠️  需要管理员权限才能安装到 ${ACCENT}$npm_prefix${NC}"
    echo ""
    echo -e "${INFO}请选择以下方式之一：${NC}"
    echo ""
    echo -e "  ${BOLD}[方案 1]${NC} 使用 sudo 运行安装脚本："
    echo -e "    ${ACCENT}curl -fsSL https://raw.githubusercontent.com/1668689224-tech/-vpn-one-click/main/openclaw-cn/install.sh | sudo bash${NC}"
    if [[ -n "${NPM_REGISTRY:-}" && "$NPM_REGISTRY" != "https://registry.npmjs.org" ]]; then
        echo -e "    ${MUTED}或带镜像源：${NC}"
        echo -e "    ${ACCENT}curl -fsSL https://raw.githubusercontent.com/1668689224-tech/-vpn-one-click/main/openclaw-cn/install.sh | sudo bash -s -- --registry $NPM_REGISTRY${NC}"
    fi
    echo ""
    echo -e "  ${BOLD}[方案 2]${NC} 配置 npm 使用用户目录（推荐，无需 sudo）："
    echo -e "    ${ACCENT}mkdir -p ~/.npm-global${NC}"
    echo -e "    ${ACCENT}npm config set prefix ~/.npm-global${NC}"
    if [[ -n "$SHELL" ]] && [[ "$SHELL" == *"zsh"* ]]; then
        echo -e "    ${ACCENT}echo 'export PATH=~/.npm-global/bin:\$PATH' >> ~/.zshrc${NC}"
        echo -e "    ${ACCENT}source ~/.zshrc${NC}"
    else
        echo -e "    ${ACCENT}echo 'export PATH=~/.npm-global/bin:\$PATH' >> ~/.bashrc${NC}"
        echo -e "    ${ACCENT}source ~/.bashrc${NC}"
    fi
    echo -e "    ${MUTED}然后重新运行安装脚本${NC}"
    echo ""
}

# 检查权限并处理
if ! check_npm_permissions; then
    show_permission_help
    exit 1
fi

# 检测并处理旧包
check_legacy_packages

# 检查并安装 Git（如果需要）
if ! check_git; then
    if [[ "$NO_PROMPT" -eq 1 ]]; then
        # 非交互模式下自动安装
        install_git
    else
        read -p "OpenClaw 依赖 Git，是否安装? [Y/n] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
            install_git
        else
            echo -e "${WARN}警告:${NC} 缺少 Git 可能导致安装失败。"
        fi
    fi
fi

# 检查并修复 Git GitHub 配置问题
fix_git_github_config

# 安装 OpenClaw 中文社区
install_openclaw() {
    local spec="openclaw-cn"
    
    if [[ "$USE_BETA" -eq 1 ]]; then
        spec="openclaw-cn@beta"
    elif [[ "$CLAWDBOT_VERSION" != "latest" ]]; then
        spec="openclaw-cn@$CLAWDBOT_VERSION"
    fi
    
    echo ""
    echo -e "${INFO}[*]${NC} 正在安装 ${ACCENT}${spec}${NC}..."
    echo -e "${INFO}[*]${NC} npm 源: ${ACCENT}${NPM_REGISTRY}${NC}"
    
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo -e "  ${MUTED}[dry-run] npm install -g $spec${NC}"
        CLAWDBOT_BIN="openclaw-cn"
        return 0
    fi
    
    if install_openclaw_npm "$spec"; then
        echo -e "${SUCCESS}[✓]${NC} OpenClaw 中文社区 安装成功"
        CLAWDBOT_BIN="openclaw-cn"
        return 0
    else
        echo -e "${ERROR}安装失败${NC}"
        return 1
    fi
}

install_openclaw

# 显示版本
if [[ -n "$CLAWDBOT_BIN" ]] && command -v "$CLAWDBOT_BIN" &> /dev/null; then
    echo ""
    echo -e "${SUCCESS}[✓]${NC} 已安装: $($CLAWDBOT_BIN --version 2>/dev/null || echo 'openclaw-cn')"
fi

# 运行引导
if [[ "$NO_ONBOARD" -eq 0 ]]; then
    echo ""
    echo -e "${INFO}[*]${NC} 正在启动引导配置..."
    echo ""
    
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo -e "  ${MUTED}[dry-run] $CLAWDBOT_BIN onboard${NC}"
    else
        # 注意：如果通过 `curl ... | bash` 运行，本脚本的 stdin 可能不是 TTY，
        # 这会导致 onboard 无法正常交互（默认选择 no 直接退出）。
        # 因此优先将交互输入绑定到 /dev/tty。
        if [[ -r /dev/tty ]]; then
            "$CLAWDBOT_BIN" onboard < /dev/tty
        else
            "$CLAWDBOT_BIN" onboard
        fi
    fi
else
    echo ""
    echo -e "${INFO}提示:${NC} 运行 ${ACCENT}openclaw-cn onboard${NC} 开始配置"
fi

echo ""
echo -e "${SUCCESS}安装完成！${NC} 🦞"
echo ""
