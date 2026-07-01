#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <SDL3/SDL.h>

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

static const CGFloat      kTitlebarHeight = 40.0;
static const CGFloat      kHoverThreshold = 44.0;  // px from top edge
static const NSTimeInterval kAnimDur      = 0.20;
static const CGFloat      kCornerRadius   = 12.0;

// ─────────────────────────────────────────────────────────────────────────────
// ScTitlebarView
// ─────────────────────────────────────────────────────────────────────────────

@interface ScTitlebarView : NSView
- (void)revealAnimated:(BOOL)animated;
- (void)hideAnimated:(BOOL)animated;
@property (nonatomic, readonly) BOOL titlebarVisible;
@end

@implementation ScTitlebarView {
    BOOL _visible;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.wantsLayer = YES;
    self.layer.backgroundColor = [NSColor clearColor].CGColor;

    // Vibrancy blur — same material Apple uses for system title bars
    NSVisualEffectView *blur = [[NSVisualEffectView alloc]
                                initWithFrame:self.bounds];
    blur.autoresizingMask  = NSViewWidthSizable | NSViewHeightSizable;
    blur.material          = NSVisualEffectMaterialTitlebar;
    blur.blendingMode      = NSVisualEffectBlendingModeWithinWindow;
    blur.state             = NSVisualEffectStateActive;
    blur.wantsLayer        = YES;
    blur.layer.cornerRadius      = kCornerRadius;
    blur.layer.maskedCorners     = kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    blur.layer.masksToBounds     = YES;
    [self addSubview:blur];

    // Start invisible
    self.alphaValue = 0.0;
    _visible = NO;

    return self;
}

// Reparent the real Cocoa traffic-light buttons into our view.
// Called by ScHoverController after the window is fully shown so the
// buttons actually exist on the borderless window.
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

- (void)revealAnimated:(BOOL)animated {
    if (_visible) return;
    _visible = YES;
    [self setAlpha:1.0 timing:kCAMediaTimingFunctionEaseOut animated:animated];
}

- (void)hideAnimated:(BOOL)animated {
    if (!_visible) return;
    _visible = NO;
    [self setAlpha:0.0 timing:kCAMediaTimingFunctionEaseIn animated:animated];
}

- (void)setAlpha:(CGFloat)alpha timing:(NSString *)timing animated:(BOOL)anim {
    if (!anim) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.alphaValue = alpha;
        self.layer.opacity = (float)alpha;
        [CATransaction commit];
        return;
    }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration       = kAnimDur;
        ctx.timingFunction = [CAMediaTimingFunction functionWithName:timing];
        self.animator.alphaValue = alpha;
    }];
}

// ── hit testing ───────────────────────────────────────────────────────────────

// When hidden, pass all hits through to the SDL Metal view below us.
- (NSView *)hitTest:(NSPoint)point {
    return _visible ? [super hitTest:point] : nil;
}

// Allow dragging the window by clicking anywhere on the visible bar.
- (BOOL)mouseDownCanMoveWindow { return YES; }

- (BOOL)titlebarVisible { return _visible; }

@end

// ─────────────────────────────────────────────────────────────────────────────
// ScHoverController
// ─────────────────────────────────────────────────────────────────────────────

@interface ScHoverController : NSObject
- (instancetype)initWithNSWindow:(NSWindow *)window;
@end

@implementation ScHoverController {
    NSWindow        *_window;
    ScTitlebarView  *_titlebar;
    id               _localMonitor;
    id               _globalMonitor;
    BOOL             _titlebarVisible;
}

