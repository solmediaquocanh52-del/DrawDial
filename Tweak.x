// DrawDial - ve so/chu tren ban phim app Dien thoai de loc Gan day + Danh ba
// iOS 16.x, hook vao com.apple.mobilephone

#import <UIKit/UIKit.h>
#import <Vision/Vision.h>
#import <Contacts/Contacts.h>
#import <objc/runtime.h>
#import <sqlite3.h>

static NSString *const kDomain = @"com.local.drawdial";
static NSMutableString *gLog;

#pragma mark - Prefs / Log

static void DDSync(void) { CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain); }

static BOOL DDBool(NSString *key, BOOL def) {
    DDSync();
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain);
    if (!v) return def;
    BOOL r = def;
    if (CFGetTypeID(v) == CFBooleanGetTypeID()) r = CFBooleanGetValue(v);
    else if (CFGetTypeID(v) == CFNumberGetTypeID()) { int i = 0; CFNumberGetValue(v, kCFNumberIntType, &i); r = i != 0; }
    CFRelease(v);
    return r;
}

static double DDNum(NSString *key, double def) {
    DDSync();
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain);
    if (!v) return def;
    double r = def;
    if (CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberDoubleType, &r);
    CFRelease(v);
    return r;
}

static void DDLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[DrawDial] %@", m);
    @synchronized (kDomain) {
        if (!gLog) gLog = [NSMutableString new];
        [gLog appendFormat:@"%@\n", m];
        if (gLog.length > 6000) [gLog deleteCharactersInRange:NSMakeRange(0, gLog.length - 6000)];
    }
    if (!DDBool(@"log", NO)) return;
    NSString *line = [m stringByAppendingString:@"\n"];
    NSArray *paths = @[@"/var/mobile/Documents/DrawDial.log",
                       [NSTemporaryDirectory() stringByAppendingPathComponent:@"DrawDial.log"]];
    for (NSString *p in paths) {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (!fh) {
            if ([line writeToFile:p atomically:NO encoding:NSUTF8StringEncoding error:nil]) break;
            continue;
        }
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
        break;
    }
}

#pragma mark - Text helpers

static NSString *DDFold(NSString *s) {
    if (!s) return @"";
    s = [s stringByReplacingOccurrencesOfString:@"đ" withString:@"d"];
    s = [s stringByReplacingOccurrencesOfString:@"Đ" withString:@"D"];
    return [s stringByFoldingWithOptions:NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch | NSWidthInsensitiveSearch locale:nil];
}

static NSString *DDDigits(NSString *s) {
    NSMutableString *o = [NSMutableString new];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c >= '0' && c <= '9') [o appendFormat:@"%C", c];
    }
    return o;
}

// Sua nham hay gap khi nhan dang che do So
static NSString *DDFixDigits(NSString *s) {
    NSMutableString *o = [NSMutableString new];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        switch (c) {
            case 'O': case 'o': case 'D': case 'Q': c = '0'; break;
            case 'I': case 'l': case 'i': case '|': case '!': case 'L': c = '1'; break;
            case 'Z': case 'z': c = '2'; break;
            case 'A': c = '4'; break;
            case 'S': case 's': c = '5'; break;
            case 'G': case 'b': c = '6'; break;
            case 'T': case 't': c = '7'; break;
            case 'B': c = '8'; break;
            case 'g': case 'q': c = '9'; break;
            default: break;
        }
        if (c >= '0' && c <= '9') [o appendFormat:@"%C", c];
    }
    return o;
}

