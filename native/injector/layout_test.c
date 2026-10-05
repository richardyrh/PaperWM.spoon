#include "layout.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>

static bool near(double left, double right)
{
    return fabs(left - right) < 0.001;
}

int main(void)
{
    paperwm_layout_view_t view = {
        .display_x = 0, .display_y = 24,
        .display_w = 1920, .display_h = 1056,
        .virtual_viewport_w = 1920, .virtual_viewport_h = 1056,
        .gap_left = 16, .gap_right = 16,
        .gap_top = 0, .gap_bottom = 16,
        .edge_margin = 1,
    };
    paperwm_layout_window_t maximized = {
        .window_id = 10, .column = 0, .row = 0,
        .rows_in_column = 1, .x = 0, .y = 0,
        .w = 1920, .h = 1056,
    };
    paperwm_layout_frame_t left;
    assert(paperwm_layout_frame(&view, &maximized, &left));
    assert(near(left.x, 16) && near(left.w, 1888));
    assert(near(left.y, 24) && near(left.h, 1040));

    paperwm_layout_window_t neighbor = maximized;
    neighbor.window_id = 11;
    neighbor.column = 1;
    neighbor.x = 1920;
    paperwm_layout_frame_t right;
    assert(paperwm_layout_frame(&view, &neighbor, &right));
    assert(near(right.logical_x, 1920));
    assert(near(right.x, 1919));
    assert(right.x >= 0 && right.x < 1920);
    assert(left.x + left.w + view.gap_right <= right.logical_x);

    // Parking remains on this display even if the next display begins at x=1920.
    neighbor.x = 6000;
    assert(paperwm_layout_frame(&view, &neighbor, &right));
    assert(near(right.x, 1919));
    view.display_x = 1920;
    assert(paperwm_layout_frame(&view, &maximized, &left));
    assert(near(left.x, 1936));
    assert(left.x >= 1920);

    view.display_x = 0;
    maximized.rows_in_column = 2;
    maximized.h = 528;
    paperwm_layout_window_t lower = maximized;
    lower.window_id = 12;
    lower.row = 1;
    lower.y = 528;
    assert(paperwm_layout_frame(&view, &maximized, &left));
    assert(paperwm_layout_frame(&view, &lower, &right));
    assert(near(right.y - (left.y + left.h), 16));
    assert(near(right.y + right.h, view.display_y + view.display_h - 16));

    view.virtual_viewport_w = 0;
    assert(!paperwm_layout_frame(&view, &maximized, &left));
    puts("layout geometry: 7 checks passed");
    return 0;
}
