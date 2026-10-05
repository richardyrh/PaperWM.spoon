#ifndef PAPERWM_LAYOUT_H
#define PAPERWM_LAYOUT_H

#include <stdbool.h>
#include <stdint.h>

// Lua sends gapless rectangles in one Space-local coordinate system. The
// backend alone inserts presentation gaps and display-local edge parking.
typedef struct paperwm_layout_view {
    double display_x;
    double display_y;
    double display_w;
    double display_h;
    double virtual_viewport_w;
    double virtual_viewport_h;
    double scroll_x;
    double gap_left;
    double gap_right;
    double gap_top;
    double gap_bottom;
    double edge_margin;
} paperwm_layout_view_t;

typedef struct paperwm_layout_window {
    uint32_t window_id;
    uint32_t column;
    uint32_t row;
    uint32_t rows_in_column;
    double x;
    double y;
    double w;
    double h;
} paperwm_layout_window_t;

typedef struct paperwm_layout_frame {
    uint32_t window_id;
    double x;
    double y;
    double w;
    double h;
    double logical_x;
} paperwm_layout_frame_t;

bool paperwm_layout_frame(const paperwm_layout_view_t *view,
                          const paperwm_layout_window_t *window,
                          paperwm_layout_frame_t *frame);

#endif
