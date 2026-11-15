// DrawDial v0.3 - ve so/chu tren app Dien thoai de loc Gan day + Danh ba
// Nhan dang kep: Vision + mau chu viet tay cua nguoi dung ($P), tim gan giong, che do Day.

#import <UIKit/UIKit.h>
#import <Vision/Vision.h>
#import <Contacts/Contacts.h>
#import <objc/runtime.h>
#import <sqlite3.h>
#import <math.h>

static NSString *const kDomain = @"com.local.drawdial";
static NSString *const kTplLock = @"com.local.drawdial.tpl";
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

static NSString *DDKey(NSString *digits) {
    return digits.length > 9 ? [digits substringFromIndex:digits.length - 9] : digits;
}

static NSString *DDNoSpace(NSString *s) {
    return [s stringByReplacingOccurrencesOfString:@" " withString:@""];
}

#pragma mark - Tim gan giong (so)

static BOOL DDDigitConf(char a, char b) {
    static const char *pairs[] = {"17", "06", "56", "38", "49", "08"};
    for (int i = 0; i < 6; i++) {
        if ((a == pairs[i][0] && b == pairs[i][1]) || (a == pairs[i][1] && b == pairs[i][0])) return YES;
    }
    return NO;
}

// 0 = khop chinh xac, 1 = chi lech cac cap hay nham, 2 = lech 1 so bat ky, 99 = khong khop
static int DDFuzzyPhone(NSString *phone, NSString *q) {
    if (!q.length) return 99;
    if ([phone containsString:q]) return 0;
    NSInteger n = q.length, m = phone.length;
    if (n < 4 || m < n) return 99;
    const char *a = q.UTF8String, *b = phone.UTF8String;
    int best = 99;
    for (NSInteger i = 0; i + n <= m; i++) {
        int conf = 0, bad = 0;
        for (NSInteger j = 0; j < n; j++) {
            if (a[j] != b[i + j]) {
                if (DDDigitConf(a[j], b[i + j])) conf++; else bad++;
                if (bad > 1) break;
            }
        }
        if (bad == 0 && conf >= 1 && conf <= 2) { if (best > 1) best = 1; }
        else if (bad == 1 && conf == 0 && n >= 6) { if (best > 2) best = 2; }
    }
    return best;
}

static int DDPhoneScore(NSString *phone, NSString *q) {
    int s = DDFuzzyPhone(phone, q);
    if (q.length > 1 && [q hasPrefix:@"0"]) {
        int s2 = DDFuzzyPhone(phone, [q substringFromIndex:1]);
        if (s2 < s) s = s2;
    }
    return s;
}

#pragma mark - Tim gan giong (chu)

static NSArray<NSString *> *DDQueryVariants(NSString *q) {
    static NSArray *rules;
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        rules = @[@[@"rn", @"m"], @[@"m", @"rn"], @[@"cl", @"d"], @[@"d", @"cl"],
                  @[@"u", @"v"], @[@"v", @"u"], @[@"i", @"l"], @[@"l", @"i"],
                  @[@"o", @"a"], @[@"a", @"o"], @[@"e", @"c"], @[@"c", @"e"],
                  @[@"n", @"h"], @[@"h", @"n"]];
    });
    NSMutableArray *out = [NSMutableArray new];
    for (NSArray *r in rules) {
        if ([q containsString:r[0]]) [out addObject:[q stringByReplacingOccurrencesOfString:r[0] withString:r[1]]];
    }
    return out;
}

static int DDNameBase(NSString *folded, NSString *flat, NSString *q) {
    if (!q.length) return 99;
    if ([folded hasPrefix:q]) return 0;
    for (NSString *w in [folded componentsSeparatedByString:@" "])
        if ([w hasPrefix:q]) return 1;
    if ([folded containsString:q]) return 2;
    NSString *qf = DDNoSpace(q);
    if (qf.length >= 2 && [flat containsString:qf]) return 2;
    return 99;
}