static NSString *DDLettersOnly(NSString *s) {
    NSString *f = DDFold(s);
    NSMutableString *o = [NSMutableString new];
    for (NSUInteger i = 0; i < f.length; i++) {
        unichar c = [f characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || c == ' ') [o appendFormat:@"%C", c];
    }
    return [o stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

static BOOL DDPhoneMatch(NSString *phone, NSString *q) {
    if (!q.length) return NO;
    if ([phone containsString:q]) return YES;
    if (q.length > 1 && [q hasPrefix:@"0"] && [phone containsString:[q substringFromIndex:1]]) return YES;
    return NO;
}

static int DDNameScore(NSString *folded, NSString *q) {
    if (!q.length || !folded.length) return 99;
    if ([folded hasPrefix:q]) return 0;
    for (NSString *w in [folded componentsSeparatedByString:@" "])
        if ([w hasPrefix:q]) return 1;
    if ([folded containsString:q]) return 2;
    return 99;
}

static NSString *DDKey(NSString *digits) {
    return digits.length > 9 ? [digits substringFromIndex:digits.length - 9] : digits;
}

#pragma mark - Data store (Danh ba + Gan day)

static NSArray *sContacts, *sRecents;

@interface DDStore : NSObject
+ (void)reload;
+ (NSArray *)defaultResults;
+ (NSArray *)resultsForCandidates:(NSArray<NSString *> *)cands digits:(BOOL)digits;
@end

@implementation DDStore

+ (NSArray *)loadRecentsWithNames:(NSDictionary *)nameMap {
    NSString *path = @"/var/mobile/Library/CallHistoryDB/CallHistory.storedata";
    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY, NULL);
    if (rc != SQLITE_OK) {
        DDLog(@"recents: open readonly failed rc=%d", rc);
        if (db) sqlite3_close(db);
        db = NULL;
        NSString *uri = [NSString stringWithFormat:@"file:%@?immutable=1", path];
        rc = sqlite3_open_v2(uri.UTF8String, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL);
        if (rc != SQLITE_OK) {
            DDLog(@"recents: open immutable failed rc=%d", rc);
            if (db) sqlite3_close(db);
            return @[];
        }
    }
    NSMutableArray *out = [NSMutableArray new];
    NSMutableSet *seen = [NSMutableSet new];
    sqlite3_stmt *st = NULL;
    rc = sqlite3_prepare_v2(db, "SELECT ZADDRESS, ZNAME FROM ZCALLRECORD ORDER BY ZDATE DESC LIMIT 500", -1, &st, NULL);
    if (rc != SQLITE_OK) {
        DDLog(@"recents: prepare failed rc=%d %s", rc, sqlite3_errmsg(db));
        sqlite3_close(db);
        return @[];
    }
    while (sqlite3_step(st) == SQLITE_ROW && out.count < 200) {
        const void *b = sqlite3_column_blob(st, 0);
        int n = sqlite3_column_bytes(st, 0);
        if (!b || n <= 0) continue;
        NSString *num = [[NSString alloc] initWithBytes:b length:n encoding:NSUTF8StringEncoding];
        NSString *d = DDDigits(num ?: @"");
        if (!d.length) continue;
        NSString *key = DDKey(d);
        if ([seen containsObject:key]) continue;
        [seen addObject:key];
        const unsigned char *nm = sqlite3_column_text(st, 1);
        NSString *name = nm ? [NSString stringWithUTF8String:(const char *)nm] : @"";
        if (!name.length) name = nameMap[key] ?: @"";
        [out addObject:@{@"name": name, @"number": num, @"digits": d,
                         @"folded": DDFold(name), @"tag": @"Gần đây"}];
    }
    sqlite3_finalize(st);
    sqlite3_close(db);
    DDLog(@"recents: loaded %lu", (unsigned long)out.count);
    return out;
}

+ (void)reload {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *cs = [NSMutableArray new];
        NSMutableDictionary *nameMap = [NSMutableDictionary new];
        CNContactStore *store = [CNContactStore new];
        CNContactFetchRequest *fr = [[CNContactFetchRequest alloc] initWithKeysToFetch:@[
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
            CNContactOrganizationNameKey, CNContactPhoneNumbersKey]];
        NSError *err = nil;
        [store enumerateContactsWithFetchRequest:fr error:&err usingBlock:^(CNContact *c, BOOL *stop) {
            NSString *name = [[NSString stringWithFormat:@"%@ %@", c.givenName, c.familyName]
                              stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (!name.length) name = c.nickname.length ? c.nickname : c.organizationName;
            if (!name) name = @"";
            NSString *folded = DDFold([name stringByAppendingFormat:@" %@", c.nickname ?: @""]);
            for (CNLabeledValue<CNPhoneNumber *> *lv in c.phoneNumbers) {
                NSString *num = lv.value.stringValue;
                NSString *d = DDDigits(num);
                if (!d.length) continue;
                nameMap[DDKey(d)] = name;
                [cs addObject:@{@"name": name, @"number": num, @"digits": d,
                                @"folded": folded, @"tag": @"Danh bạ"}];
            }
        }];
        if (err) DDLog(@"contacts error: %@", err);
        DDLog(@"contacts: loaded %lu", (unsigned long)cs.count);
        NSArray *rc = [self loadRecentsWithNames:nameMap];
        dispatch_async(dispatch_get_main_queue(), ^{ sContacts = cs; sRecents = rc; });
    });
}

