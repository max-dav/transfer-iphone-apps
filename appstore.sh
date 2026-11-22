#!/usr/bin/env bash
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
DOWNLOAD_DIR="$SCRIPT_DIR/загрузки"
RUNTIME="${TMPDIR:-/tmp}/appstore-ru-$$"
PLATFORM="iphone"
KEYCHAIN_PASS=""
PAGE_SIZE=20

mkdir -p "$RUNTIME"
: >"$RUNTIME/apps.tsv"
: >"$RUNTIME/versions.tsv"
: >"$RUNTIME/status"

cleanup() {
  rm -rf "$RUNTIME"
}
trap cleanup EXIT
trap 'echo; exit 130' INT

if ! command -v ipatool >/dev/null 2>&1; then
  echo "ipatool не найден. Установите его и запустите скрипт снова."
  exit 1
fi

PYTHON=""
if command -v python3 >/dev/null 2>&1; then
  PYTHON="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON="python"
fi

platform_title() {
  case "$1" in
    iphone) echo "iPhone" ;;
    ipad) echo "iPad" ;;
    macos) echo "Mac" ;;
    appletv) echo "Apple TV" ;;
    watchos) echo "Apple Watch" ;;
    visionos) echo "Apple Vision" ;;
    "") echo "не задана" ;;
    *) echo "$1" ;;
  esac
}

pause() {
  read -r -p "Нажмите Enter, чтобы продолжить... " _
}

confirm() {
  local answer
  read -r -p "$1 [д/н]: " answer
  case "$answer" in
    д|Д|y|Y|yes|да|Да) return 0 ;;
    *) return 1 ;;
  esac
}

ipa() {
  local cmd=(ipatool --format json --non-interactive)
  if [[ -n "$KEYCHAIN_PASS" ]]; then
    cmd+=(--keychain-passphrase "$KEYCHAIN_PASS")
  fi
  "${cmd[@]}" "$@"
}

ipa_live() {
  local cmd=(ipatool)
  if [[ -n "$KEYCHAIN_PASS" ]]; then
    cmd+=(--keychain-passphrase "$KEYCHAIN_PASS")
  fi
  "${cmd[@]}" "$@"
}

platform_args() {
  if [[ -n "$PLATFORM" ]]; then
    printf '%s\n' --platform "$PLATFORM"
  fi
}

