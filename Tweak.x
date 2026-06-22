// TweetDownloader - always-on, one-tap, best-quality media saver for Twitter/X 11.93 (Dopamine rootless)
// Adds a download button at the top-right of every tweet that has media. One tap downloads the
// photo(s) at :orig quality / video at the highest-bitrate mp4, saves to the camera roll with
// no confirmation, and shows a download percentage at the top-left of the screen.
//
// RE notes (Twitter 11.93, com.atebits.Tweetie2):
//  - Status views: T1StandardStatusView, T1TweetDetailsFocalStatusView, T1ConversationFocalStatusView,
//    T1QuotedStandardStatusView, T1SlideshowStatusView  (all expose -viewModel and -setViewModel:options:account:)
//  - viewModel -> -representedMediaEntities  => NSArray<TwitterEntityMedia *> (Swift, TFSTwitterCore)
//  - media.mediaURL (NSString) for photos ; media.videoInfo for videos
//  - videoInfo -highestBitrateVideoVariantURLWithContentType:andMaximumBitrate: => NSURL*  (@objc)

#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>

#define TWLOG(fmt, ...) NSLog(@"[TWDL] " fmt, ##__VA_ARGS__)

// ---------------------------------------------------------------------------
// Small runtime helpers
// ---------------------------------------------------------------------------

// Try several KVC keys, returning the first non-nil value (guarded against exceptions).
static id twdl_try(id obj, NSArray<NSString *> *keys) {
    if (!obj) return nil;
    for (NSString *k in keys) {
        @try {
            if ([obj respondsToSelector:NSSelectorFromString(k)]) {
                id v = [obj valueForKey:k];
                if (v && v != [NSNull null]) return v;
            }
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

static UIWindow *twdl_keyWindow(void) {
    UIWindow *best = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) return w;
                if (!best) best = w;
            }
        }
    }
    return best ?: UIApplication.sharedApplication.windows.firstObject;
}

// ---------------------------------------------------------------------------
// Media model interfaces (declare just enough for the @objc-exposed bits)
// ---------------------------------------------------------------------------
@interface TWDLVideoInfo : NSObject
- (NSURL *)highestBitrateVideoVariantURLWithContentType:(NSString *)ct andMaximumBitrate:(long long)max;
@end

// Item to download
typedef NS_ENUM(NSInteger, TWDLKind) { TWDLKindPhoto, TWDLKindVideo };
@interface TWDLItem : NSObject
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, assign) TWDLKind kind;
@end
@implementation TWDLItem @end

// ---------------------------------------------------------------------------
// Download + save manager (singleton). Sequential queue, top-left % HUD.
// ---------------------------------------------------------------------------
@interface TWDLManager : NSObject <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableArray<TWDLItem *> *queue;
@property (nonatomic, assign) NSInteger total;
@property (nonatomic, assign) NSInteger done;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, strong) UILabel *hud;
@end

static TWDLManager *gManager;

@implementation TWDLManager

+ (instancetype)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gManager = [TWDLManager new]; });
    return gManager;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = [NSMutableArray new];
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    }
    return self;
}

// --- HUD (top-left percentage) ---
- (void)ensureHUD {
    if (_hud) return;
    UILabel *l = [UILabel new];
    l.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightBold];
    l.textColor = UIColor.whiteColor;
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78];
    l.textAlignment = NSTextAlignmentCenter;
    l.layer.cornerRadius = 11;
    l.layer.masksToBounds = YES;
    l.numberOfLines = 1;
    _hud = l;
}
- (void)showHUD {
    [self ensureHUD];
    UIWindow *w = twdl_keyWindow();
    if (!w) return;
    if (_hud.superview != w) { [_hud removeFromSuperview]; [w addSubview:_hud]; }
    CGFloat top = w.safeAreaInsets.top > 0 ? w.safeAreaInsets.top : 24;
    _hud.frame = CGRectMake(10, top + 4, 86, 22);
    [w bringSubviewToFront:_hud];
    _hud.hidden = NO;
}
- (void)setHUDText:(NSString *)t { dispatch_async(dispatch_get_main_queue(), ^{ [self showHUD]; self->_hud.text = t; }); }
- (void)flashHUD:(NSString *)t thenHide:(NSTimeInterval)delay {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self showHUD]; self->_hud.text = t;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self->_hud.hidden = YES; [self->_hud removeFromSuperview];
        });
    });
}

