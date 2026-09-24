# Synthetic host test clip

`clip-1600x1000.h264` is what `Vantage.SyntheticHost` streams in a loop: an Annex-B H.264
elementary stream, 1600 × 1000, 30 fps, 4 s, High profile, no B-frames, an IDR every 30 frames
(so a keyframe request jumps to the next second), SPS/PPS repeated before every IDR, BT.709 video
range. Made once with:

```sh
ffmpeg -f lavfi -i testsrc2=size=1600x1000:rate=30 -t 4 -c:v libx264 -profile:v high -pix_fmt yuv420p \
  -bf 0 -g 30 -keyint_min 30 -sc_threshold 0 -b:v 2M -x264-params repeat-headers=1 \
  -colorspace bt709 -color_primaries bt709 -color_trc iec61966-2-1 -color_range tv \
  -f h264 clip-1600x1000.h264
```

Nothing needs ffmpeg at run time.