show_json() {
  if [[ -z "$PYTHON" ]]; then
    echo
    echo "Python не найден, показываю ответ ipatool как есть."
    echo "Для русской таблицы результатов установите python3."
    echo
    cat "$1"
    if grep -q '"success":false' "$1" 2>/dev/null || grep -q '"success": false' "$1" 2>/dev/null; then
      echo error >"$RUNTIME/status"
    elif grep -q '2FA code is required' "$1" 2>/dev/null; then
      echo need_2fa >"$RUNTIME/status"
    else
      echo ok >"$RUNTIME/status"
    fi
    return 0
  fi

  "$PYTHON" - "$1" "$RUNTIME/apps.tsv" "$RUNTIME/versions.tsv" "$RUNTIME/status" <<'PY'
import json
import sys

source, apps_path, versions_path, status_path = sys.argv[1:5]

labels = {
    "name": "Имя",
    "email": "Apple ID",
    "id": "ID",
    "bundleID": "Bundle ID",
    "version": "Версия",
    "price": "Цена",
    "count": "На странице",
    "totalCount": "Всего",
    "page": "Страница",
    "success": "Успех",
    "error": "Ошибка",
    "output": "Файл",
    "purchased": "Лицензия оформлена",
    "alreadyOwned": "Уже куплено",
    "externalVersionIdentifiers": "Идентификаторы версий",
    "externalVersionID": "ID версии",
    "displayVersion": "Версия",
    "releaseDate": "Дата выпуска",
    "purchaseDate": "Дата покупки",
    "platforms": "Платформы",
    "message": "Сообщение",
}

def translate_error(text):
    rules = (
        ("could not be found in the keyring", "Вход не выполнен. Сначала войдите в App Store."),
        ("2FA code is required", "Нужен код двухфакторной проверки."),
        ("failed to get account", "Не удалось прочитать аккаунт. Войдите ещё раз."),
        ("license is required", "На аккаунте нет лицензии на это приложение."),
        ("LicenseRequired", "На аккаунте нет лицензии на это приложение."),
        ("password token expired", "Сессия истекла. Войдите ещё раз."),
        ("invalid credentials", "Неверный Apple ID или пароль."),
        ("BadLogin", "Неверный Apple ID или пароль."),
        ("account is disabled", "Аккаунт Apple отключён."),
        ("password has changed", "Пароль Apple ID изменился. Войдите ещё раз."),
        ("either the app ID or the bundle identifier", "Нужен ID приложения или bundle ID."),
        ("invalid platform", "Такая платформа не поддерживается для этой команды."),
        ("app not found", "Приложение не найдено."),
        ("AppNotFound", "Приложение не найдено."),
    )
    for needle, russian in rules:
        if needle.lower() in text.lower():
            return russian
    return ""

def load_objects(path):
    objects = []
    raw_lines = []
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            stripped = line.strip()
            if not stripped:
                continue
            raw_lines.append(stripped)
            if stripped.startswith("{"):
                try:
                    objects.append(json.loads(stripped))
                except json.JSONDecodeError:
                    pass
    return objects, raw_lines

def price_label(value):
    if value in (None, 0, 0.0):
        return "бесплатно"
    return str(value)

def clip(value, width):
    text = "" if value is None else str(value)
    if len(text) <= width:
        return text
    return text[: width - 1] + "…"

def write_status(value):
    with open(status_path, "w", encoding="utf-8") as handle:
        handle.write(value + "\n")

def save_apps(apps):
    with open(apps_path, "w", encoding="utf-8") as handle:
        for index, app in enumerate(apps, 1):
            fields = [
                str(index),
                str(app.get("id") or ""),
                str(app.get("bundleID") or ""),
                str(app.get("name") or "").replace("\t", " "),
                str(app.get("version") or ""),
            ]
            handle.write("\t".join(fields) + "\n")

def save_versions(identifiers):
    with open(versions_path, "w", encoding="utf-8") as handle:
        for index, identifier in enumerate(identifiers, 1):
            handle.write(f"{index}\t{identifier}\n")

def print_apps(apps):
    print()
    print(f"{'#':>3}  {'Название':<32}  {'Версия':<12}  {'Цена':<12}  {'ID':<12}  Bundle ID")
    for index, app in enumerate(apps, 1):
        print(
            f"{index:>3}  "
            f"{clip(app.get('name'), 32):<32}  "
            f"{clip(app.get('version'), 12):<12}  "
            f"{clip(price_label(app.get('price')), 12):<12}  "
            f"{clip(app.get('id'), 12):<12}  "
            f"{app.get('bundleID') or ''}"
        )
    print()
    print("Дальше можно ввести номер из этого списка.")

objects, raw_lines = load_objects(source)
joined = "\n".join(raw_lines)
errors = []
infos = []
apps = []
versions = []

for obj in objects:
    if not isinstance(obj, dict):
        continue
    level = obj.get("level")
    if level == "error" or obj.get("success") is False:
        errors.append(obj)
    else:
        infos.append(obj)
    found = obj.get("apps") or obj.get("results") or []
    if isinstance(found, list) and found and isinstance(found[0], dict):
        apps = found
    found_versions = obj.get("externalVersionIdentifiers") or []
    if isinstance(found_versions, list) and found_versions:
        versions = [str(item) for item in found_versions]

if "2FA code is required" in joined and not any(obj.get("success") is True and obj.get("email") for obj in infos):
    print()
    print("Нужен код двухфакторной проверки. Он приходит на доверенные устройства Apple.")
    write_status("need_2fa")
    raise SystemExit(0)

if errors and not apps and not any(obj.get("success") is True for obj in infos):
    print()
    shown = False
    for obj in errors:
        original = str(obj.get("error") or obj.get("message") or "")
        russian = translate_error(original)
        if russian:
            print(russian)
        elif original:
            print(original)
        if original and russian and original not in russian:
            print(f"Подробности: {original}")
        shown = shown or bool(original or russian)
    if not shown:
        print("Команда завершилась с ошибкой.")
        for line in raw_lines:
            print(line)
    write_status("error")
    raise SystemExit(0)

if apps:
    save_apps(apps)
    print_apps(apps)
    for obj in infos:
        extra = []
        if "totalCount" in obj:
            extra.append(f"Всего: {obj['totalCount']}")
        if "page" in obj:
            extra.append(f"Страница: {obj['page']}")
        if "count" in obj:
            extra.append(f"Показано: {obj['count']}")
        if extra:
            print("  ".join(extra))
            break
    write_status("ok")
    raise SystemExit(0)

if versions:
    save_versions(versions)
    print()
    print("Доступные версии:")
    for index, identifier in enumerate(versions, 1):
        print(f"{index:>3}  {identifier}")
    bundle = ""
    for obj in infos:
        if obj.get("bundleID"):
            bundle = obj["bundleID"]
            break
    if bundle:
        print(f"Bundle ID: {bundle}")
    print()
    print("Чтобы скачать старую версию, укажите номер из этого списка.")
    write_status("ok")
    raise SystemExit(0)

if any(isinstance(obj, dict) and obj.get("count") == 0 for obj in infos) and not apps:
    print()
    print("Ничего не найдено.")
    write_status("ok")
    raise SystemExit(0)

interesting = []
for obj in infos:
    for key, label in labels.items():
        if key not in obj or key in ("success", "message"):
            continue
        value = obj[key]
        if key == "price":
            value = price_label(value)
        if key == "alreadyOwned":
            value = "да" if value else "нет"
        if key == "purchased":
            value = "да" if value else "нет"
        if isinstance(value, list):
            value = ", ".join(str(item) for item in value) or "—"
        interesting.append(f"{label}: {value}")

if interesting:
    print()
    for line in interesting:
        print(line)
    write_status("ok")
    raise SystemExit(0)

if raw_lines:
    print()
    for line in raw_lines:
        print(line)
else:
    print()
    print("Команда выполнена, ipatool ничего не вывел.")
write_status("ok")
PY
}