static int DDNameScore(NSString *folded, NSString *q) {
    if (!q.length || !folded.length) return 99;
    NSString *flat = DDNoSpace(folded);
    int s = DDNameBase(folded, flat, q);
    if (s < 99) return s;
    for (NSString *v in DDQueryVariants(q)) {
        int t = DDNameBase(folded, flat, v);
        if (t < 99) return 3 + t;
    }
    NSString *qf = DDNoSpace(q);
    if (qf.length >= 3) {
        for (NSString *w in [folded componentsSeparatedByString:@" "]) {
            if (w.length < qf.length) continue;
            int diff = 0;
            for (NSUInteger i = 0; i < qf.length; i++)
                if ([w characterAtIndex:i] != [qf characterAtIndex:i]) diff++;
            if (diff <= 1) return 7;
        }
    }
    return 99;
}

#pragma mark - Mau chu viet tay ($P point-cloud)

#define DD_N 32
typedef struct { double x, y; int id; } DDPt;

static double DDDist(DDPt a, DDPt b) {
    double dx = a.x - b.x, dy = a.y - b.y;
    return sqrt(dx * dx + dy * dy);
}

static void DDResample(const DDPt *in, int cnt, DDPt *out) {
    double L = 0;
    for (int i = 1; i < cnt; i++) if (in[i].id == in[i - 1].id) L += DDDist(in[i - 1], in[i]);
    if (L < 1e-6) { for (int i = 0; i < DD_N; i++) out[i] = in[0]; return; }
    double I = L / (DD_N - 1), D = 0;
    int m = 0;
    out[m++] = in[0];
    DDPt prev = in[0];
    for (int i = 1; i < cnt; i++) {
        DDPt cur = in[i];
        if (cur.id == prev.id) {
            double d = DDDist(prev, cur);
            while (d > 1e-9 && D + d >= I && m < DD_N) {
                double t = (I - D) / d;
                DDPt q = { prev.x + t * (cur.x - prev.x), prev.y + t * (cur.y - prev.y), cur.id };
                out[m++] = q;
                prev = q;
                d = DDDist(prev, cur);
                D = 0;
            }
            D += d;
        }
        prev = cur;
    }
    while (m < DD_N) out[m++] = in[cnt - 1];
}

static BOOL DDNormalizeStrokes(NSArray<NSArray<NSValue *> *> *strokes, DDPt *out) {
    int cnt = 0;
    for (NSArray *s in strokes) cnt += (int)s.count;
    if (cnt < 2) return NO;
    DDPt *in = malloc(sizeof(DDPt) * cnt);
    int k = 0, sid = 0;
    double minx = 1e18, miny = 1e18, maxx = -1e18, maxy = -1e18;
    for (NSArray<NSValue *> *s in strokes) {
        for (NSValue *v in s) {
            CGPoint p = v.CGPointValue;
            DDPt pt = { p.x, p.y, sid };
            in[k++] = pt;
            if (p.x < minx) minx = p.x;
            if (p.x > maxx) maxx = p.x;
            if (p.y < miny) miny = p.y;
            if (p.y > maxy) maxy = p.y;
        }
        sid++;
    }
    double sc = MAX(maxx - minx, maxy - miny);
    if (sc < 10) { free(in); return NO; }
    DDResample(in, cnt, out);
    free(in);
    double cx = 0, cy = 0;
    for (int i = 0; i < DD_N; i++) {
        out[i].x = (out[i].x - minx) / sc;
        out[i].y = (out[i].y - miny) / sc;
        cx += out[i].x; cy += out[i].y;
    }
    cx /= DD_N; cy /= DD_N;
    for (int i = 0; i < DD_N; i++) { out[i].x -= cx; out[i].y -= cy; }
    return YES;
}

static double DDCloudDist(const DDPt *a, const DDPt *b, int start) {
    BOOL matched[DD_N];
    memset(matched, 0, sizeof(matched));
    double sum = 0;
    int i = start;
    do {
        double mn = 1e18; int idx = 0;
        for (int j = 0; j < DD_N; j++) {
            if (!matched[j]) {
                double d = DDDist(a[i], b[j]);
                if (d < mn) { mn = d; idx = j; }
            }
        }
        matched[idx] = YES;
        double w = 1.0 - (double)((i - start + DD_N) % DD_N) / DD_N;
        sum += w * mn;
        i = (i + 1) % DD_N;
    } while (i != start);
    return sum;
}

