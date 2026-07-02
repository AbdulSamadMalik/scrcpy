#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <SDL3/SDL.h>

#include "window.h"

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

static const CGFloat        kTitlebarHeight = SC_MACOS_TITLEBAR_HEIGHT;
static const CGFloat        kHoverThreshold = SC_MACOS_INSET_TOP + 10.0;
static const NSTimeInterval kAnimDur        = 0.25;

// Chrome corner radii (top is tighter than bottom, like iPhone Mirroring)
static const CGFloat kChromeTopRadius    = 25.0;
static const CGFloat kChromeBottomRadius = 70.0;

// Phone-body corner radius, proportional to the video width
// (64pt at 364pt wide in the iPhone Mirroring layout)
static const CGFloat kPhoneRadiusRatio = 64.0 / 364.0;

// Dark graphite gray, distinct from the phone's pure black body
#define CHROME_R 0.17
#define CHROME_G 0.17
#define CHROME_B 0.19

static const void *kScChromeKey = &kScChromeKey;

// Outer chrome shape: rounded rect with different top/bottom radii.
// Rect in view coordinates (origin bottom-left, y-up).
static CGPathRef
sc_create_chrome_path(CGRect r) {
    CGFloat minX = CGRectGetMinX(r), maxX = CGRectGetMaxX(r);
    CGFloat minY = CGRectGetMinY(r), maxY = CGRectGetMaxY(r);
    CGFloat topR = kChromeTopRadius;
    CGFloat botR = kChromeBottomRadius;

    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, minX + topR, maxY);
    CGPathAddLineToPoint(p, NULL, maxX - topR, maxY);
    CGPathAddArcToPoint(p, NULL, maxX, maxY, maxX, maxY - topR, topR);
    CGPathAddLineToPoint(p, NULL, maxX, minY + botR);
    CGPathAddArcToPoint(p, NULL, maxX, minY, maxX - botR, minY, botR);
    CGPathAddLineToPoint(p, NULL, minX + botR, minY);
    CGPathAddArcToPoint(p, NULL, minX, minY, minX, minY + botR, botR);
    CGPathAddLineToPoint(p, NULL, minX, maxY - topR);
    CGPathAddArcToPoint(p, NULL, minX, maxY, minX + topR, maxY, topR);
    CGPathCloseSubpath(p);
    return p;
}

// ─────────────────────────────────────────────────────────────────────────────
// ScChromeView — the framed background around the video (visual only)
// ─────────────────────────────────────────────────────────────────────────────

@interface ScChromeView : NSView
// Video rectangle in view coordinates (origin bottom-left)
@property (nonatomic, assign) CGRect videoRect;
@property (nonatomic, assign) BOOL rounded;
@end

@implementation ScChromeView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.wantsLayer = YES;
    self.alphaValue = 0.0;
    _videoRect = CGRectZero;
    _rounded = NO;
    return self;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = [NSGraphicsContext currentContext].CGContext;
    CGRect bounds = self.bounds;

    CGPathRef outer = sc_create_chrome_path(bounds);

    CGPathRef inner = NULL;
    if (!CGRectIsEmpty(_videoRect)) {
        CGFloat radius = _rounded ? _videoRect.size.width * kPhoneRadiusRatio
                                  : 0.0;
        inner = CGPathCreateWithRoundedRect(_videoRect, radius, radius, NULL);
    }

    // Fill the chrome everywhere except the video hole (even-odd rule),
    // so the (opaque) video is never covered
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, outer);
    if (inner) {
        CGContextAddPath(ctx, inner);
    }
    CGContextSetRGBFillColor(ctx, CHROME_R, CHROME_G, CHROME_B, 0.95);
    CGContextEOFillPath(ctx);
    CGContextRestoreGState(ctx);

    CGContextSetLineWidth(ctx, 1.0);

    // Outer border
    CGContextAddPath(ctx, outer);
    CGContextSetRGBStrokeColor(ctx, 1, 1, 1, 0.15);
    CGContextStrokePath(ctx);

    // Subtle border around the phone body
    if (inner) {
        CGContextAddPath(ctx, inner);
        CGContextSetRGBStrokeColor(ctx, 1, 1, 1, 0.10);
        CGContextStrokePath(ctx);
        CGPathRelease(inner);
    }

    CGPathRelease(outer);
}

// Purely visual: never intercept events, they must reach the SDL content
// view so pointer control of the device is unaffected
- (NSView *)hitTest:(NSPoint)pt {
    (void)pt;
    return nil;
}

@end

// ─────────────────────────────────────────────────────────────────────────────
// ScTitlebarView — the top bar with the native traffic-light buttons
// ─────────────────────────────────────────────────────────────────────────────

@interface ScTitlebarView : NSView
@property (nonatomic, assign) BOOL revealed;
@end

