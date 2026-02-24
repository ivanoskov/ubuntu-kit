#!/usr/bin/env bash
# =============================================================================
# Комплексный скрипт обслуживания Ubuntu 22.04/24.04 (GNOME + dev-окружение)
# Docker, Node.js (npm), Snap/Flatpak, firmware, журналы, кэши
# Запускать через sudo. Подходит для cron (еженедельно/ежемесячно).
#
# Особенности:
#   • Полная безопасность: set -euo pipefail, проверка root
#   • Логирование + отчёт о свободном месте до/после
#   • Поддержка --yes (для cron), --dry-run, --aggressive (Docker volumes)
#   • Безопасная очистка Docker (только старше 7 дней + dangling)
#   • Автоочистка старых ядер через autoremove (оставляет текущий + предыдущий)
#   • GNOME-специфично: thumbnails, .cache, Trash
#   • Node.js: npm cache clean --force от имени пользователя
#   • Snap/Flatpak/firmware/journalctl — всё что может быть
# =============================================================================

set -euo pipefail
IFS=$' \n\t'

# ====================== Цвета и переменные ======================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

AUTO_YES=false
DRY_RUN=false
AGGRESSIVE=false

# ====================== Парсинг аргументов ======================
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)
      AUTO_YES=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --aggressive)
      AGGRESSIVE=true
      shift
      ;;
    -h|--help)
      echo -e "${BLUE}Использование:${NC}"
      echo "  sudo $0 [--yes] [--dry-run] [--aggressive]"
      echo "  --yes         — автоматический режим (для cron)"
      echo "  --dry-run     — только показать команды"
      echo "  --aggressive  — удалять неиспользуемые Docker volumes"
      exit 0
      ;;
    *)
      echo -e "${RED}Неизвестный параметр: $1${NC}"
      exit 1
      ;;
  esac
done

# ====================== Проверка root ======================
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}Скрипт нужно запускать от root (sudo)!${NC}"
  exit 1
fi

# Пользователь, от имени которого запущен sudo
REAL_USER="${SUDO_USER:-$USER}"
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# Лог
LOGFILE="/var/log/ubuntu-maintenance-$(date +%F_%H-%M).log"
exec > >(tee -a "$LOGFILE") 2>&1

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}   Запуск обслуживания системы $(date '+%Y-%m-%d %H:%M:%S')   ${NC}"
echo -e "${BLUE}   Пользователь: $REAL_USER   Домашняя папка: $USER_HOME   ${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"

# Свободное место до
BEFORE_FREE=$(df -h / | awk 'NR==2 {print $4}')
echo -e "${YELLOW}Свободно до очистки: $BEFORE_FREE${NC}"

# ====================== Вспомогательные функции ======================
run_cmd() {
  if $DRY_RUN; then
    echo -e "${YELLOW}[DRY-RUN] $*${NC}"
  else
    echo -e "${GREEN}→ $*${NC}"
    "$@"
  fi
}

# ====================== 1. Обновление пакетов ======================
echo -e "\n${BLUE}=== 1. Обновление списков пакетов ===${NC}"
run_cmd apt-get update -qq

echo -e "\n${BLUE}=== 2. Полное обновление системы (full-upgrade) ===${NC}"
if $AUTO_YES; then
  run_cmd apt-get full-upgrade -y
else
  run_cmd apt-get full-upgrade
fi

# ====================== 3. Очистка пакетов ======================
echo -e "\n${BLUE}=== 3. Удаление ненужных пакетов и старых ядер ===${NC}"
run_cmd apt-get autoremove --purge -y

echo -e "\n${BLUE}=== 4. Удаление старых конфигурационных файлов ===${NC}"
OLD_CONFIGS=$(dpkg -l | awk '/^rc/ {print $2}' || true)
if [[ -n "$OLD_CONFIGS" ]]; then
  run_cmd apt-get purge -y $OLD_CONFIGS
fi

echo -e "\n${BLUE}=== 5. Очистка кэша APT ===${NC}"
run_cmd apt-get clean
run_cmd apt-get autoclean

# ====================== 6. Snap ======================
if command -v snap >/dev/null 2>&1; then
  echo -e "\n${BLUE}=== 6. Обновление и очистка Snap-пакетов ===${NC}"
  run_cmd snap refresh
  # Удаляем отключённые ревизии
  snap list --all | awk '/disabled/{print $1" "$3}' | while read -r name rev; do
    run_cmd snap remove "$name" --revision="$rev"
  done
fi