static double DDGreedy(const DDPt *a, const DDPt *b) {
    int step = (int)floor(pow(DD_N, 0.5));
    double mn = 1e18;
    for (int i = 0; i < DD_N; i += step) {
        double d1 = DDCloudDist(a, b, i), d2 = DDCloudDist(b, a, i);
        mn = MIN(mn, MIN(d1, d2));
    }
    return mn;
}

static NSMutableArray *sTpl; // moi phan tu: @{label, data(NSData DDPt[DD_N])}

static NSString *DDTplPath(void) {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    NSString *dir = [base stringByAppendingPathComponent:@"DrawDial"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"templates.json"];
}

static void DDTplLoadIfNeeded(void) {
    @synchronized (kTplLock) {
        if (sTpl) return;
        sTpl = [NSMutableArray new];
        NSData *d = [NSData dataWithContentsOfFile:DDTplPath()];
        if (!d) return;
        NSArray *arr = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (![arr isKindOfClass:[NSArray class]]) return;
        for (NSDictionary *it in arr) {
            NSString *label = it[@"label"];
            NSArray *pts = it[@"pts"];
            if (!label.length || pts.count != DD_N * 3) continue;
            DDPt buf[DD_N];
            for (int i = 0; i < DD_N; i++) {
                buf[i].x = [pts[i * 3] doubleValue];
                buf[i].y = [pts[i * 3 + 1] doubleValue];
                buf[i].id = [pts[i * 3 + 2] intValue];
            }
            [sTpl addObject:@{@"label": label, @"data": [NSData dataWithBytes:buf length:sizeof(buf)]}];
        }
    }
}

static void DDTplSave(void) {
    NSMutableArray *arr = [NSMutableArray new];
    @synchronized (kTplLock) {
        for (NSDictionary *t in sTpl) {
            const DDPt *p = (const DDPt *)[t[@"data"] bytes];
            NSMutableArray *pts = [NSMutableArray new];
            for (int i = 0; i < DD_N; i++) {
                [pts addObject:@(p[i].x)];
                [pts addObject:@(p[i].y)];
                [pts addObject:@(p[i].id)];
            }
            [arr addObject:@{@"label": t[@"label"], @"pts": pts}];
        }
    }
    NSData *d = [NSJSONSerialization dataWithJSONObject:arr options:0 error:nil];
    if (d) [d writeToFile:DDTplPath() atomically:YES];
}

static BOOL DDIsDigitLabel(NSString *l) {
    return l.length == 1 && [l characterAtIndex:0] >= '0' && [l characterAtIndex:0] <= '9';
}

static BOOL DDTplAdd(NSString *label, NSArray *strokes) {
    DDTplLoadIfNeeded();
    DDPt q[DD_N];
    if (!DDNormalizeStrokes(strokes, q)) return NO;
    @synchronized (kTplLock) {
        [sTpl addObject:@{@"label": label, @"data": [NSData dataWithBytes:q length:sizeof(q)]}];
    }
    DDTplSave();
    return YES;
}

static NSUInteger DDTplCount(NSString *label) {
    DDTplLoadIfNeeded();
    NSUInteger n = 0;
    @synchronized (kTplLock) {
        for (NSDictionary *t in sTpl) if ([t[@"label"] isEqualToString:label]) n++;
    }
    return n;
}

static BOOL DDTplHas(BOOL digits) {
    DDTplLoadIfNeeded();
    @synchronized (kTplLock) {
        for (NSDictionary *t in sTpl) if (DDIsDigitLabel(t[@"label"]) == digits) return YES;
    }
    return NO;
}

static void DDTplClear(BOOL digits) {
    DDTplLoadIfNeeded();
    @synchronized (kTplLock) {
        NSMutableArray *keep = [NSMutableArray new];
        for (NSDictionary *t in sTpl) if (DDIsDigitLabel(t[@"label"]) != digits) [keep addObject:t];
        sTpl = keep;
    }
    DDTplSave();
}

