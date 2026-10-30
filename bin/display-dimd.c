// display-dimd: hyprsunset, plus a brightness for each display.
//
// Hyprland lets one program set each output's colour matrix; hyprsunset uses
// it for night light (a warmer white) and its gamma, the same on every
// display. This takes its place: the matrix for each output is night light's
// colour times hyprsunset's gamma times that output's own brightness, from
// $XDG_STATE_HOME/display-dim/<output> (a percent; none: 100). SIGHUP rereads
// them (bin/display-dim writes them and sends it).
//
// It answers hyprsunset's socket ($XDG_RUNTIME_DIR/hypr/<instance>/
// .hyprsunset.sock) as hyprsunset does, so `hyprctl hyprsunset temperature
// 4000`, `gamma 80`, `identity` and `reset` work, and goes by its name, so
// Omarchy's night light finds it running. ~/.config/hypr/hyprsunset.conf's
// profiles (time, temperature, gamma, identity) are followed, a change by
// hand lasting until the next one starts.

#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/signalfd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include "hyprland-ctm-control-v1-client-protocol.h"

struct output {
  struct wl_output *wl;
  uint32_t global;
  char name[64];
  struct output *next;
};

struct profile {
  int minute;  // of the day
  int temperature;
  int gamma;  // percent
  int identity;
};

static struct hyprland_ctm_control_manager_v1 *manager;
static struct output *outputs;
static char state_dir[512];
static int blocked;

// What hyprsunset holds: night light's temperature, its gamma, and whether
// it's off (identity).
static int temperature = 6000;
static int gamma_percent = 100;
static int identity = 0;

static struct profile profiles[32];
static int profile_count;
static int current_profile = -1;

static int level_of(const char *name) {
  char path[640];
  snprintf(path, sizeof path, "%s/%s", state_dir, name);
  FILE *f = fopen(path, "r");
  if (!f) return 100;
  int level = 100;
  if (fscanf(f, "%d", &level) != 1) level = 100;
  fclose(f);
  if (level < 10) level = 10;
  if (level > 100) level = 100;
  return level;
}

// hyprsunset's colour for a temperature in kelvin (Tanner Helland's fit).
static void kelvin(int k, double rgb[3]) {
  double t = k / 100.0;
  double r, g, b;
  if (t <= 66) {
    r = 255;
    g = 99.4708025861 * log(t) - 161.1195681661;
    b = t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307;
  } else {
    r = 329.698727446 * pow(t - 60, -0.1332047592);
    g = 288.1221695283 * pow(t - 60, -0.0755148492);
    b = 255;
  }
  double c[3] = { r, g, b };
  for (int i = 0; i < 3; i++) {
    if (c[i] < 0) c[i] = 0;
    if (c[i] > 255) c[i] = 255;
    rgb[i] = c[i] / 255.0;
  }
}

static void apply_all(void) {
  if (!manager || blocked) return;
  double rgb[3] = { 1, 1, 1 };
  if (!identity) kelvin(temperature, rgb);
  for (struct output *o = outputs; o; o = o->next) {
    if (!o->name[0]) continue;
    double s = gamma_percent / 100.0 * level_of(o->name) / 100.0;
    wl_fixed_t z = wl_fixed_from_double(0);
    hyprland_ctm_control_manager_v1_set_ctm_for_output(manager, o->wl,
        wl_fixed_from_double(rgb[0] * s), z, z,
        z, wl_fixed_from_double(rgb[1] * s), z,
        z, z, wl_fixed_from_double(rgb[2] * s));
  }
  hyprland_ctm_control_manager_v1_commit(manager);
}

// Profiles ---------------------------------------------------------------------

static void read_profiles(void) {
  char path[600];
  snprintf(path, sizeof path, "%s/.config/hypr/hyprsunset.conf", getenv("HOME"));
  FILE *f = fopen(path, "r");
  profile_count = 0;
  if (!f) return;
  char line[256];
  struct profile *p = NULL;
  while (fgets(line, sizeof line, f)) {
    char *s = line;
    while (isspace((unsigned char)*s)) s++;
    if (*s == '#' || !*s) continue;
    if (!strncmp(s, "profile", 7) && strchr(s, '{')) {
      if (profile_count < 32) {
        p = &profiles[profile_count++];
        *p = (struct profile){ .minute = 0, .temperature = 6000, .gamma = 100, .identity = 0 };
      }
      continue;
    }
    if (*s == '}') {
      p = NULL;
      continue;
    }
    if (!p) continue;
    char key[32], value[64];
    if (sscanf(s, "%31[a-z_] = %63s", key, value) != 2) continue;
    if (!strcmp(key, "time")) {
      int h = 0, m = 0;
      if (sscanf(value, "%d:%d", &h, &m) == 2) p->minute = h * 60 + m;
    } else if (!strcmp(key, "temperature")) {
      p->temperature = atoi(value);
    } else if (!strcmp(key, "gamma")) {
      // hyprsunset's profiles give gamma as a fraction (0.8) or a percent.
      double g = atof(value);
      p->gamma = g <= 2.0 ? (int)lround(g * 100) : (int)lround(g);
    } else if (!strcmp(key, "identity")) {
      p->identity = !strcmp(value, "true") || !strcmp(value, "1");
    }
  }
  fclose(f);
}

