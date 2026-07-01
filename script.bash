#!/usr/bin/env bash
# ==============================================================================
# App Installer for Ubuntu — Enterprise Edition v2.1
# ------------------------------------------------------------------------------
# Cài đặt lại toàn bộ phần mềm sau khi nâng cấp Ubuntu / mất dữ liệu, có:
#   - Xác thực THẬT SỰ sau khi cài (không chỉ tin vào exit code)
#   - Không dừng toàn bộ script khi 1 gói lỗi (báo cáo cuối cùng đầy đủ)
#   - Tự dò & ưu tiên nguồn cài đặt: APT > Snap > Flatpak > thủ công
#   - Bỏ qua gói đã cài sẵn (idempotent) — an toàn khi chạy lại nhiều lần
#   - Ghi log đầy đủ ra file để audit / gửi cho IT
#   - Tải file về trước khi chạy (không pipe thẳng curl|bash) để có thể audit
#   - Hỗ trợ chế độ: Common, Developer, Developer+Data, Officer, Designer
# ==============================================================================

set -uo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------------------------
# Cấu hình chung & dọn dẹp an toàn
# ------------------------------------------------------------------------------
SCRIPT_VERSION="2.1.0"
LOG_DIR="${HOME}/.local/share/app-installer/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/install_$(date +%Y%m%d_%H%M%S).log"
TMP_DIR="$(mktemp -d -t app-installer.XXXXXX)"
DRY_RUN=0
FORCE_REINSTALL=0

cleanup() { rm -rf "$TMP_DIR" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${ts} [${level}] ${msg}" >> "$LOG_FILE"
    case "$level" in
        INFO)    echo -e "${GREEN}[INFO]${NC} $msg" ;;
        WARN)    echo -e "${YELLOW}[CẢNH BÁO]${NC} $msg" ;;
        ERROR)   echo -e "${RED}[LỖI]${NC} $msg" ;;
        SUCCESS) echo -e "${GREEN}[OK]${NC} $msg" ;;
        *)       echo "$msg" ;;
    esac
}

# Thử lại lệnh khi lỗi mạng
retry() {
    local max="$1"; shift
    local attempt=1
    until "$@"; do
        if (( attempt >= max )); then
            return 1
        fi
        log WARN "Lệnh thất bại (lần $attempt/$max), thử lại sau ${attempt}s: $*"
        sleep "$attempt"
        ((attempt++))
    done
    return 0
}

# ------------------------------------------------------------------------------
# Xử lý tham số dòng lệnh
# ------------------------------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --force)   FORCE_REINSTALL=1 ;;
        --version) echo "app-installer v${SCRIPT_VERSION}"; exit 0 ;;
        --help)
            cat <<EOF
Sử dụng: $0 [--dry-run] [--force] [--version]
  --dry-run   Chỉ hiển thị sẽ làm gì, không cài đặt thật
  --force     Cài lại cả những gói đã phát hiện là đã cài sẵn
EOF
            exit 0 ;;
    esac
done

# ------------------------------------------------------------------------------
# Kiểm tra whiptail & các lệnh nền tảng cần thiết
# ------------------------------------------------------------------------------
require_base_tools() {
    local missing=()
    for cmd in curl wget whiptail; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        log WARN "Thiếu công cụ nền: ${missing[*]}. Đang cài đặt..."
        sudo apt-get update -qq || log WARN "apt update thất bại, tiếp tục thử cài."
        sudo apt-get install -y "${missing[@]}" || {
            log ERROR "Không thể cài công cụ nền tảng (${missing[*]}). Không thể tiếp tục."
            exit 1
        }
    fi
}

# ------------------------------------------------------------------------------
# Dò và chuẩn bị các trình quản lý gói
# ------------------------------------------------------------------------------
HAS_SNAP=0
HAS_FLATPAK=0
APT_UPDATED=0

ensure_apt_updated() {
    if [ "$APT_UPDATED" -eq 0 ]; then
        log INFO "Đang cập nhật danh sách gói APT (chỉ 1 lần)..."
        if retry 3 sudo apt-get update -qq; then
            APT_UPDATED=1
        else
            log ERROR "apt-get update thất bại sau 3 lần thử. Cài đặt qua APT có thể không chính xác."
        fi
    fi
}

