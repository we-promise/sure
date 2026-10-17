#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define RAILS_UID 1000
#define RAILS_GID 1000
#define BROWSER_UID 1001
#define BROWSER_GID 1001
#define MAX_LIFETIME_SECONDS 1200
#define SUPERVISOR_DIR "/run/sure-fineco"
#define RUNTIME_LOCK_NAME "runtime.lock"
#define X_SOCKET "/tmp/.X11-unix/X99"
#define X_LOCK "/tmp/.X99-lock"
#define X_DISPLAY ":99"
#define VNC_PORT 5900
#define CDP_PORT 9222
#define MAX_CHILDREN 3

static volatile sig_atomic_t stop_requested = 0;
static pid_t runtime_parent_pid = 0;
static unsigned long long runtime_parent_start_time = 0;

struct child_process {
  pid_t pid;
  const char *name;
};

static void request_stop(int signal_number) {
  (void)signal_number;
  stop_requested = 1;
}

static int token_valid(const char *token) {
  size_t index;

  if (strlen(token) != 32) return 0;
  for (index = 0; index < 32; index++) {
    if (!((token[index] >= '0' && token[index] <= '9') || (token[index] >= 'a' && token[index] <= 'f'))) return 0;
  }
  return 1;
}

static int parse_decimal(const char *value, long minimum, long maximum, long *result) {
  char *end = NULL;
  long parsed;

  errno = 0;
  parsed = strtol(value, &end, 10);
  if (errno || !end || *end || parsed < minimum || parsed > maximum) return 0;
  *result = parsed;
  return 1;
}

static int close_except(int keep_fd) {
  struct rlimit limit;
  rlim_t maximum;
  int fd;
  int range_succeeded = 1;

  if (keep_fd < 3) {
    if (syscall(SYS_close_range, 3U, UINT_MAX, 0) != 0) range_succeeded = 0;
  } else {
    if (keep_fd > 3 && syscall(SYS_close_range, 3U, (unsigned int)keep_fd - 1U, 0) != 0) range_succeeded = 0;
    if (syscall(SYS_close_range, (unsigned int)keep_fd + 1U, UINT_MAX, 0) != 0) range_succeeded = 0;
  }
  if (range_succeeded) return 0;

  if (getrlimit(RLIMIT_NOFILE, &limit) != 0) return -1;
  maximum = limit.rlim_cur == RLIM_INFINITY ? 1048576 : limit.rlim_cur;
  if (maximum > INT_MAX) maximum = INT_MAX;
  for (fd = 3; (rlim_t)fd < maximum; fd++) {
    if (fd != keep_fd) close(fd);
  }
  return 0;
}

static int supervisor_dir_fd(void) {
  struct stat status;
  int fd = open(SUPERVISOR_DIR, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);

  if (fd < 0) return -1;
  if (fstat(fd, &status) != 0 || !S_ISDIR(status.st_mode) || status.st_uid != 0 || status.st_gid != 0 ||
      (status.st_mode & 0777) != 0711) {
    close(fd);
    return -1;
  }
  return fd;
}

