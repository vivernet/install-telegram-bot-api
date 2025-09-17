#!/usr/bin/env bash

###############################################################################
# Автоматическая установка и обновление Telegram Bot API Server
# © 2025 - https://github.com/vivernet
#
# Основные функции:
# - Установка зависимостей для сборки
# - Создание системного пользователя и группы для изолированной работы службы
# - Клонирование официального репозитория Telegram Bot API
# - Компиляция бинарника с использованием Clang и libc++
# - Интерактивный запрос директории для установки
# - Интерактивный запрос настроек конфигурации
# - Интерактивный запрос api_id и api_hash
# - Создание необходимой структуры директорий
# - Настройка прав доступа и владельцев файлов
# - Создание и настройка systemd службы с ограничениями безопасности
# - Настройка logrotate для автоматического управления логами
# - Ротация резервных копий (сохранение последних 5 версий)
# - Проверка корректности установки и вывод команд управления
#
# Требования:
# - Запуск с правами root (sudo)
# - Поддерживаемые ОС: Debian 10+ и совместимые дистрибутивы
###############################################################################

set -Eeuo pipefail
umask 027
readonly SCRIPT_START_TS=$(date +%s)
shopt -s inherit_errexit 2>/dev/null || true

# -----------------------------------------------------------------------------
# Диагностика ошибок
# -----------------------------------------------------------------------------
last_cmd=""
current_cmd=""
trap 'last_cmd=$current_cmd; current_cmd=$BASH_COMMAND' DEBUG

error_trap() {
	rc=$?
	echo "[$(date '+%F %T')] Ошибка (код $rc). Последняя команда: ${last_cmd:-unknown}" >&2
	if [[ -n "${LOG_FILE:-}" && -f "$LOG_FILE" ]]; then
		echo "==================== tail $LOG_FILE (last 200 lines) ====================" >&2
		tail -n 200 "$LOG_FILE" || true
	fi
	exit $rc
}
trap 'error_trap' ERR

# -----------------------------------------------------------------------------
# Проверка прав root
# -----------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
	echo "Скрипт необходимо запускать с правами root (sudo)." >&2
	exit 1
fi

# -----------------------------------------------------------------------------
# Значения по умолчанию
# -----------------------------------------------------------------------------
DEFAULT_INSTALL_DIR="/opt/telegram-bot-api"
DEFAULT_API_PORT=8081
DEFAULT_SERVICE_NAME="telegram-bot-api"
DEFAULT_SERVICE_USER="telegram-bot-api"
DEFAULT_SRC_DIR="/usr/local/src/telegram-bot-api"
REPO_URL="https://github.com/tdlib/telegram-bot-api.git"

# -----------------------------------------------------------------------------
# Вспомогательные функции
# -----------------------------------------------------------------------------
log() {
	local ts msg
	ts="$(date '+%F %T')"
	msg="$*"
	if [[ -n "${LOG_FILE:-}" ]]; then
		printf "[%s] %s\n" "$ts" "$msg" | tee -a "$LOG_FILE"
	else
		printf "[%s] %s\n" "$ts" "$msg"
	fi
}

# Выполнение команды с выводом в лог и консоль
run_and_watch() {
	local desc="$1"; shift
	if [[ "$#" -eq 0 ]]; then
		log "run_and_watch: отсутствует команда"
		return 1
	fi

	local logfile="${LOG_FILE:-/dev/null}"
	local rcfile
	rcfile=$(mktemp) || { log "Не удалось создать временный файл"; return 1; }

	(
		set -o pipefail
		"$@" 2>&1 | tee -a "$logfile"
		echo $? > "$rcfile"
	) &
	local pid=$!

	printf "%s ..." "$desc"
	wait "$pid" || true
	printf "\r%s ✔\n" "$desc"

	local rc=1
	if [[ -f "$rcfile" ]]; then
		rc=$(<"$rcfile")
		rm -f "$rcfile"
	fi
	return "$rc"
}