@implementation ScTitlebarView {
    NSTextField *_titleLabel;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.wantsLayer = YES;
    self.alphaValue = 0.0;
    _revealed = NO;

    // Centered window title (the chrome view behind provides the background)
    _titleLabel = [NSTextField labelWithString:@""];
    _titleLabel.font = [NSFont systemFontOfSize:13
                                         weight:NSFontWeightSemibold];
    _titleLabel.textColor = [NSColor colorWithWhite:1.0 alpha:0.7];
    _titleLabel.alignment = NSTextAlignmentCenter;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_titleLabel];

    return self;
}

- (void)setTitleText:(NSString *)title {
    _titleLabel.stringValue = title ?: @"";
    [self layoutTitleLabel];
}

- (void)layoutTitleLabel {
    [_titleLabel sizeToFit];
    NSRect f = _titleLabel.frame;
    // Keep clear of the traffic lights on both sides for symmetry
    CGFloat maxWidth = self.bounds.size.width - 2 * 90.0;
    f.size.width = MIN(f.size.width, MAX(maxWidth, 0));
    f.origin.x = floor((self.bounds.size.width - f.size.width) / 2.0);
    f.origin.y = floor((self.bounds.size.height - f.size.height) / 2.0);
    _titleLabel.frame = f;
    _titleLabel.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin;
}

// Place the real Cocoa traffic-light buttons inside our bar.
// Must be called after the window is on screen.
- (void)adoptWindowButtons {
    static const NSWindowButton kKinds[] = {
        NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton
    };
    CGFloat x = 16.0;
    for (NSUInteger i = 0; i < 3; i++) {
        NSButton *btn = [self.window standardWindowButton:kKinds[i]];
        if (!btn || btn.superview == self) continue;
        [btn removeFromSuperview];
        CGFloat y = floor((kTitlebarHeight - btn.frame.size.height) / 2.0);
        btn.frame = NSMakeRect(x, y, btn.frame.size.width,
                               btn.frame.size.height);
        [self addSubview:btn];
        x += btn.frame.size.width + 8.0;
    }
}

// ── hit testing ───────────────────────────────────────────────────────────────

// Invisible when hidden — events fall through to the SDL content view.
// Note that the bar only ever covers the reserved chrome area above the
// video, so even when revealed it never steals video/pointer events.
- (NSView *)hitTest:(NSPoint)pt {
    return _revealed ? [super hitTest:pt] : nil;
}

// The visible bar is a drag handle for the window
- (BOOL)mouseDownCanMoveWindow { return YES; }

@end

// ─────────────────────────────────────────────────────────────────────────────
// ScChromeController
// ─────────────────────────────────────────────────────────────────────────────

@interface ScChromeController : NSObject
- (instancetype)initWithSDLWindow:(SDL_Window *)sdlWindow
                         nsWindow:(NSWindow *)window;
- (void)updateVideoRectX:(CGFloat)x y:(CGFloat)y w:(CGFloat)w h:(CGFloat)h
                 rounded:(BOOL)rounded;
@end

@implementation ScChromeController {
    SDL_Window     *_sdlWindow;
    NSWindow       *_window;
    ScChromeView   *_chrome;
    ScTitlebarView *_titlebar;
    id              _localMonitor;
    id              _globalMonitor;
    BOOL            _revealed;
}

