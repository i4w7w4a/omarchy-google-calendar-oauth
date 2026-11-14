# Изменения / Changes

## 1.2

- Содержимое напоминаний передаётся через закрытый ввод и D-Bus пользовательского сеанса, без названий, времени и ссылок в аргументах процессов. Уведомление и открытие календаря по нажатию сохранены.
- Отметки отправленных напоминаний хранятся отдельно с правами только для владельца; старые отметки переносятся из настроек панели.
- Reminder contents are passed through standard input and the user's D-Bus session, not process arguments. Notifications and opening the calendar by clicking remain available.
- Reminder deduplication state is stored in a user-private location; existing marks are migrated from the panel configuration.

## 1.1

- Первое публичное размещение под именем **Google Calendar OAuth — No Google Cloud Project**.
- Google OAuth через GNOME Online Accounts: собственный Google Cloud проект не требуется; iCloud backend отсутствует.
- Системный браузер по умолчанию; необязательная настройка отдельного браузера и профиля.
- Установщик сохраняет Git checkout и существующие настройки при обновлении, понимает строковые элементы панели.
- Русская и английская документация, демонстрационный снимок, явные инструкции установки/удаления и разрешений.

## 1.0

- Локальная первоначальная версия: очередь автоотправки, длительность и напоминания, проверка точных исходящих операций, исправленный Caldir provider.
- Реальный цикл Google create/edit/delete и чтение значений обратно через API проверены до публичной публикации.
