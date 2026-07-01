#ifndef SC_SYS_MACOS_WINDOW_H
#define SC_SYS_MACOS_WINDOW_H

#include <SDL3/SDL.h>

// Install the hover-to-reveal title bar overlay with rounded corners.
// MUST be called after the window is shown and the SDL renderer is created,
// so the Metal layer exists before we add our NSView overlay on top of it.
void sc_macos_setup_hover_titlebar(SDL_Window *window);

#endif
