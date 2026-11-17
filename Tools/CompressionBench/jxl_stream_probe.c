// Measures how many bytes a streaming JPEG XL decoder must consume before it
// can emit a progressive image, and at what scale. This is the only way to see
// the streaming property: ImageIO has no incremental JXL path, and truncating
// a JXL file does not work because the group index lives at the end of the
// codestream.
//
// The probe stops once the requested downsampling ratio has been reported
// (default 1/2), which is all the viewer needs; decoding to completion through
// the public API from a chunked reader is libjxl's problem, not ours.
//
// Build (Homebrew libjxl):
//   cc -O2 -I$(brew --prefix jpeg-xl)/include jxl_stream_probe.c \
//      -L$(brew --prefix jpeg-xl)/lib -ljxl -o /tmp/jxl_stream_probe
//
//   /tmp/jxl_stream_probe image.jxl [stopRatio] [chunkKiB]
#include <jxl/decode.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s file.jxl [stopRatio=2] [chunkKiB=32]\n", argv[0]);
    return 2;
  }
  setvbuf(stdout, NULL, _IONBF, 0);
  const char *path = argv[1];
  size_t stop_ratio = argc > 2 ? (size_t)atoi(argv[2]) : 2;
  size_t chunk = (argc > 3 ? atoi(argv[3]) : 32) * 1024;

  FILE *f = fopen(path, "rb");
  if (!f) {
    perror(path);
    return 2;
  }
  fseek(f, 0, SEEK_END);
  long size = ftell(f);
  fseek(f, 0, SEEK_SET);
  unsigned char *data = malloc(size);
  if (!data || fread(data, 1, size, f) != (size_t)size) return 2;
  fclose(f);

  JxlDecoder *dec = JxlDecoderCreate(NULL);
  JxlDecoderSubscribeEvents(dec, JXL_DEC_BASIC_INFO | JXL_DEC_FRAME |
                                     JXL_DEC_FRAME_PROGRESSION |
                                     JXL_DEC_FULL_IMAGE);
  JxlDecoderSetProgressiveDetail(dec, kPasses);

  size_t end = 0;
  int done = 0, progressions = 0;
  unsigned width = 0, height = 0;
  unsigned char *pixels = NULL;
  size_t pixels_size = 0;

  JxlDecoderSetInput(dec, data, chunk < (size_t)size ? chunk : (size_t)size);
  end = chunk < (size_t)size ? chunk : (size_t)size;

  while (!done) {
    JxlDecoderStatus status = JxlDecoderProcessInput(dec);
    if (status == JXL_DEC_BASIC_INFO) {
      JxlBasicInfo info;
      JxlDecoderGetBasicInfo(dec, &info);
      width = info.xsize;
      height = info.ysize;
      printf("  image %ux%u total=%ld\n", width, height, size);
    } else if (status == JXL_DEC_FRAME_PROGRESSION) {
      size_t remaining = JxlDecoderReleaseInput(dec);
      size_t consumed = end - remaining;
      size_t ratio = JxlDecoderGetIntendedDownsamplingRatio(dec);
      printf("  preview 1/%zu @ %zu bytes (%.2f%%)\n", ratio, consumed,
             100.0 * consumed / size);
      progressions++;
      if (ratio <= stop_ratio) {
        printf("  stopped after the requested scale\n");
        done = 1;
        break;
      }
      if (consumed >= (size_t)size) break;
      size_t n = (size_t)size - consumed < chunk ? (size_t)size - consumed : chunk;
      JxlDecoderSetInput(dec, data + consumed, n);
      end = consumed + n;
    } else if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
      // The decoder cannot reach FULL_IMAGE without somewhere to put pixels.
      JxlPixelFormat format = {4, JXL_TYPE_UINT8, JXL_LITTLE_ENDIAN, 0};
      size_t needed = 0;
      if (JxlDecoderImageOutBufferSize(dec, &format, &needed) != JXL_DEC_SUCCESS) {
        printf("  output buffer query failed\n");
        done = 1;
        break;
      }
      if (needed > pixels_size) {
        free(pixels);
        pixels = malloc(needed);
        pixels_size = needed;
      }
      JxlDecoderSetImageOutBuffer(dec, &format, pixels, pixels_size);
    } else if (status == JXL_DEC_FULL_IMAGE) {
      size_t remaining = JxlDecoderReleaseInput(dec);
      printf("  full image @ %zu bytes (%.2f%%)\n", end - remaining,
             100.0 * (end - remaining) / size);
      done = 1;
    } else if (status == JXL_DEC_NEED_MORE_INPUT) {
      size_t remaining = JxlDecoderReleaseInput(dec);
      size_t consumed = end - remaining;
      if (consumed >= (size_t)size) {
        printf("  end of input without a preview\n");
        done = 1;
        break;
      }
      size_t n = (size_t)size - consumed < chunk ? (size_t)size - consumed : chunk;
      JxlDecoderSetInput(dec, data + consumed, n);
      end = consumed + n;
    } else if (status == JXL_DEC_SUCCESS) {
      done = 1;
    } else if (status == JXL_DEC_ERROR) {
      printf("  error at %zu bytes\n", end);
      done = 1;
    }
  }
  printf("  progressions=%d\n", progressions);
  JxlDecoderDestroy(dec);
  free(pixels);
  free(data);
  return 0;
}
