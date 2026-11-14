# Security / безопасность

Please do not publish credentials or personal calendar data in issues. Use GitHub's private vulnerability reporting when available, or open a minimal issue asking for a private channel without exploit details or private data.

Не публикуйте в issues токены, GOA bindings, события или содержимое keyring. Используйте приватное сообщение об уязвимости GitHub, если оно доступно, либо короткую заявку на приватный канал без чувствительных данных.

## Boundaries

- Google OAuth is handled by GNOME Online Accounts. Its consent scopes may be broader than Calendar; the plugin uses only Calendar.
- No own Google Cloud project, no Caldir.org relay, no iCloud provider.
- A short-lived token is written only to an operation-specific temporary directory (`0700`, files `0600`). Refresh credentials remain with GNOME.
- Downloaded source/runtime archives and the provider patch are pinned by SHA-256. Builds run offline without personal home data after locked dependency fetching.
- A provider gate authorizes exact account/calendar/event/occurrence/action tuples from the queue. Uncertain creation is not blindly retried. The patched Google provider makes one insertion request.
- Reminder titles, times and meeting links are passed through standard input and the user's D-Bus session, not process arguments. Deduplication state is kept in the user's private state directory; older state is migrated from the panel configuration.
- The plugin itself runs unsandboxed in Omarchy Shell. File permissions do not isolate it from other processes belonging to the same user.
- Manual installation changes only the clock's placement/settings after backing them up. Removal preserves events and credentials.

Static review and tests found and corrected several upstream problems, but do not constitute a guarantee that all vulnerabilities are absent. Only the pinned versions and documented flows have been checked.
