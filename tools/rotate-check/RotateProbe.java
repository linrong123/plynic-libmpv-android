// app_process harness for rotation on the texture path's VO (vo=gpu into a
// Surface, what media_kit_video's Android texture gives mpv): an RGBX
// ImageReader (the format mpv's EGL window surface has) stands in for the Flutter texture's Surface, and every frame
// mpv renders into it is read back. The clips are four coloured quadrants
// (red, green / blue, white), so a frame's orientation is the colour of each
// quadrant of the picture: "RGBW" upright, "BRWG" turned 90 degrees
// clockwise, "WBGR" 180, "GWRB" 270. A line is printed whenever the layout
// or the picture's position changes.
//
//   RotateProbe <libmpv.so> <librotprobe.so> <WxH>[:private] <url> [opt=value | +action ...]
//
// ":private": an ImageReader MediaCodec can decode into (vo=mediacodec_embed);
// its frames are counted, not read.
//
// "@0" in an option or +set value stands for the JNI global ref of the
// Surface. The actions (rotprobe.c) run after FILE_LOADED.
import android.graphics.ImageFormat;
import android.graphics.PixelFormat;
import android.hardware.HardwareBuffer;
import android.media.Image;
import android.media.ImageReader;
import android.view.Surface;
import java.nio.ByteBuffer;
import java.util.Arrays;

public class RotateProbe {
    static native int run(Surface surface, String[] args);

    static volatile boolean done;

    static double now() { return System.nanoTime() / 1e9; }

    static char colour(int r, int g, int b) {
        if (r > 150 && g > 150 && b > 150) return 'W';
        if (r > 150 && g < 100 && b < 100) return 'R';
        if (g > 150 && r < 100 && b < 100) return 'G';
        if (b > 150 && r < 100 && g < 100) return 'B';
        return '?';
    }

    static class Watch extends Thread {
        final ImageReader r;
        int frames;
        String last = "";
        Watch(ImageReader r) { this.r = r; }
        public void run() {
            while (!done) {
                Image im;
                try {
                    while ((im = r.acquireNextImage()) != null) {
                        frames++;
                        if (im.getFormat() == PixelFormat.RGBX_8888)
                            inspect(im);
                        else if (frames == 1)
                            System.out.printf("VIDEO first frame at %.3f (format 0x%x, not read)%n", now(), im.getFormat());
                        im.close();
                    }
                } catch (IllegalStateException e) {
                    System.out.println("VIDEO acquire: " + e);
                }
                try { Thread.sleep(5); } catch (InterruptedException e) { return; }
            }
        }
        void inspect(Image im) {
            int w = im.getWidth(), h = im.getHeight();
            Image.Plane pl = im.getPlanes()[0];
            ByteBuffer b = pl.getBuffer();
            int stride = pl.getRowStride(), px = pl.getPixelStride();
            // the picture: everything that is not the black bars around it
            int x0 = w, y0 = h, x1 = -1, y1 = -1;
            for (int y = 0; y < h; y += 2) {
                for (int x = 0; x < w; x += 2) {
                    int i = y * stride + x * px;
                    int m = Math.max(b.get(i) & 0xff, Math.max(b.get(i + 1) & 0xff, b.get(i + 2) & 0xff));
                    if (m > 60) {
                        if (x < x0) x0 = x; if (x > x1) x1 = x;
                        if (y < y0) y0 = y; if (y > y1) y1 = y;
                    }
                }
            }
            String state;
            if (x1 < 0) {
                state = "layout=none";
            } else {
                StringBuilder s = new StringBuilder("layout=");
                int pw = x1 - x0 + 1, ph = y1 - y0 + 1;
                for (int qy = 0; qy < 2; qy++) {
                    for (int qx = 0; qx < 2; qx++) {
                        int x = x0 + pw * (1 + 2 * qx) / 4, y = y0 + ph * (1 + 2 * qy) / 4;
                        int i = y * stride + x * px;
                        s.append(colour(b.get(i) & 0xff, b.get(i + 1) & 0xff, b.get(i + 2) & 0xff));
                    }
                }
                s.append(String.format(" picture=%dx%d at %d,%d", pw, ph, x0, y0));
                state = s.toString();
            }
            if (!state.equals(last)) {
                last = state;
                System.out.printf("VIDEO frame %d at %.3f %dx%d %s%n", frames, now(), w, h, state);
            }
        }
    }

    public static void main(String[] a) throws Exception {
        System.load(a[0]);   // libmpv.so first, like the app's DynamicLibrary.open
        System.load(a[1]);
        boolean priv = a[2].endsWith(":private");
        String[] wh = a[2].replace(":private", "").split("x");
        int w = Integer.parseInt(wh[0]), h = Integer.parseInt(wh[1]);
        String[] rest = Arrays.copyOfRange(a, 3, a.length);
        ImageReader video = priv
                ? ImageReader.newInstance(w, h, ImageFormat.PRIVATE, 4, HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE)
                : ImageReader.newInstance(w, h, PixelFormat.RGBX_8888, 3,
                        HardwareBuffer.USAGE_GPU_COLOR_OUTPUT | HardwareBuffer.USAGE_CPU_READ_OFTEN);
        Watch watch = new Watch(video);
        watch.start();
        System.out.printf("START at %.3f surface=%dx%d%n", now(), w, h);
        int rc = run(video.getSurface(), rest);
        Thread.sleep(300);
        done = true;
        watch.join();
        System.out.printf("VIDEO frames=%d%n", watch.frames);
        System.out.println("EXIT rc=" + rc);
        System.exit(rc);
    }
}
