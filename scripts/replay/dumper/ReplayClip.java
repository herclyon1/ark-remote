// Puts a text clip on the device clipboard: `cmd clipboard` has no shell implementation on the ark37 image (API 37,
// "No shell command implementation."), so the runner's clear_clipboard / set_clipboard did nothing there and a 免输入链接
// the app itself copied (手机 · 复制免输入链接) stayed on the clipboard; the next run's cold start took it (AppGlue
// takeClipboardIfDue: a text clip from the last 10 minutes) and switched the app to the previous run's mailbox.
// It calls the clipboard service's IClipboard.setPrimaryClip directly, the way a shell-started app_process can; the
// method's trailing parameters differ between API levels (callingPackage, attributionTag, userId, deviceId), so they
// are filled by type: the first String is the calling package, other Strings null, ints 0 (user 0, default device).
// Run:   CLASSPATH=/data/local/tmp/replay-dumper.dex app_process /system/bin ReplayClip <text>
//        ... ReplayClip --get   reads the clip back (getPrimaryClip, same parameter filling)
// Print: "<<REPLAY-CLIP ok>>" (--get: "<<REPLAY-CLIP ok <text>>>") or "<<REPLAY-CLIP error <why>>>"
// Build: dumper/build.sh (the same dex as ReplayDumper)
import android.content.ClipData;
import android.os.IBinder;
import java.lang.reflect.Method;

public class ReplayClip {
    public static void main(String[] args) {
        boolean get = args.length > 0 && args[0].equals("--get");
        String text = args.length > 0 ? String.join(" ", args) : "";
        try {
            Class<?> sm = Class.forName("android.os.ServiceManager");
            IBinder b = (IBinder) sm.getMethod("getService", String.class).invoke(null, "clipboard");
            Class<?> stub = Class.forName("android.content.IClipboard$Stub");
            Object clip = stub.getMethod("asInterface", IBinder.class).invoke(null, b);
            String name = get ? "getPrimaryClip" : "setPrimaryClip";
            Method set = null;
            for (Method m : Class.forName("android.content.IClipboard").getMethods()) {
                if (m.getName().equals(name) && (set == null || m.getParameterCount() > set.getParameterCount())) {
                    set = m;
                }
            }
            if (set == null) {
                throw new NoSuchMethodException("IClipboard." + name);
            }
            Class<?>[] types = set.getParameterTypes();
            Object[] a = new Object[types.length];
            boolean pkg = false;
            for (int i = 0; i < types.length; i++) {
                if (types[i] == ClipData.class) {
                    a[i] = ClipData.newPlainText("replay", text);
                } else if (types[i] == String.class) {
                    a[i] = pkg ? null : "com.android.shell";
                    pkg = true;
                } else if (types[i] == int.class) {
                    a[i] = 0;
                }
            }
            Object r = set.invoke(clip, a);
            if (get) {
                ClipData cd = (ClipData) r;
                CharSequence t = cd == null || cd.getItemCount() == 0 ? null : cd.getItemAt(0).getText();
                System.out.println("<<REPLAY-CLIP ok " + (t == null ? "" : t.toString().replace("\n", " ")) + ">>");
                return;
            }
            System.out.println("<<REPLAY-CLIP ok>>");
        } catch (Throwable e) {
            Throwable c = e.getCause() != null ? e.getCause() : e;
            System.out.println(("<<REPLAY-CLIP error " + c + ">>").replace("\n", " "));
        }
    }
}