# Чтение значений key=value из конфигурационного файла
read_config_value() {
	local key="$1"
	local file="$2"
	if [[ -f "$file" ]]; then
		awk -F= -v k="$key" '
			$1==k {
				$1=""; sub(/^=/,""); val=$0;
				gsub(/^[ \t]+|[ \t]+$/, "", val);
				if (val ~ /^".*"$/ || val ~ /^\x27.*\x27$/) {
					val = substr(val, 2, length(val)-2)
				}
				print val
				exit
			}' "$file" || true
	fi
}

save_config() {
	local cfgfile="$1"
	shift
	mkdir -p "$(dirname "$cfgfile")"
	: > "$cfgfile"
	for kv in "$@"; do
		printf '%s\n' "$kv" >> "$cfgfile"
	done
	chown root:root "$cfgfile"
	chmod 600 "$cfgfile"
	log "Конфигурационный файл сохранён: $cfgfile"
}

# Проверка существования юнита в systemd
unit_exists() {
	# systemctl cat возвращает 0 если юнит известен
	systemctl cat "${1}.service" >/dev/null 2>&1
}

# Безопасные обёртки для проверки состояния служб
unit_is_active() {
	systemctl is-active --quiet "${1}.service" >/dev/null 2>&1
}
unit_is_enabled() {
	systemctl is-enabled --quiet "${1}.service" >/dev/null 2>&1
}

# Проверка состояния порта
# Возвращаемые значения:
# 0 - порт свободен
# 1 - порт занят указанной службой (в stdout выводится PID)
# 2 - порт занят другим процессом (в stdout выводится pid или "unknown")
port_check() {
	local port="$1"
	local svc="$2"
	local ssout pid svc_mainpid

	# Получение слушающих сокетов для указанного порта (IPv4/IPv6)
	ssout=$(ss -ltnp "( sport = :${port} )" 2>/dev/null || true)

	# Если вывода нет или нет LISTEN — порт свободен
	if [[ -z "$ssout" ]] || ! echo "$ssout" | grep -q LISTEN; then
		return 0
	fi

	# Извлечение pid из вывода ss
	pid=$(echo "$ssout" | grep -Po 'pid=\K[0-9]+' | head -n1 || true)

	# Резервный метод через lsof
	if [[ -z "$pid" && -x "$(command -v lsof)" ]]; then
		pid=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -Fp 2>/dev/null | sed -n 's/^p//p' | head -n1 || true)
	fi

	if [[ -z "$pid" ]]; then
		echo "unknown-pid"
		return 2
	fi

	# Получение MainPID службы systemd
	if unit_exists "$svc"; then
		svc_mainpid=$(systemctl show -p MainPID --value "${svc}.service" 2>/dev/null || true)
	else
		svc_mainpid=0
	fi

	# Сравнение: если слушающий pid совпадает с MainPID службы — порт занят нашей службой
	if [[ -n "$svc_mainpid" && "$svc_mainpid" != "0" && "$svc_mainpid" == "$pid" ]]; then
		printf "%s" "$pid"
		return 1
	fi

	# Порт занят другим процессом
	printf "%s" "$pid"
	return 2
}

# Определение ветки по умолчанию в репозитории
detect_default_branch() {
	local repo_dir="$1"
	local branch
	branch=$(git -C "$repo_dir" rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's@^origin/@@' || true)
	if [[ -z "$branch" ]]; then branch="master"; fi
	printf "%s" "$branch"
}