static int open_runtime_lock(int parent_fd) {
  struct stat status;
  int fd = openat(parent_fd, RUNTIME_LOCK_NAME, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);

  if (fd < 0) return -1;
  if (fstat(fd, &status) != 0 || !S_ISREG(status.st_mode) || fchown(fd, 0, 0) != 0 || fchmod(fd, 0600) != 0 ||
      fstat(fd, &status) != 0 || !S_ISREG(status.st_mode) || status.st_uid != 0 || status.st_gid != 0 ||
      (status.st_mode & 0777) != 0600 || flock(fd, LOCK_EX | LOCK_NB) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}

static int process_uid(pid_t pid, uid_t *uid) {
  char path[64];
  char line[256];
  FILE *file;
  unsigned int real_uid;
  unsigned int effective_uid;

  snprintf(path, sizeof(path), "/proc/%ld/status", (long)pid);
  file = fopen(path, "re");
  if (!file) return 0;
  while (fgets(line, sizeof(line), file)) {
    if (sscanf(line, "Uid:\t%u\t%u", &real_uid, &effective_uid) == 2) {
      fclose(file);
      *uid = (uid_t)real_uid;
      return 1;
    }
  }
  fclose(file);
  return 0;
}

static int process_state(pid_t pid, char *state) {
  char path[64];
  char line[256];
  FILE *file;

  snprintf(path, sizeof(path), "/proc/%ld/status", (long)pid);
  file = fopen(path, "re");
  if (!file) return 0;
  while (fgets(line, sizeof(line), file)) {
    if (sscanf(line, "State:\t%c", state) == 1) {
      fclose(file);
      return 1;
    }
  }
  fclose(file);
  return 0;
}

static int process_group_session(pid_t pid, pid_t *group_id, pid_t *session_id) {
  char path[64];
  char contents[4096];
  FILE *file;
  char *separator;
  char *cursor;
  char *save = NULL;
  int field = 0;
  char *token;

  snprintf(path, sizeof(path), "/proc/%ld/stat", (long)pid);
  file = fopen(path, "re");
  if (!file) return 0;
  if (!fgets(contents, sizeof(contents), file)) {
    fclose(file);
    return 0;
  }
  fclose(file);
  separator = strrchr(contents, ')');
  if (!separator || separator[1] != ' ') return 0;
  cursor = separator + 2;
  for (token = strtok_r(cursor, " ", &save); token; token = strtok_r(NULL, " ", &save)) {
    field++;
    if (field == 3) {
      long parsed;
      if (!parse_decimal(token, 1, INT_MAX, &parsed)) return 0;
      *group_id = (pid_t)parsed;
    } else if (field == 4) {
      long parsed;
      if (!parse_decimal(token, 1, INT_MAX, &parsed)) return 0;
      *session_id = (pid_t)parsed;
      return 1;
    }
  }
  return 0;
}

static int parent_still_same(pid_t parent_pid, unsigned long long parent_start_time);

static int should_stop(void) {
  struct pollfd control = { .fd = STDIN_FILENO, .events = POLLIN | POLLHUP | POLLERR };
  int poll_result;

  if (stop_requested || !parent_still_same(runtime_parent_pid, runtime_parent_start_time)) return 1;
  poll_result = poll(&control, 1, 0);
  if (poll_result > 0 && (control.revents & (POLLHUP | POLLERR))) stop_requested = 1;
  if (poll_result > 0 && (control.revents & POLLIN)) {
    char command[16];
    ssize_t ignored = read(STDIN_FILENO, command, sizeof(command));
    (void)ignored;
    stop_requested = 1;
  }
  return stop_requested;
}

static int numeric_name(const char *name) {
  size_t index;
  if (!name[0]) return 0;
  for (index = 0; name[index]; index++) if (name[index] < '0' || name[index] > '9') return 0;
  return 1;
}

static double monotonic_seconds(void);

static size_t browser_processes(pid_t *processes, size_t capacity) {
  DIR *directory = opendir("/proc");
  struct dirent *entry;
  size_t count = 0;

  if (!directory) return capacity + 1;
  while ((entry = readdir(directory)) != NULL) {
    pid_t pid;
    uid_t uid;
    char state;

    if (!numeric_name(entry->d_name)) continue;
    pid = (pid_t)strtol(entry->d_name, NULL, 10);
    if (!process_uid(pid, &uid) || uid != BROWSER_UID || !process_state(pid, &state) || state == 'X' || state == 'x') continue;
    if (count == capacity) {
      closedir(directory);
      return capacity + 1;
    }
    processes[count++] = pid;
  }
  closedir(directory);
  return count;
}

static int signal_browser_process(pid_t pid, int signal_number) {
  int pid_fd = (int)syscall(SYS_pidfd_open, pid, 0);
  uid_t uid;
  char state;
  int result;

  if (pid_fd < 0) return errno == ESRCH;
  if (!process_uid(pid, &uid) || uid != BROWSER_UID || !process_state(pid, &state)) {
    result = (int)syscall(SYS_pidfd_send_signal, pid_fd, 0, NULL, 0);
    int send_error = errno;
    close(pid_fd);
    return result != 0 && send_error == ESRCH;
  }
  if (state == 'Z' || state == 'X' || state == 'x') {
    close(pid_fd);
    return 1;
  }
  result = (int)syscall(SYS_pidfd_send_signal, pid_fd, signal_number, NULL, 0);
  close(pid_fd);
  return result == 0 || errno == ESRCH;
}

static int signal_browser_processes(int signal_number) {
  pid_t processes[4096];
  size_t count = browser_processes(processes, sizeof(processes) / sizeof(processes[0]));
  size_t index;
  int succeeded = 1;

  if (count > sizeof(processes) / sizeof(processes[0])) return 0;
  for (index = 0; index < count; index++) if (!signal_browser_process(processes[index], signal_number)) succeeded = 0;
  return succeeded;
}

static int reap_children(struct child_process *children, size_t child_count) {
  size_t index;
  int status;

  for (index = 0; index < child_count; index++) {
    pid_t waited;
    if (children[index].pid <= 0) continue;
    errno = 0;
    waited = waitpid(children[index].pid, &status, WNOHANG);
    if (waited == children[index].pid) {
      children[index].pid = -1;
    } else if (waited < 0 && errno == ECHILD) {
      uid_t uid;
      if (process_uid(children[index].pid, &uid)) return 0;
      children[index].pid = -1;
    } else if (waited < 0 && errno != EINTR) {
      return 0;
    }
  }
  return 1;
}

static int children_reaped(const struct child_process *children, size_t child_count) {
  size_t index;
  for (index = 0; index < child_count; index++) if (children[index].pid > 0) return 0;
  return 1;
}

static int wait_for_browser_processes(struct child_process *children, size_t child_count, double timeout_seconds, int signal_number) {
  double deadline = monotonic_seconds() + timeout_seconds;
  struct timespec pause = { .tv_sec = 0, .tv_nsec = 100000000 };

  while (monotonic_seconds() < deadline) {
    pid_t processes[4096];
    signal_browser_processes(signal_number);
    if (!reap_children(children, child_count)) return 0;
    size_t count = browser_processes(processes, sizeof(processes) / sizeof(processes[0]));
    if (count == 0 && children_reaped(children, child_count)) return 1;
    if (count > sizeof(processes) / sizeof(processes[0])) return 0;
    nanosleep(&pause, NULL);
  }
  {
    pid_t processes[4096];
    signal_browser_processes(signal_number);
    if (!reap_children(children, child_count) || !children_reaped(children, child_count)) return 0;
    return browser_processes(processes, sizeof(processes) / sizeof(processes[0])) == 0;
  }
}

static int terminate_browser_processes(struct child_process *children, size_t child_count, double term_timeout, double kill_timeout) {
  if (wait_for_browser_processes(children, child_count, term_timeout, SIGTERM)) return 1;
  return wait_for_browser_processes(children, child_count, kill_timeout, SIGKILL);
}

static int remove_tree_contents(int directory_fd) {
  DIR *directory = fdopendir(dup(directory_fd));
  struct dirent *entry;
  int succeeded = 1;

  if (!directory) return 0;
  while ((entry = readdir(directory)) != NULL) {
    struct stat status;
    if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
    if (fstatat(directory_fd, entry->d_name, &status, AT_SYMLINK_NOFOLLOW) != 0) {
      if (errno != ENOENT) succeeded = 0;
      continue;
    }
    if (S_ISDIR(status.st_mode)) {
      int child_fd = openat(directory_fd, entry->d_name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
      if (child_fd >= 0) {
        struct stat child_status;
        if (fstat(child_fd, &child_status) == 0 && S_ISDIR(child_status.st_mode)) {
          if (!remove_tree_contents(child_fd) || unlinkat(directory_fd, entry->d_name, AT_REMOVEDIR) != 0) succeeded = 0;
        } else {
          succeeded = 0;
        }
        close(child_fd);
      } else {
        succeeded = 0;
      }
    } else {
      if (unlinkat(directory_fd, entry->d_name, 0) != 0) succeeded = 0;
    }
  }
  closedir(directory);
  return succeeded;
}

static int remove_profile_at(int parent_fd, const char *token) {
  struct stat status;
  int profile_fd;

  if (!token_valid(token)) return 0;
  if (fstatat(parent_fd, token, &status, AT_SYMLINK_NOFOLLOW) != 0) return errno == ENOENT;
  if (!S_ISDIR(status.st_mode) || status.st_uid != BROWSER_UID || status.st_gid != BROWSER_GID ||
      (status.st_mode & 0777) != 0700) return 0;
  profile_fd = openat(parent_fd, token, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (profile_fd < 0) return 0;
  if (!remove_tree_contents(profile_fd)) {
    close(profile_fd);
    return 0;
  }
  close(profile_fd);
  return unlinkat(parent_fd, token, AT_REMOVEDIR) == 0;
}

static int remove_all_profiles(int parent_fd) {
  DIR *directory = fdopendir(dup(parent_fd));
  struct dirent *entry;
  int succeeded = 1;

  if (!directory) return 0;
  while ((entry = readdir(directory)) != NULL) {
    if (token_valid(entry->d_name) && !remove_profile_at(parent_fd, entry->d_name)) succeeded = 0;
  }
  closedir(directory);
  directory = fdopendir(dup(parent_fd));
  if (!directory) return 0;
  rewinddir(directory);
  while ((entry = readdir(directory)) != NULL) if (token_valid(entry->d_name)) succeeded = 0;
  closedir(directory);
  return succeeded;
}

static int reserved_port_free(int family, uint16_t port) {
  int fd = socket(family, SOCK_STREAM | SOCK_CLOEXEC, 0);
  int reuse = 1;
  int v6_only = 1;
  int result;

  if (fd < 0) return 0;
  if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse)) != 0) {
    close(fd);
    return 0;
  }
  if (family == AF_INET) {
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    result = bind(fd, (struct sockaddr *)&address, sizeof(address));
  } else {
    struct sockaddr_in6 address;
    if (setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v6_only, sizeof(v6_only)) != 0) {
      close(fd);
      return 0;
    }
    memset(&address, 0, sizeof(address));
    address.sin6_family = AF_INET6;
    address.sin6_port = htons(port);
    address.sin6_addr = in6addr_loopback;
    result = bind(fd, (struct sockaddr *)&address, sizeof(address));
  }
  close(fd);
  return result == 0;
}