- (instancetype)initWithSDLWindow:(SDL_Window *)sdlWindow
                         nsWindow:(NSWindow *)window {
    self = [super init];
    if (!self) return nil;

    _sdlWindow = sdlWindow;
    _window    = window;
    _revealed  = NO;

    [self suppressNativeTitlebar];
    [self addOverlays];
    [self installMonitors];

    objc_setAssociatedObject(window, kScChromeKey, self,
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
    NSView *cv        = _window.contentView;
    id      responder = cv.nextResponder;
    _window.styleMask |= NSWindowStyleMaskFullSizeContentView;
    if (cv.nextResponder != responder) {
        cv.nextResponder = responder;
    }

    // Make the native title bar area fully transparent and remove its text.
    _window.titlebarAppearsTransparent = YES;
    _window.titleVisibility            = NSWindowTitleHidden;

    // Fully transparent window: outside the chrome/video, the desktop shows
    // through, so the video appears to float like iPhone Mirroring
    _window.opaque          = NO;
    _window.backgroundColor = [NSColor clearColor];
    _window.hasShadow       = YES;
}

// ── overlays ──────────────────────────────────────────────────────────────────

- (void)addOverlays {
    NSView *cv  = _window.contentView;
    CGFloat cvW = cv.bounds.size.width;
    CGFloat cvH = cv.bounds.size.height;

    // Chrome frame above the (masked, transparent-margin) SDL metal view;
    // the video area is punched out of it, so the video always shows through
    _chrome = [[ScChromeView alloc] initWithFrame:cv.bounds];
    _chrome.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [cv addSubview:_chrome positioned:NSWindowAbove relativeTo:nil];

    NSRect barFrame = NSMakeRect(0, cvH - kTitlebarHeight, cvW,
                                 kTitlebarHeight);
    _titlebar = [[ScTitlebarView alloc] initWithFrame:barFrame];
    _titlebar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [cv addSubview:_titlebar positioned:NSWindowAbove relativeTo:nil];

    [_titlebar adoptWindowButtons];
    [_titlebar setTitleText:_window.title];
}

// ── video rect / metal layer mask ─────────────────────────────────────────────

- (CALayer *)findMetalLayer {
    Class metalClass = NSClassFromString(@"CAMetalLayer");
    for (NSView *sub in _window.contentView.subviews) {
        if ([sub.layer isKindOfClass:metalClass]) {
            return sub.layer;
        }
    }
    return nil;
}

- (void)updateVideoRectX:(CGFloat)x y:(CGFloat)y w:(CGFloat)w h:(CGFloat)h
                 rounded:(BOOL)rounded {
    NSView *cv  = _window.contentView;
    CGFloat cvH = cv.bounds.size.height;

    // Convert from top-left origin (SDL) to bottom-left origin (AppKit)
    CGRect rect = CGRectMake(x, cvH - y - h, w, h);

    _chrome.videoRect = rect;
    _chrome.rounded   = rounded;
    [_chrome setNeedsDisplay:YES];

    // Mask the SDL metal layer so the video has phone-like rounded corners
    // and the margins around it (cleared with alpha 0) stay transparent
    CALayer *metalLayer = [self findMetalLayer];
    if (metalLayer) {
        metalLayer.opaque = NO;

        CAShapeLayer *mask = (CAShapeLayer *)metalLayer.mask;
        if (![mask isKindOfClass:[CAShapeLayer class]]) {
            mask = [CAShapeLayer layer];
            metalLayer.mask = mask;
        }

        CGFloat radius = rounded ? w * kPhoneRadiusRatio : 0.0;

        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        mask.frame = metalLayer.bounds;
        CGPathRef path = CGPathCreateWithRoundedRect(rect, radius, radius,
                                                     NULL);
        mask.path = path;
        CGPathRelease(path);
        [CATransaction commit];
    }

    // The opaque shape of the window changed
    [_window invalidateShadow];
}

// ── event monitors ───────────────────────────────────────────────────────────

- (void)installMonitors {
    __weak ScChromeController *weak = self;

    NSEventMask mask = NSEventMaskMouseMoved
                     | NSEventMaskLeftMouseDragged
                     | NSEventMaskRightMouseDragged
                     | NSEventMaskOtherMouseDragged;

    // Local monitor fires inside our process regardless of SDL's
    // firstResponder. The event is returned unchanged so SDL still processes
    // it normally: this never interferes with device pointer control.
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
    // While SDL captures the pointer (relative mouse mode, used to control
    // the device), never reveal the chrome: the cursor is hidden and all
    // pointer input belongs to the device
    if (SDL_GetWindowRelativeMouseMode(_sdlWindow)) {
        [self setRevealed:NO];
        return;
    }

    if (_window.styleMask & NSWindowStyleMaskFullScreen) {
        [self setRevealed:NO];
        return;
    }

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
    _titlebar.revealed = reveal;

    CGFloat alpha = reveal ? 1.0 : 0.0;
    NSString *curve = reveal ? kCAMediaTimingFunctionEaseOut
                             : kCAMediaTimingFunctionEaseIn;

    NSWindow *window = _window;
    ScChromeView *chrome = _chrome;
    ScTitlebarView *titlebar = _titlebar;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration       = kAnimDur;
        ctx.timingFunction = [CAMediaTimingFunction functionWithName:curve];
        chrome.animator.alphaValue   = alpha;
        titlebar.animator.alphaValue = alpha;
    } completionHandler:^{
        [window invalidateShadow];
    }];
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

    if (objc_getAssociatedObject(w, kScChromeKey)) {
        // Already installed
        return;
    }

    // Install the chrome controller (retained by the window)
    (void)[[ScChromeController alloc] initWithSDLWindow:sdl_window
                                               nsWindow:w];
}

void sc_macos_update_video_rect(SDL_Window *sdl_window, float x, float y,
                                float w, float h, bool rounded) {
    NSWindow *win = get_nswindow(sdl_window);
    if (!win) return;

    ScChromeController *controller =
        objc_getAssociatedObject(win, kScChromeKey);
    if (!controller) {
        // Not installed yet; the rect will be applied on the next update
        return;
    }

    [controller updateVideoRectX:x y:y w:w h:h rounded:rounded];
}
