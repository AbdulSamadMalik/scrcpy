#ifndef SC_SYS_MACOS_WINDOW_H
#define SC_SYS_MACOS_WINDOW_H

#include <stdbool.h>
#include <SDL3/SDL.h>

// Layout of the iPhone-Mirroring-like chrome, in window points.
//
// The SDL window is enlarged by these insets, and the video content is
// rendered inset inside it, so the title bar never overlaps the video:
//
//   ┌────────────────────────────┐  ─┐
//   │         title bar          │   │ SC_MACOS_TITLEBAR_HEIGHT
//   ├────────────────────────────┤  ─┤
//   │  ┌──────────────────────┐  │   │ SC_MACOS_FRAME_PADDING
//   │  │                      │  │
//   │  │        video         │  │
//   │  │                      │  │
//   │  └──────────────────────┘  │
//   └────────────────────────────┘
#define SC_MACOS_TITLEBAR_HEIGHT 40
#define SC_MACOS_FRAME_PADDING 10
#define SC_MACOS_INSET_TOP (SC_MACOS_TITLEBAR_HEIGHT + SC_MACOS_FRAME_PADDING)
#define SC_MACOS_INSET_SIDE SC_MACOS_FRAME_PADDING

// Install the hover-to-reveal chrome (frame + title bar with the native
// traffic-light buttons).
// MUST be called after the window is shown and the SDL renderer is created,
// so the Metal layer exists before we add our NSView overlays on top of it.
void sc_macos_setup_hover_titlebar(SDL_Window *window);

// Inform the macOS chrome about the current video content rectangle.
// x and y are relative to the window's top-left corner, in points.
// If rounded is true, the video is masked with phone-like rounded corners.
void sc_macos_update_video_rect(SDL_Window *window, float x, float y,
                                float w, float h, bool rounded);

#endif