+ (NSArray *)defaultResults {
    NSArray *r = sRecents ?: @[];
    return r.count > 30 ? [r subarrayWithRange:NSMakeRange(0, 30)] : r;
}

+ (NSArray *)resultsForCandidates:(NSArray<NSString *> *)cands digits:(BOOL)digits {
    NSMutableArray *out = [NSMutableArray new];
    NSMutableSet *seen = [NSMutableSet new];
    for (NSArray *src in @[sRecents ?: @[], sContacts ?: @[]]) {
        NSMutableArray *scored = [NSMutableArray new];
        for (NSDictionary *it in src) {
            int best = 99;
            for (NSString *q in cands) {
                if (!q.length) continue;
                int s = digits ? (DDPhoneMatch(it[@"digits"], q) ? 0 : 99) : DDNameScore(it[@"folded"], q);
                if (s < best) best = s;
            }
            if (best < 99) [scored addObject:@[@(best), it]];
        }
        NSArray *sorted = [scored sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
            return [a[0] compare:b[0]];
        }];
        for (NSArray *p in sorted) {
            NSDictionary *it = p[1];
            NSString *key = DDKey(it[@"digits"]);
            if ([seen containsObject:key]) continue;
            [seen addObject:key];
            [out addObject:it];
        }
    }
    return out.count > 60 ? [out subarrayWithRange:NSMakeRange(0, 60)] : out;
}

@end

#pragma mark - Vision

static void DDRecognize(UIImage *img, BOOL digits, void (^done)(NSArray<NSString *> *)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        VNRecognizeTextRequest *req = [VNRecognizeTextRequest new];
        req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        req.usesLanguageCorrection = NO;
        req.recognitionLanguages = @[@"en-US"];
        VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCGImage:img.CGImage options:@{}];
        NSError *e = nil;
        [h performRequests:@[req] error:&e];
        if (e) DDLog(@"vision error: %@", e);
        NSMutableArray *raw = [NSMutableArray new];
        NSArray *obs = req.results ?: @[];
        for (int k = 0; k < 3; k++) {
            NSMutableString *s = [NSMutableString new];
            BOOL any = NO;
            for (VNRecognizedTextObservation *o in obs) {
                NSArray *tc = [o topCandidates:3];
                if (!tc.count) continue;
                VNRecognizedText *t = tc[MIN(k, (int)tc.count - 1)];
                [s appendString:t.string];
                any = YES;
            }
            if (any && ![raw containsObject:s]) [raw addObject:s];
        }
        NSMutableArray *proc = [NSMutableArray new];
        for (NSString *s in raw) {
            NSString *p = digits ? DDFixDigits(s) : DDLettersOnly(s);
            if (p.length && ![proc containsObject:p]) [proc addObject:p];
        }
        DDLog(@"vision raw=%@ processed=%@", raw, proc);
        done(proc);
    });
}

#pragma mark - Canvas

@interface DDCanvas : UIView
@property (nonatomic, strong) NSMutableArray<UIBezierPath *> *strokes;
@property (nonatomic, copy) void (^onIdle)(void);
- (void)undo;
- (void)clear;
- (UIImage *)snapshot;
@end

