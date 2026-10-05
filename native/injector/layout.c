#include "layout.h"

#include <math.h>

static double clamp(double value, double minimum, double maximum)
{
    return fmax(minimum, fmin(value, maximum));
}

bool paperwm_layout_frame(const paperwm_layout_view_t *view,
                          const paperwm_layout_window_t *window,
                          paperwm_layout_frame_t *frame)
{
    if (!view || !window || !frame || !window->window_id ||
        !isfinite(view->display_x) || !isfinite(view->display_y) ||
        !isfinite(view->display_w) || !isfinite(view->display_h) ||
        !isfinite(view->virtual_viewport_w) ||
        !isfinite(view->virtual_viewport_h) ||
        !isfinite(view->scroll_x) ||
        !isfinite(view->gap_left) || !isfinite(view->gap_right) ||
        !isfinite(view->gap_top) || !isfinite(view->gap_bottom) ||
        !isfinite(view->edge_margin) ||
        !isfinite(window->x) || !isfinite(window->y) ||
        !isfinite(window->w) || !isfinite(window->h) ||
        view->display_w <= 0 || view->display_h <= 0 ||
        view->virtual_viewport_w <= 0 ||
        view->virtual_viewport_h <= 0 ||
        view->gap_left < 0 || view->gap_right < 0 ||
        view->gap_top < 0 || view->gap_bottom < 0 ||
        view->edge_margin < 0 ||
        window->w <= 0 || window->h <= 0 ||
        window->rows_in_column == 0 ||
        window->row >= window->rows_in_column) return false;

    double canvas_w = view->display_w - view->gap_left - view->gap_right;
    double column_h = view->display_h - view->gap_top -
        view->gap_bottom * window->rows_in_column;
    if (canvas_w <= 0 || column_h <= 0) return false;

    double sx = canvas_w / view->virtual_viewport_w;
    double sy = column_h / view->virtual_viewport_h;
    double logical_x = view->display_x + view->gap_left +
        (window->x - view->scroll_x) * sx +
        window->column * view->gap_right;
    double width = window->w * sx;
    double screen_left = view->display_x + view->edge_margin;
    double screen_right = view->display_x + view->display_w -
        view->edge_margin;
    if (screen_right < screen_left) return false;

    *frame = (paperwm_layout_frame_t) {
        .window_id = window->window_id,
        .x = clamp(logical_x, screen_left - width, screen_right),
        .y = view->display_y + view->gap_top + window->y * sy +
            window->row * view->gap_bottom,
        .w = width,
        .h = window->h * sy,
        .logical_x = logical_x,
    };
    return isfinite(frame->x) && isfinite(frame->y) &&
        isfinite(frame->w) && isfinite(frame->h);
}