detect_package_managers() {
    if command -v snap &>/dev/null; then
        HAS_SNAP=1
    else
        log WARN "snapd chưa có trên hệ thống."
        if whiptail --title "Snap" --yesno "Snap (snapd) chưa được cài. Cài đặt để hỗ trợ các gói dùng Snap?" 9 70; then
            ensure_apt_updated
            sudo apt-get install -y snapd && HAS_SNAP=1
        fi
    fi

    if command -v flatpak &>/dev/null; then
        HAS_FLATPAK=1
    else
        if whiptail --title "Flatpak" --yesno "Flatpak chưa được cài. Cài đặt để có thêm nguồn phần mềm dự phòng?" 9 70; then
            ensure_apt_updated
            sudo apt-get install -y flatpak && HAS_FLATPAK=1
        fi
    fi

    if [ "$HAS_FLATPAK" -eq 1 ]; then
        flatpak remote-list 2>/dev/null | grep -q flathub || \
            flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# CƠ SỞ DỮ LIỆU GÓI PHẦN MỀM
#   PKG_INFO    : mô tả hiển thị
#   PKG_METHOD  : apt | snap | flatpak | curl | wget | manual | pip
#   PKG_ID      : TÊN GÓI THẬT theo trình quản lý
#   PKG_SIZE    : dung lượng ước tính (MB)
#   PKG_EXTRA   : cờ cài đặt thêm (--classic...) hoặc URL nguồn
#   PKG_VERIFY  : lệnh xác thực RIÊNG (ghi đè mặc định)
# ------------------------------------------------------------------------------
declare -A PKG_INFO PKG_METHOD PKG_ID PKG_SIZE PKG_EXTRA PKG_VERIFY PKG_STATUS

add_pkg() {
    local tag="$1" desc="$2" method="$3" size_mb="$4" extra="$5"
    local pkg_id="${6:-$tag}"
    PKG_INFO["$tag"]="$desc"
    PKG_METHOD["$tag"]="$method"
    PKG_SIZE["$tag"]="$size_mb"
    PKG_EXTRA["$tag"]="$extra"
    PKG_ID["$tag"]="$pkg_id"
}

set_verify() { PKG_VERIFY["$1"]="$2"; }

# ---------- IDE ----------
add_pkg "vscode"         "Visual Studio Code"          "snap" "100" "--classic" "code"
add_pkg "intellij"       "IntelliJ IDEA"                "snap" "500" "--classic" "intellij-idea-community"
add_pkg "pycharm"        "PyCharm"                      "snap" "400" "--classic" "pycharm-community"
add_pkg "android-studio" "Android Studio"               "snap" "800" "--classic" "android-studio"
add_pkg "webstorm"       "WebStorm"                     "snap" "450" "--classic" "webstorm"
add_pkg "clion"          "CLion"                        "snap" "450" "--classic" "clion"

# ---------- Version Control ----------
add_pkg "git"            "Git"                          "apt"  "20"  ""
add_pkg "git-lfs"        "Git LFS"                      "apt"  "5"   ""
add_pkg "github-desktop" "GitHub Desktop"                "manual" "100" "https://github.com/shiftkey/desktop/releases/latest/download/GitHubDesktop-linux-amd64.deb"
add_pkg "gitkraken"      "GitKraken"                    "snap" "200" "--classic" "gitkraken"

# ---------- Terminal ----------
add_pkg "terminator" "Terminator" "apt" "2" ""
add_pkg "tilix"       "Tilix"      "apt" "5" ""
add_pkg "tmux"        "tmux"       "apt" "1" ""
add_pkg "screen"      "screen"     "apt" "1" ""

# ---------- Shell ----------
add_pkg "zsh"      "Zsh"        "apt"  "5" ""
add_pkg "ohmyzsh"  "Oh My Zsh"  "curl" "1" "https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh"
add_pkg "starship" "Starship"   "curl" "2" "https://starship.rs/install.sh"

# ---------- Runtime / SDK ----------
add_pkg "nodejs"     "Node.js (LTS)"          "apt"  "30"  ""
add_pkg "npm"        "npm"                     "apt"  "5"   ""
add_pkg "pnpm"       "pnpm"                    "curl" "5"   "https://get.pnpm.io/install.sh"
add_pkg "yarn"       "Yarn"                    "apt"  "5"   ""
add_pkg "nvm"        "nvm (Node Version Mgr)"  "curl" "2"   "https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh"
add_pkg "openjdk"    "OpenJDK 17"              "apt"  "150" "" "openjdk-17-jdk"
add_pkg "maven"      "Apache Maven"            "apt"  "20"  ""
add_pkg "gradle"     "Gradle"                  "apt"  "50"  ""
add_pkg "python3"    "Python 3"                "apt"  "20"  ""
add_pkg "pip"        "pip"                     "apt"  "1"   "" "python3-pip"
add_pkg "pipx"       "pipx"                    "apt"  "1"   ""
add_pkg "poetry"     "Poetry"                  "curl" "10"  "https://install.python-poetry.org"
add_pkg "pyenv"      "pyenv"                   "curl" "5"   "https://pyenv.run"
add_pkg "virtualenv" "virtualenv"              "pip"  "1"   ""
add_pkg "golang"     "Go"                      "apt"  "100" "" "golang-go"
add_pkg "rust"       "Rust (rustup)"           "curl" "50"  "https://sh.rustup.rs"

# ---------- Container ----------
add_pkg "docker"         "Docker Engine"  "curl" "100" "https://get.docker.com"
add_pkg "docker-compose" "Docker Compose" "apt"  "10"  "" "docker-compose-plugin"

# ---------- DB Client ----------
add_pkg "dbeaver"   "DBeaver Community" "snap" "150" "" "dbeaver-ce"
add_pkg "tableplus" "TablePlus"          "manual" "100" "https://deb.tableplus.com/debian/22/tableplus.deb"
add_pkg "beekeeper" "Beekeeper Studio"   "snap" "80"  "" "beekeeper-studio"

# ---------- API Testing ----------
add_pkg "postman"  "Postman"  "snap" "200" "" "postman"
add_pkg "bruno"    "Bruno"    "manual" "100" "https://github.com/usebruno/bruno/releases/latest/download/bruno_linux_x86_64.deb"
add_pkg "insomnia" "Insomnia" "snap" "150" "" "insomnia"

# ---------- Trình duyệt ----------
add_pkg "chrome"  "Google Chrome"  "manual" "150" "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
add_pkg "firefox" "Firefox"        "apt"    "80"  ""
add_pkg "edge"    "Microsoft Edge" "manual" "120" "https://packages.microsoft.com/repos/edge/pool/main/m/microsoft-edge-stable/microsoft-edge-stable_amd64.deb"

add_pkg "openssh-client" "OpenSSH Client" "apt" "2" ""

# ---------- Data Science ----------
add_pkg "anaconda"   "Anaconda"        "manual" "600" "https://repo.anaconda.com/archive/Anaconda3-2024.10-1-Linux-x86_64.sh"
add_pkg "miniconda"  "Miniconda"       "manual" "100" "https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
add_pkg "jupyter"    "Jupyter Notebook" "pip"   "10"  ""
add_pkg "jupyterlab" "JupyterLab"       "pip"   "10"  ""
add_pkg "spark"      "Apache Spark"     "manual" "200" "https://downloads.apache.org/spark/spark-3.5.3/spark-3.5.3-bin-hadoop3.tgz"
add_pkg "hadoop"     "Hadoop Client"    "manual" "300" "https://downloads.apache.org/hadoop/common/hadoop-3.4.1/hadoop-3.4.1.tar.gz"
add_pkg "pgadmin"    "pgAdmin4 (web)"   "manual" "50"  "https://www.pgadmin.org/download/pgadmin-4-apt/"
add_pkg "mongodb-compass" "MongoDB Compass" "manual" "100" "https://downloads.mongodb.com/compass/mongodb-compass_1.46.5_amd64.deb"
add_pkg "powerbi"    "Power BI Desktop (Web)" "manual" "0" "https://app.powerbi.com/"
add_pkg "tableau"    "Tableau (Web)"          "manual" "0" "https://www.tableau.com/"
add_pkg "zeppelin"   "Apache Zeppelin"        "manual" "200" "https://downloads.apache.org/zeppelin/zeppelin-0.11.2/zeppelin-0.11.2-bin-all.tgz"

# ---------- Văn phòng ----------
add_pkg "libreoffice" "LibreOffice"                "apt"  "200" ""
add_pkg "onlyoffice"  "OnlyOffice Desktop Editors" "snap" "100" "" "onlyoffice-desktopeditors"
add_pkg "teams"       "Microsoft Teams"            "snap" "150" "" "teams-for-linux"
add_pkg "slack"       "Slack"                       "snap" "100" ""
add_pkg "zoom"        "Zoom"                        "snap" "80"  "" "zoom-client"
add_pkg "google-meet" "Google Meet (Web)"           "manual" "0" "https://meet.google.com/"
add_pkg "thunderbird" "Thunderbird"                 "apt"  "50"  ""
add_pkg "okular"      "Okular PDF Viewer"           "apt"  "20"  ""
add_pkg "evince"      "Evince PDF Viewer"           "apt"  "10"  ""
add_pkg "rclone"      "Rclone (OneDrive/GDrive)"    "apt"  "10"  ""
add_pkg "insync"      "Insync (Google Drive)"       "manual" "100" "https://www.insynchq.com/downloads"

# ---------- Common / Essential ----------
add_pkg "p7zip"        "p7zip (archive)"             "apt"  "5"   "" "p7zip-full"
add_pkg "unzip"        "unzip"                       "apt"  "1"   ""
add_pkg "rar"          "RAR/UnRAR"                   "apt"  "5"   "" "unrar"
add_pkg "htop"         "htop"                        "apt"  "2"   ""
add_pkg "btop"         "btop"                        "snap" "3"   "" "btop"
add_pkg "tree"         "tree"                        "apt"  "1"   ""
add_pkg "ncdu"         "ncdu"                        "apt"  "1"   ""
add_pkg "jq"           "jq"                          "apt"  "2"   ""
add_pkg "vim"          "Vim"                         "apt"  "10"  ""
add_pkg "nano"         "Nano"                        "apt"  "2"   ""
add_pkg "ms-fonts"     "Microsoft Core Fonts"        "apt"  "30"  "" "ttf-mscorefonts-installer"
add_pkg "nerd-fonts"   "Nerd Fonts"                  "manual" "50" "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/FiraCode.zip"
add_pkg "ibus"         "IBus Input Method"           "apt"  "10"  ""
add_pkg "ibus-bamboo"  "IBus Bamboo (Vietnamese)"    "apt"  "5"   "" "ibus-bamboo"

# ---------- Designer (thêm mới) ----------
# UI/UX Design
add_pkg "figma"      "Figma Desktop (unofficial)"     "snap" "150" "" "figma-linux"
add_pkg "penpot"     "Penpot Desktop (unofficial)"    "snap" "100" "" "penpot-desktop"
add_pkg "drawio"     "draw.io Desktop"                "snap" "150" "" "drawio"
add_pkg "excalidraw" "Excalidraw (Web)"               "manual" "0" "https://excalidraw.com/"

# Graphic Design
add_pkg "gimp"     "GIMP"     "apt"  "200" ""
add_pkg "inkscape" "Inkscape" "apt"  "150" ""
add_pkg "krita"    "Krita"    "snap" "300" "" "krita"
add_pkg "blender"  "Blender"  "snap" "300" "" "blender"

# PDF Processing
add_pkg "master-pdf-editor" "Master PDF Editor"     "manual" "150" "https://code-industry.net/free-pdf-editor/"
add_pkg "pdfarranger"       "PDF Arranger"          "apt"    "10"  ""

# Utilities
add_pkg "font-manager" "Font Manager" "apt" "10" ""
add_pkg "imagemagick"  "ImageMagick"  "apt" "10" ""

# ------------------------------------------------------------------------------
# Ghi đè lệnh xác thực cho các gói
# ------------------------------------------------------------------------------
set_verify "gitkraken"       "command -v gitkraken"
set_verify "dbeaver"         "command -v dbeaver"
set_verify "beekeeper"       "command -v beekeeper-studio"
set_verify "postman"         "command -v postman"
set_verify "insomnia"        "command -v insomnia"
set_verify "bruno"           "command -v bruno"
set_verify "tableplus"       "command -v tableplus"
set_verify "chrome"          "command -v google-chrome-stable || command -v google-chrome"
set_verify "edge"            "command -v microsoft-edge-stable || command -v microsoft-edge"
set_verify "mongodb-compass" "command -v mongodb-compass"
set_verify "github-desktop"  "command -v github-desktop"
set_verify "insync"          "command -v insync"
set_verify "onlyoffice"      "command -v onlyoffice-desktopeditors"
set_verify "teams"           "snap list teams-for-linux &>/dev/null"
set_verify "zoom"            "snap list zoom-client &>/dev/null"
set_verify "openjdk"         "command -v java"
set_verify "maven"           "command -v mvn"
set_verify "golang"          "command -v go"
set_verify "pip"             "command -v pip3"
set_verify "rust"            "[ -x \"\$HOME/.cargo/bin/rustc\" ] || command -v rustc"
set_verify "poetry"          "[ -x \"\$HOME/.local/bin/poetry\" ] || command -v poetry"
set_verify "pyenv"           "[ -d \"\$HOME/.pyenv\" ] || command -v pyenv"
set_verify "nvm"             "[ -s \"\$HOME/.nvm/nvm.sh\" ]"
set_verify "ohmyzsh"         "[ -d \"\$HOME/.oh-my-zsh\" ]"
set_verify "starship"        "command -v starship"
set_verify "pnpm"            "command -v pnpm"
set_verify "docker"          "command -v docker"
set_verify "docker-compose"  "docker compose version &>/dev/null || command -v docker-compose"
set_verify "anaconda"        "[ -d \"\$HOME/anaconda3\" ]"
set_verify "miniconda"       "[ -d \"\$HOME/miniconda3\" ]"
set_verify "spark"           "[ -d /opt/spark ]"
set_verify "hadoop"          "[ -d /opt/hadoop ]"
set_verify "zeppelin"        "[ -d /opt/zeppelin ]"
set_verify "jupyter"         "command -v jupyter"
set_verify "jupyterlab"      "command -v jupyter-lab"
set_verify "google-meet"     "true"
set_verify "powerbi"         "true"
set_verify "tableau"         "true"
set_verify "pgadmin"         "true"
# Common
set_verify "p7zip"           "command -v 7z || dpkg -l p7zip-full 2>/dev/null | grep -q '^ii'"
set_verify "unzip"           "command -v unzip"
set_verify "rar"             "command -v unrar"
set_verify "htop"            "command -v htop"
set_verify "btop"            "command -v btop"
set_verify "tree"            "command -v tree"
set_verify "ncdu"            "command -v ncdu"
set_verify "jq"              "command -v jq"
set_verify "vim"             "command -v vim"
set_verify "nano"            "command -v nano"
set_verify "ms-fonts"        "dpkg -l ttf-mscorefonts-installer 2>/dev/null | grep -q '^ii'"
set_verify "nerd-fonts"      "[ -d \"\$HOME/.local/share/fonts/NerdFonts\" ] && ls \"\$HOME/.local/share/fonts/NerdFonts\"/*.ttf &>/dev/null"
set_verify "ibus"            "command -v ibus"
set_verify "ibus-bamboo"     "command -v ibus-bamboo || dpkg -l ibus-bamboo 2>/dev/null | grep -q '^ii'"
# Designer
set_verify "figma"             "command -v figma-linux"
set_verify "penpot"            "command -v penpot-desktop"
set_verify "drawio"            "command -v drawio"
set_verify "excalidraw"        "true"
set_verify "gimp"              "command -v gimp"
set_verify "inkscape"          "command -v inkscape"
set_verify "krita"             "command -v krita"
set_verify "blender"           "command -v blender"
set_verify "master-pdf-editor" "command -v master-pdf-editor"
set_verify "pdfarranger"       "command -v pdfarranger"
set_verify "font-manager"      "command -v font-manager"
set_verify "imagemagick"       "command -v convert || command -v magick"

# ------------------------------------------------------------------------------
# Hàm xác thực: kiểm tra THẬT SỰ package đã được cài đúng hay chưa
# ------------------------------------------------------------------------------
verify_package() {
    local tag="$1"
    local method="${PKG_METHOD[$tag]}"
    local pkg_id="${PKG_ID[$tag]}"

    if [ -n "${PKG_VERIFY[$tag]:-}" ]; then
        eval "${PKG_VERIFY[$tag]}" &>/dev/null
        return $?
    fi

    case "$method" in
        apt)
            dpkg-query -W -f='${Status}' "$pkg_id" 2>/dev/null | grep -q "^install ok installed"
            ;;
        snap)
            snap list "$pkg_id" &>/dev/null
            ;;
        flatpak)
            flatpak info "$pkg_id" &>/dev/null
            ;;
        pip)
            pip3 show "$tag" &>/dev/null
            ;;
        *)
            command -v "$tag" &>/dev/null
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Các hàm cài đặt theo từng nguồn
# ------------------------------------------------------------------------------
try_apt() {
    local pkg_id="$1"
    ensure_apt_updated
    apt-cache show "$pkg_id" &>/dev/null || return 1
    retry 2 sudo apt-get install -y "$pkg_id"
}

