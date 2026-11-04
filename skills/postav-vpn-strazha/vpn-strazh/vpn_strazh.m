// VPN-СТРАЖ: экран-блокер, если охраняемое приложение открыто без нужного VPN.
// Реагирует ровно на одно: приложение из настройки открыто И VPN из настройки выключен.
// Всё остальное его не касается: приложение закрыто — молчит. В сеть не ходит,
// смотрит только на процессы и сетевые интерфейсы этого Мака.
//
// Логика: каждые 2 сек проверка. Два плохих замера подряд (~4 сек) → экран на всех мониторах,
// ещё через zakryt_cherez секунд приложение закрывается само. VPN вернулся или приложение
// закрыто → экран исчезает. Строка меню и Док открыты всегда: VPN можно включить при экране.
//
// Значок в строке меню: «Закрыть баннер» — убрать экран до следующего случая;
// «Выключить стража» — молчит, пока не включишь обратно или не перезагрузишь Мак.
//
// Сборка:  clang -fobjc-arc -O2 -framework Cocoa -o vpn-strazh vpn_strazh.m
// Запуск:  vpn-strazh                 — рабочий режим (через LaunchAgent)
//          vpn-strazh --status        — печать состояния и выход
//          vpn-strazh --demo          — показать экран на 12 сек, ничего не закрывает
//          vpn-strazh --vyklyuchit    — выключить до перезагрузки; --vklyuchit — включить
// Проверка: --dir ПАПКА  — своя папка настройки; приложения com.anthropic.* тогда
//                          игнорируются, чтобы тест не закрыл Клод, в котором идёт работа
//           --tiho       — без окон и значка, только лог
//           --sek N      — выйти через N сек
//           --kartinka файл.png — нарисовать экран в файл и выйти

#import <Cocoa/Cocoa.h>
#import <ifaddrs.h>
#import <netinet/in.h>
#import <string.h>
#import <sys/sysctl.h>

static const NSTimeInterval kCheckInterval = 2.0;
static const int kBadChecksToShow = 2;       // ~4 сек: секундный реконнект VPN экран не вызывает
static const NSTimeInterval kForceAfter = 5.0; // не закрылось по-хорошему за 5 сек → закрываем силой
static const long kBootTolerance = 120;      // часы могут чуть сдвинуть время старта системы

// --- Настройка: nastroyka.txt -----------------------------------------------

static NSString *gDir;
static BOOL gTestMode;
static NSMutableArray<NSDictionary<NSString *, NSString *> *> *gApps;
static NSString *gVpnProcess;        // nil — подходит любой туннель
static NSString *gVpnName = @"VPN";
static int gCloseAfter = 10;         // 0 — не закрывать, только экран

static void logLine(NSString *msg) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    printf("[%s] %s\n", [f stringFromDate:[NSDate date]].UTF8String, msg.UTF8String);
    fflush(stdout);
}

static void loadConfig(void) {
    gApps = [NSMutableArray array];
    NSString *path = [gDir stringByAppendingPathComponent:@"nastroyka.txt"];
    NSString *txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
    for (NSString *raw in [txt componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:ws];
        NSRange eq = [line rangeOfString:@"="];
        if (line.length == 0 || [line hasPrefix:@"#"] || eq.location == NSNotFound) continue;
        NSString *key = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:ws];
        NSString *val = [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:ws];
        NSArray<NSString *> *parts = [val componentsSeparatedByString:@"|"];
        NSString *first = [parts[0] stringByTrimmingCharactersInSet:ws];
        NSString *second = parts.count > 1 ? [parts[1] stringByTrimmingCharactersInSet:ws] : first;
        if ([key isEqualToString:@"prilozhenie"] && first.length) {
            if (gTestMode && [first hasPrefix:@"com.anthropic."]) continue;
            [gApps addObject:@{ @"id": first, @"name": second }];
        } else if ([key isEqualToString:@"vpn"]) {
            if ([first isEqualToString:@"любой"]) { gVpnProcess = nil; gVpnName = @"VPN"; }
            else if (first.length) { gVpnProcess = first; gVpnName = second; }
        } else if ([key isEqualToString:@"zakryt_cherez"]) {
            gCloseAfter = MAX(0, val.intValue);
        }
    }
}