@implementation DDCanvas

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        _strokes = [NSMutableArray new];
        self.backgroundColor = UIColor.whiteColor;
        self.layer.cornerRadius = 12;
        self.layer.borderWidth = 1;
        self.layer.borderColor = UIColor.systemGray3Color.CGColor;
        self.clipsToBounds = YES;
        self.multipleTouchEnabled = NO;
    }
    return self;
}

- (void)fire { if (self.onIdle) self.onIdle(); }

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fire) object:nil];
    CGPoint p = [touches.anyObject locationInView:self];
    UIBezierPath *path = [UIBezierPath bezierPath];
    path.lineWidth = 6; path.lineCapStyle = kCGLineCapRound; path.lineJoinStyle = kCGLineJoinRound;
    [path moveToPoint:p];
    [path addLineToPoint:CGPointMake(p.x + 0.1, p.y + 0.1)];
    [self.strokes addObject:path];
    [self setNeedsDisplay];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self.strokes.lastObject addLineToPoint:[touches.anyObject locationInView:self]];
    [self setNeedsDisplay];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fire) object:nil];
    [self performSelector:@selector(fire) withObject:nil afterDelay:DDNum(@"delay", 0.7)];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self touchesEnded:touches withEvent:event];
}

- (void)drawRect:(CGRect)rect {
    [UIColor.blackColor setStroke];
    for (UIBezierPath *p in self.strokes) [p stroke];
}

- (void)undo {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fire) object:nil];
    [self.strokes removeLastObject];
    [self setNeedsDisplay];
}

- (void)clear {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fire) object:nil];
    [self.strokes removeAllObjects];
    [self setNeedsDisplay];
}

- (UIImage *)snapshot {
    CGRect box = CGRectNull;
    for (UIBezierPath *p in self.strokes) box = CGRectUnion(box, p.bounds);
    if (CGRectIsNull(box)) return nil;
    CGFloat pad = MAX(24, box.size.height * 0.35);
    box = CGRectInset(box, -pad, -pad);
    CGFloat s = MIN(4, MAX(1, 240.0 / box.size.height));
    CGSize size = CGSizeMake(MIN(box.size.width * s, 3000), MIN(box.size.height * s, 3000));
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.scale = 1; fmt.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    NSArray *strokes = [self.strokes copy];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [UIColor.whiteColor setFill];
        UIRectFill(CGRectMake(0, 0, size.width, size.height));
        CGContextScaleCTM(ctx.CGContext, s, s);
        CGContextTranslateCTM(ctx.CGContext, -box.origin.x, -box.origin.y);
        [UIColor.blackColor setStroke];
        for (UIBezierPath *p in strokes) [p stroke];
    }];
}

@end

#pragma mark - Panel

@interface DDPanel : UIView <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UISegmentedControl *seg;
@property (nonatomic, strong) DDCanvas *canvas;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UIButton *undoBtn, *clearBtn;
@property (nonatomic, strong) NSArray *results;
@property (nonatomic) NSInteger gen;
- (void)prepare;
@end