// Tra ve mang @{label, dist} tot nhat cho moi label, sap tang dan theo dist
static NSArray<NSDictionary *> *DDTplRank(NSArray *group, BOOL digits) {
    DDTplLoadIfNeeded();
    DDPt q[DD_N];
    if (!DDNormalizeStrokes(group, q)) return @[];
    NSMutableDictionary *best = [NSMutableDictionary new];
    NSArray *snapshot;
    @synchronized (kTplLock) { snapshot = [sTpl copy]; }
    for (NSDictionary *t in snapshot) {
        NSString *label = t[@"label"];
        if (DDIsDigitLabel(label) != digits) continue;
        double d = DDGreedy(q, (const DDPt *)[t[@"data"] bytes]);
        NSNumber *cur = best[label];
        if (!cur || d < cur.doubleValue) best[label] = @(d);
    }
    NSMutableArray *out = [NSMutableArray new];
    for (NSString *k in best) [out addObject:@{@"label": k, @"dist": best[k]}];
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"dist"] compare:b[@"dist"]];
    }];
    return out;
}

// Tach cac net thanh tung ky tu theo chieu ngang (trai sang phai)
static NSArray<NSArray *> *DDSegment(NSArray<NSArray<NSValue *> *> *strokes) {
    NSMutableArray *info = [NSMutableArray new];
    for (NSArray<NSValue *> *s in strokes) {
        if (!s.count) continue;
        CGFloat mn = 1e9, mx = -1e9;
        for (NSValue *v in s) { CGFloat x = v.CGPointValue.x; mn = MIN(mn, x); mx = MAX(mx, x); }
        [info addObject:@{@"s": s, @"min": @(mn), @"max": @(mx)}];
    }
    [info sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"min"] compare:b[@"min"]];
    }];
    NSMutableArray *groups = [NSMutableArray new];
    NSMutableArray *cur = nil;
    CGFloat gmin = 0, gmax = 0;
    for (NSDictionary *it in info) {
        CGFloat smin = [it[@"min"] doubleValue], smax = [it[@"max"] doubleValue];
        if (!cur) { cur = [NSMutableArray arrayWithObject:it[@"s"]]; gmin = smin; gmax = smax; continue; }
        CGFloat overlap = MIN(gmax, smax) - MAX(gmin, smin);
        CGFloat sw = smax - smin, gw = gmax - gmin;
        BOOL merge = NO;
        if (overlap > 0 && overlap > 0.3 * MIN(sw, gw)) merge = YES;
        else if ((sw < 10 || gw < 10) && overlap >= -3) merge = YES;
        if (merge) {
            [cur addObject:it[@"s"]];
            gmin = MIN(gmin, smin); gmax = MAX(gmax, smax);
        } else {
            [groups addObject:cur];
            cur = [NSMutableArray arrayWithObject:it[@"s"]];
            gmin = smin; gmax = smax;
        }
    }
    if (cur) [groups addObject:cur];
    NSMutableArray *kept = [NSMutableArray new];
    for (NSArray *g in groups) {
        CGFloat x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9;
        for (NSArray<NSValue *> *s in g) for (NSValue *v in s) {
            CGPoint p = v.CGPointValue;
            x0 = MIN(x0, p.x); x1 = MAX(x1, p.x); y0 = MIN(y0, p.y); y1 = MAX(y1, p.y);
        }
        if (MAX(x1 - x0, y1 - y0) >= 10) [kept addObject:g];
    }
    return kept;
}

#pragma mark - Data store (Danh ba + Gan day)

static NSArray *sContacts, *sRecents;

@interface DDStore : NSObject
+ (void)reload;
+ (NSArray *)defaultResults;
+ (NSArray<NSString *> *)nameWords;
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

+ (NSArray<NSString *> *)nameWords {
    NSMutableOrderedSet *set = [NSMutableOrderedSet new];
    for (NSDictionary *it in (sContacts ?: @[])) {
        for (NSString *w in [it[@"folded"] componentsSeparatedByString:@" "]) {
            if (w.length >= 2) [set addObject:w];
            if (set.count >= 500) break;
        }
        if (set.count >= 500) break;
    }
    return set.array;
}