# Генерация конфигурации systemd unit
generate_unit() {
	cat <<EOF
[Unit]
Description=Telegram Bot API
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=-${ENV_FILE}
ExecStart=${BIN_DIR}/telegram-bot-api --local --http-port=${API_PORT} --dir=${DATA_DIR} --log=${LOG_DIR}/telegram-bot-api.log
Restart=on-failure
RestartSec=10
LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${DATA_DIR} ${LOG_DIR}
PrivateDevices=true
MemoryDenyWriteExecute=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6
StandardOutput=null
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

# Создание конфигурации logrotate
create_logrotate() {
	local lrfile="/etc/logrotate.d/telegram-bot-api"
	cat > "$lrfile" <<LR
${LOG_DIR}/*.log {
	daily
	rotate 7
	compress
	missingok
	notifempty
	copytruncate
	create 640 ${SERVICE_USER} ${SERVICE_GROUP}
}
LR
	log "Конфигурация logrotate создана в $lrfile"
}

# Проверка прав доступа к файлам и директориям
verify_permissions() {
	local failed=0
	declare -A want_owner want_mode create_if_missing is_dir

	# Описание ожидаемых прав доступа
	# Формат mode — строка (например "0755" или "0600")
	want_owner["$BIN_DIR/telegram-bot-api"]="root:root"
	want_mode["$BIN_DIR/telegram-bot-api"]="0755"
	is_dir["$BIN_DIR/telegram-bot-api"]=0

	want_owner["$ENV_FILE"]="${SERVICE_USER}:${SERVICE_GROUP}"
	want_mode["$ENV_FILE"]="0600"
	is_dir["$ENV_FILE"]=0

	want_owner["$LOG_DIR"]="${SERVICE_USER}:${SERVICE_GROUP}"
	want_mode["$LOG_DIR"]="0750"
	is_dir["$LOG_DIR"]=1

	want_owner["$LOG_DIR/telegram-bot-api.log"]="${SERVICE_USER}:${SERVICE_GROUP}"
	want_mode["$LOG_DIR/telegram-bot-api.log"]="0640"
	is_dir["$LOG_DIR/telegram-bot-api.log"]=0

	want_owner["$DATA_DIR"]="${SERVICE_USER}:${SERVICE_GROUP}"
	want_mode["$DATA_DIR"]="0750"
	is_dir["$DATA_DIR"]=1

	want_owner["$BACKUP_DIR"]="${SERVICE_USER}:${SERVICE_GROUP}"
	want_mode["$BACKUP_DIR"]="0750"
	is_dir["$BACKUP_DIR"]=1

	want_owner["$CONFIG_FILE"]="root:root"
	want_mode["$CONFIG_FILE"]="0600"
	is_dir["$CONFIG_FILE"]=0

	for path in "${!want_owner[@]}"; do
		local expected_owner="${want_owner[$path]}"
		local expected_mode="${want_mode[$path]}"
		local path_is_dir="${is_dir[$path]:-0}"

		# Создание директории, если она не существует
		if [[ "$path_is_dir" -eq 1 && ! -d "$path" ]]; then
			log "verify_permissions: $path не существует — создание директории."
			if ! mkdir -p "$path"; then
				log "verify_permissions: не удалось создать директорию $path"
				failed=1
				continue
			fi
		fi

		# Создание файла, если он не существует
		if [[ "$path_is_dir" -eq 0 && ! -e "$path" ]]; then
			log "verify_permissions: $path отсутствует — создание пустого файла."
			if ! touch "$path"; then
				log "verify_permissions: не удалось создать файл $path"
				failed=1
				continue
			fi
		fi

		# Получение фактических значений прав доступа
		actual_owner="$(stat -c '%U:%G' "$path" 2>/dev/null || true)"
		actual_mode="$(stat -c '%a' "$path" 2>/dev/null || true)"

		# Нормализация формата прав доступа
		printf -v actual_mode "%s" "$actual_mode"
		printf -v expected_mode "%s" "$expected_mode"
		while [[ ${#actual_mode} -lt 4 ]]; do actual_mode="0${actual_mode}"; done
		while [[ ${#expected_mode} -lt 4 ]]; do expected_mode="0${expected_mode}"; done

		if [[ "$actual_owner" != "$expected_owner" ]]; then
			log "verify_permissions: $path несовпадение владельца: expected=$expected_owner actual=$actual_owner — исправление..."
			if ! chown "$expected_owner" "$path"; then
				log "verify_permissions: не удалось изменить владельца $path"
				failed=1
			fi
		fi

		if [[ "$actual_mode" != "$expected_mode" ]]; then
			log "verify_permissions: $path несовпадение прав: expected=$expected_mode actual=$actual_mode — исправление..."
			if ! chmod "$expected_mode" "$path"; then
				log "verify_permissions: не удалось изменить права $path"
				failed=1
			fi
		fi
	done

	if [[ $failed -ne 0 ]]; then
		log "verify_permissions: Возникли проблемы с некоторыми файлами/директориями. Проверьте вручную!"
		return 1
	fi

	log "verify_permissions: Владельцы и права доступа к файлам и директориям корректны."
	return 0
}

# -----------------------------------------------------------------------------
# Ввод директории установки
# -----------------------------------------------------------------------------
read -r -p "Подтвердите директорию для установки Telegram Bot API или введите другую [${DEFAULT_INSTALL_DIR}]: " input_install_dir
INSTALL_DIR="${input_install_dir:-$DEFAULT_INSTALL_DIR}"
INSTALL_DIR="${INSTALL_DIR%/}"

CONFIG_FILE="$INSTALL_DIR/config.conf"
ENV_FILE="$INSTALL_DIR/.env"
DATA_DIR="$INSTALL_DIR/data"
LOG_DIR="$INSTALL_DIR/logs"
BIN_DIR="$INSTALL_DIR/bin"
BACKUP_DIR="$INSTALL_DIR/backup"

# -----------------------------------------------------------------------------
# Чтение настроек из конфигурационного файла или запрос у пользователя
# -----------------------------------------------------------------------------
if [[ -f "$CONFIG_FILE" ]]; then
	log "Найден $CONFIG_FILE — чтение ранее установленных настроек..."
	cfg_api_port=$(read_config_value "API_PORT" "$CONFIG_FILE" || true)
	cfg_service_name=$(read_config_value "SERVICE_NAME" "$CONFIG_FILE" || true)
	cfg_service_user=$(read_config_value "SERVICE_USER" "$CONFIG_FILE" || true)
	cfg_src_dir=$(read_config_value "SRC_DIR" "$CONFIG_FILE" || true)

	API_PORT="${cfg_api_port:-$DEFAULT_API_PORT}"
	SERVICE_NAME="${cfg_service_name:-$DEFAULT_SERVICE_NAME}"
	SERVICE_USER="${cfg_service_user:-$DEFAULT_SERVICE_USER}"
	SRC_DIR="${cfg_src_dir:-$DEFAULT_SRC_DIR}"
else
	read -r -p "Подтвердите порт для запуска Telegram Bot API или введите другой [${DEFAULT_API_PORT}]: " input_port
	API_PORT="${input_port:-$DEFAULT_API_PORT}"
	read -r -p "Подтвердите название для службы (systemd) или введите другое [${DEFAULT_SERVICE_NAME}]: " input_svc
	SERVICE_NAME="${input_svc:-$DEFAULT_SERVICE_NAME}"
	read -r -p "Подтвердите имя системного пользователя для службы или введите другое [${DEFAULT_SERVICE_USER}]: " input_user
	SERVICE_USER="${input_user:-$DEFAULT_SERVICE_USER}"
	read -r -p "Подтвердите директорию для загрузки исходников Telegram Bot API или введите другую [${DEFAULT_SRC_DIR}]: " input_src
	SRC_DIR="${input_src:-$DEFAULT_SRC_DIR}"
fi

SERVICE_GROUP="${SERVICE_USER}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
LOG_FILE="$LOG_DIR/install.log"

# -----------------------------------------------------------------------------
# Запрос отсутствующих настроек
# -----------------------------------------------------------------------------
if [[ -z "${API_PORT:-}" ]]; then
	read -r -p "Порт для запуска Telegram Bot API не указан. Пожалуйста, введите порт для запуска Telegram Bot API (рекомендуется: ${DEFAULT_API_PORT}): " API_PORT
fi
if [[ -z "${SERVICE_NAME:-}" ]]; then
	read -r -p "Название для службы (systemd) не указано. Пожалуйста, введите название службы (рекомендуется: ${DEFAULT_SERVICE_NAME}): " SERVICE_NAME
fi
if [[ -z "${SERVICE_USER:-}" ]]; then
	read -r -p "Имя системного пользователя для службы не указано. Пожалуйста, введите имя системного пользователя (рекомендуется: ${DEFAULT_SERVICE_USER}): " SERVICE_USER
	SERVICE_GROUP="$SERVICE_USER"
fi
if [[ -z "${SRC_DIR:-}" ]]; then
	read -r -p "Директорию для загрузки исходников Telegram Bot API не указана. Пожалуйста, введите директорию для загрузки исходников (рекомендуется: ${DEFAULT_SRC_DIR}): " SRC_DIR
fi

# -----------------------------------------------------------------------------
# Сохранение настроек в конфигурационный файл
# -----------------------------------------------------------------------------
mkdir -p "$INSTALL_DIR"
save_config "$CONFIG_FILE" \
	"INSTALL_DIR=${INSTALL_DIR}" \
	"API_PORT=${API_PORT}" \
	"SERVICE_NAME=${SERVICE_NAME}" \
	"SERVICE_USER=${SERVICE_USER}" \
	"SRC_DIR=${SRC_DIR}"

# -----------------------------------------------------------------------------
# Подготовка окружения
# -----------------------------------------------------------------------------
mkdir -p "$LOG_DIR" "$DATA_DIR" "$BIN_DIR" "$BACKUP_DIR"
if [[ -f "$LOG_FILE" ]]; then rm -f "$LOG_FILE" || true; fi
: > "$LOG_FILE"
chown root:root "$LOG_FILE"
chmod 600 "$LOG_FILE"

log "Начало установки/обновления Telegram Bot API..."
log "INSTALL_DIR=${INSTALL_DIR}"
log "API_PORT=${API_PORT}"
log "SERVICE_NAME=${SERVICE_NAME}"
log "SERVICE_USER=${SERVICE_USER}"
log "SRC_DIR=${SRC_DIR}"

# -----------------------------------------------------------------------------
# Проверка и создание системного пользователя
# -----------------------------------------------------------------------------
if ! id "$SERVICE_USER" &>/dev/null; then
	log "Создание системного пользователя $SERVICE_USER..."
	useradd --system --no-create-home --shell /usr/sbin/nologin --comment "Telegram Bot API" "$SERVICE_USER"
else
	log "Пользователь $SERVICE_USER уже существует."
fi

# -----------------------------------------------------------------------------
# Установка прав доступа к директориям
# -----------------------------------------------------------------------------
chown -R "$SERVICE_USER":"$SERVICE_GROUP" "$DATA_DIR" "$LOG_DIR" "$BACKUP_DIR" || true
chmod 750 "$DATA_DIR" "$BACKUP_DIR" || true
chmod 750 "$LOG_DIR" || true

# -----------------------------------------------------------------------------
# Создание основного лога службы
# -----------------------------------------------------------------------------
touch "$LOG_DIR/telegram-bot-api.log"
chown "$SERVICE_USER":"$SERVICE_GROUP" "$LOG_DIR/telegram-bot-api.log" || true
chmod 640 "$LOG_DIR/telegram-bot-api.log" || true

# -----------------------------------------------------------------------------
# Проверка наличия api_id и api_hash в .env файле
# -----------------------------------------------------------------------------
api_id_val=""
api_hash_val=""
if [[ -f "$ENV_FILE" ]]; then
	api_id_val=$(grep -E '^TELEGRAM_API_ID=' "$ENV_FILE" 2>/dev/null | sed 's/^TELEGRAM_API_ID=//')
	api_hash_val=$(grep -E '^TELEGRAM_API_HASH=' "$ENV_FILE" 2>/dev/null | sed 's/^TELEGRAM_API_HASH=//')
fi

if [[ -z "${api_id_val// }" || -z "${api_hash_val// }" ]]; then
	log "api_id и api_hash не указаны."
	echo "Получить api_id и api_hash: https://core.telegram.org/api/obtaining_api_id"
	while true; do
		read -r -p "Введите api_id: " input_api_id
		if [[ -n "${input_api_id// }" ]]; then break; fi
		echo "api_id обязателен!"
	done
	while true; do
		read -r -p "Введите api_hash: " input_api_hash
		if [[ -n "${input_api_hash// }" ]]; then break; fi
		echo "api_hash обязателен!"
	done
	cat > "$ENV_FILE" <<EOF
TELEGRAM_API_ID=${input_api_id}
TELEGRAM_API_HASH=${input_api_hash}
EOF
	chown "$SERVICE_USER":"$SERVICE_GROUP" "$ENV_FILE" || true
	chmod 600 "$ENV_FILE"
	log "Создан/обновлён $ENV_FILE"
else
	log "api_id и api_hash указаны."
fi

# -----------------------------------------------------------------------------
# Установка необходимых пакетов
# -----------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
log "Обновление списка пакетов..."
run_and_watch "apt-get update" apt-get update

log "Установка зависимостей для сборки..."
run_and_watch "Установка пакетов" apt-get install -y --no-install-recommends build-essential make git cmake pkg-config zlib1g-dev libssl-dev gperf clang libc++-dev libc++abi-dev ca-certificates curl wget gnupg lsb-release iproute2 lsof

log "Зависимости установлены."

# -----------------------------------------------------------------------------
# Проверка доступности порта
# -----------------------------------------------------------------------------
while true; do
	pidinfo=$(port_check "$API_PORT" "$SERVICE_NAME" || true)
	rc=$?
	if [[ $rc -eq 0 ]]; then
		log "Порт $API_PORT свободен."
		break
	elif [[ $rc -eq 1 ]]; then
		log "Порт $API_PORT занят, но этот PID соответствует службе $SERVICE_NAME — OK."
		break
	else
		log "Порт $API_PORT занят (PID: ${pidinfo:-unknown})."
		read -r -p "Указать другой порт? (y/N): " yn
		yn="${yn:-N}"
		if [[ "$yn" =~ ^[Yy]$ ]]; then
			read -r -p "Новый порт: " newport
			API_PORT="${newport:-$API_PORT}"
			save_config "$CONFIG_FILE" \
				"INSTALL_DIR=${INSTALL_DIR}" \
				"API_PORT=${API_PORT}" \
				"SERVICE_NAME=${SERVICE_NAME}" \
				"SERVICE_USER=${SERVICE_USER}" \
				"SRC_DIR=${SRC_DIR}"
			continue
		else
			log "Операция прервана пользователем из-за занятого порта: $API_PORT."
			exit 1
		fi
	fi
done

# -----------------------------------------------------------------------------
# Клонирование официального репозитория Telegram Bot API
# -----------------------------------------------------------------------------
if [[ ! -d "$SRC_DIR/.git" ]]; then
	log "Клонирование официального репозитория Telegram Bot API в $SRC_DIR ..."
	mkdir -p "$(dirname "$SRC_DIR")"
	run_and_watch "git clone --recursive" git clone --recursive "$REPO_URL" "$SRC_DIR" || { log "git clone --recursive FAILED"; exit 1; }
else
	log "Обновление с официального репозитория Telegram Bot API в $SRC_DIR ..."
	run_and_watch "git pull --recurse-submodules" git -C "$SRC_DIR" pull --recurse-submodules || { log "git pull FAILED"; exit 1; }
	run_and_watch "git submodule update --init --recursive" git -C "$SRC_DIR" submodule update --init --recursive || { log "git submodule update FAILED"; exit 1; }
fi

# -----------------------------------------------------------------------------
# Сборка проекта
# -----------------------------------------------------------------------------
log "Сборка Telegram Bot API..."
pushd "$SRC_DIR" >/dev/null
rm -rf build || true
mkdir -p build && cd build
log "Конфигурация CMake..."
run_and_watch "cmake configure" env CXXFLAGS="-stdlib=libc++" CC=/usr/bin/clang CXX=/usr/bin/clang++ cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX:PATH=.. .. || { log "cmake configure FAILED"; exit 1; }
CPU_COUNT=$(nproc || echo 1)
log "Компиляция (потоков: $CPU_COUNT)..."
run_and_watch "cmake --build" cmake --build . --target install -- -j"${CPU_COUNT}" || { log "cmake --build FAILED"; exit 1; }
popd >/dev/null

# -----------------------------------------------------------------------------
# Проверка скомпилированного бинарника
# -----------------------------------------------------------------------------
if [[ ! -f "$SRC_DIR/bin/telegram-bot-api" ]]; then
	log "Бинарник не найден в $SRC_DIR/bin/telegram-bot-api"
	exit 1
fi
chmod +x "$SRC_DIR/bin/telegram-bot-api" || true

# -----------------------------------------------------------------------------
# Остановка службы (если существует и запущена)
# -----------------------------------------------------------------------------
WAS_ENABLED=0
if unit_exists "$SERVICE_NAME"; then
	if unit_is_enabled "$SERVICE_NAME"; then
		WAS_ENABLED=1
		log "Служба ${SERVICE_NAME} запущена — отключение автозапуска службы..."
		run_and_watch "Отключение службы" systemctl disable "$SERVICE_NAME" || true
	else
		log "Служба ${SERVICE_NAME} не запущена."
	fi
else
	log "Служба ${SERVICE_NAME} не существует (новая установка)."
fi

if unit_exists "$SERVICE_NAME" && unit_is_active "$SERVICE_NAME"; then
	log "Служба ${SERVICE_NAME} запущена — остановка службы..."
	run_and_watch "Остановка службы" systemctl stop "$SERVICE_NAME" || true
fi

# -----------------------------------------------------------------------------
# Создание резервной копии старого бинарника
# -----------------------------------------------------------------------------
if [[ -f "$BIN_DIR/telegram-bot-api" ]]; then
	TS=$(date '+%Y%m%d-%H%M%S')
	cp "$BIN_DIR/telegram-bot-api" "$BACKUP_DIR/telegram-bot-api-$TS"
	log "Старый бинарник сохранён в $BACKUP_DIR/telegram-bot-api-$TS"
	ls -1t "$BACKUP_DIR"/telegram-bot-api-* 2>/dev/null | sed -n '6,$p' | xargs -r rm --
fi

# -----------------------------------------------------------------------------
# Копирование нового бинарника
# -----------------------------------------------------------------------------
mkdir -p "$BIN_DIR"
cp "$SRC_DIR/bin/telegram-bot-api" "$BIN_DIR/telegram-bot-api"
chown root:root "$BIN_DIR/telegram-bot-api"
chmod 755 "$BIN_DIR/telegram-bot-api"
log "Новый бинарник скопирован в $BIN_DIR/telegram-bot-api"

# -----------------------------------------------------------------------------
# Создание и обновление systemd unit
# -----------------------------------------------------------------------------
UNIT_CHANGED=0
NEW_UNIT_CONTENT=$(generate_unit)

# Подготовка временного файла и атомарная замена
tmpf=$(mktemp) || { log "mktemp FAILED"; exit 1; }

# Удаление временного файла в случае ошибки
_cleanup_tmpf() { [[ -f "$tmpf" ]] && rm -f "$tmpf" || true; }
trap _cleanup_tmpf EXIT

printf '%s\n' "$NEW_UNIT_CONTENT" >"$tmpf" || { log "Не удалось записать временный unit-файл"; exit 1; }

# Установка прав доступа к временному файлу
chown root:root "$tmpf" || { log "chown на tmpf FAILED"; exit 1; }
chmod 644 "$tmpf" || { log "chmod на tmpf FAILED"; exit 1; }

if [[ -f "$SERVICE_FILE" ]]; then
	cur_md5=$(md5sum "$SERVICE_FILE" | awk '{print $1}')
	new_md5=$(md5sum "$tmpf" | awk '{print $1}')
	if [[ "$cur_md5" != "$new_md5" ]]; then
		log "systemd unit некорректен — обновление $SERVICE_FILE"
		mv -f "$tmpf" "$SERVICE_FILE" || { log "mv FAILED"; exit 1; }
		UNIT_CHANGED=1
	else
		log "systemd unit корректен."
	fi
else
	log "Создание systemd unit $SERVICE_FILE"
	mv -f "$tmpf" "$SERVICE_FILE" || { log "mv FAILED"; exit 1; }
	UNIT_CHANGED=1
fi

trap - EXIT

if [[ "$UNIT_CHANGED" -eq 1 ]]; then
	run_and_watch "systemctl daemon-reload" systemctl daemon-reload || { log "daemon-reload FAILED"; exit 1; }
	systemctl reset-failed || true
fi

# -----------------------------------------------------------------------------
# Запуск и включение автозапуска службы
# -----------------------------------------------------------------------------
log "Попытка запуска службы $SERVICE_NAME..."
run_and_watch "Запуск службы" systemctl start "$SERVICE_NAME" || true

if systemctl is-active --quiet "$SERVICE_NAME"; then
	log "Служба $SERVICE_NAME успешно запущена."

	if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
		log "Автозапуск службы уже включён."
	else
		log "Включение автозапуска службы."
		run_and_watch "Включение службы" systemctl enable "$SERVICE_NAME" || true
	fi
else
	log "Служба $SERVICE_NAME не запустилась. Проверьте логи: journalctl -u $SERVICE_NAME -n 200"
	log "Автозапуск службы оставлен отключённым."
fi

# -----------------------------------------------------------------------------
# Создание конфигурации logrotate
# -----------------------------------------------------------------------------
if [[ ! -f /etc/logrotate.d/telegram-bot-api ]]; then
	create_logrotate
fi

# -----------------------------------------------------------------------------
# Проверка прав доступа к файлам и директориям
# -----------------------------------------------------------------------------
verify_permissions || log "verify_permissions вернул ошибку!"

# -----------------------------------------------------------------------------
# Финальная информация
# -----------------------------------------------------------------------------
sleep 1
IS_ACTIVE=0; IS_ENABLED=0
if systemctl is-active --quiet "$SERVICE_NAME"; then IS_ACTIVE=1; fi
if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then IS_ENABLED=1; fi

log "==================== Результат установки ===================="
if [[ "$IS_ACTIVE" -eq 1 ]]; then log "Служба: запущена (active)." ; else log "Служба: НЕ запущена (inactive)." ; fi
if [[ "$IS_ENABLED" -eq 1 ]]; then log "Автозапуск: включён (enabled)." ; else log "Автозапуск: отключён (disabled)." ; fi

cat <<INFO

Базовые команды для управления службой ${SERVICE_NAME}:

	# Проверка статуса службы
	systemctl status ${SERVICE_NAME}

	# Запуск службы
	systemctl start ${SERVICE_NAME}

	# Включение автозапуска службы
	systemctl enable ${SERVICE_NAME}

	# Перезапуск службы
	systemctl restart ${SERVICE_NAME}

	# Отключение автозапуска службы
	systemctl disable ${SERVICE_NAME}

	# Остановка службы
	systemctl stop ${SERVICE_NAME}

	# Просмотр логов службы
	journalctl -u ${SERVICE_NAME} -f

	# Лог установки
	tail -n +1 ${LOG_FILE}

INFO

log "Mission Complete!"
