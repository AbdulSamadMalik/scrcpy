#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <SDL3/SDL.h>

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

static const CGFloat        kTitlebarHeight = 38.0;
static const CGFloat        kHoverThreshold = 48.0;  // px from top of window
static const NSTimeInterval kAnimDur        = 0.20;
static const CGFloat        kCornerRadius   = 12.0;

// ─────────────────────────────────────────────────────────────────────────────
// ScTitlebarView  — the animated overlay bar
// ─────────────────────────────────────────────────────────────────────────────

@interface ScTitlebarView : NSView
- (void)revealAnimated:(BOOL)anim;
- (void)hideAnimated:(BOOL)anim;
@property (nonatomic, readonly) BOOL isRevealed;
@end

@implementation ScTitlebarView {
    BOOL _revealed;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.wantsLayer = YES;
    self.alphaValue = 0.0;
    _revealed = NO;

    // Frosted-glass blur — same material as system title bars
    NSVisualEffectView *blur = [[NSVisualEffectView alloc]
                                    initWithFrame:self.bounds];
    blur.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    blur.material         = NSVisualEffectMaterialTitlebar;
    blur.blendingMode     = NSVisualEffectBlendingModeWithinWindow;
    blur.state            = NSVisualEffectStateActive;
    blur.wantsLayer       = YES;
    // Round only the top two corners to match the window shape
    blur.layer.cornerRadius  = kCornerRadius;
    blur.layer.maskedCorners = kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    blur.layer.masksToBounds = YES;
    [self addSubview:blur];

    return self;
}

// Place the real Cocoa traffic-light buttons inside our bar.
// Must be called after the window is on screen.
- (void)adoptWindowButtons {
    static const NSWindowButton kKinds[] = {
        NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton
    };
    CGFloat x = 8.0;
    for (NSUInteger i = 0; i < 3; i++) {
        NSButton *btn = [self.window standardWindowButton:kKinds[i]];
        if (!btn || btn.superview == self) continue;
        [btn removeFromSuperview];
        CGFloat y = floor((kTitlebarHeight - btn.frame.size.height) / 2.0);
        btn.frame = NSMakeRect(x, y, btn.frame.size.width, btn.frame.size.height);
        [self addSubview:btn];
        x += btn.frame.size.width + 6.0;
    }
}

// ── animation ─────────────────────────────────────────────────────────────────

- (void)revealAnimated:(BOOL)anim {
    if (_revealed) return;
    _revealed = YES;
    [self animateTo:1.0 curve:kCAMediaTimingFunctionEaseOut animated:anim];
}

- (void)hideAnimated:(BOOL)anim {
    if (!_revealed) return;
    _revealed = NO;
    [self animateTo:0.0 curve:kCAMediaTimingFunctionEaseIn animated:anim];
}

- (void)animateTo:(CGFloat)alpha curve:(NSString *)curve animated:(BOOL)anim {
    if (!anim) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.alphaValue     = alpha;
        self.layer.opacity  = (float)alpha;
        [CATransaction commit];
        return;
    }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration       = kAnimDur;
        ctx.timingFunction = [CAMediaTimingFunction functionWithName:curve];
        self.animator.alphaValue = alpha;
    }];
}

// ── hit testing ───────────────────────────────────────────────────────────────

// Invisible when hidden — events fall through to SDL content view
- (NSView *)hitTest:(NSPoint)pt {
    return _revealed ? [super hitTest:pt] : nil;
}

// The visible bar is a drag handle for the window
- (BOOL)mouseDownCanMoveWindow { return YES; }

- (BOOL)isRevealed { return _revealed; }

@end

// ─────────────────────────────────────────────────────────────────────────────
// ScHoverController
// ─────────────────────────────────────────────────────────────────────────────

@interface ScHoverController : NSObject
- (instancetype)initWithNSWindow:(NSWindow *)window;
@end

@implementation ScHoverController {
    NSWindow       *_window;
    ScTitlebarView *_titlebar;
    id              _localMonitor;
    id              _globalMonitor;
    BOOL            _revealed;
}

