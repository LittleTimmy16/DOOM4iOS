//
// doomlook.c
//
// Created by Anonym on 19.10.26
//
 
// doomlook.c
// Sends a horizontal "mouse" movement into Doom so finger-drag can turn the player.
// Kept in its own .c file so Doom's headers don't clash with UIKit.

#include <string.h>
#include "d_event.h"

void DoomLookPost(int dx)
{
    event_t ev;
    memset(&ev, 0, sizeof(ev));
    ev.type  = ev_mouse;
    ev.data1 = 0;     // no mouse buttons
    ev.data2 = dx;    // left/right movement
    ev.data3 = 0;     // no forward/back movement
    D_PostEvent(&ev);
}