static int clear_reserved_x_socket(void) {
  struct stat status;

  if (lstat(X_SOCKET, &status) == 0) {
    if (!S_ISSOCK(status.st_mode) || status.st_uid != BROWSER_UID || unlink(X_SOCKET) != 0) return 0;
  } else if (errno != ENOENT) {
    return 0;
  }
  if (lstat(X_SOCKET, &status) == 0 || errno != ENOENT) return 0;

  if (lstat(X_LOCK, &status) == 0) {
    if (!S_ISREG(status.st_mode) || status.st_uid != BROWSER_UID || unlink(X_LOCK) != 0) return 0;
  } else if (errno != ENOENT) {
    return 0;
  }
  return lstat(X_LOCK, &status) != 0 && errno == ENOENT;
}

static int recover_stale_runtime(int parent_fd) {
  if (!terminate_browser_processes(NULL, 0, 2.0, 3.0)) return 0;
  if (browser_processes((pid_t[4096]){ 0 }, 4096) != 0) return 0;
  if (!remove_all_profiles(parent_fd) || !clear_reserved_x_socket()) return 0;
  return reserved_port_free(AF_INET, VNC_PORT) && reserved_port_free(AF_INET, CDP_PORT) &&
      reserved_port_free(AF_INET6, VNC_PORT) && reserved_port_free(AF_INET6, CDP_PORT);
}

