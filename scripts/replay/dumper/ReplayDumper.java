// A resident `uiautomator dump`: connects to the accessibility service once, then answers one request per stdin line
// with the same XML DumpCommand writes (it calls the same uiautomator.jar AccessibilityNodeInfoDumper.dumpWindowToFile
// on getRootInActiveWindow, with the real display's rotation and size). Each `uiautomator dump` call pays ~0.86 s of
// process start and service connect on ark37 before its 1 s idle wait (drv_android.py, measured 2026-10-06).
//
// Request: "<idle ms> <max wait ms>"  (DumpCommand uses waitForIdle(1000, 10000))
// Start:   a line "<<REPLAY-READY <pid>>>" (the runner kills that pid on the device when it is done with it)
// Reply:   the XML, then a line "<<REPLAY-END ok|timeout|error <ms>>>"
// Run:     CLASSPATH=/system/framework/uiautomator.jar:/data/local/tmp/replay-dumper.dex app_process /system/bin ReplayDumper
// Build:   dumper/build.sh (javac against the SDK's android.jar, d8 to dex; no third-party code)
import android.app.UiAutomation;
import android.graphics.Point;
import android.view.Display;
import android.view.accessibility.AccessibilityNodeInfo;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileDescriptor;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.lang.reflect.Method;
import java.util.concurrent.TimeoutException;

public class ReplayDumper {
    public static void main(String[] args) throws Exception {
        Class<?> wc = Class.forName("com.android.uiautomator.core.UiAutomationShellWrapper");
        Object w = wc.getConstructor().newInstance();
        wc.getMethod("connect").invoke(w);
        wc.getMethod("setCompressedLayoutHierarchy", boolean.class).invoke(w, args.length > 0 && args[0].equals("--compressed"));
        UiAutomation ua = (UiAutomation) wc.getMethod("getUiAutomation").invoke(w);
        Method dump = Class.forName("com.android.uiautomator.core.AccessibilityNodeInfoDumper").getMethod(
                "dumpWindowToFile", AccessibilityNodeInfo.class, File.class, int.class, int.class, int.class);
        Class<?> dmg = Class.forName("android.hardware.display.DisplayManagerGlobal");
        Object dm = dmg.getMethod("getInstance").invoke(null);
        Method realDisplay = dmg.getMethod("getRealDisplay", int.class);
        File f = new File("/data/local/tmp/replay-dump.xml");
        OutputStream out = new FileOutputStream(FileDescriptor.out);
        BufferedReader in = new BufferedReader(new InputStreamReader(System.in));
        out.write(("<<REPLAY-READY " + android.os.Process.myPid() + ">>\n").getBytes("UTF-8"));
        out.flush();
        String line;
        byte[] buf = new byte[65536];
        while ((line = in.readLine()) != null) {
            String[] p = line.trim().split("\\s+");
            if (p.length < 2) {
                continue;
            }
            long t0 = System.nanoTime();
            String status = "ok";
            try {
                try {
                    ua.waitForIdle(Long.parseLong(p[0]), Long.parseLong(p[1]));
                } catch (TimeoutException e) {
                    status = "timeout";      // DumpCommand prints "could not get idle state" and writes nothing
                }
                if (status.equals("ok")) {
                    AccessibilityNodeInfo root = ua.getRootInActiveWindow();
                    if (root == null) {
                        status = "error";
                    } else {
                        Display d = (Display) realDisplay.invoke(dm, 0);
                        Point size = new Point();
                        d.getRealSize(size);
                        f.delete();
                        dump.invoke(null, root, f, d.getRotation(), size.x, size.y);
                        try (FileInputStream fin = new FileInputStream(f)) {
                            int n;
                            while ((n = fin.read(buf)) > 0) {
                                out.write(buf, 0, n);
                            }
                        }
                    }
                }
            } catch (Throwable e) {
                status = "error";
                out.write(("\n" + e).replace("\n", " ").getBytes("UTF-8"));
            }
            long ms = (System.nanoTime() - t0) / 1000000;
            out.write(("\n<<REPLAY-END " + status + " " + ms + ">>\n").getBytes("UTF-8"));
            out.flush();
        }
        wc.getMethod("disconnect").invoke(w);
    }
}
