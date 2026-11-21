// Tiny C API over Apple's PRIVATE ReminderKit framework (sections + hashtags for reminders).
// Implemented in HAReminderKit.m (macOS only). All strings are UTF-8; out-strings are malloc'd
// and must be released with ha_rk_free(). No function ever throws or aborts: every Objective-C
// exception is caught and reported as an error.
#ifndef HA_REMINDERKIT_H
#define HA_REMINDERKIT_H

#ifdef __cplusplus
extern "C" {
#endif

/// 1 = ReminderKit loaded and every class/selector the agent needs exists; 0 otherwise.
/// `report` (optional) receives a human-readable, multi-line description of what was found.
int ha_rk_check(char **report);

/// Puts an existing reminder into `section` of its list (created if missing) and adds `tags`.
/// `list_uuid` = EKCalendar.calendarIdentifier, `reminder_uuid` = EKReminder.calendarItemIdentifier.
/// `section` may be NULL; `tags` may be NULL when tag_count is 0.
/// Returns 0 on success; otherwise non-zero with a message in `error` (optional).
int ha_rk_apply(const char *list_uuid, const char *reminder_uuid, const char *section,
                const char *const *tags, int tag_count, char **error);

/// Best-effort read-back for the probe: the reminder's section name and comma-separated tags.
/// Returns 0 on success (either out-value may still be NULL if it could not be determined).
int ha_rk_read(const char *list_uuid, const char *reminder_uuid, char **section, char **tags_csv, char **error);

void ha_rk_free(void *p);

#ifdef __cplusplus
}
#endif

#endif