static double monotonic_seconds(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0.0;
  return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

static int wait_for_socket(const char *path, int timeout_seconds) {
  double deadline = monotonic_seconds() + timeout_seconds;
  struct timespec pause = { .tv_sec = 0, .tv_nsec = 100000000 };
  while (monotonic_seconds() < deadline && !should_stop()) {
    struct stat status;
    if (lstat(path, &status) == 0 && S_ISSOCK(status.st_mode) && status.st_uid == BROWSER_UID) return 1;
    nanosleep(&pause, NULL);
  }
  return 0;
}

static int proc_net_has_loopback_listener(uint16_t port) {
  FILE *file = fopen("/proc/net/tcp", "re");
  char line[512];
  int found = 0;

  if (!file) return 0;
  while (fgets(line, sizeof(line), file)) {
    char *save = NULL;
    char *token = strtok_r(line, " \t\r\n", &save);
    char *local_address = NULL;
    char *state = NULL;
    char *uid_value = NULL;
    unsigned int field = 0;
    while (token) {
      if (field == 1) local_address = token;
      else if (field == 3) state = token;
      else if (field == 7) uid_value = token;
      field++;
      if (field > 7) break;
      token = strtok_r(NULL, " \t\r\n", &save);
    }
    if (local_address && state && uid_value) {
      char *separator = strrchr(local_address, ':');
      char *end = NULL;
      unsigned long local_port = separator ? strtoul(separator + 1, &end, 16) : 0;
      unsigned long uid = strtoul(uid_value, NULL, 10);
      if (separator && end && *end == '\0' && local_port == port && uid == BROWSER_UID &&
          strcmp(state, "0A") == 0 && (size_t)(separator - local_address) == 8 &&
          strncmp(local_address, "0100007F", 8) == 0) {
        found = 1;
        break;
      }
    }
  }
  fclose(file);
  return found;
}

static int wait_for_port(uint16_t port, int timeout_seconds) {
  double deadline = monotonic_seconds() + timeout_seconds;
  struct timespec pause = { .tv_sec = 0, .tv_nsec = 100000000 };
  while (monotonic_seconds() < deadline && !should_stop()) {
    struct sockaddr_in address;
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd >= 0) {
      memset(&address, 0, sizeof(address));
      address.sin_family = AF_INET;
      address.sin_port = htons(port);
      address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
      if (connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0) {
        close(fd);
        if (proc_net_has_loopback_listener(port)) return 1;
      } else {
        close(fd);
      }
    }
    nanosleep(&pause, NULL);
  }
  return 0;
}

