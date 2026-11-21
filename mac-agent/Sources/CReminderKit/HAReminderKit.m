// Bridge to Apple's PRIVATE ReminderKit framework: list sections (Reminders' column view) and #tags.
//
// !!! Unsupported, undocumented API. Nothing here could be verified on this project's build
// machine (Linux); it is written from public reverse-engineering notes:
//   - iMCP issues #35–#39 (JoeCotellese): ReminderKitBridge; EKReminder.calendarItemIdentifier ==
//     REMReminder uuid and EKCalendar.calendarIdentifier == REMList uuid; sections created with
//     -[REMSaveRequest updateList:] + -addListSectionWithDisplayName:toListSectionContextChangeItem:;
//     membership via REMMembership/REMMemberships on unsavedMembershipsOfRemindersInSections;
//     tags via -[REMReminderChangeItem hashtagContext] -addHashtagWithType:name:.
//   - neo-the-on3/reminders PRs #18/#25/#26/#27 (macOS 26.x): stage changes on the REMSaveRequest
//     (a change item the request doesn't track "saves" but changes nothing), fetch the list with
//     -[REMStore fetchListWithObjectID:error:], one REMMembership per move (merged by remindd,
//     newest modifiedOn wins), sections read via REMListSectionsDataView -fetchListSectionsInList:error:.
//   - falconbradley/claude-connector-apple-reminders README: REMSaveRequest updateReminder: ->
//     hashtagContext addHashtagWithType:name:, saveSynchronouslyWithError:.
// Guesses (unverified anywhere): REMObjectID construction (+objectIDWithUUID: on REMList/REMReminder,
// else +[REMObjectID objectIDWithUUID:entityName:] with "REMCDList"/"REMCDReminder"), the hashtag
// type value (0), NSUUID as membership identifiers, -[REMMemberships initWithMemberships:] taking an
// NSSet. Every selector is checked with respondsToSelector: before use and every call is wrapped in
// @try/@catch, so a mismatch reports an error (and the agent falls back to a plain title) instead of
// crashing. Run `mac-agent --probe-reminderkit --write` on the Mac to see what actually works.

#if defined(__APPLE__) && defined(__OBJC__)

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include "HAReminderKit.h"

// Declarations of the private selectors so normal message syntax (and ARC's init-family rules)
// apply. There is no implementation: calls are dispatched at runtime, always after a
// respondsToSelector: check.
@interface NSObject (HAReminderKitPrivate)
+ (id)objectIDWithUUID:(NSUUID *)uuid;
+ (id)objectIDWithUUID:(NSUUID *)uuid entityName:(NSString *)entityName;
- (instancetype)initWithStore:(id)store;
- (instancetype)initWithMemberIdentifier:(id)member groupIdentifier:(id)group isObsolete:(BOOL)obsolete modifiedOn:(NSDate *)date;
- (instancetype)initWithMemberships:(id)memberships;
- (id)fetchListWithObjectID:(id)objectID error:(NSError **)error;
- (id)fetchReminderWithObjectID:(id)objectID error:(NSError **)error;
- (id)fetchListSectionsWithListObjectID:(id)objectID error:(NSError **)error;
- (id)fetchListSectionsInList:(id)list error:(NSError **)error;
- (id)updateList:(id)list;
- (id)updateReminder:(id)reminder;
- (id)addListSectionWithDisplayName:(NSString *)name toListSectionContextChangeItem:(id)context;
- (BOOL)saveSynchronouslyWithError:(NSError **)error;
- (id)sectionsContextChangeItem;
- (void)setUnsavedMembershipsOfRemindersInSections:(id)memberships;
- (id)membershipsOfRemindersInSections;
- (id)memberships;
- (id)memberIdentifier;
- (id)groupIdentifier;
- (BOOL)isObsolete;
- (id)hashtagContext;
- (void)addHashtagWithType:(NSInteger)type name:(NSString *)name;
- (id)hashtags;
- (id)objectID;
- (id)uuid;
- (id)displayName;
- (id)name;
@end

