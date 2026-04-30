#ifndef TerminalSupport_h
#define TerminalSupport_h

#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/types.h>

#include <ghostty/vt.h>

typedef struct {
    int pty_fd;
    uint16_t cols;
    uint16_t rows;
    uint32_t cell_width;
    uint32_t cell_height;
} ADBTerminalEffects;

int adb_pty_spawn(uint16_t cols, uint16_t rows,
                  uint32_t cell_width, uint32_t cell_height,
                  pid_t *child_out);

void adb_pty_write(int pty_fd, const void *data, size_t len);

void adb_pty_resize(int pty_fd, uint16_t cols, uint16_t rows,
                    uint32_t cell_width, uint32_t cell_height);

void adb_pty_close_child(int pty_fd, pid_t child);

void adb_install_terminal_effects(GhosttyTerminal terminal,
                                  ADBTerminalEffects *ctx);

#endif