static void child_environment(const char *profile, char *environment[], char values[][PATH_MAX]) {
  snprintf(values[0], PATH_MAX, "DISPLAY=%s", X_DISPLAY);
  snprintf(values[1], PATH_MAX, "HOME=%s", profile);
  snprintf(values[2], PATH_MAX, "XDG_CACHE_HOME=%s/xdg-cache", profile);
  snprintf(values[3], PATH_MAX, "XDG_CONFIG_HOME=%s/xdg-config", profile);
  snprintf(values[4], PATH_MAX, "XDG_DATA_HOME=%s/xdg-data", profile);
  snprintf(values[5], PATH_MAX, "TMPDIR=%s", profile);
  strcpy(values[6], "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
  strcpy(values[7], "LANG=C.UTF-8");
  strcpy(values[8], "LC_ALL=C.UTF-8");
  strcpy(values[9], "TZ=UTC");
  environment[0] = values[0];
  environment[1] = values[1];
  environment[2] = values[2];
  environment[3] = values[3];
  environment[4] = values[4];
  environment[5] = values[5];
  environment[6] = values[6];
  environment[7] = values[7];
  environment[8] = values[8];
  environment[9] = values[9];
  environment[10] = NULL;
}

static void child_error(int error_fd, int error_number) {
  ssize_t ignored = write(error_fd, &error_number, sizeof(error_number));
  (void)ignored;
  _exit(127);
}

static int spawn_child(const char *name, const char *profile, pid_t group_id, struct child_process *child) {
  char *environment[11];
  char environment_values[10][PATH_MAX];
  char profile_argument[PATH_MAX + 32];
  char data_argument[PATH_MAX + 32];
  char *xvfb_argv[] = { "Xvfb", ":99", "-screen", "0", "1366x900x24", "-nolisten", "tcp", "-ac", NULL };
  char *vnc_argv[] = { "x11vnc", "-display", ":99", "-localhost", "-rfbport", "5900", "-nopw", "-forever", "-shared", "-noxdamage", "-noxfixes", "-noxrecord", "-safer", "-nocmds", "-input", "KMBC", NULL };
  char *chrome_argv[32];
  size_t chrome_argc = 0;
  const char *executable;
  char *const *arguments;
  int error_pipe[2];
  pid_t pid;

  child_environment(profile, environment, environment_values);
  if (strcmp(name, "xvfb") == 0) {
    executable = "/usr/bin/Xvfb";
    arguments = xvfb_argv;
  } else if (strcmp(name, "x11vnc") == 0) {
    executable = "/usr/bin/x11vnc";
    arguments = vnc_argv;
  } else if (strcmp(name, "chromium") == 0) {
    executable = "/usr/bin/chromium";
    snprintf(profile_argument, sizeof(profile_argument), "--user-data-dir=%s", profile);
    snprintf(data_argument, sizeof(data_argument), "--remote-debugging-address=127.0.0.1");
    chrome_argv[chrome_argc++] = "chromium";
    chrome_argv[chrome_argc++] = profile_argument;
    chrome_argv[chrome_argc++] = "--remote-debugging-port=9222";
    chrome_argv[chrome_argc++] = data_argument;
    chrome_argv[chrome_argc++] = "--window-size=1366,900";
    chrome_argv[chrome_argc++] = "--no-first-run";
    chrome_argv[chrome_argc++] = "--no-default-browser-check";
    chrome_argv[chrome_argc++] = "--disable-background-networking";
    chrome_argv[chrome_argc++] = "--disable-extensions";
    chrome_argv[chrome_argc++] = "--disable-sync";
    chrome_argv[chrome_argc++] = "--disable-dev-shm-usage";
    chrome_argv[chrome_argc++] = "--disable-gpu";
    chrome_argv[chrome_argc++] = "https://it.finecobank.com/";
    chrome_argv[chrome_argc] = NULL;
    arguments = chrome_argv;
  } else {
    errno = EINVAL;
    return -1;
  }

  if (pipe2(error_pipe, O_CLOEXEC) != 0) return -1;
  pid = fork();
  if (pid < 0) {
    close(error_pipe[0]);
    close(error_pipe[1]);
    return -1;
  }
  if (pid == 0) {
    struct rlimit core_limit = { .rlim_cur = 0, .rlim_max = 0 };
    int null_fd;
    int error_fd = error_pipe[1];
    pid_t supervisor_pid = getppid();

    close(error_pipe[0]);
    if (setpgid(0, group_id == 0 ? 0 : group_id) != 0) child_error(error_fd, errno);
    if (setgroups(0, NULL) != 0 || setresgid(BROWSER_GID, BROWSER_GID, BROWSER_GID) != 0 ||
        setresuid(BROWSER_UID, BROWSER_UID, BROWSER_UID) != 0) child_error(error_fd, errno);
    if (prctl(PR_SET_PDEATHSIG, SIGTERM) != 0 || getppid() != supervisor_pid) child_error(error_fd, errno ? errno : ESRCH);
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0 || prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) != 0) child_error(error_fd, errno);
    if (setrlimit(RLIMIT_CORE, &core_limit) != 0) child_error(error_fd, errno);
    if (chdir(profile) != 0) child_error(error_fd, errno);
    null_fd = open("/dev/null", O_RDWR | O_CLOEXEC);
    if (null_fd < 0) child_error(error_fd, errno);
    if (dup2(null_fd, STDIN_FILENO) < 0 || dup2(null_fd, STDOUT_FILENO) < 0 || dup2(null_fd, STDERR_FILENO) < 0) child_error(error_fd, errno);
    if (null_fd > STDERR_FILENO) close(null_fd);
    if (close_except(error_fd) != 0) child_error(error_fd, errno ? errno : EMFILE);
    execve(executable, (char *const *)arguments, environment);
    child_error(error_fd, errno);
  }

  close(error_pipe[1]);
  if (setpgid(pid, group_id == 0 ? pid : group_id) != 0 && errno != EACCES && errno != ESRCH) {
    int saved_errno = errno;
    close(error_pipe[0]);
    kill(pid, SIGKILL);
    waitpid(pid, NULL, 0);
    errno = saved_errno;
    return -1;
  }
  {
    struct pollfd descriptor = { .fd = error_pipe[0], .events = POLLIN | POLLHUP };
    int poll_result = poll(&descriptor, 1, 3000);
    int exec_error = 0;
    ssize_t bytes = poll_result > 0 ? read(error_pipe[0], &exec_error, sizeof(exec_error)) : -1;
    close(error_pipe[0]);
    if (poll_result <= 0 || bytes > 0) {
      kill(pid, SIGKILL);
      waitpid(pid, NULL, 0);
      errno = bytes > 0 ? exec_error : ETIMEDOUT;
      return -1;
    }
  }
  child->pid = pid;
  child->name = name;
  return 0;
}

static int status_field(pid_t pid, const char *key, char *value, size_t value_size) {
  char path[64];
  char line[512];
  FILE *file;
  size_t key_length = strlen(key);

  snprintf(path, sizeof(path), "/proc/%ld/status", (long)pid);
  file = fopen(path, "re");
  if (!file) return 0;
  while (fgets(line, sizeof(line), file)) {
    if (strncmp(line, key, key_length) == 0 && line[key_length] == ':') {
      char *cursor = line + key_length + 1;
      while (*cursor == ' ' || *cursor == '\t') cursor++;
      cursor[strcspn(cursor, "\r\n")] = '\0';
      snprintf(value, value_size, "%s", cursor);
      fclose(file);
      return 1;
    }
  }
  fclose(file);
  return 0;
}

