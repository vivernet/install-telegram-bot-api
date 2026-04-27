# install-telegram-bot-api

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Скрипт для **автоматической установки и обновления** [Telegram Bot API Server](https://core.telegram.org/bots/api#using-a-local-bot-api-server) на серверах с **Debian 10+ и совместимыми дистрибутивами Linux**.

## ✨ Возможности

- Установка всех необходимых зависимостей для сборки
- Создаёт изолированного системного пользователя и группу
- Клонирует официальный репозиторий [tdlib/telegram-bot-api](https://github.com/tdlib/telegram-bot-api)
- Компилирует с использованием **Clang** + **libc++**
- Интерактивная настройка:
  - Директория установки
  - Порт для запуска Telegram Bot API
  - Имя службы
  - Имя системного пользователя
  - `api_id` и `api_hash`
- Настройка структуры директорий (`bin/`, `data/`, `logs/`, `backup/`)
- Настройка параметров сборки для маломощных серверов (щадящий режим + ограничение потоков)
- Создание и настройка **systemd unit** с безопасными ограничениями
- Настройка **logrotate** для управления логами
- Автоматическая ротация резервных копий (хранение последних 5 бинарников)
- Проверка прав доступа и исправление при необходимости
- Пошаговое логирование установки

## 📋 Требования

- **root-доступ** (запуск через `sudo`)
- Поддерживаемая ОС: **Debian 10+** (и совместимые дистрибутивы)

## 🚀 Установка

```bash
wget https://raw.githubusercontent.com/vivernet/install-telegram-bot-api/master/install-telegram-bot-api.sh
chmod +x install-telegram-bot-api.sh
sudo ./install-telegram-bot-api.sh
```

**Скрипт задаст несколько вопросов:**

> Каждый из вопросов, кроме ввода `api_id` и `api_hash`, можно пропустить, нажав Enter, и будет использовано рекомендуемое значение по умолчанию.

* Путь установки (по умолчанию `/opt/telegram-bot-api`)
* Порт для запуска Telegram Bot API (по умолчанию `8081`)
* Имя службы (по умолчанию `telegram-bot-api`)
* Имя системного пользователя (по умолчанию `telegram-bot-api`)
* Директория для загрузки исходников Telegram Bot API (по умолчанию `/usr/local/src/telegram-bot-api`)
* Щадящий режим сборки для маломощных серверов (по умолчанию: `N`)
* Количество потоков компиляции (`auto` или число; в щадящем режиме по умолчанию `1`)
* `api_id` и `api_hash`, можно получить здесь: https://core.telegram.org/api/obtaining_api_id

После установки скрипт создаст и запустит службу.

## 🛠 Управление службой

По умолчанию используется имя службы: `telegram-bot-api`

**Проверка статуса службы:**
```bash
sudo systemctl status telegram-bot-api
```

**Запуск службы:**
```bash
sudo systemctl start telegram-bot-api
```

**Включение автозапуска службы:**
```bash
sudo systemctl enable telegram-bot-api
```

**Перезапуск службы:**
```bash
sudo systemctl restart telegram-bot-api
```

**Отключение автозапуска службы:**
```bash
sudo systemctl disable telegram-bot-api
```

**Остановка службы:**
```bash
sudo systemctl stop telegram-bot-api
```

**Просмотр логов службы:**
```bash
journalctl -u telegram-bot-api -f
```

## 📂 Структура директорий

По умолчанию используется: `/opt/telegram-bot-api`

```
/opt/telegram-bot-api
├── bin/                # Бинарник telegram-bot-api
├── data/               # Рабочие данные Telegram Bot API
├── logs/               # Логи
├── backup/             # Резервные копии бинарников
├── .env                # api_id и api_hash
└── config.conf         # Конфигурация установки
```

## 🔄 Обновление

Для обновления до последней версии Telegram Bot API просто запустите скрипт повторно:

```bash
sudo ./install-telegram-bot-api.sh
```

> Так как компиляция бинарника занимает продолжительное время, текущая версия будет продолжать работать во время компиляции. Скрипт остановит службу для замены исполняемого бинарника только после успешной компиляции нового, чтобы минимизировать время простоя.

**Процесс обновления:**

* Обновление исходников из репозитория Telegram Bot API
* Пересборка бинарника
* Создание резервной копии предыдущего бинарника
* Перезапуск службы

## 🐢 Сборка на маломощных серверах

Если сервер «подвисает» во время компиляции, включите щадящий режим сборки при запуске скрипта:

- сборка выполняется с пониженным приоритетом CPU/IO (`nice` + `ionice`);
- по умолчанию используется `1` поток компиляции;
- при необходимости можно вручную задать число потоков (или `auto`).

Параметры сохраняются в `config.conf`:

- `LOW_POWER_BUILD=yes|no`
- `BUILD_JOBS=auto|<число>`

## 🧹 Логи

* Основной лог: `/opt/telegram-bot-api/logs/telegram-bot-api.log`
* Лог установки: `/opt/telegram-bot-api/logs/install.log`
* Управление логами автоматизировано через **logrotate**

## 📜 Лицензия

MIT © 2025 – [vivernet](https://github.com/vivernet)