// --- Выключение до перезагрузки ---------------------------------------------
// Файл хранит время старта системы: после перезагрузки оно другое, и запись теряет силу.
// В файле, а не в памяти: launchd перезапустит убитый процесс, а выключенным страж должен остаться.

static long bootTime(void) {
    struct timeval tv;
    size_t len = sizeof(tv);
    int mib[2] = { CTL_KERN, KERN_BOOTTIME };
    if (sysctl(mib, 2, &tv, &len, NULL, 0) != 0) return 0;
    return tv.tv_sec;
}

static NSString *offFile(void) { return [gDir stringByAppendingPathComponent:@"vyklyuchen"]; }

static BOOL isOff(void) {
    NSString *s = [NSString stringWithContentsOfFile:offFile() encoding:NSUTF8StringEncoding error:nil];
    return s != nil && labs((long)s.longLongValue - bootTime()) <= kBootTolerance;
}

static void setOff(BOOL off) {
    if (off) {
        [[NSString stringWithFormat:@"%ld\n", bootTime()] writeToFile:offFile() atomically:YES
                                                             encoding:NSUTF8StringEncoding error:nil];
    } else {
        [[NSFileManager defaultManager] removeItemAtPath:offFile() error:nil];
    }
}

// --- Определение VPN --------------------------------------------------------

static NSString *runTool(NSString *path, NSArray<NSString *> *args) {
    NSTask *t = [NSTask new];
    t.launchPath = path;
    t.arguments = args;
    NSPipe *out = [NSPipe pipe];
    t.standardOutput = out;
    t.standardError = [NSPipe pipe];
    @try { [t launch]; } @catch (NSException *e) { return @""; }
    NSData *d = [[out fileHandleForReading] readDataToEndOfFile];
    [t waitUntilExit];
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
}

// Есть utun-интерфейс с IPv4: туннель реально поднят. Дешёвая проверка без запуска процессов.
static BOOL tunnelUp(void) {
    struct ifaddrs *addrs = NULL;
    if (getifaddrs(&addrs) != 0) return NO;
    BOOL found = NO;
    for (struct ifaddrs *p = addrs; p; p = p->ifa_next) {
        if (strncmp(p->ifa_name, "utun", 4) == 0 && p->ifa_addr && p->ifa_addr->sa_family == AF_INET) {
            found = YES;
            break;
        }
    }
    freeifaddrs(addrs);
    return found;
}

// Через sysctl, а не proc_name: тот не видит процессы root, а VPN-движки работают от root.
// Сбой чтения считаем за «есть»: ложный красный экран хуже пропущенной проверки.
static BOOL processRunning(NSString *name) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0) return YES;
    size += size / 8; // процессы могли появиться между двумя вызовами
    struct kinfo_proc *procs = malloc(size);
    if (!procs) return YES;
    BOOL found = NO;
    if (sysctl(mib, 4, procs, &size, NULL, 0) != 0) {
        found = YES;
    } else {
        const char *target = name.UTF8String;
        size_t n = size / sizeof(struct kinfo_proc);
        for (size_t i = 0; i < n; i++) {
            if (strncmp(procs[i].kp_proc.p_comm, target, MAXCOMLEN) == 0) { found = YES; break; }
        }
    }
    free(procs);
    return found;
}

