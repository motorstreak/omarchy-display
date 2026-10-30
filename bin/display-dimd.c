// display-dimd: dims chosen displays in software, each on its own, for
// monitors whose brightness can't be set (no DDC/CI). It holds each dimmed
// output's gamma control (the compositor drops the ramps when it lets go) and
// sets a straight ramp scaled to the level. Levels are files in
// $XDG_STATE_HOME/display-dim/<output> holding a percent; SIGHUP rereads them
// (bin/display-dim writes them and sends it). 100, or no file: left alone.
// Night light (hyprsunset) works through Hyprland's colour matrix instead, so
// the two stack.

#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/signalfd.h>
#include <unistd.h>
#include <wayland-client.h>
#include "wlr-gamma-control-unstable-v1-client-protocol.h"

struct output {
  struct wl_output *wl;
  uint32_t global;
  char name[64];
  struct zwlr_gamma_control_v1 *control;
  uint32_t size;  // ramp size, once the control says
  int level;      // percent being shown (100: none)
  int failed;     // another client has it
  struct output *next;
};

static struct zwlr_gamma_control_manager_v1 *manager;
static struct output *outputs;
static char state_dir[512];

static int wanted_level(const char *name) {
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

static void set_ramp(struct output *o) {
  if (!o->control || !o->size) return;
  size_t bytes = (size_t)o->size * 3 * sizeof(uint16_t);
  int fd = memfd_create("display-dim", MFD_CLOEXEC);
  if (fd < 0 || ftruncate(fd, bytes) < 0) {
    if (fd >= 0) close(fd);
    return;
  }
  uint16_t *ramp = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (ramp == MAP_FAILED) {
    close(fd);
    return;
  }
  for (uint32_t i = 0; i < o->size; i++) {
    double v = (double)i / (o->size - 1) * 65535.0 * o->level / 100.0;
    ramp[i] = ramp[o->size + i] = ramp[2 * o->size + i] = (uint16_t)(v + 0.5);
  }
  munmap(ramp, bytes);
  zwlr_gamma_control_v1_set_gamma(o->control, fd);
  close(fd);
}

static void gamma_size(void *data, struct zwlr_gamma_control_v1 *c, uint32_t size) {
  struct output *o = data;
  o->size = size;
  set_ramp(o);
}

static void gamma_failed(void *data, struct zwlr_gamma_control_v1 *c) {
  struct output *o = data;
  fprintf(stderr, "display-dimd: %s: gamma control refused (another program has it)\n", o->name);
  zwlr_gamma_control_v1_destroy(c);
  o->control = NULL;
  o->size = 0;
  o->failed = 1;
}

static const struct zwlr_gamma_control_v1_listener gamma_listener = {
  .gamma_size = gamma_size,
  .failed = gamma_failed,
};

// The output as its level file says: a control taken (and the ramp set once
// its size is known), the ramp changed, or the control let go at 100.
static void apply(struct output *o) {
  if (!o->name[0] || !manager) return;
  int level = wanted_level(o->name);
  if (level >= 100) {
    if (o->control) {
      zwlr_gamma_control_v1_destroy(o->control);
      o->control = NULL;
      o->size = 0;
    }
    o->level = 100;
    o->failed = 0;
    return;
  }
  o->level = level;
  if (!o->control) {
    o->failed = 0;
    o->control = zwlr_gamma_control_manager_v1_get_gamma_control(manager, o->wl);
    zwlr_gamma_control_v1_add_listener(o->control, &gamma_listener, o);
  } else {
    set_ramp(o);
  }
}

static void output_name(void *data, struct wl_output *wl, const char *name) {
  struct output *o = data;
  snprintf(o->name, sizeof o->name, "%s", name);
}
static void output_done(void *data, struct wl_output *wl) {
  struct output *o = data;
  if (!o->failed) apply(o); // refused: tried again only when told to reread
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
  if (strcmp(interface, zwlr_gamma_control_manager_v1_interface.name) == 0) {
    manager = wl_registry_bind(registry, id, &zwlr_gamma_control_manager_v1_interface, 1);
  } else if (strcmp(interface, wl_output_interface.name) == 0 && version >= 4) {
    struct output *o = calloc(1, sizeof *o);
    o->global = id;
    o->level = 100;
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
      if (o->control) zwlr_gamma_control_v1_destroy(o->control);
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
  const char *state = getenv("XDG_STATE_HOME");
  if (state && *state)
    snprintf(state_dir, sizeof state_dir, "%s/display-dim", state);
  else
    snprintf(state_dir, sizeof state_dir, "%s/.local/state/display-dim", getenv("HOME"));

  sigset_t mask;
  sigemptyset(&mask);
  sigaddset(&mask, SIGHUP);
  sigaddset(&mask, SIGTERM);
  sigaddset(&mask, SIGINT);
  sigprocmask(SIG_BLOCK, &mask, NULL);
  int sfd = signalfd(-1, &mask, SFD_CLOEXEC);

  struct wl_display *display = wl_display_connect(NULL);
  if (!display) {
    fprintf(stderr, "display-dimd: no Wayland display\n");
    return 1;
  }
  struct wl_registry *registry = wl_display_get_registry(display);
  wl_registry_add_listener(registry, &registry_listener, NULL);
  wl_display_roundtrip(display);
  if (!manager) {
    fprintf(stderr, "display-dimd: the compositor has no gamma control\n");
    return 1;
  }
  wl_display_roundtrip(display);

  struct pollfd fds[2] = {
    { .fd = wl_display_get_fd(display), .events = POLLIN },
    { .fd = sfd, .events = POLLIN },
  };
  for (;;) {
    wl_display_flush(display);
    if (poll(fds, 2, -1) < 0) {
      if (errno == EINTR) continue;
      break;
    }
    if (fds[0].revents & (POLLERR | POLLHUP)) break;
    if (fds[0].revents & POLLIN && wl_display_dispatch(display) < 0) break;
    if (fds[1].revents & POLLIN) {
      struct signalfd_siginfo info;
      if (read(sfd, &info, sizeof info) != sizeof info) continue;
      if (info.ssi_signo != SIGHUP) break;
      for (struct output *o = outputs; o; o = o->next) {
        o->failed = 0;
        apply(o);
      }
    }
  }
  wl_display_disconnect(display);
  return 0;
}
