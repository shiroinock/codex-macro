#pragma once
#include <stdbool.h>
#include <stdint.h>
#define PROGMEM
#define MATRIX_ROWS 10
#define MATRIX_COLS 10
#define RGB_MATRIX_LED_COUNT 100
#define KC_NO 0
#define NO_LED 255
#define RGB_MATRIX_SOLID_COLOR 1
#define QMK_KEYBOARD_H "qmk_stub.h"
typedef uint16_t matrix_row_t;
typedef struct { uint8_t h, s, v; } HSV;
typedef struct { uint8_t r, g, b; } RGB;
extern struct led_config { uint8_t matrix_co[10][10]; } g_led_config;
matrix_row_t matrix_get_row(uint8_t row);
uint32_t timer_read32(void);
uint32_t timer_elapsed32(uint32_t then);
void rgb_matrix_enable_noeeprom(void);
void rgb_matrix_mode_noeeprom(uint8_t mode);
void rgb_matrix_sethsv_noeeprom(uint8_t h, uint8_t s, uint8_t v);
void rgb_matrix_set_color(uint8_t index, uint8_t r, uint8_t g, uint8_t b);
RGB hsv_to_rgb(HSV color);

void clear_keyboard(void);
void register_mods(uint8_t mods);
void register_code(uint8_t key);
