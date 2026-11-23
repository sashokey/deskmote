Brings familiar Windows workflows to macOS. Requires macOS 27 or later on Apple silicon.

## Installation

Extract the app ZIP from [Releases](https://github.com/sashokey/deskmote/releases), move `DeskMote.app` to `/Applications`, and open it. Grant **Accessibility** to use window management and Command Shift.

The app is ad hoc signed. If Gatekeeper blocks the first launch, see [Apple’s instructions for opening an app you trust](https://support.apple.com/en-us/102445).

## Usage notes

- Reopen the app from Applications to restore its hidden menu bar icon.
- Use **Edit Widgets** on the desktop to add **Качество воздуха**. Set a compatible HTTPS page in **Source URL** in the widget’s edit menu.
- Open **System Settings → General → Login Items & Extensions → Extensions → By Category**, click ⓘ next to **File Providers**, and turn on **Finder File Creator**. Right-click a folder’s background and choose **New Text Document** or **New Compressed (zipped) Folder**. The command fails if DeskMote cannot verify the selected folder or if the folder has been replaced. Creating a ZIP requires a protected temporary location on the same volume and support for publishing the finished archive atomically.

## License

See [LICENSE](LICENSE) for the license terms.
