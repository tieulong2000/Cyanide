//
//  QuickLoader.m
//

#import <JavaScriptCore/JavaScriptCore.h>

#import "QuickLoader.h"
#import "RepoTweaks.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import "../utils/file.h"
#import "../SettingsViewController.h"
#import <stdio.h>
#import <unistd.h>
#import <string.h>
#import <pthread.h>
#import <math.h>
#import <Foundation/Foundation.h>
#import <CoreMotion/CoreMotion.h>
#import "../LogTextView.h"

#import "../tweaks/location_sim.h"
// #import "../tweaks/motion_sim.h"
// Rung
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>

extern uint64_t r_nsstr_retained(const char *str);

static NSString * const kQuickLoaderHideHomeBarMaterialKitAssets =
    @"/System/Library/PrivateFrameworks/MaterialKit.framework/Assets.car";

// ==========================================
// 1: 64-Bit Pointer Translation Helpers
// ==========================================
static uint64_t js_to_uint64(JSValue *val) {
    if ([val isString]) {
        return strtoull([[val toString] UTF8String], NULL, 16);
    }
    return (uint64_t)[val toDouble];
}

static NSString* uint64_to_js(uint64_t val) {
    return [NSString stringWithFormat:@"0x%llx", val];
}

static NSMutableDictionary *quickloader_string_values_dictionary(id raw) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if (![raw isKindOfClass:NSDictionary.class]) return out;
    [(NSDictionary *)raw enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        (void)stop;
        if ([key isKindOfClass:NSString.class] && [obj isKindOfClass:NSString.class]) {
            out[key] = obj;
        }
    }];
    return out;
}

static NSString *quickloader_pref_string(NSDictionary *prefs, NSString *key) {
    if (![prefs isKindOfClass:NSDictionary.class] || ![key isKindOfClass:NSString.class]) return @"";
    id value = prefs[key];
    return [value isKindOfClass:NSString.class] ? value : @"";
}

static NSString *quickloader_string_or_empty(id value) {
    return [value isKindOfClass:NSString.class] ? (NSString *)value : @"";
}

