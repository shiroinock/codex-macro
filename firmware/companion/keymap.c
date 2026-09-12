// SPDX-License-Identifier: GPL-2.0-or-later
// Dedicated C100 task controller. Normal keyboard output is suppressed even
// without a host. Hold K00 while reconnecting USB to enter the ROM bootloader.
#include QMK_KEYBOARD_H
#include "raw_hid.h"
#include <string.h>

const uint16_t PROGMEM keymaps[][MATRIX_ROWS][MATRIX_COLS] = { [0] = {{KC_NO}} };
_Static_assert(MATRIX_ROWS == 10 && MATRIX_COLS == 10, "C100 only");
_Static_assert(RGB_MATRIX_LED_COUNT == 100, "C100 LED count");

static const uint8_t magic[4] = {0xC9, 0x43, 0x31, 0x30};
static HSV displayed[100], staging[100];
static uint8_t staged[13], last_keys[13], event_sequence;
static uint32_t last_contact;
static bool active;
typedef struct { uint8_t mods, key; } shortcut_t;
static shortcut_t shortcuts[100], pending[8];
static uint8_t pending_head, pending_count;
static bool tapping;
static uint32_t tap_time, press_time[100];
static uint8_t press_tickets[100];

static void cancel_output(bool forget) {
    clear_keyboard();
    tapping = false; pending_count = pending_head = 0;
    memset(press_tickets, 0, sizeof(press_tickets));
    tap_time = timer_read32();
    if (forget) memset(shortcuts, 0, sizeof(shortcuts));
}

static void service_output(void) {
    if (tapping && timer_elapsed32(tap_time) >= 20) {
        clear_keyboard(); tapping = false; tap_time = timer_read32();
    } else if (!tapping && pending_count && timer_elapsed32(tap_time) >= 5) {
        shortcut_t shortcut = pending[pending_head];
        pending_head = (pending_head + 1) % 8; --pending_count;
        register_mods(shortcut.mods);
        register_code(shortcut.key);
        tapping = true; tap_time = timer_read32();
    }
}

static void key_bitmap(uint8_t *out) {
    memset(out, 0, 13);
    for (uint8_t row = 0; row < 10; ++row) {
        matrix_row_t bits = matrix_get_row(row);
        for (uint8_t col = 0; col < 10; ++col) {
            uint8_t index = row * 10 + col;
            if (bits & ((matrix_row_t)1 << col)) out[index / 8] |= 1 << (index % 8);
        }
    }
}

static void clear_display(void) {
    active = false;
    cancel_output(true);
    memset(displayed, 0, sizeof(displayed));
    memset(staging, 0, sizeof(staging));
    memset(staged, 0, sizeof(staged));
}

