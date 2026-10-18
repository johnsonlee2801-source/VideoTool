# Third-party software in VideoTool

VideoTool plays media with **mpv** and **FFmpeg**, packaged for Apple platforms by
**MPVKit** (LGPL build). Every library below ships as a separate dynamic framework in
`VideoTool.app/Contents/Frameworks/` and can be replaced with a compatible build, as
the LGPL requires. Source code for each component is available at the address given;
MPVKit's build scripts (https://github.com/mpvkit/MPVKit, tag 1.1.0-n9.0.2)
reproduce the exact binaries.

Licences were checked against each project's own licence file on 2026-10-18.

| Component | Frameworks | Licence | Source |
|---|---|---|---|
| mpv (built without GPL-only files) | Libmpv | LGPL-2.1-or-later | https://github.com/mpv-player/mpv |
| FFmpeg (LGPL configuration) | Libavcodec, Libavdevice, Libavfilter, Libavformat, Libavutil, Libswresample, Libswscale | LGPL-2.1-or-later | https://ffmpeg.org |
| MPVKit (packaging, build scripts) | — | LGPL-3.0 | https://github.com/mpvkit/MPVKit |
| libass | Libass | ISC | https://github.com/libass/libass |
| libbluray | Libbluray | LGPL-2.1-or-later | https://code.videolan.org/videolan/libbluray |
| OpenSSL | Libcrypto, Libssl | Apache-2.0 | https://github.com/openssl/openssl |
| dav1d | Libdav1d | BSD-2-Clause | https://code.videolan.org/videolan/dav1d |
| libdovi (dovi_tool) | Libdovi | MIT | https://github.com/quietvoid/dovi_tool |
| FreeType | Libfreetype | FreeType License (FTL), chosen from FTL / GPL-2.0 | https://freetype.org |
| GNU FriBidi | Libfribidi | LGPL-2.1-or-later | https://github.com/fribidi/fribidi |
| HarfBuzz | Libharfbuzz | MIT ("Old MIT") | https://github.com/harfbuzz/harfbuzz |
| LuaJIT | Libluajit | MIT | https://luajit.org |
| libplacebo | Libplacebo | LGPL-2.1-or-later | https://code.videolan.org/videolan/libplacebo |
| shaderc (with glslang, SPIRV-Tools) | Libshaderc_combined | Apache-2.0 (components: BSD-3-Clause, MIT, Apache-2.0) | https://github.com/google/shaderc |
| uavs3d | Libuavs3d | BSD-3-Clause | https://github.com/uavs3/uavs3d |
| uchardet | Libuchardet | MPL-1.1 / GPL-2.0-or-later / LGPL-2.1-or-later (MPL-1.1 used) | https://www.freedesktop.org/wiki/Software/uchardet/ |
| libunibreak | Libunibreak | Zlib | https://github.com/adah1972/libunibreak |
| GMP | gmp | LGPL-3.0-or-later (dual with GPL-2.0-or-later) | https://gmplib.org |
| GnuTLS (library) | gnutls | LGPL-2.1-or-later | https://gnutls.org |
| Nettle | nettle, hogweed | LGPL-3.0-or-later (dual with GPL-2.0-or-later) | https://www.lysator.liu.se/~nisse/nettle/ |
| Little CMS | lcms2 | MIT | https://github.com/mm2/Little-CMS |

Not shipped: VideoTool links the LGPL product of MPVKit only. Its GPL variant
(`MPVKit-GPL`, which adds Samba support) is not used.

Development-only tools (not part of the app): XcodeGen, ffmpeg (to generate test
videos), luajit (prototype tests).
