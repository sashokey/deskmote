Brings familiar Windows workflows to macOS. Requires macOS 27 or later on Apple silicon.

## Installation

Extract the app ZIP from [Releases](https://github.com/sashokey/deskmote/releases), move `DeskMote.app` to `/Applications`, and open it. Grant **Accessibility** to use window management and Command Shift.

The app is ad hoc signed. If Gatekeeper blocks the first launch, see [Apple’s instructions for opening an app you trust](https://support.apple.com/en-us/102445).

## Usage notes

- Reopen the app from Applications to restore its hidden menu bar icon.
- Use **Edit Widgets** on the desktop to add **Качество воздуха**. Set **Source URL** to an HTTPS page serving a current AQI card that follows this structure.

  ```html
  <div data-qa="airQualityCard">
    <h2>Current air quality</h2>
    <div class="air-quality-content">
      <div class="aq-number">37</div>
    </div>
  </div>
  ```

  The content `div` must be the next element sibling after `h2` and have no `data-qa`. The parser searches for the first `p.aq-number` or `div.aq-number` within the content and stops if it encounters a heading or a descendant with `data-qa` first. After trimming whitespace, the reading must contain only ASCII digits and fit a Swift `Int`. The page can also supply pollutant cards and a city in inline `currentLocation` data.

- Open **System Settings → General → Login Items & Extensions → Extensions → By Category**, click ⓘ next to **File Providers**, and turn on **Finder File Creator**. Right-click a folder’s background and choose **New Text Document** or **New Compressed (zipped) Folder**. DeskMote verifies the selected folder’s identity when opening it and rechecks the path before publishing to the opened folder. If the folder moves after the last check, publication can still finish in that same folder at its new location. ZIP creation requires a protected staging location on the same volume and atomic publication with the destination’s permissions.

## License

See [LICENSE](LICENSE) for the license terms.
