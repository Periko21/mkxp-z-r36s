/* ---------------------------------------------------------------------------
 * exitwatch -- give an ArkOS port the console's usual SELECT+START quit combo.
 *
 * mkxp-z reads the gamepad through SDL and knows nothing about ArkOS's global
 * "hold SELECT+START to quit" convention, so a running game can only be left
 * by resetting the handheld. This watches the raw evdev devices READ-ONLY
 * (never grabbing them, so SDL keeps receiving every event exactly as before)
 * and, when both buttons are held at once, asks the game to quit.
 *
 * SIGTERM first: SDL turns it into an SDL_QUIT event, so the engine shuts down
 * cleanly and saves nothing halfway. SIGKILL only if it is still alive after a
 * grace period.
 *
 *     usage: exitwatch <pid-to-signal>
 * ------------------------------------------------------------------------ */
#include <dirent.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAX_DEVS 32
#define GRACE_SECONDS 5

int main(int argc, char **argv)
{
    struct pollfd fds[MAX_DEVS];
    int nfds = 0;
    int select_down = 0, start_down = 0;
    pid_t target;
    DIR *dir;
    struct dirent *ent;

    if (argc != 2) {
        fprintf(stderr, "usage: %s <pid>\n", argv[0]);
        return 2;
    }
    target = (pid_t)atoi(argv[1]);
    if (target <= 0) {
        return 2;
    }

    dir = opendir("/dev/input");
    if (!dir) {
        return 0; /* nothing to watch; stay out of the way */
    }
    while ((ent = readdir(dir)) && nfds < MAX_DEVS) {
        char path[300];
        int fd;

        if (strncmp(ent->d_name, "event", 5) != 0) {
            continue;
        }
        snprintf(path, sizeof(path), "/dev/input/%s", ent->d_name);

        /* O_RDONLY, and deliberately no EVIOCGRAB: this must stay a passive
           observer or it would steal the controller from the game. */
        fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0) {
            continue;
        }
        fds[nfds].fd = fd;
        fds[nfds].events = POLLIN;
        nfds++;
    }
    closedir(dir);

    if (nfds == 0) {
        return 0;
    }

    for (;;) {
        int i;

        /* Time out periodically so the watcher notices the game exiting on its
           own and does not linger forever holding the devices open. */
        if (poll(fds, nfds, 1000) < 0) {
            break;
        }
        if (kill(target, 0) != 0) {
            break; /* game already gone */
        }

        for (i = 0; i < nfds; i++) {
            struct input_event ev;

            if (!(fds[i].revents & POLLIN)) {
                continue;
            }
            while (read(fds[i].fd, &ev, sizeof(ev)) == (ssize_t)sizeof(ev)) {
                if (ev.type != EV_KEY || ev.value == 2 /* autorepeat */) {
                    continue;
                }
                if (ev.code == BTN_SELECT) {
                    select_down = ev.value;
                } else if (ev.code == BTN_START) {
                    start_down = ev.value;
                }
            }
        }

        if (select_down && start_down) {
            int waited;

            kill(target, SIGTERM);
            for (waited = 0; waited < GRACE_SECONDS * 10; waited++) {
                if (kill(target, 0) != 0) {
                    return 0;
                }
                usleep(100000);
            }
            kill(target, SIGKILL);
            return 0;
        }
    }

    return 0;
}
