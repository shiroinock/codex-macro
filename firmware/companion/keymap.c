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
    uint8_t keys[13];
    key_bitmap(keys);
    if (memcmp(keys, last_keys, sizeof(keys))) {
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