- (instancetype)initWithNSWindow:(NSWindow *)window {
    self = [super init];
    if (!self) return nil;

    _window          = window;
    _titlebarVisible = NO;

    [self addTitlebar];
    [self installMonitors];

    // Self-retain for the lifetime of the window
    objc_setAssociatedObject(window, (__bridge void *)self, self,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return self;
}

- (void)dealloc {
    if (_localMonitor)  [NSEvent removeMonitor:_localMonitor];
    if (_globalMonitor) [NSEvent removeMonitor:_globalMonitor];
}

// ── setup ─────────────────────────────────────────────────────────────────────

- (void)addTitlebar {
    // The Metal layer (SDL renderer) is the content view's layer, not a
    // subview — so we can safely add our NSView overlay on top.
    NSView *cv  = _window.contentView;
    CGFloat cvH = cv.bounds.size.height;
    CGFloat cvW = cv.bounds.size.width;

    NSRect frame = NSMakeRect(0, cvH - kTitlebarHeight, cvW, kTitlebarHeight);
    _titlebar = [[ScTitlebarView alloc] initWithFrame:frame];
    _titlebar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;

    // addSubview:positioned:relativeTo: puts it in front of all SDL sublayers
    [cv addSubview:_titlebar positioned:NSWindowAbove relativeTo:nil];

    // Reparent the real traffic-light buttons now that the window is visible
    [_titlebar adoptWindowButtons];
}

- (void)installMonitors {
    __weak ScHoverController *weak = self;

    // NSEventMask covering all cursor movement (including during drags)
    NSEventMask mask = NSEventMaskMouseMoved
                     | NSEventMaskLeftMouseDragged
                     | NSEventMaskRightMouseDragged
                     | NSEventMaskOtherMouseDragged;

    // LOCAL monitor — fires inside our process regardless of firstResponder.
    // We return the event unchanged so SDL still receives it.
    _localMonitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:mask
                                     handler:^NSEvent *(NSEvent *e) {
        [weak evaluateCursor];
        return e;
    }];

    // GLOBAL monitor — fires when cursor is in a different application.
    _globalMonitor = [NSEvent
        addGlobalMonitorForEventsMatchingMask:mask
                                      handler:^(NSEvent *__unused e) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weak setVisible:NO];
        });
    }];
}

// ── core logic ────────────────────────────────────────────────────────────────

// Use [NSEvent mouseLocation] (screen-space) instead of event.locationInWindow
// because event.window can be nil or a different SDL-private NSWindow subclass.
- (void)evaluateCursor {
    NSPoint cursor     = [NSEvent mouseLocation];  // screen coords, Y up
    NSRect  winFrame   = _window.frame;            // screen coords

    if (!NSPointInRect(cursor, winFrame)) {
        [self setVisible:NO];
        return;
    }

    // Distance from the TOP of the window (screen Y increases upward)
    CGFloat fromTop = NSMaxY(winFrame) - cursor.y;
    [self setVisible:(fromTop <= kHoverThreshold)];
}

- (void)setVisible:(BOOL)visible {
    if (visible == _titlebarVisible) return;
    _titlebarVisible = visible;
    if (visible) {
        [_titlebar revealAnimated:YES];
    } else {
        [_titlebar hideAnimated:YES];
    }
}

@end

// ─────────────────────────────────────────────────────────────────────────────
// C API
// ─────────────────────────────────────────────────────────────────────────────

static NSWindow *get_nswindow(SDL_Window *sdl_window) {
    return (__bridge NSWindow *)
        SDL_GetPointerProperty(SDL_GetWindowProperties(sdl_window),
                               SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
}

// Called once, AFTER the window has been shown and the Metal renderer created.
// Do NOT call this during sc_screen_init — the Metal layer isn't set up yet.
void sc_macos_setup_hover_titlebar(SDL_Window *sdl_window) {
    NSWindow *w = get_nswindow(sdl_window);
    if (!w) return;

    // Apply corner radius to the SDL content view's backing layer.
    // SDL's Metal renderer uses a CAMetalLayer as the view's layer, so
    // masksToBounds here clips the rendered content to the rounded rect.
    w.contentView.wantsLayer = YES;
    w.contentView.layer.cornerRadius    = kCornerRadius;
    w.contentView.layer.masksToBounds   = YES;

    // Transparent window background so the rounded corners are visible
    w.opaque            = NO;
    w.backgroundColor   = [NSColor clearColor];

    // NOTE: We do NOT touch styleMask here — SDL owns it and touching it
    // breaks its internal listener/responder chain setup.

    // Install the hover overlay (self-retaining via associated object)
    (void)[[ScHoverController alloc] initWithNSWindow:w];
}
