// Herdr Server.app launcher: a resident, bundled parent for `herdr server`.
//
// macOS resolves TCC and Local Network Privacy consent against a process's "responsible
// process", which is assigned at spawn time and inherited from the parent. A `herdr server`
// started by launchd or by an incoming SSH attach is its own responsible process and, being
// a bare ad-hoc Mach-O, has no bundle id to grant against (herdrdev/herdr#808). A server
// spawned by this launcher inherits the launcher as its responsible process; the launcher
// lives inside an app bundle with an Info.plist, so it can be granted once and every pane
// process under the server inherits that grant.
//
// Two behaviours matter:
//   * The launcher never execs herdr. It stays alive as the parent for as long as any server
//     exists, because attribution reverts to self the moment the responsible process exits.
//   * `herdr server live-handoff` makes the old server spawn its replacement, so the child
//     exits while a (still launcher-attributed) server keeps running. The launcher notices
//     that server on the socket and stands by instead of racing it, then respawns once it
//     is gone. Without this, KeepAlive would crash-loop on "server is already running".
//
// Environment:
//   HERDR_SERVER_BIN    herdr binary (default: /opt/homebrew/bin/herdr, /usr/local/bin/herdr)
//   HERDR_SOCKET_PATH   API socket to probe (default: ~/.config/herdr/herdr.sock)

#define _DARWIN_C_SOURCE

#include <errno.h>
#include <pwd.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef HERDR_SERVER_VERSION
#define HERDR_SERVER_VERSION "dev"
#endif

// Seconds between socket probes while a server the launcher did not spawn is running.
#define STANDBY_INTERVAL 15
// A child that dies this quickly is failing to start; back off before retrying.
#define FAST_EXIT_SECONDS 5
#define FAST_EXIT_BACKOFF 10

extern char **environ;

static volatile sig_atomic_t g_stop = 0;
static volatile pid_t g_child = 0;

static void on_signal(int sig) {
  g_stop = 1;
  pid_t child = g_child;
  if (child > 0) {
    kill(child, sig);
  }
}

static void logmsg(const char *fmt, ...) {
  char stamp[32];
  time_t now = time(NULL);
  struct tm tm;
  localtime_r(&now, &tm);
  strftime(stamp, sizeof stamp, "%Y-%m-%dT%H:%M:%S", &tm);
  fprintf(stderr, "%s herdr-server-launcher: ", stamp);
  va_list ap;
  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
  fputc('\n', stderr);
  fflush(stderr);
}

// Sleep that returns early on a signal so shutdown is prompt.
static void sleep_interruptible(int seconds) {
  struct timespec ts = {.tv_sec = seconds, .tv_nsec = 0};
  while (!g_stop && nanosleep(&ts, &ts) == -1 && errno == EINTR) {
  }
}

static const char *resolve_herdr(void) {
  static const char *candidates[] = {"/opt/homebrew/bin/herdr", "/usr/local/bin/herdr", NULL};
  const char *env = getenv("HERDR_SERVER_BIN");
  if (env && *env) {
    return env;
  }
  for (int i = 0; candidates[i]; i++) {
    if (access(candidates[i], X_OK) == 0) {
      return candidates[i];
    }
  }
  return NULL;
}

static void resolve_socket_path(char *buf, size_t n) {
  const char *env = getenv("HERDR_SOCKET_PATH");
  if (env && *env) {
    snprintf(buf, n, "%s", env);
    return;
  }
  const char *home = getenv("HOME");
  if (!home || !*home) {
    struct passwd *pw = getpwuid(getuid());
    home = pw ? pw->pw_dir : "";
  }
  snprintf(buf, n, "%s/.config/herdr/herdr.sock", home);
}

// True when something accepts connections on the API socket. A leftover socket file from a
// crash fails to connect, so this does not wedge on stale files.
static int server_alive(const char *path) {
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof addr);
  addr.sun_family = AF_UNIX;
  if (strlen(path) >= sizeof addr.sun_path) {
    return 0;
  }
  strcpy(addr.sun_path, path);

  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) {
    return 0;
  }
  int rc = connect(fd, (struct sockaddr *)&addr, sizeof addr);
  close(fd);
  return rc == 0;
}

static pid_t spawn_server(const char *herdr) {
  char *argv[] = {(char *)herdr, "server", NULL};
  pid_t pid = 0;
  int rc = posix_spawn(&pid, herdr, NULL, NULL, argv, environ);
  if (rc != 0) {
    logmsg("posix_spawn %s server failed: %s", herdr, strerror(rc));
    return -1;
  }
  return pid;
}

static int wait_child(pid_t pid) {
  int status = 0;
  for (;;) {
    pid_t r = waitpid(pid, &status, 0);
    if (r == pid) {
      break;
    }
    if (r == -1 && errno == EINTR) {
      continue;
    }
    logmsg("waitpid failed: %s", strerror(errno));
    return -1;
  }
  if (WIFEXITED(status)) {
    return WEXITSTATUS(status);
  }
  if (WIFSIGNALED(status)) {
    return 128 + WTERMSIG(status);
  }
  return -1;
}

int main(int argc, char **argv) {
  if (argc > 1) {
    if (strcmp(argv[1], "--version") == 0) {
      printf("herdr-server-launcher %s\n", HERDR_SERVER_VERSION);
      return 0;
    }
    fprintf(stderr, "usage: %s [--version]\n", argv[0]);
    return 64;
  }

  const char *herdr = resolve_herdr();
  if (!herdr) {
    logmsg("herdr binary not found (set HERDR_SERVER_BIN)");
    return 1;
  }
  char sock[1024];
  resolve_socket_path(sock, sizeof sock);

  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = on_signal;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = 0; // no SA_RESTART: let waitpid/nanosleep return EINTR
  sigaction(SIGTERM, &sa, NULL);
  sigaction(SIGINT, &sa, NULL);
  sigaction(SIGHUP, &sa, NULL);

  logmsg("version %s herdr=%s socket=%s pid=%d", HERDR_SERVER_VERSION, herdr, sock, (int)getpid());

  int standing_by = 0;
  while (!g_stop) {
    if (server_alive(sock)) {
      if (!standing_by) {
        logmsg("a server is already listening; standing by as responsible parent");
        standing_by = 1;
      }
      sleep_interruptible(STANDBY_INTERVAL);
      continue;
    }
    standing_by = 0;

    time_t started = time(NULL);
    pid_t pid = spawn_server(herdr);
    if (pid < 0) {
      sleep_interruptible(FAST_EXIT_BACKOFF);
      continue;
    }
    g_child = pid;
    logmsg("spawned herdr server pid=%d", (int)pid);
    int code = wait_child(pid);
    g_child = 0;
    logmsg("herdr server pid=%d exited status=%d", (int)pid, code);

    if (g_stop) {
      break;
    }
    if (code != 0 && time(NULL) - started < FAST_EXIT_SECONDS) {
      sleep_interruptible(FAST_EXIT_BACKOFF);
    } else {
      sleep_interruptible(1);
    }
  }

  logmsg("exiting");
  return 0;
}
