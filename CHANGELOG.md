# Changelog

## [0.4.0](https://github.com/ArishSultan/bridge/compare/v0.3.0...v0.4.0) (2026-10-28)


### Features

* terminal monitor, right-click menu, ⇧↩ for a new line, ⌘B for the sidebar ([6c58977](https://github.com/ArishSultan/bridge/commit/6c5897784095080abe7db269dc8c64a37e43341f))


### Fixes

* no "Last login" line, and Mac text editing keys at the prompt ([4ef946e](https://github.com/ArishSultan/bridge/commit/4ef946e5dbefdbee6ff7cdfb9f08fd00ba09f30d))

## [0.3.0](https://github.com/ArishSultan/bridge/compare/v0.2.0...v0.3.0) (2026-10-27)


### ⚠ BREAKING CHANGES

* v1 and v2 no longer share their files; changes made in v1 after v2's first start don't reach v2.
* rewrite Bridge in Swift on libghostty

### Features

* check for updates hourly and show a badge when one is ready ([83e3948](https://github.com/ArishSultan/bridge/commit/83e394895801f579f40a39a3aaf76d47d5865791))
* instant sandboxed terminals, settings for shared things, native chrome ([2164634](https://github.com/ArishSultan/bridge/commit/216463498d5191e0132c7dd1bc0013bfc7edb8d6))
* keep the app's data in SwiftData instead of JSON files ([475406e](https://github.com/ArishSultan/bridge/commit/475406e86eecba5a1aaad3da5423e63b771f6870))
* modern sheets, a + menu, and Global pages ([b6c36b6](https://github.com/ArishSultan/bridge/commit/b6c36b693f011e44f8bbdc9077f65055256ed960))
* native project windows, items and views ([439e7fd](https://github.com/ArishSultan/bridge/commit/439e7fd0069bae299fc8ca3f77e8d1e69cc3afb7))
* rewrite Bridge in Swift on libghostty ([6225472](https://github.com/ArishSultan/bridge/commit/62254727ce85372e2a3df8777a5e7a4c6f3fd0d2))
* run on macOS 15 and later ([68883ea](https://github.com/ArishSultan/bridge/commit/68883ea2ad3f200410df2849e6d0295b1df28233))
* sandboxed terminals ([57cb0a8](https://github.com/ArishSultan/bridge/commit/57cb0a86fac9117d839df81b34eda6ac00f51ea4))
* shell integration, command history and attention ([e32e6df](https://github.com/ArishSultan/bridge/commit/e32e6df48da387699c6e8e39175efcc9b9f64232))
* Sparkle updates, Developer ID signing and notarization in releases ([7cc3bd4](https://github.com/ArishSultan/bridge/commit/7cc3bd4acde7fed3d098b7aeed8e44e00460279b))
* SSH hosts and port forwards ([3751da8](https://github.com/ArishSultan/bridge/commit/3751da8201f0d8d0d599fc1f99266c69b6ac3acf))
* suggestions and completions in zsh ([cf8b8af](https://github.com/ArishSultan/bridge/commit/cf8b8afa10735cb054e7ea7f29c72aecf9b8ef15))
* v1's deep dark look ([98cafdd](https://github.com/ArishSultan/bridge/commit/98cafdd4aa7de77bde9511ab7c276860f68d5f1f))
* **vault:** sign in to Vaultwarden with single sign-on ([55e2cdd](https://github.com/ArishSultan/bridge/commit/55e2cdd28905f8b7061c23c7cf9f7bb29a259c25))
* Vaultwarden SSH keys ([3177364](https://github.com/ArishSultan/bridge/commit/317736494bbe399d4b2b4e766c8d626b7ba1d9b9))


### Fixes

* dragging terminals into splits, and focus that stays where you put it ([7d226a4](https://github.com/ArishSultan/bridge/commit/7d226a4cdfe8edb1524513b2de1ffab5f95a3c59))
* Liquid Glass again in builds that run on macOS 15 ([31b5d4f](https://github.com/ArishSultan/bridge/commit/31b5d4f81ff846f42511146aef509fc6ebaff610))
* **sandbox:** close the escapes found in the security review ([9650b29](https://github.com/ArishSultan/bridge/commit/9650b29e6469b119b3c0ceb8ac29f680c0e1a380))
* the + button is a blue glass button like the toolbar's, opening a native menu ([14c6871](https://github.com/ArishSultan/bridge/commit/14c6871a3b635403572f0b07301a737200e25d5a))

## [0.2.0](https://github.com/ArishSultan/bridge/compare/v0.1.1...v0.2.0) (2026-10-22)


### Features

* app icon from Icon Composer ([47cd219](https://github.com/ArishSultan/bridge/commit/47cd219b100b1abbd82573c46236981e9df22a69))

## [0.1.1](https://github.com/ArishSultan/bridge/compare/v0.1.0...v0.1.1) (2026-10-21)


### Fixes

* **ci:** correct lipo -verify_arch argument order ([d51c943](https://github.com/ArishSultan/bridge/commit/d51c943c2083c099835c2d6940ca6577b3fc5623))

## 0.1.0 (2026-10-21)


### Features

* Bridge, a macOS workspace for projects, terminals and SSH ([57780e5](https://github.com/ArishSultan/bridge/commit/57780e59a523a5b43089a051578f84a5b5de3bd9))