static int command_line(pid_t pid, char *buffer, size_t buffer_size) {
  char path[64];
  int fd;
  ssize_t length;

  snprintf(path, sizeof(path), "/proc/%ld/cmdline", (long)pid);
  fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return 0;
  length = read(fd, buffer, buffer_size - 1);
  close(fd);
  if (length <= 0) return 0;
  buffer[length] = '\0';
  for (ssize_t index = 0; index < length; index++) if (buffer[index] == '\0') buffer[index] = ' ';
  return 1;
}

static int supervisor_ids_match(uid_t expected_effective_uid, gid_t expected_effective_gid) {
  uid_t real_uid;
  uid_t effective_uid;
  uid_t saved_uid;
  gid_t real_gid;
  gid_t effective_gid;
  gid_t saved_gid;

  if (getresuid(&real_uid, &effective_uid, &saved_uid) != 0 || getresgid(&real_gid, &effective_gid, &saved_gid) != 0) return 0;
  return real_uid == RAILS_UID && effective_uid == expected_effective_uid && saved_uid == 0 &&
      real_gid == RAILS_GID && effective_gid == expected_effective_gid && saved_gid == RAILS_GID;
}

static int supervisor_nondumpable(void) {
  return prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) == 0 && prctl(PR_GET_DUMPABLE, 0, 0, 0, 0) == 0;
}

static int restore_supervisor_identity(void) {
  int restored = 1;

  if (seteuid(0) != 0) restored = 0;
  if (setegid(RAILS_GID) != 0) restored = 0;
  if (!supervisor_nondumpable()) restored = 0;
  if (!supervisor_ids_match(0, RAILS_GID)) restored = 0;
  return restored;
}

static int namespace_stat_as_browser(pid_t pid, struct stat *status) {
  char path[64];
  int result;
  int stat_errno;

  if (!supervisor_ids_match(0, RAILS_GID) || !supervisor_nondumpable()) return -1;
  if (setegid(BROWSER_GID) != 0) return restore_supervisor_identity() ? 0 : -1;
  if (!supervisor_ids_match(0, BROWSER_GID) || !supervisor_nondumpable()) {
    restore_supervisor_identity();
    return -1;
  }
  if (seteuid(BROWSER_UID) != 0) return restore_supervisor_identity() ? 0 : -1;
  if (!supervisor_ids_match(BROWSER_UID, BROWSER_GID) || !supervisor_nondumpable()) {
    restore_supervisor_identity();
    return -1;
  }

  snprintf(path, sizeof(path), "/proc/%ld/ns/user", (long)pid);
  result = stat(path, status);
  stat_errno = errno;
  if (!restore_supervisor_identity()) return -1;
  errno = stat_errno;
  return result == 0 ? 1 : 0;
}

static int renderer_sandboxed(pid_t browser_pid, pid_t runtime_session_id, pid_t *renderer_pid) {
  struct stat browser_namespace;
  DIR *directory;
  struct dirent *entry;
  int found = 0;
  int namespace_result;

  namespace_result = namespace_stat_as_browser(browser_pid, &browser_namespace);
  if (namespace_result <= 0) return namespace_result;
  directory = opendir("/proc");
  if (!directory) return 0;
  while ((entry = readdir(directory)) != NULL) {
    pid_t pid;
    char cmdline[32768];
    struct stat renderer_namespace;
    char seccomp[64];
    char filters[64];
    char no_new_privs[64];
    char capabilities[128];
    char *end = NULL;
    unsigned long long cap_value;
    uid_t uid;
    pid_t group_id;
    pid_t session_id;

    if (!numeric_name(entry->d_name)) continue;
    pid = (pid_t)strtol(entry->d_name, NULL, 10);
    if (!process_uid(pid, &uid) || uid != BROWSER_UID || !process_group_session(pid, &group_id, &session_id) ||
        session_id != runtime_session_id ||
        !command_line(pid, cmdline, sizeof(cmdline))) continue;
    if (!strstr(cmdline, "--type=renderer")) continue;
    namespace_result = namespace_stat_as_browser(pid, &renderer_namespace);
    if (namespace_result < 0) {
      closedir(directory);
      return -1;
    }
    if (namespace_result == 0) continue;
    if (renderer_namespace.st_dev == browser_namespace.st_dev && renderer_namespace.st_ino == browser_namespace.st_ino) continue;
    if (!status_field(pid, "Seccomp", seccomp, sizeof(seccomp)) || strcmp(seccomp, "2") != 0) continue;
    if (!status_field(pid, "Seccomp_filters", filters, sizeof(filters)) || strtol(filters, NULL, 10) < 2) continue;
    if (!status_field(pid, "NoNewPrivs", no_new_privs, sizeof(no_new_privs)) || strcmp(no_new_privs, "1") != 0) continue;
    if (!status_field(pid, "CapEff", capabilities, sizeof(capabilities))) continue;
    errno = 0;
    cap_value = strtoull(capabilities, &end, 16);
    if (errno || !end || *end || cap_value != 0) continue;
    *renderer_pid = pid;
    found = 1;
    break;
  }
  closedir(directory);
  return found;
}