@implementation DDPanel

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.backgroundColor = UIColor.systemBackgroundColor;

        _seg = [[UISegmentedControl alloc] initWithItems:@[@"Số", @"Chữ"]];
        _seg.selectedSegmentIndex = DDBool(@"defaultLetters", NO) ? 1 : 0;
        [_seg addTarget:self action:@selector(runRecognition) forControlEvents:UIControlEventValueChanged];
        [self addSubview:_seg];

        _undoBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        [_undoBtn setTitle:@"Hoàn tác" forState:UIControlStateNormal];
        [_undoBtn addTarget:self action:@selector(doUndo) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_undoBtn];

        _clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        [_clearBtn setTitle:@"Xóa" forState:UIControlStateNormal];
        [_clearBtn addTarget:self action:@selector(doClear) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_clearBtn];

        _canvas = [[DDCanvas alloc] initWithFrame:CGRectZero];
        __weak typeof(self) ws = self;
        _canvas.onIdle = ^{ [ws runRecognition]; };
        [self addSubview:_canvas];

        _label = [UILabel new];
        _label.font = [UIFont systemFontOfSize:14];
        _label.textColor = UIColor.secondaryLabelColor;
        _label.text = @"Vẽ số hoặc chữ vào ô trắng";
        [self addSubview:_label];

        _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
        _table.dataSource = self; _table.delegate = self;
        _table.backgroundColor = UIColor.clearColor;
        [self addSubview:_table];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height, y = 6;
    self.seg.frame = CGRectMake(12, y, 140, 32);
    self.clearBtn.frame = CGRectMake(w - 12 - 60, y, 60, 32);
    self.undoBtn.frame = CGRectMake(w - 12 - 60 - 84, y, 84, 32);
    y += 40;
    CGFloat ch = MIN(MAX(h * 0.38, 120), 240);
    self.canvas.frame = CGRectMake(12, y, w - 24, ch);
    y += ch + 4;
    self.label.frame = CGRectMake(14, y, w - 28, 22);
    y += 24;
    self.table.frame = CGRectMake(0, y, w, MAX(0, h - y));
}

- (void)prepare {
    [DDStore reload];
    [self.canvas clear];
    self.label.text = @"Vẽ số hoặc chữ vào ô trắng";
    // cho danh sach tai xong roi hien Gan day
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self.canvas.strokes.count) { self.results = [DDStore defaultResults]; [self.table reloadData]; }
    });
}

- (void)doUndo { [self.canvas undo]; [self runRecognition]; }
- (void)doClear { [self.canvas clear]; [self runRecognition]; }

- (void)runRecognition {
    UIImage *img = [self.canvas snapshot];
    if (!img) {
        self.results = [DDStore defaultResults];
        self.label.text = @"Vẽ số hoặc chữ vào ô trắng";
        [self.table reloadData];
        return;
    }
    BOOL digits = (self.seg.selectedSegmentIndex == 0);
    NSInteger g = ++self.gen;
    self.label.text = @"Đang nhận dạng...";
    DDRecognize(img, digits, ^(NSArray<NSString *> *cands) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (g != self.gen) return;
            if (!cands.count) {
                self.label.text = @"Không nhận ra, thử vẽ lại";
                self.results = @[];
            } else {
                self.results = [DDStore resultsForCandidates:cands digits:digits];
                self.label.text = [NSString stringWithFormat:@"Nhận dạng: %@  (%lu kết quả)", cands.firstObject, (unsigned long)self.results.count];
            }
            [self.table reloadData];
        });
    });
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.results.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"c"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    NSDictionary *it = self.results[ip.row];
    NSString *name = it[@"name"];
    c.textLabel.text = name.length ? name : it[@"number"];
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@  ·  %@", it[@"number"], it[@"tag"]];
    c.backgroundColor = UIColor.clearColor;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *num = self.results[ip.row][@"number"];
    NSString *clean = [[num componentsSeparatedByCharactersInSet:
                        [[NSCharacterSet characterSetWithCharactersInString:@"+0123456789"] invertedSet]]
                       componentsJoinedByString:@""];
    NSURL *url = [NSURL URLWithString:[@"tel:" stringByAppendingString:clean]];
    DDLog(@"dial %@", clean);
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

@end

#pragma mark - Helper (long press = hien log)

@interface DDHelper : NSObject
+ (instancetype)shared;
- (void)longPress:(UILongPressGestureRecognizer *)g;
@end

@implementation DDHelper
+ (instancetype)shared {
    static DDHelper *h; static dispatch_once_t t;
    dispatch_once(&t, ^{ h = [DDHelper new]; });
    return h;
}
- (void)longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIResponder *r = g.view;
    while (r && ![r isKindOfClass:[UIViewController class]]) r = r.nextResponder;
    UIViewController *vc = (UIViewController *)r;
    if (!vc) return;
    NSString *text;
    @synchronized (kDomain) { text = gLog.length ? [gLog copy] : @"(chưa có log)"; }
    if (text.length > 1800) text = [text substringFromIndex:text.length - 1800];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"DrawDial log" message:text preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Sao chép" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        @synchronized (kDomain) { UIPasteboard.generalPasteboard.string = gLog ?: @""; }
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
}
@end