// --- queueing ---
- (void)enqueueItems:(NSArray<TWDLItem *> *)items {
    if (items.count == 0) { [self flashHUD:@"No media" thenHide:1.4]; return; }
    [self.queue addObjectsFromArray:items];
    self.total += items.count;
    if (!self.busy) { self.done = 0; self.total = items.count; [self pump]; }
    [self setHUDText:@"0%"];
}

- (void)pump {
    if (self.queue.count == 0) {
        self.busy = NO;
        [self flashHUD:@"Saved ✓" thenHide:1.3];
        self.total = 0; self.done = 0;
        return;
    }
    self.busy = YES;
    TWDLItem *item = self.queue.firstObject;
    [self.queue removeObjectAtIndex:0];
    TWLOG(@"downloading (%ld/%ld) %@", (long)(self.done + 1), (long)self.total, item.url);
    NSURLSessionDownloadTask *task = [self.session downloadTaskWithURL:item.url];
    task.taskDescription = (item.kind == TWDLKindVideo) ? @"video" : @"photo";
    [task resume];
}

// --- progress ---
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
      didWriteData:(int64_t)bytes totalBytesWritten:(int64_t)written totalBytesExpectedToWrite:(int64_t)expected {
    CGFloat frac = (expected > 0) ? (CGFloat)written / (CGFloat)expected : 0;
    NSInteger overall;
    if (self.total > 0)
        overall = (NSInteger)(((CGFloat)self.done + frac) / (CGFloat)self.total * 100.0);
    else
        overall = (NSInteger)(frac * 100.0);
    NSString *suffix = (self.total > 1) ? [NSString stringWithFormat:@" (%ld/%ld)", (long)(self.done + 1), (long)self.total] : @"";
    [self setHUDText:[NSString stringWithFormat:@"%ld%%%@", (long)overall, suffix]];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
      didFinishDownloadingToURL:(NSURL *)location {
    BOOL isVideo = [task.taskDescription isEqualToString:@"video"];
    NSString *ext = isVideo ? @"mp4" : @"jpg";
    NSURL *dst = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
                  URLByAppendingPathComponent:[NSString stringWithFormat:@"twdl_%@.%@", NSUUID.UUID.UUIDString, ext]];
    [NSFileManager.defaultManager removeItemAtURL:dst error:nil];
    NSError *mvErr = nil;
    [NSFileManager.defaultManager moveItemAtURL:location toURL:dst error:&mvErr];
    if (mvErr) { TWLOG(@"move err %@", mvErr); }
    [self saveToCameraRoll:dst isVideo:isVideo];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        TWLOG(@"download error %@", error);
        self.done++;
        dispatch_async(dispatch_get_main_queue(), ^{ [self pump]; });
    }
}

- (void)saveToCameraRoll:(NSURL *)fileURL isVideo:(BOOL)isVideo {
    void (^doSave)(void) = ^{
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            PHAssetCreationRequest *req = [PHAssetCreationRequest creationRequestForAsset];
            [req addResourceWithType:(isVideo ? PHAssetResourceTypeVideo : PHAssetResourceTypePhoto)
                             fileURL:fileURL options:nil];
        } completionHandler:^(BOOL success, NSError *err) {
            if (!success) TWLOG(@"save err %@", err);
            [NSFileManager.defaultManager removeItemAtURL:fileURL error:nil];
            self.done++;
            dispatch_async(dispatch_get_main_queue(), ^{ [self pump]; });
        }];
    };
    if (@available(iOS 14, *)) {
        PHAuthorizationStatus st = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
        if (st == PHAuthorizationStatusAuthorized || st == PHAuthorizationStatusLimited) { doSave(); }
        else {
            [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus s) {
                if (s == PHAuthorizationStatusAuthorized || s == PHAuthorizationStatusLimited) doSave();
                else { TWLOG(@"no photo permission %ld", (long)s); self.done++; dispatch_async(dispatch_get_main_queue(), ^{ [self pump]; }); }
            }];
        }
    } else { doSave(); }
}
@end