static const char *kRKPath = "/System/Library/PrivateFrameworks/ReminderKit.framework/ReminderKit";
static void *gHandle = NULL;
static char gLoadError[512];
static pthread_once_t gLoadOnce = PTHREAD_ONCE_INIT;

static void ha_load(void) {
    gHandle = dlopen(kRKPath, RTLD_LAZY | RTLD_LOCAL);
    if (!gHandle) {
        const char *e = dlerror();
        snprintf(gLoadError, sizeof gLoadError, "dlopen failed: %s", e ? e : "unknown error");
    }
}

static char *ha_dup(NSString *s) {
    if (!s) return NULL;
    const char *u = [s UTF8String];
    return u ? strdup(u) : NULL;
}

static void ha_out(char **out, NSString *s) {
    if (out) *out = ha_dup(s);
}

static NSString *ha_str(const char *c) {
    return c ? [NSString stringWithUTF8String:c] : nil;
}

void ha_rk_free(void *p) { free(p); }

// ---- availability ------------------------------------------------------------------------------

typedef struct { const char *cls; const char *sel; BOOL classMethod; } HASelReq;

// Selectors that must exist on known classes. Selectors on objects whose class we can't name
// ahead of time (change items, contexts) are checked again right before each call.
static const HASelReq kRequired[] = {
    {"REMStore", "fetchListWithObjectID:error:", NO},
    {"REMStore", "fetchReminderWithObjectID:error:", NO},
    {"REMSaveRequest", "initWithStore:", NO},
    {"REMSaveRequest", "updateList:", NO},
    {"REMSaveRequest", "updateReminder:", NO},
    {"REMSaveRequest", "addListSectionWithDisplayName:toListSectionContextChangeItem:", NO},
    {"REMSaveRequest", "saveSynchronouslyWithError:", NO},
    {"REMMembership", "initWithMemberIdentifier:groupIdentifier:isObsolete:modifiedOn:", NO},
    {"REMMemberships", "initWithMemberships:", NO},
    {"REMListChangeItem", "sectionsContextChangeItem", NO},
    {"REMReminderChangeItem", "hashtagContext", NO},
};

static BOOL ha_has_object_ids(NSMutableString *log) {
    Class list = NSClassFromString(@"REMList"), rem = NSClassFromString(@"REMReminder");
    Class oid = NSClassFromString(@"REMObjectID");
    BOOL direct = list && rem && [list respondsToSelector:@selector(objectIDWithUUID:)]
        && [rem respondsToSelector:@selector(objectIDWithUUID:)];
    BOOL generic = oid && [oid respondsToSelector:@selector(objectIDWithUUID:entityName:)];
    [log appendFormat:@"  object ids: %@\n", direct ? @"+[REMList/REMReminder objectIDWithUUID:]"
                     : generic ? @"+[REMObjectID objectIDWithUUID:entityName:] (entity names guessed)" : @"MISSING"];
    return direct || generic;
}

static BOOL ha_has_section_reader(NSMutableString *log) {
    Class store = NSClassFromString(@"REMStore");
    Class view = NSClassFromString(@"REMListSectionsDataView");
    BOOL viaStore = store && [store instancesRespondToSelector:@selector(fetchListSectionsWithListObjectID:error:)];
    BOOL viaView = view && [view instancesRespondToSelector:@selector(initWithStore:)]
        && [view instancesRespondToSelector:@selector(fetchListSectionsInList:error:)];
    [log appendFormat:@"  read sections: %@\n", viaStore ? @"-[REMStore fetchListSectionsWithListObjectID:error:]"
                     : viaView ? @"-[REMListSectionsDataView fetchListSectionsInList:error:]" : @"MISSING"];
    return viaStore || viaView;
}