try_snap() {
    local pkg_id="$1" extra="$2"
    [ "$HAS_SNAP" -eq 1 ] || return 1
    snap info "$pkg_id" &>/dev/null || return 1
    # shellcheck disable=SC2086
    retry 2 sudo snap install "$pkg_id" $extra
}

try_flatpak() {
    local pkg_id="$1"
    [ "$HAS_FLATPAK" -eq 1 ] || return 1
    flatpak remote-info flathub "$pkg_id" &>/dev/null || return 1
    retry 2 flatpak install -y flathub "$pkg_id"
}

download_to_tmp() {
    local url="$1" dest="$2"
    retry 3 curl -fsSL "$url" -o "$dest"
}

install_via_curl_script() {
    local tag="$1"
    local url="${PKG_EXTRA[$tag]}"
    local script_file="$TMP_DIR/${tag}_install.sh"
    download_to_tmp "$url" "$script_file" || return 1
    chmod +x "$script_file"
    case "$tag" in
        ohmyzsh)  RUNZSH=no CHSH=no sh "$script_file" --unattended ;;
        starship) sh "$script_file" -y ;;
        nvm)      bash "$script_file" ;;
        poetry)   python3 "$script_file" ;;
        pyenv)    bash "$script_file" ;;
        pnpm)     sh "$script_file" ;;
        rust)     bash "$script_file" -y --default-toolchain stable ;;
        docker)   sudo sh "$script_file" ;;
        *)        bash "$script_file" ;;
    esac
}

