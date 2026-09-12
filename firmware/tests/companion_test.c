// Test the actual firmware command handler, with only hardware APIs replaced.
#include "qmk_stub.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static uint32_t now;
static matrix_row_t rows[10];
static uint8_t reply[32];
static unsigned sends;
struct led_config g_led_config;
matrix_row_t matrix_get_row(uint8_t row) { return rows[row]; }
uint32_t timer_read32(void) { return now; }
uint32_t timer_elapsed32(uint32_t then) { return now - then; }
void rgb_matrix_enable_noeeprom(void) {}
void rgb_matrix_mode_noeeprom(uint8_t mode) { (void)mode; }
void rgb_matrix_sethsv_noeeprom(uint8_t h, uint8_t s, uint8_t v) { (void)h; (void)s; (void)v; }
void rgb_matrix_set_color(uint8_t i, uint8_t r, uint8_t g, uint8_t b) { (void)i; (void)r; (void)g; (void)b; }
RGB hsv_to_rgb(HSV hsv) { return (RGB){hsv.v, hsv.v, hsv.v}; }
void raw_hid_send(uint8_t *data, uint8_t length) { assert(length == 32); memcpy(reply, data, 32); ++sends; }
#include "../companion/keymap.c"

static uint8_t request[32];
static void command(uint8_t op) {
    memset(request, 0, sizeof(request)); memcpy(request, magic, 4);
    request[4] = 1; request[5] = op; request[6] = 123;
}
static void dispatch(void) {
    assert(c100_companion_receive(request, 32));
    assert(reply[5] == (request[5] | 0x80) && reply[6] == 123);
}
static void full_frame(uint8_t value) {
    for (int start = 0; start < 100; start += 7) {
        command(3); request[8] = start; request[9] = start > 93 ? 100-start : 7;
        for (int i = 0; i < request[9]; ++i) request[12+i*3] = value;
        dispatch(); assert(reply[7] == 0);
    }
}
int main(void) {
    keyboard_post_init_user();
    command(1); dispatch(); assert(reply[8] == 10 && reply[10] == 7 && !active);
    request[4] = 2; dispatch(); assert(reply[7] == 1 && !active);
    request[0] = 0; assert(!c100_companion_receive(request, 32));
    command(3); request[9] = 1; dispatch(); assert(reply[7] == 2);
    command(2); dispatch(); assert(active && reply[21] == 0);
    command(2); dispatch(); assert(reply[21] == 1);
    command(3); request[8] = 99; request[9] = 2; dispatch(); assert(reply[7] == 1);
    command(4); dispatch(); assert(reply[7] == 3);
    full_frame(31); assert(displayed[99].v == 0);
    command(4); dispatch(); assert(reply[7] == 0 && displayed[0].v == 31 && displayed[99].v == 31);
    command(4); dispatch(); assert(reply[7] == 3); // cannot recommit a consumed frame
    command(3); request[9] = 1; dispatch();
    command(4); dispatch(); assert(reply[7] == 3 && displayed[99].v == 31);
    full_frame(0); command(4); dispatch(); assert(displayed[0].v == 0 && displayed[99].v == 0);
    rows[0] = 1; rows[9] = 1 << 9; matrix_scan_user();
    assert(reply[5] == 0x40 && reply[8] == 1 && reply[20] == 8);
    unsigned before = sends; matrix_scan_user(); assert(sends == before);
    rows[0] = rows[9] = 0; matrix_scan_user(); assert(reply[8] == 0 && reply[20] == 0);
    full_frame(47); command(4); dispatch();
    now = 2999; matrix_scan_user(); assert(active && displayed[0].v == 47);
    now = 3000; matrix_scan_user(); assert(!active && displayed[0].v == 0);
    before = sends; rows[0] = 1; matrix_scan_user(); assert(sends == before);
    command(2); dispatch(); assert(reply[21] == 0 && reply[8] == 1);
    command(5); dispatch(); assert(!active);
    now = UINT32_MAX - 100; command(2); dispatch();
    now = 2900; matrix_scan_user(); assert(!active); // watchdog handles timer wrap
    puts("firmware tests passed: handshake, bounds, atomic frames, input, blackout, watchdog, timer wrap");
}
