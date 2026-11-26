# Object Scanner (iPhone app)

Walk around an object with your iPhone. The LiDAR scanner and camera capture it from every side,
and the app builds a textured 3D model (`.usdz`) on the phone. You can spin it around, place it in
your room in AR, or share it to Files, AirDrop, Messages and so on.

> Needs **iOS 17 or later** and a phone with a **LiDAR scanner**: iPhone 12 Pro / Pro Max or any
> later **Pro** model, or a recent iPad Pro. Other phones can install the app but can't scan.

---

## Getting it onto your iPhone from a Windows PC

You'll need: a free **GitHub** account, your **Apple ID**, your iPhone and its USB cable.
If you already set up Sideloadly for the Wi-Fi Heatmap app, Part 2 is just the last two steps.

### Part 1 – Let GitHub build the app (about 15 minutes, mostly waiting)

Either way works:

**With GitHub Desktop**
1. **File → Add local repository…** → choose this `ObjectScanner` folder. When it says it isn't a
   repository yet, click **create a repository** → **Create repository**.
2. Click **Publish repository**, untick **Keep this code private** (public repos get unlimited free
   build time), and publish.

**Or in the browser**
1. On **github.com** click **+** → **New repository**, name it `ObjectScanner`, choose **Public**, **Create repository**.
2. Click **uploading an existing file**, drag **everything inside** this folder (including the
   `.github` folder) onto the page, and click **Commit changes**.

Then:
3. Open the repo's **Actions** tab. A run called "Build iPhone app" starts automatically
   (if GitHub asks you to enable workflows, click the green button, then **Run workflow**).
4. Wait for a green ✓ (about 5–10 minutes). Click the run, scroll to **Artifacts**,
   and download **ObjectScanner-ipa**. Unzip it to get `ObjectScanner.ipa`.

   If you get a red ✗ instead, click into the failed step and copy the error lines to Claude to fix.

### Part 2 – Install it with Sideloadly

1. Install **iTunes** and **iCloud** from Apple's website, **not** the Microsoft Store versions:
   https://www.apple.com/itunes/download/win64
2. Install **Sideloadly** from https://sideloadly.io
3. Plug in your iPhone, unlock it, and tap **Trust** when asked.
4. Open Sideloadly → drag `ObjectScanner.ipa` onto it → type your Apple ID → **Start**.
5. On the iPhone: **Settings → Privacy & Security → Developer Mode** on (restart when prompted), then
   **Settings → General → VPN & Device Management** → your Apple ID → **Trust**.
6. Open **Object Scanner** from your home screen.

**Every 7 days** the app stops opening (an Apple rule for free accounts). Run Sideloadly again with
the same `.ipa`. Your scans are kept.

---

## Scanning

1. **+** → name the object → **Start**.
2. **Find the object:** point the camera at it. A glowing outline traces its border (the same
   feature Photos uses to lift a subject). Tap a different object to switch. The readout shows
   its distance and size from LiDAR. When it's centered, 0.3–1.5 m away and 5–120 cm big, the outline
   turns green and the scan starts by itself. **Skip** goes straight to Apple's own detection.
3. The scan box appears around the object on its own (tap **Continue** if it doesn't).
   Adjust it if needed, then **Start capture**.
4. Walk slowly all the way around, about one step a second. The app takes extra photos as you
   turn, on top of the automatic ones, and the camera button takes one by hand. The **photo rate**
   slider at the bottom (Fewer … More) sets how often the extra photos come. Each scan has a photo
   limit, and a hint warns you when you're close to it.
5. When a pass is done, choose **Another pass** (go around from a lower or higher angle),
   **Flip object** (lay it on its side to capture the bottom), or **Done**.
6. The yellow hint under the instructions tells you what to fix: tracking is weak or lost,
   too close, too far, too fast, too dark, or the object is out of view. Green means it's going well.
   Tap a tracking hint (or the **?** button) for tracking tips.
7. On the scan's page, pick a **Quality** and tap **Build 3D model**. Keep the app open and the
   phone unlocked.
   - **Fast**: quickest, standard phone detail (how the app always built before).
   - **Balanced**: looks harder for matching points between photos. Slower, fewer holes on plain objects.
   - **Best (experimental)**: asks for full detail. iPhones may only allow standard detail; if so,
     the app builds Balanced instead and says so on the scan's page.
8. **View in 3D / AR** to inspect it, **Share model** to export the `.usdz`.
9. **Export scan data** makes a `.zip` for building a more detailed model on a computer: the photos,
   the LiDAR depth map from each photo (16-bit PNG, millimeters), the 3D point cloud (`pointcloud.ply`),
   each photo's camera position (`poses.json`) and the model. A `README.txt` inside explains each file.

The gear on the main screen opens **Settings**: photo rate, default build quality, tracking tips
and the printable scan mat. The ladybug button on the capture screen shows the raw scanner state
for testing, including the finder's readings and camera tracking.

### Helping it keep track
The scanner works out where the phone is by watching the things around the object. A plain table
gives it little to follow, so it can lose its place. Give it marks around the object:
- **Scan mat**: Settings → **Make scan mat (PDF)**. Print it at 100%, lay it flat, and put the object
  in the dashed circle. Pick 4 pages for bigger objects and tape them together.
- **Tape**: stick strips of matte masking tape around the object (not touching it) and draw a
  different arrow, number or scribble on each one.
- Don't move the mat or tape during a scan; flip the object, not the mat. The marks only help
  tracking: the app cuts the object out when building, so they don't end up in the model.

### Tips for good models
- Objects about the size of a shoe up to a chair work best.
- Matte, textured objects scan best. Shiny, see-through or very thin objects scan badly.
- Use bright, even light with no harsh shadows.
- Put the object on the scan mat or a surface with tape marks, with room to walk all the way around.
- Do 2–3 passes, including one flipped, if the object can safely lie on its side.

---

## Roadmap
- **Phase 2 – Live LiDAR mesh + camera color**: a "large object / furniture" mode that builds a
  mesh in real time, paints it with camera frames, and exports `.usdz` / `.obj`.
