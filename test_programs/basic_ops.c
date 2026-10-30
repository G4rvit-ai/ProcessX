// basic_ops.c: a small, predictable program for ProcessX to trace.
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define PATH "/tmp/processx_demo.txt"

// Print a message using the write system call directly
static void say(const char *msg) {
    write(STDOUT_FILENO, msg, strlen(msg));
}

int main(void) {
    const char *text = "hello from ProcessX\n";
    char buf[64];

    // 1. File-system: create the file and write to it
    int fd = open(PATH, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd < 0) { perror("open"); return 1; }
    write(fd, text, strlen(text));
    close(fd);
    say("file written\n");

    // 2. File-system: read it back
    fd = open(PATH, O_RDONLY);
    if (fd < 0) { perror("open"); return 1; }
    read(fd, buf, sizeof(buf));
    close(fd);
    say("file read\n");

    // 3. Process creation: fork a child that runs echo; the parent waits
    pid_t pid = fork();
    if (pid < 0) { perror("fork"); return 1; }
    if (pid == 0) {
        execl("/bin/echo", "echo", "hello from the child process", (char *)NULL);
        _exit(127);  // only reached if exec fails
    }
    waitpid(pid, NULL, 0);
    say("child finished\n");

    // 4. File-system: delete the file
    unlink(PATH);
    say("file deleted\n");
    return 0;
}
