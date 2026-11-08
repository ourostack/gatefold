<!-- ourostack:brand:start -->
<p align="center">
  <a href="https://github.com/ourostack"><img src="https://raw.githubusercontent.com/ourostack/.github/main/brand/headers/gatefold.webp" alt="Ouro on a tartan blanket beside a big storybook folded open into three panels and a small two-screen folding phone" width="100%"></a>
</p>
<!-- ourostack:brand:end -->

# Gatefold

**Pick up on the very same line.** Gatefold is a free reader for iPhone and iPad that keeps your place in step with your PocketBook e-reader through PocketBook Cloud, and it is built for every posture of iPhone Duo.

<p align="center">
  <img src="docs/shots/01-shelf.webp" alt="Your shelf, in your pocket: the Gatefold library with every book from PocketBook Cloud" width="28%">
  <img src="docs/shots/02-very-line.webp" alt="Pick up on the very line: a book opened on the exact line the e-reader left off, underlined" width="28%">
  <img src="docs/shots/05-midnight.webp" alt="Light by day, ink by night: the true-black Midnight page" width="28%">
</p>

[Website](https://ourostack.github.io/gatefold/) · [Privacy](https://ourostack.github.io/gatefold/privacy/) · [Support](https://ourostack.github.io/gatefold/support/) · [More from Ouro](https://github.com/ourostack)

- **Your place, down to the line.** Reading position syncs both ways with your PocketBook e-reader.
- **Your marks come along.** Highlights, notes and bookmarks travel between the e-reader and your phone.
- **A real gatefold.** On iPhone Duo it reads folded, flat as a two-page spread, or half-open on the table.
- **Free, for good.** No ads, no subscriptions, no tracking.

**Status:** TestFlight beta, by invite. Not on the App Store yet; ask for an invite by [opening an issue](https://github.com/ourostack/gatefold/issues/new).

**Build it:** with Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen). It runs in Simulator as is; for a device, set your own team in `project.yml` (`DEVELOPMENT_TEAM`).

```sh
brew install xcodegen
xcodegen generate && open Gatefold.xcodeproj
```

Not affiliated with or endorsed by PocketBook International SA.