// ---------------------------------------------------------------------------
// Media extraction from a status view
// ---------------------------------------------------------------------------

// Upgrade a Twitter photo URL string to original quality.
static NSURL *twdl_origPhotoURL(NSString *s) {
    if (s.length == 0) return nil;
    // Style A: https://pbs.twimg.com/media/<id>?format=jpg&name=small  -> name=orig
    if ([s containsString:@"name="]) {
        NSURLComponents *c = [NSURLComponents componentsWithString:s];
        NSMutableArray *q = [c.queryItems mutableCopy] ?: [NSMutableArray new];
        BOOL set = NO;
        for (NSInteger i = 0; i < (NSInteger)q.count; i++) {
            NSURLQueryItem *qi = q[i];
            if ([qi.name isEqualToString:@"name"]) { q[i] = [NSURLQueryItem queryItemWithName:@"name" value:@"orig"]; set = YES; }
        }
        if (!set) [q addObject:[NSURLQueryItem queryItemWithName:@"name" value:@"orig"]];
        c.queryItems = q;
        return c.URL;
    }
    // Style B: https://pbs.twimg.com/media/<id>.jpg  -> append :orig
    if ([s rangeOfString:@"?"].location == NSNotFound &&
        ([s hasSuffix:@".jpg"] || [s hasSuffix:@".png"] || [s hasSuffix:@".jpeg"] || [s hasSuffix:@".webp"])) {
        return [NSURL URLWithString:[s stringByAppendingString:@":orig"]];
    }
    return [NSURL URLWithString:s];
}

// Pull the media entities array out of a status view (defensive across versions).
static NSArray *twdl_mediaEntities(id statusView) {
    id vm = twdl_try(statusView, @[@"viewModel"]);
    NSArray *m = twdl_try(vm, @[@"representedMediaEntities", @"mediaEntities", @"allMediaEntities", @"media"]);
    if (![m isKindOfClass:NSArray.class]) m = nil;
    if (m.count == 0) {
        // some view models nest the status
        id status = twdl_try(vm, @[@"status", @"tweet"]);
        m = twdl_try(status, @[@"mediaEntities", @"media", @"representedMediaEntities"]);
        if (![m isKindOfClass:NSArray.class]) m = nil;
    }
    return m;
}

static BOOL twdl_hasMedia(id statusView) {
    return twdl_mediaEntities(statusView).count > 0;
}

static NSArray<TWDLItem *> *twdl_itemsForStatusView(id statusView) {
    NSMutableArray<TWDLItem *> *items = [NSMutableArray new];
    NSArray *entities = twdl_mediaEntities(statusView);
    for (id media in entities) {
        // video?
        id vinfo = twdl_try(media, @[@"videoInfo"]);
        if (vinfo) {
            NSURL *vurl = nil;
            @try {
                if ([vinfo respondsToSelector:@selector(highestBitrateVideoVariantURLWithContentType:andMaximumBitrate:)])
                    vurl = [(TWDLVideoInfo *)vinfo highestBitrateVideoVariantURLWithContentType:@"video/mp4" andMaximumBitrate:LLONG_MAX];
            } @catch (__unused NSException *e) {}
            if (!vurl) {
                NSString *p = twdl_try(vinfo, @[@"primaryUrl", @"url"]);
                if (p) vurl = [NSURL URLWithString:p];
            }
            if (vurl) {
                TWDLItem *it = [TWDLItem new]; it.url = vurl; it.kind = TWDLKindVideo; [items addObject:it];
                continue;
            }
        }
        // photo
        NSString *purl = twdl_try(media, @[@"mediaURL", @"mediaUrl", @"url"]);
        NSURL *u = twdl_origPhotoURL(purl);
        if (u) { TWDLItem *it = [TWDLItem new]; it.url = u; it.kind = TWDLKindPhoto; [items addObject:it]; }
    }
    TWLOG(@"extracted %lu item(s) from %@", (unsigned long)items.count, [statusView class]);
    return items;
}

// ---------------------------------------------------------------------------
// The download button + injection into status views
// ---------------------------------------------------------------------------
static char kBtnKey;

static UIButton *twdl_button(UIView *statusView) {
    return objc_getAssociatedObject(statusView, &kBtnKey);
}

