/* variants.c - a test program with a normal mode and five deliberately odd modes.
 *
 * Build:  gcc -Wall -Wextra -o test_programs/variants.out test_programs/variants.c
 * Run:    test_programs/variants.out [secret|homewrite|spawn|net|crash]
 *
 * Normal (no argument): write a file in /tmp, read it back, delete it, and run /bin/echo.
 *
 * Odd modes do everything the normal mode does, and then one more thing that a
 * baseline built from normal runs has never seen. All of them are harmless:
 *   secret     read /etc/passwd (a world-readable file, but a sensitive one)
 *   homewrite  write a file in your home folder, then delete it again
 *   spawn      start three programs the normal mode never starts (date, uname, true)
 *   net        open a network connection to 127.0.0.1 port 9 (this computer only; nothing listens there)
 *   crash      crash with a segmentation fault (core files are switched off first)
 */
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

static void run(const char *path, char *const argv[]) {
    pid_t pid = fork();
    if (pid == 0) {
        execv(path, argv);
        _exit(127);
    }
    int status;
    waitpid(pid, &status, 0);
}

static void read_first_line(const char *path) {
    char line[256];
    FILE *f = fopen(path, "r");
    if (f) {
        if (!fgets(line, sizeof line, f)) line[0] = '\0';
        fclose(f);
    }
}

static void write_and_delete(const char *path) {
    FILE *f = fopen(path, "w");
    if (f) {
        fputs("hello\n", f);
        fclose(f);
    }
    read_first_line(path);
    unlink(path);
}

int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "normal";
    if (strcmp(mode, "normal") && strcmp(mode, "secret") && strcmp(mode, "homewrite") &&
        strcmp(mode, "spawn") && strcmp(mode, "net") && strcmp(mode, "crash")) {
        fprintf(stderr, "usage: %s [secret|homewrite|spawn|net|crash]\n", argv[0]);
        return 2;
    }

    /* the normal behaviour, in every mode */
    write_and_delete("/tmp/processx_variants.txt");
    char *echo_args[] = {"echo", "hello", NULL};
    run("/bin/echo", echo_args);

    if (!strcmp(mode, "secret")) {
        read_first_line("/etc/passwd");
    } else if (!strcmp(mode, "homewrite")) {
        const char *home = getenv("HOME");
        char path[512];
        if (home && snprintf(path, sizeof path, "%s/processx_variant.txt", home) < (int)sizeof path)
            write_and_delete(path);
    } else if (!strcmp(mode, "spawn")) {
        char *date_args[] = {"date", NULL}, *uname_args[] = {"uname", NULL}, *true_args[] = {"true", NULL};
        run("/bin/date", date_args);
        run("/bin/uname", uname_args);
        run("/bin/true", true_args);
    } else if (!strcmp(mode, "net")) {
        int s = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof addr);
        addr.sin_family = AF_INET;
        addr.sin_port = htons(9);
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
        connect(s, (struct sockaddr *)&addr, sizeof addr);
        close(s);
    } else if (!strcmp(mode, "crash")) {
        struct rlimit no_core = {0, 0};
        setrlimit(RLIMIT_CORE, &no_core);
        volatile int *nothing = NULL;
        *nothing = 1;
    }
    return 0;
}