+ (NSArray *)resultsForCandidates:(NSArray<NSString *> *)cands digits:(BOOL)digits {
    NSMutableArray *out = [NSMutableArray new];
    NSMutableSet *seen = [NSMutableSet new];
    for (NSArray *src in @[sRecents ?: @[], sContacts ?: @[]]) {
        NSMutableArray *scored = [NSMutableArray new];
        for (NSDictionary *it in src) {
            int best = 9999;
            for (NSUInteger ci = 0; ci < cands.count; ci++) {
                NSString *q = cands[ci];
                if (!q.length) continue;
                int s = digits ? DDPhoneScore(it[@"digits"], q) : DDNameScore(it[@"folded"], q);
                if (s >= 99) continue;
                int w = s * 4 + (int)MIN(ci, 3);
                if (w < best) best = w;
            }
            if (best < 9999) [scored addObject:@[@(best), it]];
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

#pragma mark - Vision + gop ket qua

static NSArray<NSString *> *DDVisionCands(UIImage *img, BOOL digits) {
    VNRecognizeTextRequest *req = [VNRecognizeTextRequest new];
    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.recognitionLanguages = @[@"en-US"];
    if (digits) {
        req.usesLanguageCorrection = NO;
    } else {
        req.usesLanguageCorrection = YES;
        NSArray *w = [DDStore nameWords];
        if (w.count) req.customWords = w;
    }
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
    return proc;
}

static NSString *DDNormLabel(NSString *label, BOOL digits) {
    return digits ? label : DDFold(label);
}

static NSArray<NSString *> *DDFuse(NSArray<NSString *> *vision, NSArray *strokes, BOOL digits) {
    NSMutableArray *out = [NSMutableArray new];
    void (^add)(NSString *) = ^(NSString *s) { if (s.length && ![out containsObject:s]) [out addObject:s]; };
    NSString *visFlat = DDNoSpace(vision.firstObject ?: @"");

    if (DDBool(@"useTemplates", YES) && strokes.count && DDTplHas(digits)) {
        NSArray *groups = DDSegment(strokes);
        NSMutableArray *ranks = [NSMutableArray new];
        BOOL ok = groups.count > 0;
        for (NSArray *g in groups) {
            NSArray *r = DDTplRank(g, digits);
            if (!r.count) { ok = NO; break; }
            [ranks addObject:r];
        }
        if (ok) {
            NSMutableString *tpl = [NSMutableString new], *fused = [NSMutableString new];
            NSMutableArray *margins = [NSMutableArray new];
            BOOL lenMatch = (visFlat.length == ranks.count);
            for (NSUInteger i = 0; i < ranks.count; i++) {
                NSArray *r = ranks[i];
                double d1 = [r[0][@"dist"] doubleValue];
                double d2 = r.count > 1 ? [r[1][@"dist"] doubleValue] : 1e9;
                NSString *tl = DDNormLabel(r[0][@"label"], digits);
                BOOL conf = (d1 < 6.0 && d1 < 0.75 * d2);
                [tpl appendString:tl];
                NSString *vc = lenMatch ? [visFlat substringWithRange:NSMakeRange(i, 1)] : nil;
                [fused appendString:(conf || !vc) ? tl : vc];
                [margins addObject:@(d2 > 0 && d2 < 1e8 ? d1 / d2 : 0)];
            }
            add(fused);
            add(tpl);
            for (NSString *v in vision) add(v);
            NSMutableArray *idxs = [NSMutableArray new];
            for (NSUInteger i = 0; i < margins.count; i++) [idxs addObject:@(i)];
            [idxs sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
                return [margins[b.unsignedIntegerValue] compare:margins[a.unsignedIntegerValue]];
            }];
            NSUInteger made = 0;
            for (NSNumber *n in idxs) {
                if (made >= 2) break;
                NSUInteger i = n.unsignedIntegerValue;
                NSArray *r = ranks[i];
                if (r.count < 2) continue;
                NSMutableString *alt = [tpl mutableCopy];
                [alt replaceCharactersInRange:NSMakeRange(i, 1) withString:DDNormLabel(r[1][@"label"], digits)];
                add(alt);
                made++;
            }
            return out;
        }
    }
    for (NSString *v in vision) add(v);
    return out;
}

#pragma mark - Canvas

@interface DDCanvas : UIView
@property (nonatomic, strong) NSMutableArray<UIBezierPath *> *strokes;
@property (nonatomic, strong) NSMutableArray<NSMutableArray<NSValue *> *> *pts;
@property (nonatomic, copy) void (^onIdle)(void);
- (void)undo;
- (void)clear;
- (UIImage *)snapshot;
- (NSArray<NSArray<NSValue *> *> *)pointStrokesCopy;
@end

@implementation DDCanvas

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        _strokes = [NSMutableArray new];
        _pts = [NSMutableArray new];
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
    [self.pts addObject:[NSMutableArray arrayWithObject:[NSValue valueWithCGPoint:p]]];
    [self setNeedsDisplay];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    CGPoint p = [touches.anyObject locationInView:self];
    [self.strokes.lastObject addLineToPoint:p];
    NSMutableArray *cur = self.pts.lastObject;
    CGPoint last = [cur.lastObject CGPointValue];
    if (hypot(p.x - last.x, p.y - last.y) >= 1.5) [cur addObject:[NSValue valueWithCGPoint:p]];
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
    [self.pts removeLastObject];
    [self setNeedsDisplay];
}

- (void)clear {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fire) object:nil];
    [self.strokes removeAllObjects];
    [self.pts removeAllObjects];
    [self setNeedsDisplay];
}