// Called before Keychron/VIA command dispatch by the small, guarded build patch.
bool c100_companion_receive(uint8_t *data, uint8_t length) {
    if (length != 32 || memcmp(data, magic, 4)) return false;
    uint8_t command = data[5];
    uint8_t response[32] = {0};
    memcpy(response, magic, 4);
    response[4] = 1; response[5] = command | 0x80; response[6] = data[6];
    if (data[4] != 1 || data[7] != 0) {
        response[7] = 1;
    } else {
        if (active && timer_elapsed32(last_contact) >= 3000) clear_display();
        switch (command) {
            case 1: // capabilities; read-only, does not acquire control
                response[8] = 10; response[9] = 10;
                response[10] = 7; response[11] = 3;
                response[12] = 1; // optional keyboard-output protocol v1
                break;
            case 2: // heartbeat + full input snapshot
                response[21] = active;
                active = true;
                last_contact = timer_read32();
                key_bitmap(response + 8);
                break;
            case 3: { // stage HSV chunk, at most seven keys
                uint8_t start = data[8], count = data[9];
                if (!active) { response[7] = 2; break; }
                if (!count || count > 7 || start >= 100 || start + count > 100) {
                    response[7] = 1; break;
                }
                // A frame always starts at key zero. Never commit a partial
                // frame left behind by a failed transfer or former process.
                if (start == 0) memset(staged, 0, sizeof(staged));
                for (uint8_t i = 0; i < count; ++i) {
                    staging[start+i] = (HSV){data[10+i*3], data[11+i*3], data[12+i*3]};
                    staged[(start+i)/8] |= 1 << ((start+i)%8);
                }
                last_contact = timer_read32();
                break;
            }
            case 4: // atomic frame commit, including true V=0 blackout
                if (!active) { response[7] = 2; break; }
                for (uint8_t i = 0; i < 100; ++i) {
                    if (!(staged[i/8] & (1 << (i%8)))) { response[7] = 3; break; }
                }
                if (!response[7]) {
                    memcpy(displayed, staging, sizeof(displayed));
                    memset(staged, 0, sizeof(staged));
                    last_contact = timer_read32();
                }
                break;
            case 5:
                clear_display();
                break;
            case 6: { // configure one RAM shortcut: index, USB modifiers, usage
                uint8_t index = data[8], mods = data[9], key = data[10];
                if (!active) { response[7] = 2; break; }
                if (index >= 100 || (key && (key < 4 || key > 0x73)) || (!key && mods)) { response[7] = 1; break; }
                shortcuts[index] = (shortcut_t){mods, key};
                break;
            }
            case 7: { // host authorizes a tap after checking foreground app
                uint8_t index = data[8];
                if (!active) { response[7] = 2; break; }
                if (index >= 100 || !shortcuts[index].key) { response[7] = 1; break; }
                if (pending_count == 8) { response[7] = 4; break; }
                if (!press_tickets[index] || timer_elapsed32(press_time[index]) > 500) { response[7] = 5; break; }
                --press_tickets[index];
                pending[(pending_head + pending_count) % 8] = shortcuts[index];
                ++pending_count;
                break;
            }
            case 8: // revoke queued/held output and forget all assignments
                cancel_output(true);
                break;
            default:
                response[7] = 1;
        }
    }
    raw_hid_send(response, sizeof(response));
    return true;
}

void keyboard_post_init_user(void) {
    clear_display();
    rgb_matrix_enable_noeeprom();
    rgb_matrix_mode_noeeprom(RGB_MATRIX_SOLID_COLOR);
    rgb_matrix_sethsv_noeeprom(0, 0, 0);
    key_bitmap(last_keys);
}

void matrix_scan_user(void) {
    if (active && timer_elapsed32(last_contact) >= 3000) clear_display();
    if (active) service_output();
    uint8_t keys[13];
    key_bitmap(keys);
    if (memcmp(keys, last_keys, sizeof(keys))) {
        if (active) for (uint8_t index = 0; index < 100; ++index) {
            uint8_t bit = 1 << (index % 8);
            if ((keys[index/8] & bit) && !(last_keys[index/8] & bit)) {
                if (timer_elapsed32(press_time[index]) > 500) press_tickets[index] = 0;
                if (press_tickets[index] < 8) ++press_tickets[index];
                press_time[index] = timer_read32();
            }
        }
        memcpy(last_keys, keys, sizeof(keys));
        if (active) {
            uint8_t packet[32] = {0};
            memcpy(packet, magic, 4);
            packet[4] = 1; packet[5] = 0x40; packet[6] = ++event_sequence;
            memcpy(packet + 8, keys, sizeof(keys));
            raw_hid_send(packet, sizeof(packet));
        }
    }
}

bool rgb_matrix_indicators_user(void) {
    for (uint8_t row = 0; row < 10; ++row) {
        for (uint8_t col = 0; col < 10; ++col) {
            uint8_t led = g_led_config.matrix_co[row][col];
            if (led == NO_LED) continue;
            RGB color = hsv_to_rgb(displayed[row * 10 + col]);
            rgb_matrix_set_color(led, color.r, color.g, color.b);
        }
    }
    return false;
}

void suspend_power_down_user(void) { clear_display(); }
