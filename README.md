# Switch Captures

Copy Nintendo Switch 2 screenshots and video clips directly to a folder on your Mac over USB. The app runs on Apple silicon and Intel Macs with macOS 14 or later.

## Copy captures

1. Open **Switch Captures.app**.
2. On the Switch 2, open **System Settings → Data Management → Manage Screenshots and Videos → Copy to PC via USB Connection**.
3. Connect a USB data cable to the console’s bottom USB-C port and leave the transfer screen open. Choose **Allow** if macOS asks to connect the USB accessory.
4. Select captures and click **Copy Selected…**, or use **Copy All Shown…**. Pick a destination folder.

The app copies the original bytes and filenames into the selected folder. If a name is already taken, the next copy gets a suffix such as ` (2)`. You can stop a batch after the current file. A failed transfer leaves completed files in the destination and removes the partial copy.

If the connection is busy, quit other MTP and camera apps and retry. If the macOS camera service still holds the interface, **Release Camera Connection…** offers a one-time retry. Confirming it briefly stops the camera service for your user account, which can interrupt another camera transfer.

If the console reports a previous session, unplug the data cable, reopen **Copy to PC via USB Connection**, and reconnect.

## Build

Use Xcode or the Apple Command Line Tools with Swift 6 and a matching macOS SDK.

```sh
./Scripts/build-app.sh
open "dist/Switch Captures.app"
```

The script creates an ad hoc signed universal app and a ZIP in `dist/`. Set `SWITCH_CAPTURES_SDK` to the path of a matching SDK if you have multiple SDKs installed. With a matching Swift Package Manager, run `swift test` for the USB protocol and file-copy tests.

## Research

- Nintendo documents the console's USB transfer mode as MTP. It requires a data cable plugged directly into the console and notes that third-party MTP software can provide access on other systems. [Nintendo support](https://www.nintendo.com/en-gb/Support/Troubleshooting/How-to-Transfer-Screenshots-and-Video-Captures-from-Nintendo-Switch-2-to-a-Computer-via-a-USB-Cable-2914249.html)
- A Switch 2 hardware trace identifies transfer mode as USB `057e:2061` and shows a read-only **Album**. The app uses baseline PTP commands on that interface and walks each game folder separately, since the console rejects a single request for every object. [Switch 2 trace on the libmtp tracker](https://sourceforge.net/p/libmtp/bugs/1953/) · [Tethersnap’s hardware testing](https://blog.luminoid.dev/Tethersnap-Switch-2-PTP-on-a-Mac/)
- The app uses IOKit to claim the console's USB interface from user space. A prior Mac transfer implementation documents that macOS's camera service can claim the same interface. [Apple USB device interface guide](https://developer.apple.com/library/archive/documentation/DeviceDrivers/Conceptual/USBBook/USBDeviceInterfaces/USBDevInterfaces.html) · [Switch USB transfer report on macOS](https://github.com/radical-beard/switch-screenshots-mac#how-it-works)
