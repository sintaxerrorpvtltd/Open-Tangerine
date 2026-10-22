# Updates and notch · 0.1.2

Notch is the new default, including a one-time migration from earlier trials. Users can switch back to Card afterward. The original citrus character animates at 12 frames/second while work is active, stops when idle and respects Reduce Motion. Up to three job rows are visible; larger batches scroll. No Codex hooks, agent monitoring or permissions were added.

The referenced app was [Coucou](https://github.com/Louis-CFM/coucou). Its source is MIT but [LICENSE-ASSETS.md](https://github.com/Louis-CFM/coucou/blob/main/LICENSE-ASSETS.md) reserves the Mochi character, expressions and animations. No Coucou source or artwork was copied. Open Tangerine uses its own citrus character.

The menu-bar Check for Updates command checks this repository's latest public GitHub release, compares strict three-part versions numerically, and opens the fixed repository release page on request. Automatic checks occur at most once daily after successful checks; requests send no filenames, file content or account credentials. GitHub receives normal connection metadata. Offline, rate-limited and unpublished-release cases are reported for manual checks.

This is an update notification/download flow, **not automatic installation**. A signed update channel (for example Sparkle with a protected signing key), notarized binaries and rollback verification are required before shipping in-app replacement. Do not disable macOS security to install an update.

The release workflow tests, builds, verifies the signature and publishes versioned developer-trial ZIPs. Unless the release notes state that a build is Developer ID signed and notarized, these packages are ad-hoc signed, are not Apple-notarized and can be blocked by macOS. Downloading or hosting them does not bypass Gatekeeper. Published versions are never overwritten.


## Character interaction

The wheel opens a watching preview in notch mode. Hovering different options changes the gaze and caption. Enqueueing a job triggers acknowledgment, followed by processing. Successful completion triggers delivery then a happy expression; failures and cancellation have separate expressions. Delayed transitions use generation tokens so stale animation completions cannot overwrite newer states. Version comparison and interrupted character transitions passed the dedicated interaction tests. Live visual review remains necessary because this execution environment has blocked native app registration.


## 0.1.3 recovery and presentation fixes

The notch now joins the physical top edge of the display and reserves the camera-safe area above its content. The original citrus character has highlighted eyes, cheeks, a curved smile and separate received, busy, delivery and error expressions.

Starting a new conversion clears completed results. Failures no longer contaminate the next job's companion state; cancellation is checked before reporting success. Failure rows use past-tense error titles. Missing image dimensions and the 40-megapixel resource limit have distinct messages; large images include their measured dimensions. The resource limit remains in place to protect memory.

The updater has HTTP-response regression tests for a newer version, the current version and an unpublished release. A source commit is not a downloadable update. Version 0.1.3 fixes are included in the 0.1.4 developer trial.

## 0.1.4 website and manual updates

The landing page is hosted on GitHub Pages from `/docs`. Check for Updates opens `https://sintaxerrorpvtltd.github.io/Open-Tangerine/?version=<installed>#download`. The website compares the supplied version with GitHub's latest published release. If that request fails, it provides the releases page without claiming the app is current. Automatic background checks still contact GitHub at most once a day after successful checks. Updates are manual downloads and replacements; no Apple account is required for this flow. This does not remove macOS's checks for unsigned/unnotarized software.