// Нужный VPN включён. Если в настройке назван конкретный — нужен именно его процесс и поднятый
// туннель: чужой VPN не считается. «Любой» — туннель или системный VPN-профиль в состоянии Connected.
static BOOL vpnOn(void) {
    if (gVpnProcess) return tunnelUp() && processRunning(gVpnProcess);
    if (tunnelUp()) return YES;
    return [runTool(@"/usr/sbin/scutil", @[ @"--nc", @"list" ]) containsString:@"(Connected)"];
}

// --- Охраняемые приложения --------------------------------------------------

static NSArray<NSRunningApplication *> *runningTargets(void) {
    NSMutableSet<NSString *> *ids = [NSMutableSet set];
    for (NSDictionary *app in gApps) [ids addObject:app[@"id"]];
    NSMutableArray *found = [NSMutableArray array];
    for (NSRunningApplication *a in [NSWorkspace sharedWorkspace].runningApplications) {
        if (a.bundleIdentifier && [ids containsObject:a.bundleIdentifier]) [found addObject:a];
    }
    return found;
}

static NSArray<NSString *> *runningWatched(void) {
    NSMutableSet<NSString *> *live = [NSMutableSet set];
    for (NSRunningApplication *a in runningTargets()) [live addObject:a.bundleIdentifier];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSDictionary *app in gApps) {
        if ([live containsObject:app[@"id"]]) [names addObject:app[@"name"]];
    }
    return names;
}

// «Claude» / «Claude и Codex» — для текста на экране и кнопки.
static NSString *joinNames(NSArray<NSString *> *names) {
    return [names componentsJoinedByString:@" и "];
}

// --- Приложение ---------------------------------------------------------------

@interface OverlayWindow : NSWindow
@end
@implementation OverlayWindow
- (BOOL)canBecomeKeyWindow { return YES; }
@end

@interface GuardDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic) BOOL demoMode;
@property (nonatomic) BOOL quiet;                         // --tiho: без окон и значка
@property (nonatomic) NSTimeInterval demoSeconds;
@property (nonatomic, strong) NSMutableArray<NSWindow *> *overlays;
@property (nonatomic, strong) NSMutableArray<NSTextField *> *countdownLabels;
@property (nonatomic) int badCount;
@property (nonatomic) BOOL shown;
@property (nonatomic) BOOL reacting;                      // идёт случай: приложение открыто без VPN
@property (nonatomic) BOOL dismissed;                     // «Закрыть баннер»: молчим до конца этого случая
@property (nonatomic) BOOL shownOtherTunnel;
@property (nonatomic, strong) NSTimer *secondTimer;       // обратный отсчёт, пока идёт случай
@property (nonatomic, strong) NSDate *closeAt;
@property (nonatomic, strong) NSDate *forceAt;
@property (nonatomic, strong) NSDate *demoUntil;          // пока идёт демо из меню, tick не прячет экран
@property (nonatomic, strong) NSArray<NSString *> *shownApps;
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenuItem *headMenuItem;
@property (nonatomic, strong) NSMenuItem *stateMenuItem;
@property (nonatomic, strong) NSMenuItem *bannerMenuItem;
@property (nonatomic, strong) NSMenuItem *offMenuItem;
- (NSView *)overlayViewWithSize:(NSSize)size;
@end

@implementation GuardDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    self.overlays = [NSMutableArray array];
    self.countdownLabels = [NSMutableArray array];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(screensChanged:)
                                                 name:NSApplicationDidChangeScreenParametersNotification object:nil];
    if (self.demoMode) {
        [self showOverlays];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.demoSeconds * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ exit(0); });
        return;
    }
    logLine([NSString stringWithFormat:@"VPN-страж запущен: стерегу %@, нужен %@, закрытие через %d с.",
             gApps.count ? joinNames([gApps valueForKey:@"name"]) : @"(нет приложений в настройке)",
             gVpnName, gCloseAfter]);
    if (!self.quiet) [self setupStatusItem];
    // CommonModes: иначе таймеры встают, пока открыто меню значка.
    NSTimer *t = [NSTimer timerWithTimeInterval:kCheckInterval target:self selector:@selector(tick)
                                       userInfo:nil repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
    [self tick];
}

