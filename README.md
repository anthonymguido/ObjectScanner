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
2. Follow the instructions at the top of the screen:
   - **Continue**: point at the object.
   - Fit the box around it, then **Start capture**.
   - Walk slowly all the way around. The ring fills in as you cover each side.
   - When a pass is done, choose **Another pass** (go around from a lower or higher angle),
     **Flip object** (lay it on its side to capture the bottom), or **Done**.
3. The yellow hint under the instructions tells you what to fix: too close, too far,
   too fast, too dark, or the object is out of view. Green means it's going well.
4. On the scan's page, tap **Build 3D model**. Keep the app open and the phone unlocked.
   It usually takes a few minutes.
5. **View in 3D / AR** to inspect it, **Share model** to export the `.usdz`.

The ladybug button on the capture screen shows the raw scanner state for testing.

### Tips for good models
- Objects about the size of a shoe up to a chair work best.
- Matte, textured objects scan best. Shiny, see-through or very thin objects scan badly.
- Use bright, even light with no harsh shadows.
- Put the object on a plain surface that contrasts with it, with room to walk all the way around.
- Do 2–3 passes, including one flipped, if the object can safely lie on its side.

---

## Roadmap
- **Phase 2 – Live LiDAR mesh + camera color**: a "large object / furniture" mode that builds a
  mesh in real time, paints it with camera frames, and exports `.usdz` / `.obj`.