#pragma mark - Tab rieng

@interface DDDrawViewController : UIViewController
@property (nonatomic, strong) DDPanel *panel;
@end

@implementation DDDrawViewController

- (instancetype)init {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        self.title = @"Vẽ";
        self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Vẽ"
                                                        image:[UIImage systemImageNamed:@"pencil.tip.crop.circle"]
                                                          tag:99];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.panel = [[DDPanel alloc] initWithFrame:self.view.bounds];
    [self.view addSubview:self.panel];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.panel.frame = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.panel prepare];
}

@end

static DDDrawViewController *sDrawVC;

static BOOL DDIsKeypadVC(UIViewController *vc) {
    NSMutableArray *chain = [NSMutableArray arrayWithObject:vc];
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UINavigationController *n = (UINavigationController *)vc;
        if (n.viewControllers.firstObject) [chain addObject:n.viewControllers.firstObject];
        if (n.topViewController) [chain addObject:n.topViewController];
    }
    [chain addObjectsFromArray:vc.childViewControllers];
    for (UIViewController *c in chain) {
        NSString *cn = NSStringFromClass([c class]);
        if ([cn containsString:@"Keypad"] || [cn containsString:@"Dialer"]) return YES;
    }
    NSString *t = vc.tabBarItem.title ?: @"";
    return [t isEqualToString:@"Bàn phím"] || [t isEqualToString:@"Keypad"];
}

static NSArray *DDAugment(UITabBarController *tbc, NSArray *vcs) {
    if (!vcs.count) return vcs;
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.mobilephone"]) return vcs;
    if (!DDBool(@"enabled", YES) || !DDBool(@"showTab", NO)) return vcs;
    for (UIViewController *v in vcs)
        if ([v isKindOfClass:[DDDrawViewController class]]) return vcs;

    NSInteger idx = -1;
    for (NSUInteger i = 0; i < vcs.count; i++) {
        UIViewController *v = vcs[i];
        DDLog(@"tab %lu: %@ title=%@", (unsigned long)i, NSStringFromClass([v class]), v.tabBarItem.title);
        if (DDIsKeypadVC(v)) idx = (NSInteger)i;
    }
    if (!sDrawVC) sDrawVC = [DDDrawViewController new];
    NSMutableArray *m = [vcs mutableCopy];
    if (idx >= 0) [m insertObject:sDrawVC atIndex:idx + 1];
    else [m addObject:sDrawVC];
    DDLog(@"them tab Ve tai vi tri %ld (keypad idx=%ld)", (long)(idx >= 0 ? idx + 1 : (NSInteger)m.count - 1), (long)idx);
    return m;
}

static void DDEnsureTab(UITabBarController *tbc) {
    NSArray *v = tbc.viewControllers;
    if (!v.count) return;
    NSArray *n = DDAugment(tbc, v);
    if (n.count != v.count) {
        UIViewController *sel = tbc.selectedViewController;
        [tbc setViewControllers:n animated:NO];
        if (sel && [n containsObject:sel]) tbc.selectedViewController = sel;
    }
}

#pragma mark - Install / Layout

static const void *kPanelKey = &kPanelKey;
static const void *kBtnKey = &kBtnKey;

static UIView *DDFindView(UIView *v, NSString *sub) {
    for (UIView *s in v.subviews) {
        if ([NSStringFromClass([s class]) rangeOfString:sub].location != NSNotFound) return s;
        UIView *r = DDFindView(s, sub);
        if (r) return r;
    }
    return nil;
}

static void DDDumpTree(UIView *v, int depth) {
    if (depth > 4) return;
    DDLog(@"%*s%@ %@", depth * 2, "", NSStringFromClass([v class]), NSStringFromCGRect(v.frame));
    for (UIView *s in v.subviews) DDDumpTree(s, depth + 1);
}