static int wait_for_renderer(pid_t browser_pid, pid_t runtime_session_id, pid_t *renderer_pid, int timeout_seconds) {
  double deadline = monotonic_seconds() + timeout_seconds;
  struct timespec pause = { .tv_sec = 0, .tv_nsec = 100000000 };
  while (monotonic_seconds() < deadline && !should_stop()) {
    int sandboxed = renderer_sandboxed(browser_pid, runtime_session_id, renderer_pid);
    if (sandboxed > 0) return 1;
    if (sandboxed < 0) return 0;
    nanosleep(&pause, NULL);
  }
  return 0;
}

static int read_parent_start_time(pid_t pid, unsigned long long *start_time) {
  char path[64];
  char contents[4096];
  char *separator;
  char *save = NULL;
  char *token;
  int field = 0;
  FILE *file;

  snprintf(path, sizeof(path), "/proc/%ld/stat", (long)pid);
  file = fopen(path, "re");
  if (!file) return 0;
  if (!fgets(contents, sizeof(contents), file)) {
    fclose(file);
    return 0;
  }
  fclose(file);
  separator = strrchr(contents, ')');
  if (!separator || separator[1] != ' ') return 0;
  for (token = strtok_r(separator + 2, " ", &save); token; token = strtok_r(NULL, " ", &save)) {
    field++;
    if (field == 20) {
      char *end = NULL;
      unsigned long long parsed = strtoull(token, &end, 10);
      if (!end || *end) return 0;
      *start_time = parsed;
      return 1;
    }
  }
  return 0;
}

static int parent_still_same(pid_t parent_pid, unsigned long long parent_start_time) {
  uid_t uid;
  unsigned long long current_start_time;
  return getppid() == parent_pid && process_uid(parent_pid, &uid) && uid == RAILS_UID &&
      read_parent_start_time(parent_pid, &current_start_time) && current_start_time == parent_start_time;
}

