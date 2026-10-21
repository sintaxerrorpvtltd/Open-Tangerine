# Contributing

Use macOS 15 (Sequoia) or later and Xcode 16 / compatible Command Line Tools. Fork the repository, create a focused branch, run `./scripts/test.sh` and `./scripts/build-app.sh`, and open a pull request with the problem, behavior change and verification. Use `BUILD_UNIVERSAL=1 ./scripts/build-app.sh` when both Intel and Apple silicon output need checking.

Keep originals safe. Never overwrite user files silently. Use argument arrays for processes. Do not add network calls, telemetry, binary downloads or new permissions without an explicit design discussion. Declare codec and dependency licenses. Do not copy proprietary code or assets.

Add regression tests for data-loss, parser, naming and conversion changes. Use generated fixtures; never commit personal files or API keys. Update the README capability table when adding a feature. UI changes should include screenshots and accessibility labels.

Contributions are accepted under GPL-3.0-only for new project code; preserve MIT notices in upstream-derived code. You retain copyright. Sign off commits (`git commit -s`) to certify the Developer Certificate of Origin at https://developercertificate.org/ . No copyright assignment is required.

Suggested first issues: bounded archive worker, capability filtering, nonblocking native jobs, animation preservation, customizable shortcuts, and notarized release automation.

## How a contribution reaches a release

Forks are independent copies: editing a fork does not change this repository or the downloadable app. Open a pull request to propose changes. The maintainer reviews the diff, checks licenses and behavior, and runs tests before choosing whether to merge. Approval is not automatic. Changes ship only when the maintainer publishes a new version. Do not grant repository write access just to accept a contribution.