- (instancetype)initWithNSWindow:(NSWindow *)window {
    self = [super init];
    if (!self) return nil;

    _window   = window;
    _revealed = NO;

    [self suppressNativeTitlebar];
    [self addOverlayTitlebar];
    [self installMonitors];

    objc_setAssociatedObject(window, (__bridge void *)self, self,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return self;
}

- (void)dealloc {
    if (_localMonitor)  [NSEvent removeMonitor:_localMonitor];
    if (_globalMonitor) [NSEvent removeMonitor:_globalMonitor];
}

// ── suppress the ghost native title bar ──────────────────────────────────────

- (void)suppressNativeTitlebar {
    // NSWindowStyleMaskFullSizeContentView extends SDL's contentView all the
    // way up through the native title bar area — no gap, no offset.
    // We OR it into the existing mask so SDL's other flags are preserved.
    // setStyleMask can disturb the view's nextResponder; SDL sets it to its
    // listener object, so we restore it after.
    NSView *cv       = _window.contentView;
    id      responder = cv.nextResponder;
    _window.styleMask |= NSWindowStyleMaskFullSizeContentView;
    if (cv.nextResponder != responder) {
        cv.nextResponder = responder;
    }

    // Make the native title bar area fully transparent and remove its text.
    _window.titlebarAppearsTransparent = YES;
    _window.titleVisibility            = NSWindowTitleHidden;

    // Window transparent so the rounded corner radius shows through
    _window.opaque          = NO;
    _window.backgroundColor = [NSColor clearColor];
    _window.hasShadow       = YES;
}

// ── overlay titlebar (lives at the top of the SDL content view) ──────────────

- (void)addOverlayTitlebar {
    // With NSWindowStyleMaskFullSizeContentView the SDL contentView now covers
    // the entire window including where the native title bar used to be.
    // Our bar sits at the top of contentView — it overlays the top edge of
    // the phone screen just like iPhone Mirroring does.
    NSView *cv  = _window.contentView;
    CGFloat cvW = cv.bounds.size.width;
    CGFloat cvH = cv.bounds.size.height;

    NSRect barFrame = NSMakeRect(0, cvH - kTitlebarHeight, cvW, kTitlebarHeight);
    _titlebar = [[ScTitlebarView alloc] initWithFrame:barFrame];
    _titlebar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;

    [cv addSubview:_titlebar positioned:NSWindowAbove relativeTo:nil];
    [_titlebar adoptWindowButtons];
}

// ── event monitors ───────────────────────────────────────────────────────────

- (void)installMonitors {
    __weak ScHoverController *weak = self;

    NSEventMask mask = NSEventMaskMouseMoved
                     | NSEventMaskLeftMouseDragged
                     | NSEventMaskRightMouseDragged
                     | NSEventMaskOtherMouseDragged;

    // Local monitor fires inside our process regardless of SDL's firstResponder.
    // Return the event unchanged so SDL still processes it normally.
    _localMonitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:mask
                                     handler:^NSEvent *(NSEvent *e) {
        [weak evaluateCursor];
        return e;
    }];

    // Global monitor fires when the cursor is in another application.
    _globalMonitor = [NSEvent
        addGlobalMonitorForEventsMatchingMask:mask
                                      handler:^(NSEvent *__unused e) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weak setRevealed:NO];
        });
    }];
}

// ── proximity logic ───────────────────────────────────────────────────────────

// [NSEvent mouseLocation] gives screen-space coordinates, which are reliable
// regardless of SDL's internal view/window subclassing.
- (void)evaluateCursor {
    NSPoint cursor   = [NSEvent mouseLocation];
    NSRect  winFrame = _window.frame;

    if (!NSPointInRect(cursor, winFrame)) {
        [self setRevealed:NO];
        return;
    }

    // Distance from the top edge (screen Y increases upward)
    CGFloat fromTop = NSMaxY(winFrame) - cursor.y;
    [self setRevealed:(fromTop <= kHoverThreshold)];
}

- (void)setRevealed:(BOOL)reveal {
    if (reveal == _revealed) return;
    _revealed = reveal;
    if (reveal) {
        [_titlebar revealAnimated:YES];
    } else {
        [_titlebar hideAnimated:YES];
    }
}

@end

// ─────────────────────────────────────────────────────────────────────────────
// C API  (called from screen.c after window is shown + Metal renderer exists)
// ─────────────────────────────────────────────────────────────────────────────

static NSWindow *get_nswindow(SDL_Window *sdl_window) {
    return (__bridge NSWindow *)
        SDL_GetPointerProperty(SDL_GetWindowProperties(sdl_window),
                               SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
}

void sc_macos_setup_hover_titlebar(SDL_Window *sdl_window) {
    NSWindow *w = get_nswindow(sdl_window);
    if (!w) return;

    // Round the SDL content view's Metal layer so the phone screen has
    // rounded corners that match the window shape.
    w.contentView.wantsLayer             = YES;
    w.contentView.layer.cornerRadius     = kCornerRadius;
    w.contentView.layer.masksToBounds    = YES;

    // Install the hover controller (self-retaining)
    (void)[[ScHoverController alloc] initWithNSWindow:w];
}