static BOOL quickloader_valid_identifier(NSString *name) {
    if (![name isKindOfClass:NSString.class] || name.length == 0) return NO;
    unichar first = [name characterAtIndex:0];
    if (![[NSCharacterSet letterCharacterSet] characterIsMember:first] && first != '_' && first != '$') return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$"];
    return [name rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

static NSString *quickloader_js_string_literal(NSString *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[value ?: @""]
                                                   options:0
                                                     error:nil];
    NSString *arrayLiteral = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if (arrayLiteral.length >= 2 && [arrayLiteral hasPrefix:@"["] && [arrayLiteral hasSuffix:@"]"]) {
        return [arrayLiteral substringWithRange:NSMakeRange(1, arrayLiteral.length - 2)];
    }
    return @"\"\"";
}

static NSString *quickloader_js_number_literal(NSString *value) {
    double number = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0.0;
    if (!isfinite(number)) number = 0.0;
    return [NSString stringWithFormat:@"%.12g", number];
}

static NSString * const kQuickLoaderSourceRepoURLKey = @"QuickLoaderSourceRepoURL";
static NSString * const kQuickLoaderSourceTweakIDKey = @"QuickLoaderSourceTweakID";

static NSString *quickloader_compiled_script_for_raw_script(NSString *rawScript,
                                                            NSMutableDictionary *values) {
    if (![rawScript isKindOfClass:NSString.class] || rawScript.length == 0) return nil;
    if (![values isKindOfClass:NSMutableDictionary.class]) values = [NSMutableDictionary dictionary];

    NSMutableString *finalScript = [NSMutableString stringWithString:@"//Variables injected by Cyanide\n"];
    NSArray *lines = [rawScript componentsSeparatedByString:@"\n"];
    for (NSString *line in lines) {
        if (![line containsString:@"@param:"]) continue;
        NSArray *parts = [line componentsSeparatedByString:@"|"];
        if (parts.count < 4) continue;

        NSArray *typeParts = [parts[0] componentsSeparatedByString:@"@param:"];
        if (typeParts.count < 2) continue;
        NSString *type = [quickloader_string_or_empty(typeParts[1]) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *varName = [quickloader_string_or_empty(parts[1]) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *defValue = [quickloader_string_or_empty(parts[3]) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!quickloader_valid_identifier(varName)) continue;

        NSString *currentValue = quickloader_string_or_empty(values[varName]);
        if (currentValue.length == 0) {
            currentValue = defValue;
            values[varName] = defValue ?: @"";
        }

        if ([type isEqualToString:@"switch"]) {
            [finalScript appendFormat:@"var %@ = %@;\n", varName, [currentValue boolValue] ? @"true" : @"false"];
        } else if ([type isEqualToString:@"text"] || [type isEqualToString:@"color"]) {
            [finalScript appendFormat:@"var %@ = %@;\n", varName, quickloader_js_string_literal(currentValue)];
        } else if ([type isEqualToString:@"slider"] || [type isEqualToString:@"number"]) {
            [finalScript appendFormat:@"var %@ = %@;\n", varName, quickloader_js_number_literal(currentValue)];
        }
    }

    [finalScript appendString:@"// --------------------------------------\n\n"];
    [finalScript appendString:rawScript];
    return finalScript;
}

static bool quickloader_save_repo_tweak_internal(NSString *repoURL,
                                                 NSString *tweakID,
                                                 NSString *displayName,
                                                 NSString *rawScript,
                                                 NSDictionary *values,
                                                 BOOL logQueued) {
    NSString *safeRepo = quickloader_string_or_empty(repoURL);
    NSString *safeID = quickloader_string_or_empty(tweakID);
    NSString *safeName = quickloader_string_or_empty(displayName);
    if (safeRepo.length == 0 || safeID.length == 0 || rawScript.length == 0) return false;

    NSMutableDictionary *mutableValues = quickloader_string_values_dictionary(values);
    NSString *compiled = quickloader_compiled_script_for_raw_script(rawScript, mutableValues);
    if (compiled.length == 0) return false;

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:safeName.length ? safeName : safeID forKey:@"QuickLoaderSourceScriptName"];
    [d setObject:rawScript forKey:@"QuickLoaderSourceRawJS"];
    [d setObject:mutableValues forKey:@"QuickLoaderSourceValues"];
    [d setObject:safeRepo forKey:kQuickLoaderSourceRepoURLKey];
    [d setObject:safeID forKey:kQuickLoaderSourceTweakIDKey];
    [d setObject:compiled forKey:@"QuickLoaderSavedJS"];
    [d setObject:mutableValues forKey:repotweaks_values_defaults_key(safeRepo, safeID)];
    [d synchronize];
    if (logQueued) {
        log_user("[QuickLoader] Queued repo package: %s\n", (safeName.length ? safeName : safeID).UTF8String);
    }
    return true;
}


static const double kLocationSimPi = 3.14159265358979323846;
static const double kLocationSimMetersPerDegreeLatitude = 111320.0;
static double locationsim_distance_between(
    LocationSimWaypoint a,
    LocationSimWaypoint b)
{
    double avgLat =
        (a.latitude + b.latitude) * 0.5;

    double cosLat =
        cos(avgLat * kLocationSimPi / 180.0);

    if (fabs(cosLat) < 0.000001)
        cosLat = 0.000001;

    double north =
        (b.latitude - a.latitude) *
        kLocationSimMetersPerDegreeLatitude;

    double east =
        (b.longitude - a.longitude) *
        kLocationSimMetersPerDegreeLatitude *
        cosLat;

    return sqrt(
        north * north +
        east * east
    );
}

static double locationsim_route_distance(
    const LocationSimWaypoint *points,
    size_t count,
    bool closeLoop)
{
    if (!points || count < 2)
        return 0.0;

    double total = 0.0;

    for (size_t i = 0;
         i + 1 < count;
         i++) {

        total +=
            locationsim_distance_between(
                points[i],
                points[i + 1]
            );
    }

    if (closeLoop) {
        total +=
            locationsim_distance_between(
                points[count - 1],
                points[0]
            );
    }

    return total;
}

bool quickloader_save_repo_tweak(NSString *repoURL,
                                 NSString *tweakID,
                                 NSString *displayName,
                                 NSString *rawScript,
                                 NSDictionary *values) {
    return quickloader_save_repo_tweak_internal(repoURL,
                                                tweakID,
                                                displayName,
                                                rawScript,
                                                values,
                                                YES);
}

bool quickloader_is_repo_tweak_installed(NSString *repoURL, NSString *tweakID) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *safeRepo = quickloader_string_or_empty(repoURL);
    NSString *safeID = quickloader_string_or_empty(tweakID);
    if (safeRepo.length == 0 || safeID.length == 0) return false;
    return [[d stringForKey:kQuickLoaderSourceRepoURLKey] isEqualToString:safeRepo] &&
           [[d stringForKey:kQuickLoaderSourceTweakIDKey] isEqualToString:safeID] &&
           [[d stringForKey:@"QuickLoaderSavedJS"] length] > 0;
}

void quickloader_clear_repo_tweak_if_matches(NSString *repoURL, NSString *tweakID) {
    if (!quickloader_is_repo_tweak_installed(repoURL, tweakID)) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d removeObjectForKey:@"QuickLoaderSourceScriptName"];
    [d removeObjectForKey:@"QuickLoaderSourceRawJS"];
    [d removeObjectForKey:@"QuickLoaderSourceValues"];
    [d removeObjectForKey:kQuickLoaderSourceRepoURLKey];
    [d removeObjectForKey:kQuickLoaderSourceTweakIDKey];
    [d removeObjectForKey:@"QuickLoaderSavedJS"];
    [d synchronize];
}

bool quickloader_is_driven_by_repo_tweak(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *repoURL = quickloader_string_or_empty([d stringForKey:kQuickLoaderSourceRepoURLKey]);
    return repoURL.length > 0;
}