static int minute_now(void) {
  time_t t = time(NULL);
  struct tm tm;
  localtime_r(&t, &tm);
  return tm.tm_hour * 60 + tm.tm_min;
}

// The profile in force now: the last to start at or before now (yesterday's
// last before the first of today).
static int active_profile(void) {
  if (profile_count == 0) return -1;
  int now = minute_now(), best = -1, latest = -1;
  for (int i = 0; i < profile_count; i++) {
    if (profiles[i].minute <= now && (best < 0 || profiles[i].minute > profiles[best].minute)) best = i;
    if (latest < 0 || profiles[i].minute > profiles[latest].minute) latest = i;
  }
  return best >= 0 ? best : latest;
}

static void use_profile(int i) {
  current_profile = i;
  if (i < 0) {
    temperature = 6000;
    gamma_percent = 100;
    identity = 0;
    return;
  }
  identity = profiles[i].identity;
  temperature = identity ? 6000 : profiles[i].temperature;
  gamma_percent = profiles[i].gamma;
}

// Milliseconds until the next minute starts, to look for a profile change.
static int ms_to_next_minute(void) {
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  return (int)((60 - ts.tv_sec % 60) * 1000 - ts.tv_nsec / 1000000) + 50;
}

// hyprsunset's socket ----------------------------------------------------------

// A value, absolute or "+N" / "-N" from the current one.
static int parse_value(const char *arg, int current, int *out) {
  char *end;
  long v = strtol(arg, &end, 10);
  if (end == arg || *end) return 0;
  *out = (arg[0] == '+' || arg[0] == '-') ? current + (int)v : (int)v;
  return 1;
}

static void answer(int client) {
  char buf[256];
  ssize_t n = read(client, buf, sizeof buf - 1);
  if (n <= 0) return;
  buf[n] = 0;
  char cmd[32] = "", arg[64] = "";
  sscanf(buf, "%31s %63s", cmd, arg);
  char reply[64] = "ok";
  if (!strcmp(cmd, "temperature")) {
    if (!*arg) {
      snprintf(reply, sizeof reply, "%d", temperature);
    } else {
      int v;
      if (parse_value(arg, temperature, &v) && v >= 1000 && v <= 20000) {
        temperature = v;
        identity = 0;
        apply_all();
      } else {
        snprintf(reply, sizeof reply, "invalid temperature");
      }
    }
  } else if (!strcmp(cmd, "gamma")) {
    if (!*arg) {
      snprintf(reply, sizeof reply, "%d", gamma_percent);
    } else {
      int v;
      if (parse_value(arg, gamma_percent, &v) && v >= 0 && v <= 200) {
        gamma_percent = v;
        apply_all();
      } else {
        snprintf(reply, sizeof reply, "invalid gamma");
      }
    }
  } else if (!strcmp(cmd, "identity")) {
    // Reported as 6000 K, as hyprsunset does: Omarchy counts below it as night light.
    identity = 1;
    temperature = 6000;
    apply_all();
  } else if (!strcmp(cmd, "reset")) {
    use_profile(active_profile());
    apply_all();
  } else {
    snprintf(reply, sizeof reply, "invalid command");
  }
  ssize_t ignored = write(client, reply, strlen(reply));
  (void)ignored;
}

static int open_socket(void) {
  const char *runtime = getenv("XDG_RUNTIME_DIR"), *instance = getenv("HYPRLAND_INSTANCE_SIGNATURE");
  if (!runtime || !instance) return -1;
  struct sockaddr_un addr = { .sun_family = AF_UNIX };
  snprintf(addr.sun_path, sizeof addr.sun_path, "%s/hypr/%s/.hyprsunset.sock", runtime, instance);
  unlink(addr.sun_path);
  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0 || bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0 || listen(fd, 8) < 0) {
    fprintf(stderr, "display-dimd: can't open %s: %s\n", addr.sun_path, strerror(errno));
    if (fd >= 0) close(fd);
    return -1;
  }
  return fd;
}

// Wayland ----------------------------------------------------------------------

static void ctm_blocked(void *data, struct hyprland_ctm_control_manager_v1 *m) {
  fprintf(stderr, "display-dimd: another program sets the colour matrix (hyprsunset?)\n");
  blocked = 1;
}

static const struct hyprland_ctm_control_manager_v1_listener ctm_listener = {
  .blocked = ctm_blocked,
};

static void output_name(void *data, struct wl_output *wl, const char *name) {
  struct output *o = data;
  snprintf(o->name, sizeof o->name, "%s", name);
}
static void output_done(void *data, struct wl_output *wl) {
  apply_all();
}
static void output_geometry(void *d, struct wl_output *w, int32_t x, int32_t y, int32_t pw, int32_t ph,
    int32_t sub, const char *make, const char *model, int32_t t) {}
