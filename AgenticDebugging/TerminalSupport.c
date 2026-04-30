#include "TerminalSupport.h"

#include <fcntl.h>
#include <pwd.h>
#include <signal.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <util.h>
#else
#include <pty.h>
#endif

int adb_pty_spawn(uint16_t cols, uint16_t rows,
                  uint32_t cell_width, uint32_t cell_height,
                  pid_t *child_out)
{
    int pty_fd = -1;
    struct winsize ws = {
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = (unsigned short)(cols * cell_width),
        .ws_ypixel = (unsigned short)(rows * cell_height),
    };

    pid_t child = forkpty(&pty_fd, NULL, NULL, &ws);
    if (child < 0) return -1;

    if (child == 0) {
        const char *shell = getenv("SHELL");
        if (!shell || shell[0] == '\0') {
            struct passwd *pw = getpwuid(getuid());
            shell = (pw && pw->pw_shell && pw->pw_shell[0] != '\0')
                ? pw->pw_shell
                : "/bin/sh";
        }

        const char *shell_name = strrchr(shell, '/');
        shell_name = shell_name ? shell_name + 1 : shell;

        setenv("TERM", "xterm-256color", 1);
        execl(shell, shell_name, NULL);
        _exit(127);
    }

    int flags = fcntl(pty_fd, F_GETFL);
    if (flags < 0 || fcntl(pty_fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        close(pty_fd);
        return -1;
    }

    *child_out = child;
    return pty_fd;
}

void adb_pty_write(int pty_fd, const void *data, size_t len)
{
    const uint8_t *ptr = (const uint8_t *)data;
    while (len > 0) {
        ssize_t written = write(pty_fd, ptr, len);
        if (written > 0) {
            ptr += written;
            len -= (size_t)written;
        } else if (written < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
}

void adb_pty_resize(int pty_fd, uint16_t cols, uint16_t rows,
                    uint32_t cell_width, uint32_t cell_height)
{
    struct winsize ws = {
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = (unsigned short)(cols * cell_width),
        .ws_ypixel = (unsigned short)(rows * cell_height),
    };
    ioctl(pty_fd, TIOCSWINSZ, &ws);
}

void adb_pty_close_child(int pty_fd, pid_t child)
{
    if (pty_fd >= 0) close(pty_fd);
    if (child > 0) {
        kill(child, SIGHUP);
        waitpid(child, NULL, WNOHANG);
    }
}

static void adb_effect_write_pty(GhosttyTerminal terminal, void *userdata,
                                 const uint8_t *data, size_t len)
{
    (void)terminal;
    ADBTerminalEffects *ctx = (ADBTerminalEffects *)userdata;
    if (ctx) adb_pty_write(ctx->pty_fd, data, len);
}

static bool adb_effect_size(GhosttyTerminal terminal, void *userdata,
                            GhosttySizeReportSize *out_size)
{
    (void)terminal;
    ADBTerminalEffects *ctx = (ADBTerminalEffects *)userdata;
    if (!ctx || !out_size) return false;

    out_size->rows = ctx->rows;
    out_size->columns = ctx->cols;
    out_size->cell_width = ctx->cell_width;
    out_size->cell_height = ctx->cell_height;
    return true;
}

static bool adb_effect_device_attributes(GhosttyTerminal terminal,
                                         void *userdata,
                                         GhosttyDeviceAttributes *out_attrs)
{
    (void)terminal;
    (void)userdata;
    if (!out_attrs) return false;

    memset(out_attrs, 0, sizeof(*out_attrs));
    out_attrs->primary.conformance_level = GHOSTTY_DA_CONFORMANCE_VT220;
    out_attrs->primary.features[0] = GHOSTTY_DA_FEATURE_COLUMNS_132;
    out_attrs->primary.features[1] = GHOSTTY_DA_FEATURE_SELECTIVE_ERASE;
    out_attrs->primary.features[2] = GHOSTTY_DA_FEATURE_ANSI_COLOR;
    out_attrs->primary.num_features = 3;
    out_attrs->secondary.device_type = GHOSTTY_DA_DEVICE_TYPE_VT220;
    out_attrs->secondary.firmware_version = 1;
    out_attrs->secondary.rom_cartridge = 0;
    out_attrs->tertiary.unit_id = 0;
    return true;
}

static GhosttyString adb_effect_xtversion(GhosttyTerminal terminal,
                                          void *userdata)
{
    (void)terminal;
    (void)userdata;
    static const uint8_t name[] = "AgenticDebugging";
    return (GhosttyString){ .ptr = name, .len = sizeof(name) - 1 };
}

void adb_install_terminal_effects(GhosttyTerminal terminal,
                                  ADBTerminalEffects *ctx)
{
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, ctx);
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                         (const void *)adb_effect_write_pty);
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SIZE,
                         (const void *)adb_effect_size);
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES,
                         (const void *)adb_effect_device_attributes);
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_XTVERSION,
                         (const void *)adb_effect_xtversion);
}