bool quickloader_refresh_active_repo_tweak(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *repoURL = quickloader_string_or_empty([d stringForKey:kQuickLoaderSourceRepoURLKey]);
    NSString *tweakID = quickloader_string_or_empty([d stringForKey:kQuickLoaderSourceTweakIDKey]);
    if (repoURL.length == 0 || tweakID.length == 0) return false;

    NSString *rawScript = [d stringForKey:repotweaks_script_defaults_key(repoURL, tweakID)];
    if (rawScript.length == 0) {
        log_user("[QuickLoader] Selected repo package script is missing; refresh its source first.\n");
        return false;
    }

    NSDictionary *values = [d dictionaryForKey:repotweaks_values_defaults_key(repoURL, tweakID)] ?: @{};
    NSString *displayName = [d stringForKey:@"QuickLoaderSourceScriptName"];
    return quickloader_save_repo_tweak_internal(repoURL,
                                                tweakID,
                                                displayName.length ? displayName : tweakID,
                                                rawScript,
                                                values,
                                                NO);
}


// ==========================================
// Global variables for js daemon and kill switch
// ==========================================
static JSContext *g_quickloader_context = nil;
static NSMutableDictionary *g_quickloader_timers = nil;
static int g_quickloader_timer_id = 0;

static int g_quickloader_shutting_down = 0;
static char g_quickloader_queue_key;
static pthread_mutex_t g_quickloader_queue_lock = PTHREAD_MUTEX_INITIALIZER;
static dispatch_queue_t g_quickloader_queue = nil;
static uint64_t g_quickloader_generation = 1;