static int make_profile(int parent_fd, const char *token, char *profile, size_t profile_size) {
  int profile_fd;
  struct stat status;

  if (mkdirat(parent_fd, token, 0700) != 0) return 0;
  profile_fd = openat(parent_fd, token, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (profile_fd < 0) {
    unlinkat(parent_fd, token, AT_REMOVEDIR);
    return 0;
  }
  if (fchown(profile_fd, BROWSER_UID, BROWSER_GID) != 0 || fchmod(profile_fd, 0700) != 0 ||
      fstat(profile_fd, &status) != 0 || status.st_uid != BROWSER_UID || status.st_gid != BROWSER_GID || (status.st_mode & 0777) != 0700) {
    remove_tree_contents(profile_fd);
    close(profile_fd);
    unlinkat(parent_fd, token, AT_REMOVEDIR);
    return 0;
  }
  close(profile_fd);
  snprintf(profile, profile_size, "%s/%s", SUPERVISOR_DIR, token);
  return 1;
}

static int signal_and_wait(struct child_process *children, size_t child_count) {
  return terminate_browser_processes(children, child_count, 2.0, 3.0);
}

static int session_supervisor(const char *token, pid_t parent_pid, unsigned long long parent_start_time) {
  int parent_fd = -1;
  int runtime_lock_fd = -1;
  char profile[PATH_MAX];
  struct child_process children[MAX_CHILDREN] = { { 0, NULL }, { 0, NULL }, { 0, NULL } };
  size_t child_count = 0;
  pid_t child_group_id = 0;
  pid_t renderer_pid = 0;
  int startup_ok = 0;
  double deadline = monotonic_seconds() + MAX_LIFETIME_SECONDS;
  struct sigaction action;
  int cleanup_succeeded = 0;
  const char *failure_stage = "browser_setup";

  memset(&action, 0, sizeof(action));
  action.sa_handler = request_stop;
  sigemptyset(&action.sa_mask);
  sigaction(SIGTERM, &action, NULL);
  sigaction(SIGINT, &action, NULL);
  sigaction(SIGHUP, &action, NULL);
  runtime_parent_pid = parent_pid;
  runtime_parent_start_time = parent_start_time;
  failure_stage = "runtime_directory";
  parent_fd = supervisor_dir_fd();
  if (parent_fd < 0 || !parent_still_same(parent_pid, parent_start_time)) goto finish;
  failure_stage = "runtime_lock";
  runtime_lock_fd = open_runtime_lock(parent_fd);
  if (runtime_lock_fd < 0) goto finish;
  failure_stage = "stale_cleanup";
  if (!recover_stale_runtime(parent_fd)) goto finish;
  failure_stage = "profile";
  if (!make_profile(parent_fd, token, profile, sizeof(profile))) goto finish;
  failure_stage = "xvfb_start";
  if (spawn_child("xvfb", profile, child_group_id, &children[child_count]) != 0) goto finish;
  child_group_id = children[child_count++].pid;
  failure_stage = "x_display";
  if (!wait_for_socket(X_SOCKET, 8)) goto finish;
  failure_stage = "vnc_start";
  if (spawn_child("x11vnc", profile, child_group_id, &children[child_count]) != 0) goto finish;
  child_count++;
  failure_stage = "vnc_listener";
  if (!wait_for_port(VNC_PORT, 8)) goto finish;
  failure_stage = "chromium_start";
  if (spawn_child("chromium", profile, child_group_id, &children[child_count]) != 0) goto finish;
  {
    pid_t browser_pid = children[child_count++].pid;
    failure_stage = "cdp_listener";
    if (!wait_for_port(CDP_PORT, 12)) goto finish;
    failure_stage = "renderer_sandbox";
    if (!wait_for_renderer(browser_pid, getpid(), &renderer_pid, 20)) goto finish;
    failure_stage = "startup_pipe";
    if (dprintf(STDOUT_FILENO, "READY %ld %ld %ld %ld %ld\n", (long)children[0].pid, (long)children[1].pid, (long)browser_pid, (long)renderer_pid, (long)child_group_id) < 0) goto finish;
    startup_ok = 1;
  }

  while (!stop_requested && parent_still_same(parent_pid, parent_start_time) && monotonic_seconds() < deadline) {
    struct pollfd control = { .fd = STDIN_FILENO, .events = POLLIN | POLLHUP | POLLERR };
    int poll_result = poll(&control, 1, 250);
    size_t index;
    if (poll_result > 0 && (control.revents & (POLLHUP | POLLERR))) break;
    if (poll_result > 0 && (control.revents & POLLIN)) {
      char command[16];
      ssize_t length = read(STDIN_FILENO, command, sizeof(command));
      if (length <= 0 || (length < 5 || memcmp(command, "STOP\n", 5) != 0)) break;
      stop_requested = 1;
    }
    for (index = 0; index < child_count; index++) {
      int status;
      if (children[index].pid <= 0) {
        stop_requested = 1;
        break;
      }
      errno = 0;
      if (waitpid(children[index].pid, &status, WNOHANG) == children[index].pid) {
        children[index].pid = -1;
        stop_requested = 1;
        break;
      }
      if (errno != 0 && errno != EINTR && errno != ECHILD) stop_requested = 1;
    }
  }
finish:
  if (!startup_ok) dprintf(STDOUT_FILENO, "ERROR %s\n", failure_stage);
  if (runtime_lock_fd < 0) {
    cleanup_succeeded = child_count == 0;
  } else {
    cleanup_succeeded = signal_and_wait(children, child_count);
    if (cleanup_succeeded && parent_fd >= 0) cleanup_succeeded = remove_profile_at(parent_fd, token);
  }
  if (runtime_lock_fd >= 0) close(runtime_lock_fd);
  if (parent_fd >= 0) close(parent_fd);
  return cleanup_succeeded ? 0 : 1;
}

static int check_mode(void) {
  if (getuid() != RAILS_UID || geteuid() != 0 || getgid() != RAILS_GID || getegid() != RAILS_GID) return 1;
  if (dprintf(STDOUT_FILENO, "FINECO_SUPERVISOR_OK\n") < 0) return 1;
  return 0;
}

int main(int argc, char **argv) {
  long parsed_parent_pid;
  unsigned long long parent_start_time;
  int result;

  umask(077);
  clearenv();
  signal(SIGPIPE, SIG_IGN);
  if (argc == 2 && strcmp(argv[1], "--check") == 0) return check_mode();
  if (argc != 3) {
    dprintf(STDOUT_FILENO, "ERROR argument_count\n");
    return 1;
  }
  if (!token_valid(argv[1])) {
    dprintf(STDOUT_FILENO, "ERROR flow_token\n");
    return 1;
  }
  if (!parse_decimal(argv[2], 2, INT_MAX, &parsed_parent_pid)) {
    dprintf(STDOUT_FILENO, "ERROR parent_argument\n");
    return 1;
  }
  if (getuid() != RAILS_UID || geteuid() != 0 || getgid() != RAILS_GID || getegid() != RAILS_GID) {
    dprintf(STDOUT_FILENO, "ERROR caller_identity\n");
    return 1;
  }
  {
    uid_t parent_uid;
    if (getppid() != (pid_t)parsed_parent_pid) {
      dprintf(STDOUT_FILENO, "ERROR caller_parent\n");
      return 1;
    }
    if (!process_uid((pid_t)parsed_parent_pid, &parent_uid) || parent_uid != RAILS_UID) {
      dprintf(STDOUT_FILENO, "ERROR caller_uid\n");
      return 1;
    }
    if (!read_parent_start_time((pid_t)parsed_parent_pid, &parent_start_time)) {
      dprintf(STDOUT_FILENO, "ERROR caller_start_time\n");
      return 1;
    }
  }
  runtime_parent_pid = (pid_t)parsed_parent_pid;
  runtime_parent_start_time = parent_start_time;
  if (setsid() != getpid()) {
    dprintf(STDOUT_FILENO, "ERROR setsid\n");
    return 1;
  }
  if (close_except(-1) != 0) {
    dprintf(STDOUT_FILENO, "ERROR close_fds\n");
    return 1;
  }
  result = session_supervisor(argv[1], (pid_t)parsed_parent_pid, parent_start_time);
  return result;
}