- (void)tick {
    BOOL off = isOff();
    NSArray<NSString *> *apps = runningWatched();
    BOOL v = off ? YES : vpnOn();
    BOOL bad = !off && apps.count > 0 && !v;
    BOOL demoActive = self.demoUntil && [self.demoUntil timeIntervalSinceNow] > 0;
    if (bad && !self.dismissed) {
        self.badCount += 1;
        if (self.badCount >= kBadChecksToShow) {
            if (!self.reacting) {
                self.reacting = YES;
                logLine([NSString stringWithFormat:@"%@ без %@ → показываю экран.", joinNames(apps), gVpnName]);
                if (gCloseAfter > 0) self.closeAt = [NSDate dateWithTimeIntervalSinceNow:gCloseAfter];
                [self startSecondTimer];
                [self showOverlays];
            } else if (![apps isEqualToArray:self.shownApps] || self.shownOtherTunnel != (gVpnProcess && tunnelUp())) {
                [self showOverlays]; // изменился текст: другой набор приложений или поднялся чужой VPN
            }
        }
    } else {
        self.badCount = 0;
        if (!bad) self.dismissed = NO;
        if (self.reacting) {
            logLine(off ? @"Стража выключили → убираю экран."
                        : (apps.count == 0 ? @"Приложение закрыто → убираю экран." : @"VPN включён → убираю экран."));
            [self stopReacting];
        }
        if (self.shown && !demoActive) [self closeBanner];
    }
    [self updateStatusVPN:v apps:apps off:off];
}

- (void)stopReacting {
    self.reacting = NO;
    self.closeAt = nil;
    self.forceAt = nil;
    [self.secondTimer invalidate];
    self.secondTimer = nil;
}

- (void)startSecondTimer {
    [self.secondTimer invalidate];
    self.secondTimer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(secondTick)
                                             userInfo:nil repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:self.secondTimer forMode:NSRunLoopCommonModes];
}

- (void)secondTick {
    if (!self.closeAt) return;
    NSTimeInterval left = [self.closeAt timeIntervalSinceNow];
    if (left > 0) {
        [self setCountdownText:[self countdownTextFor:(int)ceil(left)]];
        return;
    }
    if (isOff() || vpnOn()) return; // VPN только что вернулся: tick уберёт экран, закрывать нельзя
    NSArray<NSRunningApplication *> *targets = runningTargets();
    if (!self.forceAt) {
        logLine([NSString stringWithFormat:@"Отсчёт вышел — закрываю %@.", joinNames(self.shownApps)]);
        for (NSRunningApplication *a in targets) [a terminate];
        self.forceAt = [NSDate dateWithTimeIntervalSinceNow:kForceAfter];
        [self setCountdownText:[NSString stringWithFormat:@"Закрываю %@…", joinNames(self.shownApps)]];
    } else if ([self.forceAt timeIntervalSinceNow] <= 0 && targets.count) {
        logLine([NSString stringWithFormat:@"Не закрылось по-хорошему (%@) — закрываю силой.", joinNames(self.shownApps)]);
        for (NSRunningApplication *a in targets) [a forceTerminate];
        self.forceAt = [NSDate dateWithTimeIntervalSinceNow:kForceAfter];
    }
}

- (NSString *)countdownTextFor:(int)seconds {
    BOOL many = self.shownApps.count > 1;
    return [NSString stringWithFormat:@"Через %d с %@ %@.", seconds, joinNames(self.shownApps),
            many ? @"закроются сами" : @"закроется сам"];
}

- (void)setCountdownText:(NSString *)text {
    for (NSTextField *f in self.countdownLabels) f.stringValue = text;
}

// --- Значок в строке меню ---------------------------------------------------
// 🛡 всё в порядке · 🟡 VPN выключен, но приложение закрыто · ⛔ экран показан · 💤 страж выключен.
// Подвинуть значок ближе к VPN: Cmd + перетащить мышкой.