static dispatch_queue_t quickloader_create_js_queue_locked(void) {
    NSString *label = [NSString stringWithFormat:@"com.zeroxjf.cyanide.quickloader.js.%llu",
                       (unsigned long long)g_quickloader_generation];
    dispatch_queue_t q = dispatch_queue_create(label.UTF8String, DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(q, &g_quickloader_queue_key, &g_quickloader_queue_key, NULL);
    return q;
}

static dispatch_queue_t quickloader_js_queue(void) {
    pthread_mutex_lock(&g_quickloader_queue_lock);
    if (!g_quickloader_queue) {
        g_quickloader_queue = quickloader_create_js_queue_locked();
    }
    dispatch_queue_t q = g_quickloader_queue;
    pthread_mutex_unlock(&g_quickloader_queue_lock);
    return q;
}

static uint64_t quickloader_current_generation(void) {
    pthread_mutex_lock(&g_quickloader_queue_lock);
    uint64_t generation = g_quickloader_generation;
    pthread_mutex_unlock(&g_quickloader_queue_lock);
    return generation;
}

static void quickloader_set_shutting_down(BOOL shuttingDown) {
    pthread_mutex_lock(&g_quickloader_queue_lock);
    g_quickloader_shutting_down = shuttingDown ? 1 : 0;
    pthread_mutex_unlock(&g_quickloader_queue_lock);
}

static uint64_t quickloader_begin_run_generation(void) {
    pthread_mutex_lock(&g_quickloader_queue_lock);
    g_quickloader_generation++;
    if (g_quickloader_generation == 0) g_quickloader_generation = 1;
    g_quickloader_shutting_down = 0;
    if (!g_quickloader_queue) {
        g_quickloader_queue = quickloader_create_js_queue_locked();
    }
    uint64_t generation = g_quickloader_generation;
    pthread_mutex_unlock(&g_quickloader_queue_lock);
    return generation;
}

static BOOL quickloader_generation_is_current(uint64_t generation) {
    pthread_mutex_lock(&g_quickloader_queue_lock);
    BOOL current = (generation == g_quickloader_generation);
    pthread_mutex_unlock(&g_quickloader_queue_lock);
    return current;
}

static BOOL quickloader_generation_is_active(uint64_t generation) {
    pthread_mutex_lock(&g_quickloader_queue_lock);
    BOOL active = !g_quickloader_shutting_down && generation == g_quickloader_generation;
    pthread_mutex_unlock(&g_quickloader_queue_lock);
    return active;
}

static void quickloader_abandon_js_queue_after_timeout(const char *reason, BOOL shuttingDown) {
    pthread_mutex_lock(&g_quickloader_queue_lock);
    g_quickloader_generation++;
    if (g_quickloader_generation == 0) g_quickloader_generation = 1;
    g_quickloader_shutting_down = shuttingDown ? 1 : 0;
    g_quickloader_queue = quickloader_create_js_queue_locked();
    g_quickloader_context = nil;
    g_quickloader_timers = nil;
    pthread_mutex_unlock(&g_quickloader_queue_lock);
    log_user("[QuickLoader] Abandoned wedged JS queue after %s; future runs will use a fresh queue.\n",
             reason ? reason : "timeout");
}

static bool quickloader_perform_sync_timeout(dispatch_block_t block, int64_t timeoutNsec) {
    if (!block) return true;
    if (dispatch_get_specific(&g_quickloader_queue_key)) {
        block();
        return true;
    }

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    dispatch_async(quickloader_js_queue(), ^{
        block();
        dispatch_semaphore_signal(sema);
    });
    dispatch_time_t deadline = timeoutNsec < 0
        ? DISPATCH_TIME_FOREVER
        : dispatch_time(DISPATCH_TIME_NOW, timeoutNsec);
    return dispatch_semaphore_wait(sema, deadline) == 0;
}


// ==========================================
// Session init with auto-load default settings
// ==========================================
bool quickloader_apply_in_session() {
    quickloader_set_shutting_down(NO);

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *activeRepoURL = quickloader_string_or_empty([d stringForKey:kQuickLoaderSourceRepoURLKey]);
    NSString *activeTweakID = quickloader_string_or_empty([d stringForKey:kQuickLoaderSourceTweakIDKey]);
    NSString *activeName = quickloader_string_or_empty([d stringForKey:@"QuickLoaderSourceScriptName"]);
    BOOL hasRepoPackage = activeRepoURL.length > 0 && activeTweakID.length > 0;

    if (hasRepoPackage) {
        log_user("[QuickLoader] Active session detected. Checking selected repo package: %s...\n",
                 (activeName.length ? activeName : activeTweakID).UTF8String);
        if (!quickloader_refresh_active_repo_tweak()) {
            return false;
        }
    } else {
        log_user("[QuickLoader] Active session detected. Checking manually selected JS tweak...\n");
    }

    NSString *savedJS = [d stringForKey:@"QuickLoaderSavedJS"];

    if (savedJS && savedJS.length > 0) {

        // ===============================================================
        // auto-loading default settings
        // ===============================================================
        NSMutableDictionary *savedValues = quickloader_string_values_dictionary([d dictionaryForKey:@"QuickLoaderSourceValues"]);
        BOOL didUpdateDefaults = NO;

        NSArray *lines = [savedJS componentsSeparatedByString:@"\n"];
        for (NSString *line in lines) {
            if ([line containsString:@"@param:"]) {
                NSArray *parts = [line componentsSeparatedByString:@"|"];
                if (parts.count >= 4) {
                    //extracting variable name and default
                    NSString *varName = [parts[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    NSString *defValue = [parts[3] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if (!quickloader_valid_identifier(varName)) {
                        log_user("[QuickLoader] Skipping invalid parameter name: %s\n", varName.UTF8String);
                        continue;
                    }

                    //if new, use .js default values
                    if (!savedValues[varName]) {
                        savedValues[varName] = defValue;
                        didUpdateDefaults = YES;
                    }
                }
            }
        }

        //if defaults found, saves them in memory
        if (didUpdateDefaults) {
            [d setObject:savedValues forKey:@"QuickLoaderSourceValues"];
            [d synchronize];
        }
        // ===============================================================

        if (hasRepoPackage) {
            log_user("[QuickLoader] Executing repo package: %s\n",
                     (activeName.length ? activeName : activeTweakID).UTF8String);
        } else {
            log_user("[QuickLoader] Executing user-provided JS file...\n");
        }
        return quickloader_run_js_string(savedJS);
    } else {
        log_user("[QuickLoader] No JS file loaded.\n");
    }

    return false;
}

// ==========================================
// Javascript interpreter engine
// ==========================================
bool quickloader_run_js_string(NSString *jsCode) {
    if (!jsCode || jsCode.length == 0) return false;

    __block bool ok = true;
    uint64_t runGeneration = quickloader_begin_run_generation();
    bool completed = quickloader_perform_sync_timeout(^{
        if (!quickloader_generation_is_current(runGeneration)) return;
        log_user("[JS Engine] Initializing long-living environment...\n");

        if (g_quickloader_timers == nil) {
            g_quickloader_timers = [[NSMutableDictionary alloc] init];
        } else {
            for (dispatch_source_t t in g_quickloader_timers.allValues) {
                if (dispatch_testcancel(t) == 0) {
                    dispatch_source_cancel(t);
                }
            }
            [g_quickloader_timers removeAllObjects];
        }
        NSMutableDictionary *timers = g_quickloader_timers;

        g_quickloader_context = [[JSContext alloc] init];
        JSContext *context = g_quickloader_context;

        context.exceptionHandler = ^(JSContext *ctx, JSValue *exception) {
            log_user("[JS ERROR] %s\n", [[exception toString] UTF8String]);
        };

        // Timers target the same serial queue as the JSContext. JavaScriptCore
        // contexts are not safe to touch concurrently, and SpringBoard
        // RemoteCall state is single-session by design.
        context[@"setInterval"] = ^JSValue*(JSValue *func, JSValue *delay) {
            if (!quickloader_generation_is_active(runGeneration)) return [JSValue valueWithInt32:0 inContext:[JSContext currentContext]];
            int tId = ++g_quickloader_timer_id;
            uint64_t ms = [delay toUInt32];
            if (ms < 16) ms = 16;

            dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, quickloader_js_queue());
            dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, ms * NSEC_PER_MSEC), ms * NSEC_PER_MSEC, (ms / 10) * NSEC_PER_MSEC);
            dispatch_source_set_event_handler(timer, ^{
                if (quickloader_generation_is_active(runGeneration)) {
                    [func callWithArguments:@[]];
                }
            });

            timers[@(tId)] = timer;
            dispatch_resume(timer);
            return [JSValue valueWithInt32:tId inContext:[JSContext currentContext]];
        };

        context[@"clearInterval"] = ^(JSValue *timerId) {
            if (!quickloader_generation_is_active(runGeneration)) return;
            int tId = [timerId toInt32];
            dispatch_source_t timer = timers[@(tId)];
            if (timer) {
                dispatch_source_cancel(timer);
                [timers removeObjectForKey:@(tId)];
            }
        };

        context[@"setTimeout"] = ^JSValue*(JSValue *func, JSValue *delay) {
            if (!quickloader_generation_is_active(runGeneration)) return [JSValue valueWithInt32:0 inContext:[JSContext currentContext]];
            int tId = ++g_quickloader_timer_id;
            uint64_t ms = [delay toUInt32];

            dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, quickloader_js_queue());
            dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, ms * NSEC_PER_MSEC), DISPATCH_TIME_FOREVER, 0);
            dispatch_source_set_event_handler(timer, ^{
                if (quickloader_generation_is_active(runGeneration)) {
                    [func callWithArguments:@[]];
                }
                dispatch_source_cancel(timer);
                [timers removeObjectForKey:@(tId)];
            });

            timers[@(tId)] = timer;
            dispatch_resume(timer);
            return [JSValue valueWithInt32:tId inContext:[JSContext currentContext]];
        };

        context[@"clearTimeout"] = ^(JSValue *timerId) {
            if (!quickloader_generation_is_active(runGeneration)) return;
            int tId = [timerId toInt32];
            dispatch_source_t timer = timers[@(tId)];
            if (timer) {
                dispatch_source_cancel(timer);
                [timers removeObjectForKey:@(tId)];
            }
        };

        //Bridge ipc core (safe with kill-switch)
        context[@"log"] = ^(NSString *msg) {
            if (!quickloader_generation_is_active(runGeneration)) return;
            log_user("[JS] %s\n", [msg UTF8String]);
        };

        context[@"dz_zero_system_file_page"] = ^NSNumber*(NSString *path, JSValue *offsetValue) {
            if (!quickloader_generation_is_active(runGeneration)) return @(NO);
            if (![path isKindOfClass:NSString.class] || path.length == 0) {
                log_user("[QuickLoader] dz_zero_system_file_page missing path.\n");
                return @(NO);
            }
            uint64_t offset = offsetValue ? js_to_uint64(offsetValue) : 0;
            log_user("[QuickLoader] Stable page-zero request: %s offset=%llu\n",
                     path.UTF8String,
                     (unsigned long long)offset);
            int rc = zero_system_file_page(path.UTF8String, (off_t)offset);
            if (rc == 0 &&
                offset == 0 &&
                [path isEqualToString:kQuickLoaderHideHomeBarMaterialKitAssets]) {
                settings_note_hide_home_bar_respring_pending();
            }
            return @(rc == 0);
        };

        context[@"r_pref_num"] = ^NSNumber*(NSString *key) {
            if (!quickloader_generation_is_active(runGeneration)) return @(0);
            NSDictionary *prefs = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"QuickLoaderSourceValues"];
            return @([quickloader_pref_string(prefs, key) doubleValue]);
        };

        context[@"r_pref_str"] = ^NSString*(NSString *key) {
            if (!quickloader_generation_is_active(runGeneration)) return @"";
            NSDictionary *prefs = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"QuickLoaderSourceValues"];
            return quickloader_pref_string(prefs, key);
        };

        context[@"r_pref_bool"] = ^NSNumber*(NSString *key) {
            if (!quickloader_generation_is_active(runGeneration)) return @(0);
            NSDictionary *prefs = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"QuickLoaderSourceValues"];
            return @([quickloader_pref_string(prefs, key) boolValue]);
        };

        context[@"r_class"] = ^(NSString *className) {
            if (!quickloader_generation_is_active(runGeneration)) return uint64_to_js(0);
            uint64_t cls = r_class([className UTF8String]);
            return uint64_to_js(cls);
        };

        context[@"r_responds"] = ^() {
            if (!quickloader_generation_is_active(runGeneration)) return @(0);
            NSArray *args = [JSContext currentArguments];
            if (args.count < 2) return @(0);

            uint64_t target = js_to_uint64(args[0]);
            NSString *selector = [args[1] toString];
            return @(r_responds(target, [selector UTF8String]));
        };

        context[@"r_sel"] = ^NSString*(NSString *selName) {
            if (!quickloader_generation_is_active(runGeneration)) return uint64_to_js(0);
            if (![selName isKindOfClass:NSString.class]) return uint64_to_js(0);
            uint64_t selPtr = r_sel([selName UTF8String]);
            return uint64_to_js(selPtr);
        };

        context[@"r_msg2"] = ^() {
            if (!quickloader_generation_is_active(runGeneration)) return uint64_to_js(0);
            NSArray *args = [JSContext currentArguments];
            if (args.count < 2) return uint64_to_js(0);
            uint64_t target = js_to_uint64(args[0]);
            NSString *selector = [args[1] toString];

            uint64_t a1 = args.count > 2 ? js_to_uint64(args[2]) : 0;
            uint64_t a2 = args.count > 3 ? js_to_uint64(args[3]) : 0;
            uint64_t a3 = args.count > 4 ? js_to_uint64(args[4]) : 0;
            uint64_t a4 = args.count > 5 ? js_to_uint64(args[5]) : 0;

            uint64_t res = r_msg2(target, [selector UTF8String], a1, a2, a3, a4);
            return uint64_to_js(res);
        };

        context[@"r_msg2_main"] = ^() {
            if (!quickloader_generation_is_active(runGeneration)) return uint64_to_js(0);
            NSArray *args = [JSContext currentArguments];
            if (args.count < 2) return uint64_to_js(0);
            uint64_t target = js_to_uint64(args[0]);
            NSString *selector = [args[1] toString];

            uint64_t a1 = args.count > 2 ? js_to_uint64(args[2]) : 0;
            uint64_t a2 = args.count > 3 ? js_to_uint64(args[3]) : 0;
            uint64_t a3 = args.count > 4 ? js_to_uint64(args[4]) : 0;
            uint64_t a4 = args.count > 5 ? js_to_uint64(args[5]) : 0;

            uint64_t res = r_msg2_main(target, [selector UTF8String], a1, a2, a3, a4);
            return uint64_to_js(res);
        };

        context[@"r_nsstr"] = ^NSString*(NSString *str) {
            if (!quickloader_generation_is_active(runGeneration)) return uint64_to_js(0);
            if (!str) return uint64_to_js(0);
            uint64_t ptr = r_nsstr_retained([str UTF8String]);
            return uint64_to_js(ptr);
        };
        
        context[@"locsim_start_route"] = ^NSNumber*(NSString *jsonString,  NSNumber *speedKmh,  NSNumber *durationMinutes) {

            if (!quickloader_generation_is_active(runGeneration))
                return @(NO);

            if (![jsonString isKindOfClass:NSString.class] ||
                jsonString.length == 0) {

                log_user("[RepoTweaks][LOCSIM] Missing route JSON\n");
                return @(NO);
            }

            NSData *jsonData =
                [jsonString dataUsingEncoding:NSUTF8StringEncoding];

            if (!jsonData) {
                log_user("[RepoTweaks][LOCSIM] Cannot encode route JSON\n");
                return @(NO);
            }

            NSError *jsonError = nil;

            id object =
                [NSJSONSerialization JSONObjectWithData:jsonData
                                                options:0
                                                  error:&jsonError];

            if (jsonError ||
                ![object isKindOfClass:NSArray.class]) {

                log_user("[RepoTweaks][LOCSIM] Invalid route JSON: %s\n",
                        jsonError.localizedDescription.UTF8String ?: "unknown error");

                return @(NO);
            }

            NSArray *route = (NSArray *)object;

            if (route.count < 2) {
                log_user("[RepoTweaks][LOCSIM] Route needs at least 2 points\n");
                return @(NO);
            }

            /*
            * Tránh script đưa số lượng điểm quá lớn làm
            * QuickLoader/RemoteCall bị treo.
            */
            const NSUInteger maxPoints = 5000;

            if (route.count > maxPoints) {
                log_user("[RepoTweaks][LOCSIM] Too many route points: %lu (max=%lu)\n",
                        (unsigned long)route.count,
                        (unsigned long)maxPoints);

                return @(NO);
            }

            LocationSimWaypoint *points =
                calloc(route.count, sizeof(LocationSimWaypoint));

            if (!points) {
                log_user("[RepoTweaks][LOCSIM] Cannot allocate route points\n");
                return @(NO);
            }

            size_t validCount = 0;

            for (id entry in route) {

                if (![entry isKindOfClass:NSArray.class])
                    continue;

                NSArray *coordinate = (NSArray *)entry;

                if (coordinate.count < 2)
                    continue;

                id latObject = coordinate[0];
                id lonObject = coordinate[1];

                if (![latObject respondsToSelector:@selector(doubleValue)] ||
                    ![lonObject respondsToSelector:@selector(doubleValue)])
                    continue;

                double latitude =
                    [latObject doubleValue];

                double longitude =
                    [lonObject doubleValue];

                if (!isfinite(latitude) ||
                    !isfinite(longitude))
                    continue;

                if (latitude < -90.0 ||
                    latitude > 90.0 ||
                    longitude < -180.0 ||
                    longitude > 180.0)
                    continue;

                points[validCount].latitude = latitude;
                points[validCount].longitude = longitude;

                validCount++;
            }

            if (validCount < 2) {

                log_user("[RepoTweaks][LOCSIM] Route contains fewer than 2 valid points\n");

                free(points);

                return @(NO);
            }
            double duraMinutes = 15.0;

            if ([durationMinutes isKindOfClass:NSNumber.class]) {
                duraMinutes = durationMinutes.doubleValue;
            }

            double kmh = 5.0;

            if ([speedKmh isKindOfClass:NSNumber.class]) {
                kmh = speedKmh.doubleValue;
            }

            if (!isfinite(kmh) || kmh <= 0.0) {
                kmh = 5.0;
            }

            /* Giới hạn ví dụ 1–120 km/h */
            if (kmh < 1.0) kmh = 1.0;
            if (kmh > 120.0) kmh = 120.0;

            /* CoreLocation dùng m/s */
            double routeSpeed = kmh / 3.6;

            if (!isfinite(routeSpeed) ||
                routeSpeed <= 0.0) {

                routeSpeed = 1.4;
            }

            double routeDistance =
                locationsim_route_distance(
                    points,
                    validCount,
                    true
                );

            /*
            * Ví dụ muốn simulation chạy khoảng 2 giờ.
            */
            double targetSeconds = duraMinutes * 60.0;

            double oneLoopSeconds =
                routeDistance /
                routeSpeed;

            size_t loopCount = 1;

            if (oneLoopSeconds > 0.0) {

                loopCount =
                    (size_t)ceil(
                        targetSeconds /
                        oneLoopSeconds
                    );

                if (loopCount < 1)
                    loopCount = 1;
            }

            log_user(
                "[LOCSIM] distance=%.1fm speed=%.2fm/s oneLoop=%.1fs loops=%zu target=%.1fs\n",
                routeDistance,
                routeSpeed,
                oneLoopSeconds,
                loopCount,
                targetSeconds
            );
            LocationSimConfig config = {
                .latitude = points[0].latitude,
                .longitude = points[0].longitude,

                .altitude = 0.0,

                .horizontalAccuracy = 5.0,
                .verticalAccuracy = 5.0,

                .hostProcess = "Maps",
                .launchHost = true,

                .routePoints = points,
                .routePointCount = validCount,
                .routeSpeed = routeSpeed,
                .routeLoopCount = loopCount,
            };

            log_user("[QuickLoader][LOCSIM] Starting route points=%zu speed=%.1f km/h (%.2f m/s)\n",
                validCount,
                kmh,
                routeSpeed);

            bool ok = locationsim_apply_static(&config);

            /*
            * Có thể free ở đây vì location_sim.m đã biến
            * từng waypoint thành CLLocation và append vào
            * CLSimulationManager trước khi hàm trả về.
            */
            free(points);

            log_user("[RepoTweaks][LOCSIM] Route start => %s\n",
                    ok ? "OK" : "FAILED");

            return @(ok);
        };
        context[@"locsim_stop"] = ^NSNumber*{

            if (!quickloader_generation_is_active(runGeneration))
                return @(NO);

            log_user("[QuickLoader][LOCSIM] Stopping simulation\n");

            bool ok = locationsim_stop("Maps", true);

            log_user("[QuickLoader][LOCSIM] Stop => %s\n",
                    ok ? "OK" : "FAILED");

            return @(ok);
        };
        
        context[@"r_vibrate"] = ^(NSNumber *style) {

            NSInteger vibrationStyle = 1;

            if ([style isKindOfClass:NSNumber.class]) {
                vibrationStyle = style.integerValue;
            }

            dispatch_async(dispatch_get_main_queue(), ^{

                UIImpactFeedbackStyle impactStyle =
                    UIImpactFeedbackStyleMedium;

                if (vibrationStyle == 0) {
                    impactStyle = UIImpactFeedbackStyleLight;
                }
                else if (vibrationStyle == 2) {
                    impactStyle = UIImpactFeedbackStyleHeavy;
                }

                UIImpactFeedbackGenerator *generator =
                    [[UIImpactFeedbackGenerator alloc]
                        initWithStyle:impactStyle];

                [generator prepare];
                [generator impactOccurred];
            });
        };
        context[@"r_vibrate_strong"] = ^(NSNumber *style) {
            dispatch_async(dispatch_get_main_queue(), ^{
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
            });
        };
        // context[@"motionsim_start"] = ^NSNumber*(NSNumber *speedKmh,
        //           NSNumber *intensity) {

        //     if (!quickloader_generation_is_active(runGeneration))
        //         return @(NO);

        //     double speed = 5.0;
        //     double strength = 1.0;

        //     if ([speedKmh isKindOfClass:NSNumber.class])
        //         speed = speedKmh.doubleValue;

        //     if ([intensity isKindOfClass:NSNumber.class])
        //         strength = intensity.doubleValue;

        //     MotionSimConfig config = {
        //         .speedKmh = speed,
        //         .intensity = strength
        //     };

        //     bool ok =
        //         motionsim_start(&config);

        //     log_user(
        //         "[QuickLoader][MOTIONSIM] start speed=%.2f km/h intensity=%.2f result=%s\n",
        //         speed,
        //         strength,
        //         ok ? "OK" : "FAILED"
        //     );

        //     return @(ok);
        // };

        // context[@"motionsim_stop"] = ^NSNumber*{

        //     if (!quickloader_generation_is_active(runGeneration))
        //         return @(NO);

        //     bool ok = motionsim_stop();

        //     log_user(
        //         "[QuickLoader][MOTIONSIM] stop => %s\n",
        //         ok ? "OK" : "FAILED"
        //     );

        //     return @(ok);
        // };

        // context[@"motionsim_sample"] = ^NSDictionary*{

        //     MotionSimSample s =
        //         motionsim_current_sample();

        //     return @{
        //         @"ax": @(s.accelX),
        //         @"ay": @(s.accelY),
        //         @"az": @(s.accelZ),

        //         @"gx": @(s.gyroX),
        //         @"gy": @(s.gyroY),
        //         @"gz": @(s.gyroZ)
        //     };
        // };
        // context[@"motionsim_coremotion_test"] = ^{

        //     static CMMotionManager *manager = nil;
        //     static NSOperationQueue *queue = nil;

        //     manager =
        //         [[CMMotionManager alloc] init];

        //     queue =
        //         [[NSOperationQueue alloc] init];

        //     manager.accelerometerUpdateInterval = 0.1;
        //     manager.gyroUpdateInterval = 0.1;

        //     log_user(
        //         "[MOTIONSIM][TEST] accelAvailable=%d gyroAvailable=%d\n",
        //         manager.accelerometerAvailable,
        //         manager.gyroAvailable
        //     );

        //     if (manager.accelerometerAvailable) {

        //         [manager
        //             startAccelerometerUpdatesToQueue:queue
        //             withHandler:^(
        //                 CMAccelerometerData *data,
        //                 NSError *error)
        //         {
        //             if (error) {
        //                 log_user(
        //                     "[MOTIONSIM][TEST][ACC] error=%s\n",
        //                     error.localizedDescription.UTF8String
        //                 );
        //                 return;
        //             }

        //             if (data) {
        //                 accLogCount++;

        //                 if (accLogCount >= 10) {
        //                     accLogCount = 0;

        //                     log_user(
        //                         "[MOTIONSIM][TEST][ACC] %.3f %.3f %.3f\n",
        //                         data.acceleration.x,
        //                         data.acceleration.y,
        //                         data.acceleration.z
        //                     );
        //                 }
        //             }
        //         }];
        //     }

        //     if (manager.gyroAvailable) {

        //         [manager
        //             startGyroUpdatesToQueue:queue
        //             withHandler:^(
        //                 CMGyroData *data,
        //                 NSError *error)
        //         {
        //             if (error) {
        //                 log_user(
        //                     "[MOTIONSIM][TEST][GYRO] error=%s\n",
        //                     error.localizedDescription.UTF8String
        //                 );
        //                 return;
        //             }

        //             if (data) {
        //                 gyroLogCount++;

        //                 if (gyroLogCount >= 10) {
        //                     gyroLogCount = 0;

        //                     log_user(
        //                         "[MOTIONSIM][TEST][GYRO] %.3f %.3f %.3f\n",
        //                         data.rotationRate.x,
        //                         data.rotationRate.y,
        //                         data.rotationRate.z
        //                     );
        //                 }
        //             }
        //         }];
        //     }
        // };

        log_user("[JS Engine] Executing user script...\n");
        [context evaluateScript:jsCode];
        if (context.exception) {
            ok = false;
        } else {
            log_user("[JS Engine] Execution complete.\n");
        }
    }, 120  * NSEC_PER_SEC);

    if (!completed) {
        ok = false;
        quickloader_abandon_js_queue_after_timeout("run timeout", NO);
    }

    return ok;
}

// ==========================================
// Teardown engine
// ==========================================
bool quickloader_stop_in_session(void) {
    //Order timers to stop
    quickloader_set_shutting_down(YES);
    uint64_t stopGeneration = quickloader_current_generation();

    bool stopped = quickloader_perform_sync_timeout(^{
        if (!quickloader_generation_is_current(stopGeneration)) return;
        log_user("[QuickLoader] Clean Up: Green light, safely stopping JS timer...\n");

        if (g_quickloader_timers) {
            for (id key in [g_quickloader_timers allKeys]) {
                dispatch_source_t timer = (dispatch_source_t)g_quickloader_timers[key];
                if (dispatch_testcancel(timer) == 0) {
                    dispatch_source_cancel(timer);
                }
            }
            [g_quickloader_timers removeAllObjects];
        }

        g_quickloader_context = nil;
    }, 2 * NSEC_PER_SEC);

    if (!stopped) {
        log_user("[QuickLoader] Clean Up timed out; the script may be stuck in a long-running loop.\n");
        quickloader_abandon_js_queue_after_timeout("cleanup timeout", YES);
    }

    return stopped;
}