int ha_rk_check(char **report) {
    @autoreleasepool {
        NSMutableString *log = [NSMutableString string];
        @try {
            pthread_once(&gLoadOnce, ha_load);
            if (!gHandle) {
                [log appendFormat:@"ReminderKit: %s\n", gLoadError];
                ha_out(report, log);
                return 0;
            }
            NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
            [log appendFormat:@"ReminderKit loaded (macOS %ld.%ld.%ld)\n", (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion];
            BOOL ok = YES;
            for (size_t i = 0; i < sizeof kRequired / sizeof kRequired[0]; i++) {
                Class c = NSClassFromString([NSString stringWithUTF8String:kRequired[i].cls]);
                SEL s = NSSelectorFromString([NSString stringWithUTF8String:kRequired[i].sel]);
                BOOL has = c && (kRequired[i].classMethod ? [c respondsToSelector:s] : [c instancesRespondToSelector:s]);
                [log appendFormat:@"  %@ %s%s %s\n", has ? @"ok     " : @"MISSING", kRequired[i].cls,
                    kRequired[i].classMethod ? " +" : " -", kRequired[i].sel];
                ok = ok && has;
            }
            ok = ha_has_object_ids(log) && ok;
            ok = ha_has_section_reader(log) && ok;
            [log appendFormat:@"=> sections + tags %@\n", ok ? @"AVAILABLE" : @"NOT available"];
            ha_out(report, log);
            return ok ? 1 : 0;
        } @catch (NSException *e) {
            [log appendFormat:@"exception during check: %@: %@\n", e.name, e.reason];
            ha_out(report, log);
            return 0;
        }
    }
}

// ---- helpers (all called inside @try) ----------------------------------------------------------

static id ha_object_id(NSString *className, NSString *entity, NSUUID *uuid) {
    Class cls = NSClassFromString(className);
    if (cls && [cls respondsToSelector:@selector(objectIDWithUUID:)]) return [cls objectIDWithUUID:uuid];
    Class oid = NSClassFromString(@"REMObjectID");
    if (oid && [oid respondsToSelector:@selector(objectIDWithUUID:entityName:)]) return [oid objectIDWithUUID:uuid entityName:entity];
    return nil;
}

static BOOL ha_fail(char **error, NSString *msg) {
    ha_out(error, msg);
    return NO;
}

static NSArray *ha_sections(id store, id list, id listOID) {
    NSError *err = nil;
    id result = nil;
    if ([store respondsToSelector:@selector(fetchListSectionsWithListObjectID:error:)]) {
        result = [store fetchListSectionsWithListObjectID:listOID error:&err];
    } else {
        Class view = NSClassFromString(@"REMListSectionsDataView");
        id dv = view ? [[view alloc] initWithStore:store] : nil;
        if (dv && [dv respondsToSelector:@selector(fetchListSectionsInList:error:)]) {
            result = [dv fetchListSectionsInList:list error:&err];
        }
    }
    if ([result isKindOfClass:[NSArray class]]) return result;
    if ([result isKindOfClass:[NSSet class]]) return [(NSSet *)result allObjects];
    return nil;
}

static NSString *ha_section_name(id section) {
    id n = [section respondsToSelector:@selector(displayName)] ? [section displayName] : nil;
    return [n isKindOfClass:[NSString class]] ? n : nil;
}

static NSUUID *ha_uuid_of(id object) {
    id oid = [object respondsToSelector:@selector(objectID)] ? [object objectID] : nil;
    id u = [oid respondsToSelector:@selector(uuid)] ? [oid uuid] : nil;
    return [u isKindOfClass:[NSUUID class]] ? u : nil;
}

static BOOL ha_fetch(id store, NSUUID *listUUID, NSUUID *remUUID, id *listOut, id *listOIDOut, id *remOut,
                     char **error) {
    id listOID = ha_object_id(@"REMList", @"REMCDList", listUUID);
    id remOID = ha_object_id(@"REMReminder", @"REMCDReminder", remUUID);
    if (!listOID || !remOID) return ha_fail(error, @"could not build ReminderKit object ids");
    NSError *err = nil;
    id list = [store fetchListWithObjectID:listOID error:&err];
    if (!list) return ha_fail(error, [NSString stringWithFormat:@"list not found in ReminderKit (%@)", err.localizedDescription ?: @"nil"]);
    err = nil;
    id rem = [store fetchReminderWithObjectID:remOID error:&err];
    if (!rem) return ha_fail(error, [NSString stringWithFormat:@"reminder not found in ReminderKit (%@)", err.localizedDescription ?: @"nil"]);
    *listOut = list;
    *listOIDOut = listOID;
    *remOut = rem;
    return YES;
}

// ---- apply -------------------------------------------------------------------------------------

static BOOL ha_apply(NSString *listID, NSString *remID, NSString *section, NSArray<NSString *> *tags, char **error) {
    NSUUID *listUUID = [[NSUUID alloc] initWithUUIDString:listID];
    NSUUID *remUUID = [[NSUUID alloc] initWithUUIDString:remID];
    if (!listUUID || !remUUID) return ha_fail(error, @"identifiers are not UUIDs");

    Class storeClass = NSClassFromString(@"REMStore");
    Class requestClass = NSClassFromString(@"REMSaveRequest");
    if (!storeClass || !requestClass) return ha_fail(error, @"ReminderKit classes missing");
    id store = [[storeClass alloc] init];
    id list = nil, listOID = nil, rem = nil;
    if (!ha_fetch(store, listUUID, remUUID, &list, &listOID, &rem, error)) return NO;

    id request = [[requestClass alloc] initWithStore:store];
    if (!request) return ha_fail(error, @"could not create REMSaveRequest");

    if (tags.count > 0) {
        id change = [request updateReminder:rem];
        id context = [change respondsToSelector:@selector(hashtagContext)] ? [change hashtagContext] : nil;
        if (!context || ![context respondsToSelector:@selector(addHashtagWithType:name:)])
            return ha_fail(error, @"hashtag context unavailable");
        for (NSString *t in tags) [context addHashtagWithType:0 name:t];
    }

    if (section.length > 0) {
        id listChange = [request updateList:list];
        id sectionsContext = [listChange respondsToSelector:@selector(sectionsContextChangeItem)]
            ? [listChange sectionsContextChangeItem] : nil;
        if (!sectionsContext || ![sectionsContext respondsToSelector:@selector(setUnsavedMembershipsOfRemindersInSections:)])
            return ha_fail(error, @"sections context unavailable");

        NSArray *existing = ha_sections(store, list, listOID);
        if (!existing) return ha_fail(error, @"could not read the list's sections");
        NSUUID *sectionUUID = nil;
        for (id s in existing) {
            NSString *n = ha_section_name(s);
            if (n && [n caseInsensitiveCompare:section] == NSOrderedSame) { sectionUUID = ha_uuid_of(s); break; }
        }
        if (!sectionUUID) {
            id created = [request addListSectionWithDisplayName:section toListSectionContextChangeItem:sectionsContext];
            sectionUUID = ha_uuid_of(created);
            if (!sectionUUID) return ha_fail(error, @"created section has no uuid");
        }
        Class membershipClass = NSClassFromString(@"REMMembership");
        Class membershipsClass = NSClassFromString(@"REMMemberships");
        id membership = [[membershipClass alloc] initWithMemberIdentifier:remUUID groupIdentifier:sectionUUID
                                                               isObsolete:NO modifiedOn:[NSDate date]];
        id memberships = membership ? [[membershipsClass alloc] initWithMemberships:[NSSet setWithObject:membership]] : nil;
        if (!memberships) return ha_fail(error, @"could not build REMMemberships");
        [sectionsContext setUnsavedMembershipsOfRemindersInSections:memberships];
    }

    NSError *err = nil;
    if (![request saveSynchronouslyWithError:&err])
        return ha_fail(error, [NSString stringWithFormat:@"save failed: %@", err.localizedDescription ?: @"unknown"]);
    return YES;
}

int ha_rk_apply(const char *list_uuid, const char *reminder_uuid, const char *section,
                const char *const *tags, int tag_count, char **error) {
    @autoreleasepool {
        @try {
            pthread_once(&gLoadOnce, ha_load);
            if (!gHandle) { ha_out(error, [NSString stringWithUTF8String:gLoadError]); return 1; }
            NSMutableArray<NSString *> *names = [NSMutableArray array];
            for (int i = 0; tags && i < tag_count; i++) {
                NSString *t = ha_str(tags[i]);
                if (t.length > 0 && ![names containsObject:t]) [names addObject:t];
            }
            return ha_apply(ha_str(list_uuid), ha_str(reminder_uuid), ha_str(section), names, error) ? 0 : 2;
        } @catch (NSException *e) {
            ha_out(error, [NSString stringWithFormat:@"ReminderKit exception %@: %@", e.name, e.reason]);
            return 3;
        }
    }
}

// ---- read-back (probe) -------------------------------------------------------------------------

int ha_rk_read(const char *list_uuid, const char *reminder_uuid, char **section, char **tags_csv, char **error) {
    @autoreleasepool {
        @try {
            pthread_once(&gLoadOnce, ha_load);
            if (!gHandle) { ha_out(error, [NSString stringWithUTF8String:gLoadError]); return 1; }
            NSUUID *listUUID = [[NSUUID alloc] initWithUUIDString:ha_str(list_uuid)];
            NSUUID *remUUID = [[NSUUID alloc] initWithUUIDString:ha_str(reminder_uuid)];
            if (!listUUID || !remUUID) { ha_out(error, @"identifiers are not UUIDs"); return 2; }
            id store = [[NSClassFromString(@"REMStore") alloc] init];
            id list = nil, listOID = nil, rem = nil;
            if (!ha_fetch(store, listUUID, remUUID, &list, &listOID, &rem, error)) return 2;

            // Tags: -[REMReminder hashtags] → collection of objects with -name.
            id tagsObj = [rem respondsToSelector:@selector(hashtags)] ? [rem hashtags] : nil;
            if ([tagsObj respondsToSelector:@selector(countByEnumeratingWithState:objects:count:)]) {
                NSMutableArray *names = [NSMutableArray array];
                for (id h in tagsObj) {
                    id n = [h respondsToSelector:@selector(name)] ? [h name] : nil;
                    if ([n isKindOfClass:[NSString class]]) [names addObject:n];
                }
                ha_out(tags_csv, [names componentsJoinedByString:@","]);
            }

            // Section: the list's stored memberships (getter availability varies by macOS version).
            id ms = [list respondsToSelector:@selector(membershipsOfRemindersInSections)] ? [list membershipsOfRemindersInSections] : nil;
            id all = [ms respondsToSelector:@selector(memberships)] ? [ms memberships] : ms;
            NSUUID *group = nil;
            if ([all respondsToSelector:@selector(countByEnumeratingWithState:objects:count:)]) {
                for (id m in all) {
                    id member = [m respondsToSelector:@selector(memberIdentifier)] ? [m memberIdentifier] : nil;
                    BOOL obsolete = [m respondsToSelector:@selector(isObsolete)] ? [m isObsolete] : NO;
                    if (!obsolete && [member isEqual:remUUID]) {
                        id g = [m respondsToSelector:@selector(groupIdentifier)] ? [m groupIdentifier] : nil;
                        if ([g isKindOfClass:[NSUUID class]]) group = g;
                    }
                }
            }
            if (group) {
                for (id s in ha_sections(store, list, listOID) ?: @[]) {
                    if ([ha_uuid_of(s) isEqual:group]) { ha_out(section, ha_section_name(s)); break; }
                }
            }
            return 0;
        } @catch (NSException *e) {
            ha_out(error, [NSString stringWithFormat:@"ReminderKit exception %@: %@", e.name, e.reason]);
            return 3;
        }
    }
}

#else
// Not macOS: nothing to compile. (This target is only declared in Package.swift on macOS.)
typedef int ha_reminderkit_unavailable_on_this_platform;
#endif