install_via_deb() {
    local tag="$1"
    local url="${PKG_EXTRA[$tag]}"
    local deb_file="$TMP_DIR/${tag}.deb"
    download_to_tmp "$url" "$deb_file" || return 1
    sudo apt-get install -y "$deb_file" 2>/dev/null || sudo dpkg -i "$deb_file" || {
        sudo apt-get install -f -y
        sudo dpkg -i "$deb_file"
    }
}

install_via_archive() {
    local tag="$1"
    local dest_name="$2"
    local url="${PKG_EXTRA[$tag]}"
    local archive_file="$TMP_DIR/${tag}.tgz"
    download_to_tmp "$url" "$archive_file" || return 1
    sudo tar -xzf "$archive_file" -C /opt/ || return 1
    sudo ln -sfn /opt/"${dest_name}"-* /opt/"$dest_name" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Hàm cài đặt trung tâm
# ------------------------------------------------------------------------------
install_package() {
    local tag="$1"
    local method="${PKG_METHOD[$tag]}"
    local desc="${PKG_INFO[$tag]}"
    local extra="${PKG_EXTRA[$tag]}"
    local pkg_id="${PKG_ID[$tag]}"

    log INFO "Đang xử lý: $desc ($tag)"

    if [ "$FORCE_REINSTALL" -eq 0 ] && verify_package "$tag"; then
        log SUCCESS "$desc đã được cài sẵn — bỏ qua."
        PKG_STATUS["$tag"]="ĐÃ CÀI SẴN (bỏ qua)"
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log INFO "[DRY-RUN] Sẽ cài $desc qua phương thức: $method (id: $pkg_id)"
        PKG_STATUS["$tag"]="DRY-RUN"
        return 0
    fi

    local ok=1
    case "$method" in
        apt)
            try_apt "$pkg_id" && ok=0
            ;;
        snap)
            if try_apt "$pkg_id"; then
                ok=0
            elif try_snap "$pkg_id" "$extra"; then
                ok=0
            elif try_flatpak "$pkg_id"; then
                ok=0
            fi
            ;;
        flatpak)
            try_flatpak "$pkg_id" && ok=0
            ;;
        pip)
            retry 2 pip3 install --user "$tag" && ok=0
            ;;
        curl)
            install_via_curl_script "$tag" && ok=0
            ;;
        wget)
            install_via_deb "$tag" && ok=0
            ;;
        manual)
            if try_apt "$pkg_id"; then
                ok=0
            elif try_snap "$pkg_id" "$extra"; then
                ok=0
            else
                case "$tag" in
                    anaconda)
                        download_to_tmp "$extra" "$TMP_DIR/anaconda.sh" && \
                        bash "$TMP_DIR/anaconda.sh" -b -p "$HOME/anaconda3" && \
                        grep -q 'anaconda3/bin' "$HOME/.bashrc" 2>/dev/null || \
                        echo 'export PATH="$HOME/anaconda3/bin:$PATH"' >> "$HOME/.bashrc"
                        [ -d "$HOME/anaconda3" ] && ok=0
                        ;;
                    miniconda)
                        download_to_tmp "$extra" "$TMP_DIR/miniconda.sh" && \
                        bash "$TMP_DIR/miniconda.sh" -b -p "$HOME/miniconda3" && \
                        grep -q 'miniconda3/bin' "$HOME/.bashrc" 2>/dev/null || \
                        echo 'export PATH="$HOME/miniconda3/bin:$PATH"' >> "$HOME/.bashrc"
                        [ -d "$HOME/miniconda3" ] && ok=0
                        ;;
                    spark)    install_via_archive "$tag" "spark"    && ok=0 ;;
                    hadoop)   install_via_archive "$tag" "hadoop"   && ok=0 ;;
                    zeppelin) install_via_archive "$tag" "zeppelin" && ok=0 ;;
                    tableplus|bruno|chrome|edge|mongodb-compass|github-desktop|master-pdf-editor)
                        install_via_deb "$tag" && ok=0
                        ;;
                    insync)
                        log WARN "Insync yêu cầu thêm APT repo riêng có xác thực tài khoản. Vui lòng làm thủ công: $extra"
                        ;;
                    google-meet|powerbi|tableau|pgadmin|excalidraw)
                        log INFO "$desc là ứng dụng web / chưa có bản desktop ổn định. Truy cập: $extra"
                        ok=0
                        ;;
                    nerd-fonts)
                        # Cài unzip nếu chưa có (cần cho giải nén)
                        if ! command -v unzip &>/dev/null; then
                            log INFO "Cài unzip để giải nén Nerd Fonts..."
                            sudo apt-get install -y unzip || log WARN "Không thể cài unzip, thử giải nén bằng cách khác."
                        fi
                        mkdir -p "$HOME/.local/share/fonts/NerdFonts"
                        local zip_file="$TMP_DIR/nerd-fonts.zip"
                        download_to_tmp "$extra" "$zip_file" && \
                        unzip -o "$zip_file" -d "$HOME/.local/share/fonts/NerdFonts/" && \
                        fc-cache -fv
                        [ -d "$HOME/.local/share/fonts/NerdFonts" ] && ok=0
                        ;;
                    *)
                        log WARN "Chưa có quy trình tự động cho $tag. Hướng dẫn thủ công: $extra"
                        ;;
                esac
            fi
            ;;
        *)
            log ERROR "Phương thức không xác định: $method cho $tag"
            ;;
    esac

    if [ "$ok" -eq 0 ] && verify_package "$tag"; then
        log SUCCESS "$desc đã cài đặt và XÁC THỰC thành công."
        PKG_STATUS["$tag"]="OK (đã xác thực)"
        return 0
    else
        log ERROR "$desc CÀI ĐẶT THẤT BẠI hoặc không xác thực được sau khi cài."
        PKG_STATUS["$tag"]="THẤT BẠI"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# UI chọn gói
