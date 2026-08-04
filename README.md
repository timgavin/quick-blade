# Quick Blade

Quick Look previews for Laravel Blade templates. Select a `.blade.php` file in Finder, press Space, and you get the rendered page — layout resolved, compiled CSS applied — instead of a wall of raw directives.

More at [quickblade.app](https://quickblade.app).

## Install

```
brew install --cask timgavin/tap/quick-blade
```

Then open Quick Blade once. macOS registers Quick Look extensions when the host app first launches, so this step isn't optional.

Requires macOS 15 or later.

## What it does

When you preview a Blade file, Quick Blade walks up from the file to find the Laravel project root, then:

- resolves the surrounding layout — `<x-layouts.app>` components, `@extends`, or a full-page Livewire component's layout
- pulls in `@include`s and Blade components
- inlines your compiled Vite CSS and local images, so the preview looks like your app
- transpiles the directives: loops repeat their bodies, conditionals resolve to a single branch, and `{{ }}` echoes are filled with plausible fake data

Files outside a Laravel project (or without a layout) still render with a built-in stylesheet. Plain PHP files render as readable source, since Quick Look hands the extension every `.php` file.

## Folder access

The extension reads the files next to the one you're previewing — the layout, the compiled CSS, the images they reference. Projects under `~/Herd`, `~/Sites`, or `~/Developer` work with no setup. Desktop, Documents, Downloads, iCloud, and external volumes are protected by macOS, so the first preview there asks for permission. If you decline, macOS won't ask again — turn it back on in System Settings > Privacy & Security > Files and Folders > Quick Blade.

More troubleshooting at [quickblade.app/support](https://quickblade.app/support/).

## Building from source

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen), so generate it first:

```
git clone https://github.com/timgavin/quick-blade.git
cd quick-blade
xcodegen generate
xcodebuild -scheme QuickBlade -configuration Debug build
```

Builds are unsigned by default, which is fine for development. To sign with your own certificate, create a `Local.xcconfig` next to `Signing.xcconfig` — the comments in that file explain it.

Run the tests with:

```
xcodebuild -scheme BladeQuickLookTests test
```

For a quick smoke test, build, launch the app once, then `qlmanage -p TestFiles/welcome.blade.php`.

## License

MIT — see [LICENSE](LICENSE).