- (NSMenuItem *)menuItem:(NSString *)title action:(SEL)action {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    if (action) item.target = self; else item.enabled = NO;
    return item;
}

- (void)setupStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.autosaveName = @"vpn-strazh"; // место после Cmd+перетаскивания переживает перезапуск
    self.statusItem.button.title = @"🛡";
    self.statusItem.button.toolTip = @"VPN-страж: не даёт работать без нужного VPN";

    NSMenu *menu = [NSMenu new];
    menu.autoenablesItems = NO;
    self.headMenuItem = [self menuItem:@"VPN-страж работает" action:nil];
    self.stateMenuItem = [self menuItem:@"…" action:nil];
    self.bannerMenuItem = [self menuItem:@"Закрыть баннер" action:@selector(menuDismissBanner:)];
    self.offMenuItem = [self menuItem:@"Выключить стража до перезагрузки" action:@selector(menuToggleOff:)];
    [menu addItem:self.headMenuItem];
    [menu addItem:self.stateMenuItem];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:self.bannerMenuItem];
    [menu addItem:self.offMenuItem];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[self menuItem:@"Показать баннер (12 сек)" action:@selector(menuDemo:)]];
    [menu addItem:[self menuItem:@"Открыть лог" action:@selector(menuOpenLog:)]];
    self.statusItem.menu = menu;
}

- (void)updateStatusVPN:(BOOL)v apps:(NSArray<NSString *> *)apps off:(BOOL)off {
    if (!self.statusItem) return;
    self.statusItem.button.title = off ? @"💤" : (self.shown ? @"⛔" : (v ? @"🛡" : @"🟡"));
    self.headMenuItem.title = off ? @"VPN-страж выключен до перезагрузки" : @"VPN-страж работает";
    NSMutableString *line = [NSMutableString stringWithFormat:@"%@: %@", gVpnName,
                             off ? @"не проверяю" : (v ? @"включён" : @"ВЫКЛЮЧЕН")];
    for (NSDictionary *app in gApps) {
        [line appendFormat:@" · %@: %@", app[@"name"], [apps containsObject:app[@"name"]] ? @"открыт" : @"закрыт"];
    }
    self.stateMenuItem.title = line;
    self.bannerMenuItem.enabled = self.shown;
    self.offMenuItem.title = off ? @"Включить стража" : @"Выключить стража до перезагрузки";
}

- (void)menuDismissBanner:(id)sender {
    logLine(@"Закрыть баннер: молчу, пока VPN не вернётся или приложение не закроют.");
    self.dismissed = self.reacting || self.dismissed;
    self.demoUntil = nil;
    [self stopReacting];
    [self closeBanner];
    [self tick];
}

- (void)menuToggleOff:(id)sender {
    BOOL off = !isOff();
    setOff(off);
    logLine(off ? @"Страж выключен до перезагрузки." : @"Страж включён.");
    [self tick];
}

- (void)menuDemo:(id)sender {
    logLine(@"Показ баннера из меню (12 сек).");
    self.demoUntil = [NSDate dateWithTimeIntervalSinceNow:12];
    [self showOverlays];
}

- (void)menuOpenLog:(id)sender {
    NSString *log = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/vpn-strazh.log"];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:log]];
}

// --- Экран --------------------------------------------------------------------

- (void)screensChanged:(NSNotification *)note {
    if (self.shown) [self showOverlays]; // подключили или сняли монитор
}

