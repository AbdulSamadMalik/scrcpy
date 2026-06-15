#import <Cocoa/Cocoa.h>
#include <SDL3/SDL.h>

void sc_macos_set_window_corner_radius(SDL_Window *window, float radius) {
    // SDL3 exposes the native NSWindow via its properties API
    NSWindow *nswindow = (__bridge NSWindow *)
        SDL_GetPointerProperty(SDL_GetWindowProperties(window),
                               SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
    if (!nswindow) {
        return;
    }

    // corner radius lives on the contentView's layer
    nswindow.contentView.wantsLayer = YES;
    nswindow.contentView.layer.cornerRadius = radius;
    nswindow.contentView.layer.masksToBounds = YES;

    // make the window itself transparent so the rounded corners show
    nswindow.opaque = NO;
    nswindow.backgroundColor = [NSColor clearColor];
}