- (NSArray<NSArray<NSValue *> *> *)pointStrokesCopy {
    NSMutableArray *out = [NSMutableArray new];
    for (NSArray *s in self.pts) [out addObject:[s copy]];
    return out;
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

static UIViewController *DDTopVC(UIView *v) {
    UIResponder *r = v;
    while (r && ![r isKindOfClass:[UIViewController class]]) r = r.nextResponder;
    return (UIViewController *)r;
}

@interface DDPanel : UIView <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UISegmentedControl *seg;
@property (nonatomic, strong) DDCanvas *canvas;
@property (nonatomic, strong) UILabel *label, *modeLabel, *bigLabel;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UIScrollView *chips;
@property (nonatomic, strong) UIStackView *teachBar;
@property (nonatomic, strong) UIButton *undoBtn, *clearBtn, *teachBtn;
@property (nonatomic, strong) NSArray *results;
@property (nonatomic, strong) NSArray<NSString *> *cands;
@property (nonatomic) NSInteger gen;
@property (nonatomic) BOOL teachMode, teachDigits;
@property (nonatomic, strong) NSMutableArray<NSString *> *teachQueue;
- (void)prepare;
@end

@implementation DDPanel

- (UIButton *)makeButton:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.backgroundColor = UIColor.systemBackgroundColor;

        _seg = [[UISegmentedControl alloc] initWithItems:@[@"Số", @"Chữ"]];
        _seg.selectedSegmentIndex = DDBool(@"defaultLetters", NO) ? 1 : 0;
        [_seg addTarget:self action:@selector(runRecognition) forControlEvents:UIControlEventValueChanged];
        [self addSubview:_seg];

        _modeLabel = [UILabel new];
        _modeLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        _modeLabel.hidden = YES;
        [self addSubview:_modeLabel];

        _teachBtn = [self makeButton:@"Dạy" action:@selector(enterTeach)];
        [self addSubview:_teachBtn];
        _undoBtn = [self makeButton:@"Hoàn tác" action:@selector(doUndo)];
        [self addSubview:_undoBtn];
        _clearBtn = [self makeButton:@"Xóa" action:@selector(doClear)];
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

        _chips = [UIScrollView new];
        _chips.showsHorizontalScrollIndicator = NO;
        [self addSubview:_chips];

        _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
        _table.dataSource = self; _table.delegate = self;
        _table.backgroundColor = UIColor.clearColor;
        [self addSubview:_table];

        _bigLabel = [UILabel new];
        _bigLabel.font = [UIFont systemFontOfSize:56 weight:UIFontWeightMedium];
        _bigLabel.textAlignment = NSTextAlignmentCenter;
        _bigLabel.hidden = YES;
        [self addSubview:_bigLabel];

        _teachBar = [[UIStackView alloc] initWithArrangedSubviews:@[
            [self makeButton:@"Lưu" action:@selector(teachSave)],
            [self makeButton:@"Bỏ qua" action:@selector(teachSkip)],
            [self makeButton:@"Xóa mẫu" action:@selector(teachClear)],
            [self makeButton:@"Thoát" action:@selector(exitTeach)]]];
        _teachBar.distribution = UIStackViewDistributionFillEqually;
        _teachBar.hidden = YES;
        [self addSubview:_teachBar];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height, y = 6;
    CGFloat right = w - 12;
    self.clearBtn.frame = CGRectMake(right - 44, y, 44, 32); right -= 44;
    self.undoBtn.frame = CGRectMake(right - 76, y, 76, 32); right -= 76;
    self.teachBtn.frame = CGRectMake(right - 44, y, 44, 32);
    self.seg.frame = CGRectMake(12, y, 100, 32);
    self.modeLabel.frame = CGRectMake(12, y, 160, 32);
    y += 40;
    CGFloat ch = MIN(MAX(h * 0.34, 110), 220);
    self.canvas.frame = CGRectMake(12, y, w - 24, ch);
    y += ch + 4;
    self.label.frame = CGRectMake(14, y, w - 28, 22);
    y += 24;
    if (self.teachMode) {
        self.bigLabel.frame = CGRectMake(0, y, w, 70);
        y += 72;
        self.teachBar.frame = CGRectMake(12, y, w - 24, 36);
    } else {
        self.chips.frame = CGRectMake(0, y, w, 34);
        y += 36;
        self.table.frame = CGRectMake(0, y, w, MAX(0, h - y));
    }
}