run_json() {
  local output="$RUNTIME/last.json"
  ipa "$@" >"$output" 2>&1
  local code=$?
  show_json "$output"
  return "$code"
}

account_text() {
  local output="$RUNTIME/account.json"
  if ! ipa auth info >"$output" 2>&1; then
    echo "не выполнен вход"
    return
  fi
  if [[ -z "$PYTHON" ]]; then
    echo "вход выполнен"
    return
  fi
  "$PYTHON" - "$output" <<'PY'
import json
import sys
name = email = ""
with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as handle:
    for line in handle:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        name = obj.get("name") or name
        email = obj.get("email") or email
if name and email:
    print(f"{name} ({email})")
elif email or name:
    print(email or name)
else:
    print("вход выполнен")
PY
}

choose_platform() {
  echo
  echo "Платформа:"
  echo "  1) iPhone"
  echo "  2) iPad"
  echo "  3) Mac"
  echo "  4) Apple TV"
  echo "  5) Apple Watch"
  echo "  6) Apple Vision"
  echo "  7) Не указывать"
  local choice
  read -r -p "Номер [${PLATFORM}]: " choice
  case "$choice" in
    1) PLATFORM="iphone" ;;
    2) PLATFORM="ipad" ;;
    3) PLATFORM="macos" ;;
    4) PLATFORM="appletv" ;;
    5) PLATFORM="watchos" ;;
    6) PLATFORM="visionos" ;;
    7) PLATFORM="" ;;
    "") ;;
    *) echo "Оставляю текущую платформу." ;;
  esac
  echo "Сейчас: $(platform_title "$PLATFORM")"
}