@interface TWDLButton : UIButton
@property (nonatomic, weak) UIView *statusView;
@end
@implementation TWDLButton
- (void)tap {
    NSArray<TWDLItem *> *items = twdl_itemsForStatusView(self.statusView);
    [[TWDLManager shared] enqueueItems:items];
}
@end

static void twdl_ensureButton(UIView *statusView) {
    UIButton *existing = twdl_button(statusView);
    BOOL has = twdl_hasMedia(statusView);
    if (!has) { existing.hidden = YES; return; }
    if (!existing) {
        TWDLButton *b = [TWDLButton buttonWithType:UIButtonTypeSystem];
        b.statusView = statusView;
        UIImage *img = nil;
        if (@available(iOS 13, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
            img = [UIImage systemImageNamed:@"arrow.down.circle" withConfiguration:cfg];
        }
        [b setImage:img forState:UIControlStateNormal];
        b.tintColor = [UIColor colorWithRed:0.45 green:0.55 blue:0.6 alpha:1.0];
        [b addTarget:b action:@selector(tap) forControlEvents:UIControlEventTouchUpInside];
        b.translatesAutoresizingMaskIntoConstraints = YES;
        [statusView addSubview:b];
        objc_setAssociatedObject(statusView, &kBtnKey, b, OBJC_ASSOCIATION_ASSIGN); // view retains it as subview
        existing = b;
    }
    existing.hidden = NO;
    [statusView bringSubviewToFront:existing];
}

// Find the caret ("..."/chevron) subview so we can sit just to its left.
static UIView *twdl_findCaret(UIView *root) {
    for (UIView *v in root.subviews) {
        NSString *cn = NSStringFromClass(v.class);
        if ([cn containsString:@"Caret"] || [cn containsString:@"caret"]) return v;
        UIView *deep = twdl_findCaret(v);
        if (deep) return deep;
    }
    return nil;
}

static void twdl_layoutButton(UIView *statusView) {
    UIButton *b = twdl_button(statusView);
    if (!b || b.hidden) return;
    CGFloat size = 30;
    CGFloat y = 6, rightInset = 8;
    UIView *caret = twdl_findCaret(statusView);
    CGFloat right = statusView.bounds.size.width - rightInset;
    if (caret && caret.superview) {
        CGRect cf = [caret convertRect:caret.bounds toView:statusView];
        right = cf.origin.x - 2;      // sit just left of the caret
        y = cf.origin.y + (cf.size.height - size) / 2.0;
    }
    b.frame = CGRectMake(right - size, y, size, size);
    [statusView bringSubviewToFront:b];
}

// ---- Hooks: one macro-ish block per status view class ----
// Minimal interface decls so Logos can type `self` for each hooked class.
@interface T1StandardStatusView : UIView @end
@interface T1TweetDetailsFocalStatusView : UIView @end
@interface T1ConversationFocalStatusView : UIView @end
@interface T1SlideshowStatusView : UIView @end

%hook T1StandardStatusView
- (void)setViewModel:(id)vm options:(NSUInteger)o account:(id)a { %orig; twdl_ensureButton(self); }
- (void)layoutSubviews { %orig; twdl_ensureButton(self); twdl_layoutButton(self); }
%end

%hook T1TweetDetailsFocalStatusView
- (void)setViewModel:(id)vm options:(NSUInteger)o account:(id)a { %orig; twdl_ensureButton(self); }
- (void)layoutSubviews { %orig; twdl_ensureButton(self); twdl_layoutButton(self); }
%end

%hook T1ConversationFocalStatusView
- (void)setViewModel:(id)vm options:(NSUInteger)o account:(id)a { %orig; twdl_ensureButton(self); }
- (void)layoutSubviews { %orig; twdl_ensureButton(self); twdl_layoutButton(self); }
%end

%hook T1SlideshowStatusView
- (void)setViewModel:(id)vm options:(NSUInteger)o account:(id)a { %orig; twdl_ensureButton(self); }
- (void)layoutSubviews { %orig; twdl_ensureButton(self); twdl_layoutButton(self); }
%end

%ctor {
    TWLOG(@"TweetDownloader loaded into %@", NSBundle.mainBundle.bundleIdentifier);
}
