fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios download_metadata

```sh
[bundle exec] fastlane ios download_metadata
```

Download the current App Store metadata for comparison

### ios sync_metadata

```sh
[bundle exec] fastlane ios sync_metadata
```

Validate and upload metadata without submitting for review

### ios build

```sh
[bundle exec] fastlane ios build
```

Archive and export an App Store IPA

### ios upload_binary

```sh
[bundle exec] fastlane ios upload_binary
```

Upload the existing IPA; final review submission remains manual

### ios release

```sh
[bundle exec] fastlane ios release
```

Build and upload the binary; final review submission remains manual

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
