#!/bin/zsh
# Generates the format-matrix fixtures in Tests/Fixtures/formats with ffmpeg:
# 3-second test patterns in every common codec/container, plus edge cases.
# Re-run only to regenerate; the outputs are committed (small, deterministic enough).
set -e
cd "${0:A:h:h}/Tests/Fixtures/formats"
F=(ffmpeg -hide_banner -loglevel error -y)
V="testsrc2=size=320x180:rate=30:duration=3"
A="sine=frequency=440:duration=3"

"${F[@]}" -f lavfi -i $V -f lavfi -i $A -c:v libx264 -pix_fmt yuv420p -c:a aac h264_aac.mp4
"${F[@]}" -f lavfi -i $V -f lavfi -i $A -c:v libx265 -tag:v hvc1 -x265-params log-level=error -c:a aac hevc_aac.mp4
"${F[@]}" -f lavfi -i $V -f lavfi -i $A -c:v libx265 -pix_fmt yuv420p10le -x265-params log-level=error -c:a aac hevc_10bit.mkv
"${F[@]}" -f lavfi -i $V -f lavfi -i $A -c:v libvpx-vp9 -b:v 200k -c:a libopus vp9_opus.webm
"${F[@]}" -f lavfi -i $V -f lavfi -i $A -c:v libvpx -b:v 200k -c:a libopus vp8_opus.webm
"${F[@]}" -f lavfi -i $V -f lavfi -i $A -c:v libsvtav1 -preset 12 -svtav1-params verbosity=0 -c:a libopus av1_opus.mkv
"${F[@]}" -f lavfi -i $V -f lavfi -i $A -c:v mpeg4 -q:v 5 -c:a libmp3lame mpeg4_mp3.avi
"${F[@]}" -f lavfi -i $V -f lavfi -i $A -c:v mpeg2video -c:a ac3 mpeg2_ac3.ts
"${F[@]}" -f lavfi -i $V -f lavfi -i $A -c:v mpeg2video -c:a mp2 -f vob mpeg2_mp2.mpg
"${F[@]}" -f lavfi -i $V -f lavfi -i $A -c:v prores_ks -profile:v 0 -c:a pcm_s16le prores_pcm.mov
"${F[@]}" -f lavfi -i $V -f lavfi -i $A -c:v libx264 -pix_fmt yuv420p -c:a aac h264_aac.flv
"${F[@]}" -f lavfi -i $V -f lavfi -i $A -c:v wmv2 -c:a libmp3lame wmv2_mp3.wmv
"${F[@]}" -f lavfi -i "testsrc2=size=176x144:rate=15:duration=3" -f lavfi -i $A -c:v h263 -c:a aac -ar 16000 -ac 1 h263_aac.3gp
"${F[@]}" -f lavfi -i $V -f lavfi -i $A -c:v mjpeg -q:v 5 -c:a pcm_s16le mjpeg_pcm.avi
"${F[@]}" -f lavfi -i "testsrc2=size=180x320:rate=30:duration=3" -f lavfi -i $A -c:v libx264 -pix_fmt yuv420p -c:a aac vertical_9x16.mp4
"${F[@]}" -f lavfi -i "testsrc2=size=320x180:rate=60:duration=3" -f lavfi -i $A -c:v libx264 -pix_fmt yuv420p -c:a aac hfr_60fps.mp4
# phone-style rotation flag: stored 320x180, displayed 180x320
"${F[@]}" -f lavfi -i $V -f lavfi -i $A -c:v libx264 -pix_fmt yuv420p -c:a aac -display_rotation:v:0 90 rotated_90.mp4 2>/dev/null \
  || "${F[@]}" -display_rotation 90 -i h264_aac.mp4 -c copy rotated_90.mp4
# two audio tracks (zh/en) + an embedded SRT subtitle
cat > subs.srt <<'SRT'
1
00:00:00,500 --> 00:00:02,500
字幕测试 subtitle test
SRT
"${F[@]}" -f lavfi -i $V -f lavfi -i $A -f lavfi -i "sine=frequency=880:duration=3" -i subs.srt \
  -map 0:v -map 1:a -map 2:a -map 3:s -c:v libx264 -pix_fmt yuv420p -c:a aac -c:s srt \
  -metadata:s:a:0 language=chi -metadata:s:a:1 language=eng -metadata:s:s:0 language=chi multi_audio_subs.mkv
rm -f subs.srt
# audio only, and a file cut off mid-download
"${F[@]}" -f lavfi -i $A -c:a libmp3lame audio_only.mp3
"${F[@]}" -f lavfi -i $A -c:a flac audio_only.flac
"${F[@]}" -f lavfi -i "testsrc2=size=320x180:rate=30:duration=6" -f lavfi -i "sine=duration=6" -c:v libx264 -pix_fmt yuv420p \
  -c:a aac -movflags +faststart truncated_source.mp4
head -c $(( $(stat -f%z truncated_source.mp4) * 55 / 100 )) truncated_source.mp4 > truncated.mp4 && rm truncated_source.mp4
cp h264_aac.mkv "测试 视频 #1 (中文)&'名字.mkv" 2>/dev/null || "${F[@]}" -i h264_aac.mp4 -c copy "测试 视频 #1 (中文)&'名字.mkv"
ls -la