require_login() {
  if ipa auth info >/dev/null 2>&1; then
    return 0
  fi
  echo "Сначала войдите в App Store."
  return 1
}

login_account() {
  local email password code output
  echo
  echo "Первый вход может занять несколько минут."
  read -r -p "Apple ID (email или телефон): " email
  read -r -s -p "Пароль: " password
  echo
  if [[ -z "$email" || -z "$password" ]]; then
    echo "Apple ID и пароль нужны оба."
    unset password
    return 1
  fi
  output="$RUNTIME/login.json"
  ipa auth login --email "$email" --password "$password" >"$output" 2>&1
  show_json "$output"
  if [[ "$(cat "$RUNTIME/status")" == "need_2fa" ]]; then
    read -r -p "Код 2FA: " code
    if [[ -z "$code" ]]; then
      echo "Без кода войти нельзя."
      unset password code
      return 1
    fi
    ipa auth login --email "$email" --password "$password" --auth-code "$code" >"$output" 2>&1
    show_json "$output"
  fi
  unset password code
  [[ "$(cat "$RUNTIME/status")" == "ok" ]]
}

logout_account() {
  echo
  if confirm "Выйти и удалить сохранённый вход из связки ключей?"; then
    run_json auth revoke
  fi
}

read_app() {
  APP_ID=""
  BUNDLE_ID=""
  local input="$1"
  if [[ -z "$input" ]]; then
    read -r -p "Номер из списка, bundle ID или #ID: " input
  fi
  if [[ -z "$input" ]]; then
    echo "Пустой ввод."
    return 1
  fi
  if [[ "$input" == \#* ]]; then
    APP_ID="${input#\#}"
    return 0
  fi
  if [[ "$input" == *.* ]]; then
    BUNDLE_ID="$input"
    return 0
  fi
  if [[ "$input" =~ ^[0-9]+$ ]] && [[ -s "$RUNTIME/apps.tsv" ]]; then
    local row
    row=$(awk -F '\t' -v n="$input" '$1 == n { print $2 "\t" $3; found=1 } END { if (!found) exit 1 }' "$RUNTIME/apps.tsv") && {
      APP_ID=${row%%$'\t'*}
      BUNDLE_ID=${row#*$'\t'}
      return 0
    }
  fi
  if [[ "$input" =~ ^[0-9]+$ ]]; then
    APP_ID="$input"
    return 0
  fi
  echo "Не удалось разобрать «$input»."
  return 1
}

app_args() {
  if [[ -n "${BUNDLE_ID:-}" ]]; then
    printf '%s\n' --bundle-identifier "$BUNDLE_ID"
  elif [[ -n "${APP_ID:-}" ]]; then
    printf '%s\n' --app-id "$APP_ID"
  fi
}

search_apps() {
  local term limit=10
  echo
  read -r -p "Что найти: " term
  if [[ -z "$term" ]]; then
    echo "Пустой запрос."
    return
  fi
  read -r -p "Сколько результатов [10]: " limit
  limit=${limit:-10}
  if ! [[ "$limit" =~ ^[0-9]+$ ]] || [[ "$limit" -lt 1 ]]; then
    echo "Нужно число больше нуля. Беру 10."
    limit=10
  fi
  if [[ "$PLATFORM" == "visionos" && "$limit" -gt 12 ]]; then
    echo "Для Apple Vision ipatool отдаёт не больше 12 результатов."
    limit=12
  fi
  : >"$RUNTIME/apps.tsv"
  local args=(search "$term" --limit "$limit")
  if [[ -n "$PLATFORM" ]]; then
    args+=(--platform "$PLATFORM")
  fi
  run_json "${args[@]}"
}

list_purchases() {
  local page=1 choice platform_note=()
  while true; do
    echo
    : >"$RUNTIME/apps.tsv"
    if [[ "$PLATFORM" == "watchos" ]]; then
      echo "Список покупок не фильтруется по Apple Watch. Показываю все платформы."
    elif [[ -n "$PLATFORM" ]]; then
      platform_note=(--platform "$PLATFORM")
    else
      platform_note=()
    fi
    run_json list-purchases --page "$page" --max-results "$PAGE_SIZE" "${platform_note[@]}"
    echo
    echo "  n) следующая страница"
    echo "  p) предыдущая страница"
    echo "  Enter) назад в меню"
    read -r -p "Страницы или номер приложения: " choice
    case "$choice" in
      "") return ;;
      n|N|с|С) page=$((page + 1)) ;;
      p|P|п|П)
        if [[ "$page" -gt 1 ]]; then
          page=$((page - 1))
        else
          echo "Это первая страница."
        fi
        ;;
      *)
        if read_app "$choice"; then
          app_actions
        fi
        ;;
    esac
  done
}

