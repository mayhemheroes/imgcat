/*
 * In-process libFuzzer harness for imgcat.
 *
 * The upstream Mayhem target was a raw file-input CLI (`imgcat @@`) which reads an
 * image file, decodes it (CImg + libpng/libjpeg), rescales it, and renders it to the
 * terminal. As a black-box CLI it produced no coverage, so it is converted here to an
 * in-process harness that drives the SAME code path: print_image() -> load_image()
 * (CImg decode + resize) -> the colour-quantisation printers (rgbtree). The fuzz input
 * is the image file bytes; we exercise every output format and both the full-height and
 * half-height renderers so the decoder, the resize logic and the rgb kd-tree are all hit.
 */
#define _GNU_SOURCE
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>

#include "print_image.h"

/* Rendering writes escape sequences to stdout; sink them to a scratch file under /tmp so the
 * harness doesn't flood the fuzz log. (Not /dev/null — an absolute device path trips the
 * read-only-image lint; /tmp is the sanctioned scratch location.) */
static int sink_fd = -1;

int LLVMFuzzerInitialize(int *argc, char ***argv) {
    (void)argc;
    (void)argv;
    sink_fd = open("/tmp/imgcat_fuzz_sink", O_WRONLY | O_CREAT | O_TRUNC, 0600);
    return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    /* CImg decodes by FILENAME (it opens/reopens the path), so stage the input to a
     * temp file — exactly what imgcat itself does for piped stdin. */
    char path[] = "/tmp/imgcat_fuzz_XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0) {
        return 0;
    }
    if (size > 0) {
        ssize_t off = 0;
        while ((size_t)off < size) {
            ssize_t n = write(fd, data + off, size - (size_t)off);
            if (n <= 0) {
                break;
            }
            off += n;
        }
    }
    close(fd);

    fflush(stdout);
    int saved_stdout = dup(STDOUT_FILENO);
    if (sink_fd >= 0) {
        lseek(sink_fd, 0, SEEK_SET);
        dup2(sink_fd, STDOUT_FILENO);
    }

    static const Format formats[] = {
        F_8_COLOR, F_256_COLOR, F_TRUE_COLOR, F_ITERM2
    };
    for (unsigned i = 0; i < sizeof(formats) / sizeof(formats[0]); i++) {
        for (int half = 0; half < 2; half++) {
            PrintRequest request;
            memset(&request, 0, sizeof(request));
            request.filename = path;
            /* Bound the decoded/rescaled image so a giant declared geometry can't blow up
             * output — exercises the aspect-ratio resize path in load_image(). */
            request.max_width = 80;
            request.max_height = 24;
            request.desired_width = 80;
            request.desired_height = 24;
            request.half_height = (bool)half;
            request.preserve_aspect_ratio = true;
            request.format = formats[i];
            print_image(&request);
        }
    }

    fflush(stdout);
    if (saved_stdout >= 0) {
        dup2(saved_stdout, STDOUT_FILENO);
        close(saved_stdout);
    }
    unlink(path);
    return 0;
}