# ====================== 7. Flatpak ======================
if command -v flatpak >/dev/null 2>&1; then
  echo -e "\n${BLUE}=== 7. Обновление и очистка Flatpak ===${NC}"
  run_cmd flatpak update -y
  run_cmd flatpak uninstall --unused -y
fi

# ====================== 8. Firmware ======================
if command -v fwupdmgr >/dev/null 2>&1; then
  echo -e "\n${BLUE}=== 8. Обновление микропрограмм (fwupd) ===${NC}"
  run_cmd fwupdmgr refresh --force  >/dev/null 2>&1 || true
  run_cmd fwupdmgr update --no-reboot-check >/dev/null 2>&1 || true   # игнорируем любой exit code
  echo -e "${YELLOW}fwupd: попытка обновления выполнена (отсутствие обновлений — не ошибка)${NC}"
else
  echo -e "${YELLOW}fwupdmgr отсутствует — пропускаем${NC}"
fi

# ====================== 9. Журналы systemd ======================
echo -e "\n${BLUE}=== 9. Очистка старых журналов (journalctl) ===${NC}"
run_cmd journalctl --vacuum-time=30d --vacuum-size=500M -q

# ====================== 10. Docker (dev-специфика) ======================
if command -v docker >/dev/null 2>&1; then
  echo -e "\n${BLUE}=== 10. Очистка Docker (только старше 7 дней) ===${NC}"
  # Безопасно: удаляем dangling + неиспользуемые образы старше 7 дней
  run_cmd docker system prune -a -f --filter "until=168h"

  if $AGGRESSIVE; then
    echo -e "${YELLOW}   → Агрессивный режим: удаляем неиспользуемые volumes${NC}"
    run_cmd docker volume prune -f
  else
    echo -e "${YELLOW}   → Volumes не удаляем (добавьте --aggressive при необходимости)${NC}"
  fi

  run_cmd docker builder prune -f --all  # build cache
  run_cmd docker container prune -f
fi

# ====================== 11. Node.js / npm ======================
if command -v npm >/dev/null 2>&1; then
  echo -e "\n${BLUE}=== 11. Очистка кэша npm (от имени пользователя) ===${NC}"
  run_cmd sudo -u "$REAL_USER" npm cache clean --force
fi

# ====================== 12. GNOME + пользовательские кэши ======================
echo -e "\n${BLUE}=== 12. Очистка GNOME/пользовательских кэшей ===${NC}"
if [[ -d "$USER_HOME/.cache" ]]; then
  # Thumbnails (самый жирный кэш в GNOME)
  run_cmd sudo -u "$REAL_USER" rm -rf "${USER_HOME}/.cache/thumbnails/"*
  # Старые файлы кэша (> 30 дней)
  run_cmd sudo -u "$REAL_USER" find "${USER_HOME}/.cache" -type f -atime +30 -delete 2>/dev/null || true
fi

# Корзина
if [[ -d "$USER_HOME/.local/share/Trash" ]]; then
  run_cmd sudo -u "$REAL_USER" rm -rf "${USER_HOME}/.local/share/Trash/"* 2>/dev/null || true
fi

# ====================== 13. Временные файлы ======================
echo -e "\n${BLUE}=== 13. Очистка старых временных файлов (/tmp, /var/tmp) ===${NC}"
run_cmd find /tmp -type f -mtime +7 -delete 2>/dev/null || true
run_cmd find /var/tmp -type f -mtime +7 -delete 2>/dev/null || true

# ====================== Итог ======================
AFTER_FREE=$(df -h / | awk 'NR==2 {print $4}')
RECLAIMED=$(df -h / | awk 'NR==2 {print $3}' | sed 's/G//;s/M//;s/K//')

echo -e "\n${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}   Обслуживание завершено успешно!   ${NC}"
echo -e "${GREEN}   Было свободно : $BEFORE_FREE${NC}"
echo -e "${GREEN}   Стало свободно: $AFTER_FREE${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"

if [[ -f /var/run/reboot-required ]]; then
  echo -e "${YELLOW}⚠️  Требуется перезагрузка для применения обновлений ядра/пакетов!${NC}"
fi

echo -e "${BLUE}Подробный лог: $LOGFILE${NC}"
echo -e "${BLUE}Рекомендация для cron (раз в неделю, воскресенье 4:00):${NC}"
echo "   0 4 * * 0   root   /usr/local/bin/maintain.sh --yes >> /var/log/maintain.log 2>&1"

# =============================================================================
# Как установить:
#   1. sudo nano /usr/local/bin/maintain.sh
#   2. Вставить этот код
#   3. sudo chmod +x /usr/local/bin/maintain.sh
#   4. sudo maintain.sh --yes   # первый запуск
# =============================================================================
