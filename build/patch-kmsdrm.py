import pathlib, sys

S = pathlib.Path("/root/mkxp-z/linux/downloads/armv7old/sdl2/src/video/kmsdrm")

# ---------------------------------------------------------------------------
# PATCH A -- fall back to a synchronous pageflip when the async one is rejected.
#
# SDL asks for DRM_MODE_PAGE_FLIP_ASYNC whenever vsync is off and the driver
# advertises DRM_CAP_ASYNC_PAGE_FLIP. Rockchip's DRM driver (RK3326: R36S,
# RG351, ...) advertises the capability but rejects every async flip with
# -EINVAL, so on those devices EVERY frame fails to reach the screen: the game
# ends up rendering into the buffer that is still being scanned out, which
# shows up as tearing/half-drawn text and unresponsive-feeling input.
# ---------------------------------------------------------------------------
gles = S / "SDL_kmsdrmopengles.c"
t = gles.read_text()

OLD_A = """        ret = KMSDRM_drmModePageFlip(viddata->drm_fd, dispdata->crtc->crtc_id,
                                     fb_info->fb_id, flip_flags, &windata->waiting_for_flip);

        if (ret == 0) {"""

NEW_A = """        ret = KMSDRM_drmModePageFlip(viddata->drm_fd, dispdata->crtc->crtc_id,
                                     fb_info->fb_id, flip_flags, &windata->waiting_for_flip);

        /* Some drivers advertise DRM_CAP_ASYNC_PAGE_FLIP but then reject every
           async flip with -EINVAL (Rockchip's, as used by RK3326 handhelds,
           is one). Without this fallback the flip fails on every single frame,
           so nothing the game draws is ever scanned out properly.
           Retry synchronously and stop requesting async from now on, making
           this cost one rejected ioctl per session rather than one per frame.
           A synchronous flip is safe at this point: SwapWindow already waited
           for any previous flip to complete, so the CRTC cannot be busy. */
        if (ret && (flip_flags & DRM_MODE_PAGE_FLIP_ASYNC)) {
            viddata->async_pageflip_support = SDL_FALSE;
            flip_flags &= ~DRM_MODE_PAGE_FLIP_ASYNC;
            ret = KMSDRM_drmModePageFlip(viddata->drm_fd, dispdata->crtc->crtc_id,
                                         fb_info->fb_id, flip_flags, &windata->waiting_for_flip);
            if (ret == 0) {
                SDL_LogInfo(SDL_LOG_CATEGORY_VIDEO,
                    "Async pageflip rejected by the driver; using synchronous flips.");
            }
        }

        if (ret == 0) {"""

if OLD_A not in t:
    sys.exit("FATAL: pageflip call site not found")
gles.write_text(t.replace(OLD_A, NEW_A))
print("PATCH A applied: async pageflip -> synchronous fallback")

# ---------------------------------------------------------------------------
# PATCH B -- actually honour SDL_VIDEO_DOUBLE_BUFFER.
#
# SDL_WindowData carries a `double_buffer` flag that makes SwapWindow wait for
# the flip right after submitting it, trading one buffer of throughput for one
# frame less of input latency. In this tree nothing ever sets it, so the option
# is dead code and the extra frame of lag is unavoidable. Wire it back up to
# the documented hint.
# ---------------------------------------------------------------------------
vid = S / "SDL_kmsdrmvideo.c"
t = vid.read_text()

OLD_B = """    /* Setup driver data for this window */
    windata->viddata = viddata;
    window->driverdata = windata;"""

NEW_B = """    /* Setup driver data for this window */
    windata->viddata = viddata;
    window->driverdata = windata;

    /* Waiting for the flip immediately after queueing it costs some throughput
       but removes a frame of input latency, which matters much more on a
       handheld running a 2D game. Nothing else in this driver sets the flag,
       so read the documented hint here. */
    windata->double_buffer = SDL_GetHintBoolean(SDL_HINT_VIDEO_DOUBLE_BUFFER, SDL_FALSE);"""

if OLD_B not in t:
    sys.exit("FATAL: window-data init site not found")
t = t.replace(OLD_B, NEW_B)
if "#include \"SDL_hints.h\"" not in t:
    sys.exit("FATAL: SDL_hints.h not included in SDL_kmsdrmvideo.c")
vid.write_text(t)
print("PATCH B applied: SDL_VIDEO_DOUBLE_BUFFER honoured")
