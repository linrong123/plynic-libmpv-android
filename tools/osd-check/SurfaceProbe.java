// app_process harness for the surface-based VOs (mediacodec_embed,
// mediacodec_osd, gpu): ImageReader surfaces stand in for the app's
// SurfaceViews. The video surface's frames are counted; every OSD buffer the
// VO posts is inspected (opaque pixels, bounding box) and a few are saved as
// PNG.
//
//   SurfaceProbe <libmpv.so> <libsurfprobe.so> <mode: embed|osd|gpu> <WxH> <outdir> <url> [opt=value | +action ...]
//
// "@0"/"@1" in an option value stands for the JNI global ref of the video /
// OSD surface. Actions are run by the native side after FILE_LOADED.
import android.graphics.Bitmap;
import android.graphics.ImageFormat;
import android.graphics.PixelFormat;
import android.hardware.HardwareBuffer;
import android.media.Image;
import android.media.ImageReader;
import android.view.Surface;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;
import java.util.Arrays;

public class SurfaceProbe {
    static native int run(Surface[] surfaces, String[] args);

    static volatile boolean done;

    static double now() { return System.nanoTime() / 1e9; }

    static class VideoWatch extends Thread {
        final ImageReader r;
        volatile int frames;
        long firstTs = -1, lastTs = -1;
        VideoWatch(ImageReader r) { this.r = r; }
        public void run() {
            while (!done) {
                Image im;
                try {
                    while ((im = r.acquireNextImage()) != null) {
                        if (firstTs < 0) {
                            firstTs = im.getTimestamp();
                            System.out.printf("VIDEO first frame at %.3f (%dx%d fmt=0x%x)%n",
                                    now(), im.getWidth(), im.getHeight(), im.getFormat());
                        }
                        lastTs = im.getTimestamp();
                        frames++;
                        im.close();
                    }
                } catch (IllegalStateException e) {
                    System.out.println("VIDEO acquire: " + e);
                }
                try { Thread.sleep(5); } catch (InterruptedException e) { return; }
            }
        }
    }

    static class OsdWatch extends Thread {
        final ImageReader r;
        final String outdir;
        volatile int posts, saved;
        OsdWatch(ImageReader r, String outdir) { this.r = r; this.outdir = outdir; }
        public void run() {
            while (!done) {
                Image im;
                try {
                    while ((im = r.acquireNextImage()) != null) {
                        posts++;
                        inspect(im);
                        im.close();
                    }
                } catch (IllegalStateException e) {
                    System.out.println("OSD acquire: " + e);
                }
                try { Thread.sleep(5); } catch (InterruptedException e) { return; }
            }
        }
        void inspect(Image im) {
            int w = im.getWidth(), h = im.getHeight();
            Image.Plane pl = im.getPlanes()[0];
            ByteBuffer b = pl.getBuffer();
            int stride = pl.getRowStride(), px = pl.getPixelStride();
            int opaque = 0, x0 = w, y0 = h, x1 = -1, y1 = -1;
            long sumR = 0, sumG = 0, sumB = 0;
            for (int y = 0; y < h; y++) {
                int row = y * stride;
                for (int x = 0; x < w; x++) {
                    int i = row + x * px;
                    int a = b.get(i + 3) & 0xff;
                    if (a != 0) {
                        opaque++;
                        sumR += b.get(i) & 0xff; sumG += b.get(i + 1) & 0xff; sumB += b.get(i + 2) & 0xff;
                        if (x < x0) x0 = x; if (x > x1) x1 = x;
                        if (y < y0) y0 = y; if (y > y1) y1 = y;
                    }
                }
            }
            String bbox = opaque > 0 ? String.format("bbox=%d,%d-%d,%d", x0, y0, x1, y1) : "empty";
            String avg = opaque > 0 ? String.format(" avgRGB=%d,%d,%d", sumR / opaque, sumG / opaque, sumB / opaque) : "";
            System.out.printf("OSD post %d at %.3f %dx%d opaque=%d %s%s%n", posts, now(), w, h, opaque, bbox, avg);
            if (opaque > 0 && saved < 12) {
                // RGBA in memory -> Bitmap ARGB_8888 (which is RGBA in memory too)
                Bitmap bm = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
                ByteBuffer copy = ByteBuffer.allocate(w * h * 4);
                for (int y = 0; y < h; y++) {
                    ByteBuffer row = b.duplicate();
                    row.position(y * stride);
                    row.limit(y * stride + w * 4);
                    copy.put(row);
                }
                copy.rewind();
                bm.copyPixelsFromBuffer(copy);
                String f = String.format("%s/osd-%02d.png", outdir, posts);
                try (FileOutputStream o = new FileOutputStream(f)) {
                    bm.compress(Bitmap.CompressFormat.PNG, 100, o);
                    saved++;
                } catch (Exception e) {
                    System.out.println("OSD save: " + e);
                }
                bm.recycle();
            }
        }
    }

    public static void main(String[] a) throws Exception {
        System.load(a[0]);   // libmpv.so first, like the app's DynamicLibrary.open
        System.load(a[1]);
        String mode = a[2];
        String[] wh = a[3].split("x");
        int w = Integer.parseInt(wh[0]), h = Integer.parseInt(wh[1]);
        String outdir = a[4];
        String[] rest = Arrays.copyOfRange(a, 5, a.length);

        long usage = mode.equals("gpu")
                ? HardwareBuffer.USAGE_GPU_COLOR_OUTPUT | HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE
                : HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE;
        ImageReader video = ImageReader.newInstance(w, h, ImageFormat.PRIVATE, 4, usage);
        VideoWatch vw = new VideoWatch(video);
        vw.start();
        ImageReader osd = null;
        OsdWatch ow = null;
        Surface[] surfaces;
        if (mode.equals("osd")) {
            osd = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 3);
            ow = new OsdWatch(osd, outdir);
            ow.start();
            surfaces = new Surface[] {video.getSurface(), osd.getSurface()};
        } else {
            surfaces = new Surface[] {video.getSurface()};
        }
        System.out.printf("START at %.3f mode=%s surface=%dx%d%n", now(), mode, w, h);
        int rc = run(surfaces, rest);
        Thread.sleep(300);
        done = true;
        vw.join();
        if (ow != null) ow.join();
        double secs = vw.firstTs >= 0 ? (vw.lastTs - vw.firstTs) / 1e9 : 0;
        System.out.printf("VIDEO frames=%d over %.2f s%n", vw.frames, secs);
        if (ow != null)
            System.out.printf("OSD posts=%d saved=%d%n", ow.posts, ow.saved);
        System.out.println("EXIT rc=" + rc);
        System.exit(rc);
    }
}