- (void)showOverlays {
    [self hideOverlays];
    NSArray<NSString *> *apps = runningWatched();
    if (apps.count == 0) apps = [gApps valueForKey:@"name"]; // показ из меню, когда ничего не открыто
    self.shownApps = apps;
    self.shownOtherTunnel = gVpnProcess && tunnelUp();
    self.shown = YES;
    if (self.quiet) return;
    [NSApp unhideWithoutActivation];
    for (NSScreen *screen in [NSScreen screens]) {
        NSWindow *w = [self makeOverlayForScreen:screen];
        [w orderFrontRegardless];
        [self.overlays addObject:w];
    }
    // Активным становится страж: своего меню у него нет, строка меню освобождается и видны все
    // значки. Иначе длинное меню активного приложения вытесняет значки стража и VPN.
    [NSApp activateIgnoringOtherApps:YES];
}

// Конец показа: вернуть фокус приложению, которое было активно до экрана.
- (void)closeBanner {
    [self hideOverlays];
    if (!self.quiet) [NSApp hide:nil];
}

- (void)hideOverlays {
    for (NSWindow *w in self.overlays) {
        [w orderOut:nil];
        [w close];
    }
    [self.overlays removeAllObjects];
    [self.countdownLabels removeAllObjects];
    self.shown = NO;
}

- (void)closeNowClicked:(id)sender {
    logLine([NSString stringWithFormat:@"Кнопка «Закрыть» — закрываю %@.", joinNames(self.shownApps)]);
    for (NSRunningApplication *a in runningTargets()) [a terminate];
}

static NSTextField *makeLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *f = [NSTextField labelWithString:text];
    f.font = [NSFont systemFontOfSize:size weight:weight];
    f.textColor = color;
    return f;
}

- (NSView *)overlayViewWithSize:(NSSize)size {
    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    content.wantsLayer = YES;
    content.layer.backgroundColor = [NSColor colorWithSRGBRed:0x15/255.0 green:0x0A/255.0 blue:0x0B/255.0 alpha:1.0].CGColor;

    NSColor *white = [NSColor whiteColor];
    NSColor *dim = [white colorWithAlphaComponent:0.8];
    NSString *names = joinNames(self.shownApps);
    NSString *verb = self.shownApps.count > 1 ? @"открыты" : @"открыт";

    NSTextField *title = makeLabel(@"⛔ VPN ВЫКЛЮЧЕН", 64, NSFontWeightHeavy,
                                   [NSColor colorWithSRGBRed:0xC2/255.0 green:0x4A/255.0 blue:0x3E/255.0 alpha:1.0]);
    NSTextField *line2 = makeLabel([NSString stringWithFormat:@"%@ %@ без %@ — работать сейчас опасно.", names, verb, gVpnName],
                                   30, NSFontWeightSemibold, white);
    NSMutableArray<NSView *> *views = [NSMutableArray arrayWithObjects:title, line2, nil];
    if (self.shownOtherTunnel) {
        [views addObject:makeLabel([NSString stringWithFormat:@"Сейчас поднят другой VPN, а считается только %@.", gVpnName],
                                   22, NSFontWeightRegular, dim)];
    }
    [views addObject:makeLabel([NSString stringWithFormat:@"Включи %@ в строке меню — окно исчезнет само.", gVpnName],
                               22, NSFontWeightRegular, dim)];
    if (gCloseAfter > 0) {
        int left = self.closeAt ? (int)ceil(MAX(0, [self.closeAt timeIntervalSinceNow])) : gCloseAfter;
        NSTextField *countdown = makeLabel([self countdownTextFor:left], 22, NSFontWeightSemibold, white);
        [self.countdownLabels addObject:countdown];
        [views addObject:countdown];
    }
    NSButton *btn = [NSButton buttonWithTitle:[NSString stringWithFormat:@"Закрыть %@ сейчас", names]
                                       target:self action:@selector(closeNowClicked:)];
    btn.bezelStyle = NSBezelStyleRounded;
    btn.controlSize = NSControlSizeLarge;
    btn.font = [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];
    btn.refusesFirstResponder = YES; // случайный пробел не должен закрыть приложение: экран теперь с фокусом
    [views addObject:btn];
    [views addObject:makeLabel(@"Закрыть баннер или выключить стража — значок ⛔ в строке меню.", 15, NSFontWeightRegular, dim)];

    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 28;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
    ]];
    return content;
}