static void output_mode(void *d, struct wl_output *w, uint32_t f, int32_t wd, int32_t h, int32_t r) {}
static void output_scale(void *d, struct wl_output *w, int32_t s) {}
static void output_description(void *d, struct wl_output *w, const char *s) {}

static const struct wl_output_listener output_listener = {
  .geometry = output_geometry,
  .mode = output_mode,
  .done = output_done,
  .scale = output_scale,
  .name = output_name,
  .description = output_description,
};

static void global_add(void *data, struct wl_registry *registry, uint32_t id, const char *interface,
    uint32_t version) {
  if (strcmp(interface, hyprland_ctm_control_manager_v1_interface.name) == 0) {
    manager = wl_registry_bind(registry, id, &hyprland_ctm_control_manager_v1_interface, version < 2 ? version : 2);
    hyprland_ctm_control_manager_v1_add_listener(manager, &ctm_listener, NULL);
  } else if (strcmp(interface, wl_output_interface.name) == 0 && version >= 4) {
    struct output *o = calloc(1, sizeof *o);
    o->global = id;
    o->wl = wl_registry_bind(registry, id, &wl_output_interface, 4);
    wl_output_add_listener(o->wl, &output_listener, o);
    o->next = outputs;
    outputs = o;
  }
}

static void global_remove(void *data, struct wl_registry *registry, uint32_t id) {
  for (struct output **p = &outputs; *p; p = &(*p)->next) {
    if ((*p)->global == id) {
      struct output *o = *p;
      *p = o->next;
      wl_output_release(o->wl);
      free(o);
      return;
    }
  }
}

static const struct wl_registry_listener registry_listener = {
  .global = global_add,
  .global_remove = global_remove,
};

int main(void) {
  // Omarchy's night light looks for a "hyprsunset" process before starting one.
  prctl(PR_SET_NAME, "hyprsunset", 0, 0, 0);

  const char *state = getenv("XDG_STATE_HOME");
  if (state && *state)
    snprintf(state_dir, sizeof state_dir, "%s/display-dim", state);
  else
    snprintf(state_dir, sizeof state_dir, "%s/.local/state/display-dim", getenv("HOME"));

  read_profiles();
  use_profile(active_profile());

  sigset_t mask;
  sigemptyset(&mask);
  sigaddset(&mask, SIGHUP);
  sigaddset(&mask, SIGTERM);
  sigaddset(&mask, SIGINT);
  sigprocmask(SIG_BLOCK, &mask, NULL);
  int sfd = signalfd(-1, &mask, SFD_CLOEXEC);
  signal(SIGPIPE, SIG_IGN);

  struct wl_display *display = wl_display_connect(NULL);
  if (!display) {
    fprintf(stderr, "display-dimd: no Wayland display\n");
    return 1;
  }
  struct wl_registry *registry = wl_display_get_registry(display);
  wl_registry_add_listener(registry, &registry_listener, NULL);
  wl_display_roundtrip(display);
  if (!manager) {
    fprintf(stderr, "display-dimd: the compositor has no colour matrix control\n");
    return 1;
  }
  wl_display_roundtrip(display);
  if (blocked) return 2;
  apply_all();

  int sock = open_socket();
  struct pollfd fds[3] = {
    { .fd = wl_display_get_fd(display), .events = POLLIN },
    { .fd = sfd, .events = POLLIN },
    { .fd = sock, .events = POLLIN },
  };
  for (;;) {
    wl_display_flush(display);
    int n = poll(fds, sock >= 0 ? 3 : 2, ms_to_next_minute());
    if (n < 0) {
      if (errno == EINTR) continue;
      break;
    }
    if (n == 0) {
      // A profile starting now takes over from any change by hand.
      int p = active_profile();
      if (p != current_profile) {
        use_profile(p);
        apply_all();
      }
      continue;
    }
    if (fds[0].revents & (POLLERR | POLLHUP)) break;
    if (fds[0].revents & POLLIN && wl_display_dispatch(display) < 0) break;
    if (blocked) break;
    if (fds[1].revents & POLLIN) {
      struct signalfd_siginfo info;
      if (read(sfd, &info, sizeof info) != sizeof info) continue;
      if (info.ssi_signo != SIGHUP) break;
      apply_all();
    }
    if (sock >= 0 && fds[2].revents & POLLIN) {
      int client = accept4(sock, NULL, NULL, SOCK_CLOEXEC);
      if (client >= 0) {
        answer(client);
        close(client);
      }
    }
  }
  // Colours back to plain as it goes.
  if (manager && !blocked) {
    for (struct output *o = outputs; o; o = o->next) {
      wl_fixed_t one = wl_fixed_from_double(1), z = wl_fixed_from_double(0);
      if (o->name[0])
        hyprland_ctm_control_manager_v1_set_ctm_for_output(manager, o->wl, one, z, z, z, one, z, z, z, one);
    }
    hyprland_ctm_control_manager_v1_commit(manager);
    wl_display_roundtrip(display);
  }
  wl_display_disconnect(display);
  return blocked ? 2 : 0;
}
