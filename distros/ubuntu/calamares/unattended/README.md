# Unattended Calamares config — TEST ONLY

This tree drives a complete Calamares install with no human input, so the installed
target can be asserted against in CI. It is consumed only via `calamares -c`, from
the cloud-init seed built by `scripts/make-cloud-init-seed.sh --profile install`.

**It must never be wired into a shipping settings file.** It disables the install
confirmation prompt, erases the disk without asking, and accepts an empty user
password. `tests/host/test_unattended_install.bats` asserts that
`apply-parental-overlay.py` does not reference it.

The mechanism is the per-instance `autoProceed` flag, undocumented in upstream
configs: it clicks Next once a step's Next button becomes enabled
(`src/libcalamares/Settings.cpp:100`, `src/calamares/CalamaresWindow.cpp:108-121`)
and cascades, because `ViewManager::next()` re-emits `nextEnabledChanged` for the
newly current step (`ViewManager.cpp:395`).

Do not try to shorten this by emptying `show:`. `ViewModule::loadSelf()` registers a
view step unconditionally (`ViewModule.cpp:64`) regardless of which phase listed
the module, so an empty `show:` produces more interactive pages rather than fewer, and
`quit-at-end` never fires because `isAtVeryEnd()` is false for an out-of-range index
(`ViewManager.cpp:285-288`).