download_app() {
  local version_id="${1:-}"
  if ! require_login; then
    return
  fi
  if [[ -z "${APP_ID:-}${BUNDLE_ID:-}" ]]; then
    read_app "" || return
  fi
  local purchase_flag=()
  if confirm "Получить лицензию, если её ещё нет?"; then
    purchase_flag=(--purchase)
  fi
  mkdir -p "$DOWNLOAD_DIR"
  echo
  echo "Скачиваю в папку: $DOWNLOAD_DIR"
  echo "Платформа: $(platform_title "$PLATFORM")"
  local args=(download)
  while IFS= read -r arg; do
    args+=("$arg")
  done < <(app_args)
  if [[ -n "$PLATFORM" ]]; then
    args+=(--platform "$PLATFORM")
  fi
  if [[ -n "$version_id" ]]; then
    args+=(--external-version-id "$version_id")
  fi
  args+=("${purchase_flag[@]}")
  (
    cd "$DOWNLOAD_DIR" || exit 1
    ipa_live "${args[@]}"
  )
  local code=$?
  echo
  if [[ "$code" -eq 0 ]]; then
    echo "Готово. Файл лежит в папке загрузок."
  else
    echo "Скачивание не удалось (код $code)."
  fi
}

purchase_app() {
  if ! require_login; then
    return
  fi
  if [[ -z "${APP_ID:-}${BUNDLE_ID:-}" ]]; then
    read_app "" || return
  fi
  local args=(purchase)
  local arg
  while IFS= read -r arg; do
    args+=("$arg")
  done < <(app_args)
  if [[ -n "$PLATFORM" ]]; then
    args+=(--platform "$PLATFORM")
  fi
  run_json "${args[@]}"
}

list_versions() {
  if ! require_login; then
    return
  fi
  if [[ -z "${APP_ID:-}${BUNDLE_ID:-}" ]]; then
    read_app "" || return
  fi
  local args=(list-versions)
  local arg
  while IFS= read -r arg; do
    args+=("$arg")
  done < <(app_args)
  if [[ -n "$PLATFORM" ]]; then
    args+=(--platform "$PLATFORM")
  fi
  : >"$RUNTIME/versions.tsv"
  run_json "${args[@]}" || return
  echo
  local pick
  read -r -p "Номер версии для скачивания (Enter — пропустить): " pick
  if [[ -z "$pick" ]]; then
    return
  fi
  local version_id
  version_id=$(awk -F '\t' -v n="$pick" '$1 == n { print $2; found=1 } END { if (!found) exit 1 }' "$RUNTIME/versions.tsv") || {
    echo "Нет версии с номером $pick."
    return
  }
  download_app "$version_id"
}