- (void)prepare {
    [DDStore reload];
    if (self.teachMode) [self exitTeach];
    [self.canvas clear];
    self.cands = @[];
    [self reloadChips];
    self.label.text = @"Vẽ số hoặc chữ vào ô trắng";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self.canvas.strokes.count && !self.teachMode) { self.results = [DDStore defaultResults]; [self.table reloadData]; }
    });
}

- (void)doUndo { [self.canvas undo]; [self runRecognition]; }
- (void)doClear { [self.canvas clear]; [self runRecognition]; }

#pragma mark nhan dang

- (void)reloadChips {
    for (UIView *v in self.chips.subviews) [v removeFromSuperview];
    CGFloat x = 12;
    for (NSUInteger i = 0; i < MIN(self.cands.count, 6); i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:self.cands[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:15];
        b.backgroundColor = UIColor.secondarySystemBackgroundColor;
        b.layer.cornerRadius = 14;
        b.tag = (NSInteger)i;
        CGSize sz = [self.cands[i] sizeWithAttributes:@{NSFontAttributeName: b.titleLabel.font}];
        CGFloat bw = MAX(44, sz.width + 24);
        b.frame = CGRectMake(x, 3, bw, 28);
        [b addTarget:self action:@selector(chipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.chips addSubview:b];
        x += bw + 8;
    }
    self.chips.contentSize = CGSizeMake(x + 12, 34);
}

- (void)chipTapped:(UIButton *)b {
    NSString *c = self.cands[b.tag];
    BOOL digits = (self.seg.selectedSegmentIndex == 0);
    self.results = [DDStore resultsForCandidates:@[c] digits:digits];
    self.label.text = [NSString stringWithFormat:@"Đang dùng: %@  (%lu kết quả)", c, (unsigned long)self.results.count];
    [self.table reloadData];
}

- (void)runRecognition {
    if (self.teachMode) return;
    UIImage *img = [self.canvas snapshot];
    if (!img) {
        self.cands = @[];
        [self reloadChips];
        self.results = [DDStore defaultResults];
        self.label.text = @"Vẽ số hoặc chữ vào ô trắng";
        [self.table reloadData];
        return;
    }
    BOOL digits = (self.seg.selectedSegmentIndex == 0);
    NSInteger g = ++self.gen;
    NSArray *strokes = [self.canvas pointStrokesCopy];
    self.label.text = @"Đang nhận dạng...";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *vis = DDVisionCands(img, digits);
        NSArray *cands = DDFuse(vis, strokes, digits);
        DDLog(@"cands=%@", cands);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (g != self.gen) return;
            self.cands = cands;
            [self reloadChips];
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

#pragma mark che do Day

- (NSMutableArray<NSString *> *)buildTeachQueueDigits:(BOOL)digits {
    NSString *set = digits ? @"0123456789" : @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    NSInteger target = digits ? 2 : 1;
    NSMutableArray *needs = [NSMutableArray new];
    for (NSUInteger i = 0; i < set.length; i++) {
        NSString *l = [set substringWithRange:NSMakeRange(i, 1)];
        [needs addObject:@(MAX(0, target - (NSInteger)DDTplCount(l)))];
    }
    NSMutableArray *q = [NSMutableArray new];
    for (NSInteger pass = 0; pass < target; pass++) {
        for (NSUInteger i = 0; i < set.length; i++) {
            if ([needs[i] integerValue] > pass) [q addObject:[set substringWithRange:NSMakeRange(i, 1)]];
        }
    }
    return q;
}

- (void)setTeachUI:(BOOL)on {
    self.teachMode = on;
    self.seg.hidden = on;
    self.teachBtn.hidden = on;
    self.modeLabel.hidden = !on;
    self.chips.hidden = on;
    self.table.hidden = on;
    self.bigLabel.hidden = !on;
    self.teachBar.hidden = !on;
    [self setNeedsLayout];
}

- (void)updateTeachUI {
    NSString *cur = self.teachQueue.firstObject;
    self.bigLabel.text = cur ?: @"Xong";
    if (cur) {
        self.label.text = [NSString stringWithFormat:@"Vẽ ký tự lớn, rõ, rồi bấm Lưu. Còn %lu mẫu.", (unsigned long)self.teachQueue.count];
    } else {
        self.label.text = @"Đã dạy đủ. Bấm Thoát để dùng.";
    }
}

- (void)enterTeach {
    self.teachDigits = (self.seg.selectedSegmentIndex == 0);
    self.teachQueue = [self buildTeachQueueDigits:self.teachDigits];
    self.modeLabel.text = self.teachDigits ? @"Dạy: số" : @"Dạy: chữ";
    [self.canvas clear];
    [self setTeachUI:YES];
    [self updateTeachUI];
}

- (void)exitTeach {
    [self.canvas clear];
    [self setTeachUI:NO];
    self.label.text = @"Vẽ số hoặc chữ vào ô trắng";
    [self runRecognition];
}

- (void)teachSave {
    NSString *cur = self.teachQueue.firstObject;
    if (!cur) return;
    if (!DDTplAdd(cur, [self.canvas pointStrokesCopy])) {
        self.label.text = @"Chưa có nét hoặc nét quá nhỏ, vẽ lớn hơn rồi Lưu lại";
        return;
    }
    DDLog(@"saved template %@", cur);
    [self.teachQueue removeObjectAtIndex:0];
    [self.canvas clear];
    [self updateTeachUI];
}

- (void)teachSkip {
    if (!self.teachQueue.count) return;
    [self.teachQueue removeObjectAtIndex:0];
    [self.canvas clear];
    [self updateTeachUI];
}

- (void)teachClear {
    UIViewController *vc = DDTopVC(self);
    if (!vc) return;
    BOOL digits = self.teachDigits;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Xóa mẫu đã dạy"
        message:digits ? @"Xóa tất cả mẫu chữ số?" : @"Xóa tất cả mẫu chữ cái?"
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Xóa" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        DDTplClear(digits);
        self.teachQueue = [self buildTeachQueueDigits:digits];
        [self updateTeachUI];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
}

#pragma mark table

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
    UIViewController *vc = DDTopVC(g.view);
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
    DDLog(@"them tab Ve (keypad idx=%ld)", (long)idx);
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

#pragma mark - Install / Layout (nut but chi tren Ban phim)

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
    DDLog(@"v0.3 loaded in %@", NSBundle.mainBundle.bundleIdentifier);
    DDTplLoadIfNeeded();
    DDLog(@"templates: digits=%d letters=%d", DDTplHas(YES), DDTplHas(NO));
}