# ------------------------------------------------------------------------------
SELECTED_TAGS=()
select_packages() {
    local title="$1"; shift
    local tags=("$@")
    local items=()
    for tag in "${tags[@]}"; do
        items+=("$tag" "${PKG_INFO[$tag]}" "OFF")
    done

    local selection
    selection=$(whiptail --title "$title" --checklist \
        "Chọn các gói (Space: chọn/bỏ, Arrow: di chuyển, Enter: OK, ESC: hủy bỏ)" \
        20 80 10 "${items[@]}" 3>&1 1>&2 2>&3)
    local rc=$?

    SELECTED_TAGS=()
    if [ $rc -eq 0 ] && [ -n "$selection" ]; then
        selection=$(echo "$selection" | tr -d '"')
        IFS=' ' read -r -a SELECTED_TAGS <<< "$selection"
        return 0
    fi
    return 1
}

estimate_time() {
    local total_mb="$1" speed_mbps="$2"
    if [ "$speed_mbps" -eq 0 ] 2>/dev/null; then
        echo "Không xác định"
    else
        local seconds=$(( (total_mb * 8) / speed_mbps ))
        echo "$((seconds / 60)) phút $((seconds % 60)) giây"
    fi
}

process_category() {
    local category="$1"; shift
    local tags=("$@")
    local valid_tags=()
    for t in "${tags[@]}"; do
        [ -n "${PKG_INFO[$t]:-}" ] && valid_tags+=("$t")
    done
    [ ${#valid_tags[@]} -eq 0 ] && return 0

    while true; do
        local action
        action=$(whiptail --title "Danh mục: $category" --menu \
            "Bạn muốn làm gì với danh mục này?" 15 60 3 \
            "select" "Chọn các gói để cài đặt" \
            "skip"   "Bỏ qua danh mục này" \
            "exit"   "Thoát toàn bộ cài đặt" \
            3>&1 1>&2 2>&3)

        case "$action" in
            select)
                if select_packages "$category" "${valid_tags[@]}"; then
                    if [ ${#SELECTED_TAGS[@]} -gt 0 ]; then
                        return 0
                    fi
                    whiptail --msgbox "Bạn chưa chọn gói nào. Hãy chọn ít nhất một gói hoặc chọn 'skip'." 8 50
                elif whiptail --title "Xác nhận" --yesno "Bạn đã hủy chọn. Bỏ qua danh mục này?" 8 50; then
                    return 0
                fi
                ;;
            skip) return 0 ;;
            exit) log INFO "Thoát theo yêu cầu người dùng."; exit 0 ;;
            *)    log INFO "Thoát."; exit 0 ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------
main() {
    require_base_tools

    if ! sudo -v; then
        log ERROR "Cần quyền sudo để cài đặt."
        exit 1
    fi
    # Giữ sudo timestamp sống
    while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &
    SUDO_KEEPALIVE_PID=$!
    trap 'cleanup; kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT INT TERM

    log INFO "=== app-installer v${SCRIPT_VERSION} bắt đầu. Log: $LOG_FILE ==="
    detect_package_managers

    whiptail --title "HƯỚNG DẪN NHANH" --msgbox \
"Trong các màn hình chọn gói, bạn có thể:
  - Space: chọn/bỏ chọn một gói
  - Arrow Up/Down: di chuyển lên/xuống
  - Enter: xác nhận lựa chọn
  - ESC: hủy bỏ và quay lại

Script sẽ:
  1) Bỏ qua các gói đã cài sẵn (idempotent)
  2) Xác thực THẬT SỰ sau khi cài từng gói
  3) Ghi log chi tiết ra: $LOG_FILE
  4) Không dừng toàn bộ nếu 1 gói lỗi — báo cáo đầy đủ ở cuối" \
        17 76

    MODE=$(whiptail --title "CHỌN CHẾ ĐỘ CÀI ĐẶT" --menu \
        "Chọn chế độ phù hợp với nhu cầu của bạn:" 19 70 5 \
        "Common" "Phần mềm thiết yếu cho mọi người (browser, office, utility...)" \
        "Developer" "Công cụ phát triển (IDE, Git, Docker, ...)" \
        "Developer+Data" "Developer + Data Science (Anaconda, Spark, ...)" \
        "Officer" "Văn phòng, email, PDF, cloud, trình duyệt" \
        "Designer" "Thiết kế UI/UX, đồ hoạ, PDF, font, công cụ hỗ trợ" \
        3>&1 1>&2 2>&3)

    [ -z "$MODE" ] && { log INFO "Đã hủy."; exit 0; }

    declare -A CATEGORY_TAGS

    # ----- Chế độ Common (thiết yếu) -----
    if [[ "$MODE" == "Common" ]]; then
        CATEGORY_TAGS["Browser"]="chrome firefox"
        CATEGORY_TAGS["Communication"]="slack teams zoom"
        CATEGORY_TAGS["Archive"]="p7zip unzip rar"
        CATEGORY_TAGS["Utility"]="htop btop tree ncdu jq"
        CATEGORY_TAGS["Editor"]="vim nano"
        CATEGORY_TAGS["PDF"]="evince"
        CATEGORY_TAGS["Fonts"]="ms-fonts nerd-fonts"
        CATEGORY_TAGS["Input Method"]="ibus ibus-bamboo"
    fi

    # ----- Chế độ Developer -----
    if [[ "$MODE" == "Developer" || "$MODE" == "Developer+Data" ]]; then
        CATEGORY_TAGS["IDE"]="vscode intellij pycharm android-studio webstorm clion"
        CATEGORY_TAGS["Version Control"]="git git-lfs github-desktop gitkraken"
        CATEGORY_TAGS["Terminal"]="terminator tilix tmux screen"
        CATEGORY_TAGS["Shell"]="zsh ohmyzsh starship"
        CATEGORY_TAGS["Runtime"]="nodejs npm pnpm yarn nvm openjdk maven gradle python3 pip pipx poetry pyenv virtualenv golang rust"
        CATEGORY_TAGS["Docker"]="docker docker-compose"
        CATEGORY_TAGS["Database Client"]="dbeaver tableplus beekeeper"
        CATEGORY_TAGS["API Testing"]="postman bruno insomnia"
        CATEGORY_TAGS["Browser"]="chrome firefox edge"
        CATEGORY_TAGS["SSH"]="openssh-client"
    fi

    # ----- Bổ sung cho Developer+Data -----
    if [[ "$MODE" == "Developer+Data" ]]; then
        CATEGORY_TAGS["Python Environment"]="anaconda miniconda jupyter jupyterlab"
        CATEGORY_TAGS["Data Processing"]="spark hadoop"
        CATEGORY_TAGS["BI Tools"]="powerbi tableau"
        CATEGORY_TAGS["Notebook"]="zeppelin"
        CATEGORY_TAGS["Database Client"]+=" pgadmin mongodb-compass"
    fi

    # ----- Chế độ Officer (Văn phòng) -----
    if [[ "$MODE" == "Officer" ]]; then
        CATEGORY_TAGS["Office"]="libreoffice onlyoffice"
        CATEGORY_TAGS["Communication"]="teams slack zoom google-meet"
        CATEGORY_TAGS["Mail"]="thunderbird"
        CATEGORY_TAGS["PDF"]="okular evince"
        CATEGORY_TAGS["Cloud"]="rclone insync"
        CATEGORY_TAGS["Browser"]="chrome firefox edge"
    fi

    # ----- Chế độ Designer (Thiết kế) -----
    if [[ "$MODE" == "Designer" ]]; then
        CATEGORY_TAGS["UI/UX Design"]="figma penpot drawio excalidraw"
        CATEGORY_TAGS["Graphic Design"]="gimp inkscape krita blender"
        CATEGORY_TAGS["PDF Processing"]="master-pdf-editor okular pdfarranger"
        CATEGORY_TAGS["Design Utilities"]="font-manager imagemagick"
        CATEGORY_TAGS["Browser"]="chrome firefox edge"
    fi

    # Lấy danh sách category
    categories=()
    for key in "${!CATEGORY_TAGS[@]}"; do categories+=("$key"); done
    total=${#categories[@]}
    index=1
    ALL_SELECTED=()

    for category in "${categories[@]}"; do
        IFS=' ' read -r -a tags <<< "${CATEGORY_TAGS[$category]}"
        process_category "[$index/$total] $category" "${tags[@]}"
        for t in "${SELECTED_TAGS[@]}"; do ALL_SELECTED+=("$t"); done
        SELECTED_TAGS=()
        ((index++))
    done

    if [ ${#ALL_SELECTED[@]} -gt 0 ]; then
        IFS=" " read -r -a UNIQ_SELECTED <<< "$(echo "${ALL_SELECTED[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
    else
        UNIQ_SELECTED=()
    fi

    if [ ${#UNIQ_SELECTED[@]} -eq 0 ]; then
        whiptail --title "Thông báo" --msgbox "Bạn đã bỏ qua tất cả danh mục. Không có gì để cài đặt." 8 50
        exit 0
    fi

    TOTAL_SIZE=0
    for pkg in "${UNIQ_SELECTED[@]}"; do
        TOTAL_SIZE=$((TOTAL_SIZE + ${PKG_SIZE[$pkg]}))
    done
    whiptail --title "Tổng kết" --msgbox "Đã chọn ${#UNIQ_SELECTED[@]} gói. Tổng dung lượng ước tính: ~${TOTAL_SIZE} MB" 9 55

    SPEED=$(whiptail --inputbox "Nhập tốc độ mạng (Mbps), mặc định 20:" 8 50 "20" 3>&1 1>&2 2>&3)
    [[ "$SPEED" =~ ^[0-9]+$ ]] || SPEED=20
    whiptail --title "Ước lượng thời gian" --msgbox "Với tốc độ ${SPEED} Mbps, thời gian tải dự kiến: $(estimate_time "$TOTAL_SIZE" "$SPEED")" 8 60

    if ! whiptail --title "Xác nhận" --yesno "Bắt đầu cài đặt ${#UNIQ_SELECTED[@]} gói đã chọn?" 8 50; then
        log INFO "Đã hủy bởi người dùng."
        exit 0
    fi

    log INFO "Bắt đầu cài đặt ${#UNIQ_SELECTED[@]} gói..."
    local fail_count=0
    for pkg in "${UNIQ_SELECTED[@]}"; do
        install_package "$pkg" || ((fail_count++))
    done

    # ---- BÁO CÁO CUỐI ----
    {
        echo ""
        echo "===================== BÁO CÁO CÀI ĐẶT ====================="
        printf "%-20s %-30s\n" "GÓI" "TRẠNG THÁI"
        for pkg in "${UNIQ_SELECTED[@]}"; do
            printf "%-20s %-30s\n" "$pkg" "${PKG_STATUS[$pkg]:-KHÔNG RÕ}"
        done
        echo "============================================================="
    } | tee -a "$LOG_FILE"

    if [ "$fail_count" -gt 0 ]; then
        whiptail --title "Hoàn tất (có lỗi)" --msgbox \
"Cài đặt hoàn tất với ${fail_count} gói THẤT BẠI trong tổng số ${#UNIQ_SELECTED[@]}.
Xem chi tiết log tại: $LOG_FILE
Một số gói có thể cần khởi động lại terminal / đăng xuất-đăng nhập lại." 12 70
    else
        whiptail --title "Hoàn tất" --msgbox \
"Cài đặt hoàn tất — tất cả ${#UNIQ_SELECTED[@]} gói đã được xác thực thành công.
Log chi tiết: $LOG_FILE
Một số gói có thể cần khởi động lại terminal / đăng xuất-đăng nhập lại." 11 70
    fi

    log INFO "=== Hoàn tất. ${fail_count} lỗi / ${#UNIQ_SELECTED[@]} gói. ==="
}

main "$@"