static void DDLayout(UIViewController *vc) {
    DDPanel *panel = objc_getAssociatedObject(vc, kPanelKey);
    UIButton *btn = objc_getAssociatedObject(vc, kBtnKey);
    if (!panel || !btn) return;
    UIView *view = vc.view;
    CGFloat top = view.bounds.size.height * 0.30;
    UIView *pad = DDFindView(view, @"NumberPad");
    if (pad && pad != panel) {
        CGRect r = [view convertRect:pad.bounds fromView:pad];
        if (r.origin.y > 60 && r.origin.y < view.bounds.size.height * 0.7) top = r.origin.y;
    }
    CGFloat bottom = view.bounds.size.height - view.safeAreaInsets.bottom;
    panel.frame = CGRectMake(0, top, view.bounds.size.width, MAX(100, bottom - top));
    btn.frame = CGRectMake(12, view.safeAreaInsets.top + 8, 40, 40);
    [view bringSubviewToFront:panel];
    [view bringSubviewToFront:btn];
}

static void DDInstall(UIViewController *vc) {
    if (!DDBool(@"enabled", YES) || !DDBool(@"showPencil", YES)) return;
    if (objc_getAssociatedObject(vc, kPanelKey)) return;

    DDLog(@"install on %@", NSStringFromClass([vc class]));
    DDDumpTree(vc.view, 0);

    DDPanel *panel = [[DDPanel alloc] initWithFrame:CGRectZero];
    panel.hidden = YES;
    [vc.view addSubview:panel];

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:22];
    [btn setImage:[UIImage systemImageNamed:@"pencil.tip.crop.circle" withConfiguration:cfg] forState:UIControlStateNormal];
    __weak UIButton *wb = btn;
    [btn addAction:[UIAction actionWithHandler:^(UIAction *a) {
        panel.hidden = !panel.hidden;
        if (!panel.hidden) [panel prepare];
        [wb setImage:[UIImage systemImageNamed:(panel.hidden ? @"pencil.tip.crop.circle" : @"circle.grid.3x3.fill") withConfiguration:cfg] forState:UIControlStateNormal];
    }] forControlEvents:UIControlEventTouchUpInside];
    [btn addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:[DDHelper shared] action:@selector(longPress:)]];
    [vc.view addSubview:btn];

    objc_setAssociatedObject(vc, kPanelKey, panel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, kBtnKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    DDLayout(vc);
}

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.mobilephone"]) return;
    if ([self isKindOfClass:[DDDrawViewController class]]) return;
    if (objc_getAssociatedObject(self, kPanelKey)) return;
    if (!DDBool(@"enabled", YES) || !DDBool(@"showPencil", YES)) return;
    UIView *pad = DDFindView(self.view, @"NumberPad") ?: DDFindView(self.view, @"Keypad") ?: DDFindView(self.view, @"Dialer");
    if (!pad) return;
    UIResponder *r = pad;
    while (r && ![r isKindOfClass:[UIViewController class]]) r = r.nextResponder;
    if (r != self) return;
    DDInstall(self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    DDLayout(self);
}

%end

%hook UITabBarController

- (void)setViewControllers:(NSArray *)vcs animated:(BOOL)animated {
    %orig(DDAugment(self, vcs), animated);
}

- (void)setViewControllers:(NSArray *)vcs {
    %orig(DDAugment(self, vcs));
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    DDEnsureTab(self);
}

%end

%ctor {
    DDLog(@"loaded in %@", NSBundle.mainBundle.bundleIdentifier);
    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    int logged = 0;
    for (unsigned int i = 0; i < n && logged < 40; i++) {
        NSString *name = NSStringFromClass(list[i]);
        if ([name containsString:@"Keypad"] || [name containsString:@"NumberPad"] || [name containsString:@"HandsetDialer"]) {
            DDLog(@"class: %@", name);
            logged++;
        }
    }
    free(list);
    }