version_metadata() {
  if ! require_login; then
    return
  fi
  if [[ -z "${APP_ID:-}${BUNDLE_ID:-}" ]]; then
    read_app "" || return
  fi
  local version_id
  read -r -p "Номер из списка версий или сам ID версии: " version_id
  if [[ -z "$version_id" ]]; then
    echo "Нужен идентификатор версии."
    return
  fi
  if [[ "$version_id" =~ ^[0-9]+$ ]] && [[ -s "$RUNTIME/versions.tsv" ]]; then
    local mapped
    mapped=$(awk -F '\t' -v n="$version_id" '$1 == n { print $2; found=1 } END { if (!found) exit 1 }' "$RUNTIME/versions.tsv") && version_id="$mapped"
  fi
  local args=(get-version-metadata --external-version-id "$version_id")
  local arg
  while IFS= read -r arg; do
    args+=("$arg")
  done < <(app_args)
  if [[ -n "$PLATFORM" ]]; then
    args+=(--platform "$PLATFORM")
  fi
  run_json "${args[@]}"
}

app_actions() {
  echo
  echo "Приложение: ${BUNDLE_ID:-$APP_ID}"
  echo "  1) Скачать"
  echo "  2) Получить лицензию"
  echo "  3) Список версий"
  echo "  4) Метаданные версии"
  echo "  0) Назад"
  local choice
  read -r -p "Действие: " choice
  case "$choice" in
    1) download_app ;;
    2) purchase_app ;;
    3) list_versions ;;
    4) version_metadata ;;
    *) ;;
  esac
}

change_download_dir() {
  echo
  echo "Сейчас: $DOWNLOAD_DIR"
  local path
  read -r -p "Новая папка (Enter — оставить): " path
  if [[ -n "$path" ]]; then
    DOWNLOAD_DIR="$path"
    mkdir -p "$DOWNLOAD_DIR"
    echo "Папка загрузок: $DOWNLOAD_DIR"
  fi
}

main_menu() {
  while true; do
    echo
    echo "=============================================="
    echo "  App Store через ipatool"
    echo "=============================================="
    echo "Аккаунт:   $(account_text)"
    echo "Платформа: $(platform_title "$PLATFORM")"
    echo "Загрузки:  $DOWNLOAD_DIR"
    echo
    echo "  1) Войти"
    echo "  2) Какой аккаунт сейчас"
    echo "  3) Выйти"
    echo "  4) Найти приложение"
    echo "  5) Мои покупки"
    echo "  6) Скачать приложение"
    echo "  7) Получить лицензию"
    echo "  8) Версии приложения"
    echo "  9) Метаданные версии"
    echo " 10) Сменить платформу"
    echo " 11) Сменить папку загрузок"
    echo "  0) Закрыть"
    echo
    local choice
    read -r -p "Выберите пункт: " choice
    case "$choice" in
      1) login_account; pause ;;
      2)
        echo
        run_json auth info
        pause
        ;;
      3) logout_account; pause ;;
      4)
        if require_login; then
          search_apps
          echo
          if confirm "Открыть действие для номера из списка?"; then
            APP_ID=""
            BUNDLE_ID=""
            read_app "" && app_actions
          fi
        fi
        pause
        ;;
      5)
        if require_login; then
          list_purchases
        fi
        pause
        ;;
      6)
        APP_ID=""
        BUNDLE_ID=""
        download_app
        pause
        ;;
      7)
        APP_ID=""
        BUNDLE_ID=""
        purchase_app
        pause
        ;;
      8)
        APP_ID=""
        BUNDLE_ID=""
        list_versions
        pause
        ;;
      9)
        APP_ID=""
        BUNDLE_ID=""
        version_metadata
        pause
        ;;
      10) choose_platform; pause ;;
      11) change_download_dir; pause ;;
      0|q|Q|й|Й) echo "Готово."; exit 0 ;;
      *) echo "Нет такого пункта." ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main_menu
fi