- (NSWindow *)makeOverlayForScreen:(NSScreen *)screen {
    // visibleFrame = экран БЕЗ строки меню и Дока: их оставляем доступными, чтобы всегда
    // можно было включить VPN или открыть меню стража.
    NSRect frame = screen.visibleFrame;
    OverlayWindow *w = [[OverlayWindow alloc] initWithContentRect:frame
                                                        styleMask:NSWindowStyleMaskBorderless
                                                          backing:NSBackingStoreBuffered
                                                            defer:NO];
    // На ступень НИЖЕ строки меню: выше ВСЕХ обычных окон (включая полноэкранные),
    // но строка меню и её выпадающие меню (включить VPN!) остаются поверх и кликабельны.
    w.level = NSMainMenuWindowLevel - 1;
    w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                           NSWindowCollectionBehaviorFullScreenAuxiliary |
                           NSWindowCollectionBehaviorStationary;
    w.opaque = YES;
    w.backgroundColor = [NSColor colorWithSRGBRed:0x15/255.0 green:0x0A/255.0 blue:0x0B/255.0 alpha:1.0];
    w.movable = NO;
    w.hidesOnDeactivate = NO;
    w.releasedWhenClosed = NO;
    w.contentView = [self overlayViewWithSize:frame.size];
    return w;
}

@end

static NSString *argValue(NSArray<NSString *> *args, NSString *name) {
    NSUInteger i = [args indexOfObject:name];
    return (i != NSNotFound && i + 1 < args.count) ? args[i + 1] : nil;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSArray<NSString *> *args = [NSProcessInfo processInfo].arguments;
        NSString *dir = argValue(args, @"--dir");
        gTestMode = dir != nil;
        gDir = dir ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/vpn-strazh"];
        loadConfig();

        if ([args containsObject:@"--vyklyuchit"] || [args containsObject:@"--vklyuchit"]) {
            setOff([args containsObject:@"--vyklyuchit"]);
            printf("%s\n", isOff() ? "Страж выключен до перезагрузки." : "Страж включён.");
            return 0;
        }
        NSApplication *app = [NSApplication sharedApplication];
        if ([args containsObject:@"--status"]) {
            BOOL off = isOff();
            BOOL v = vpnOn();
            NSArray<NSString *> *apps = runningWatched();
            printf("vpn=%s (%s) tunnel=%s apps=%s zakryt_cherez=%d overlay=%s strazh=%s\n",
                   v ? "on" : "off", gVpnName.UTF8String, tunnelUp() ? "up" : "down",
                   apps.count ? [apps componentsJoinedByString:@","].UTF8String : "-", gCloseAfter,
                   (!off && apps.count && !v) ? "SHOW" : "hidden", off ? "off" : "on");
            return 0;
        }
        GuardDelegate *delegate = [GuardDelegate new];
        NSString *png = argValue(args, @"--kartinka");
        if (png) {
            delegate.countdownLabels = [NSMutableArray array];
            delegate.shownApps = [gApps valueForKey:@"name"];
            delegate.shownOtherTunnel = [args containsObject:@"--drugoy-vpn"];
            NSView *v = [delegate overlayViewWithSize:NSMakeSize(1440, 800)];
            [v layoutSubtreeIfNeeded];
            NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
            [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:png atomically:YES];
            return 0;
        }
        delegate.demoMode = [args containsObject:@"--demo"];
        delegate.quiet = [args containsObject:@"--tiho"];
        NSString *sek = argValue(args, @"--sek");
        delegate.demoSeconds = sek ? sek.doubleValue : 12;
        if (sek && !delegate.demoMode) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sek.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ exit(0); });
        }
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory]; // без значка в Доке
        [app run];
    }
    return 0;
}
