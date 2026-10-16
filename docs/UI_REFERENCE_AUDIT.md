# macOS Reference UI Audit (October 2026)

This audit compares the original design collage (user-supplied) against native macOS CI screenshots. **The mountain scene is macOS wallpaper, never app artwork**. Compare the glass with a comparable wallpaper before judging blur or hue.

| Area | Observed mismatch in previous render | Implemented correction | Acceptance check |
| --- | --- | --- | --- |
| Window chrome | Duplicate 45pt toolbar, extra page title and text CTA | Removed full toolbar; placed floating plus in content chrome | No duplicate title/toolbar in each page |
| Overall proportions | Header-to-card vertical spacing too short; sidebar narrow | Sidebar width recalibrated; overview heading-to-card gap expanded | Compare measured edges and card rows, not simply typography |
| Sidebar | Dark inactive icons and opaque-looking material strip | Blue inactive icons and light translucent sidebar tint | Inactive icons remain visible with wallpaper |
| Frosted cards | White overlay looked like a transparent photograph, not blurred glass | Layered behind-window AppKit blur and local per-card NSVisualEffectView with thin tint | Wallpaper recognizable but locally defocused, readable text |
| Overview | Incorrect lower-right IPv4 rules card, small power halo | Lower-right protection tile, real session tile in right column, enlarged halo | Two narrow statistics plus wider protection, no fabricated traffic |
| Profiles | Missing import button beside search; native gray detail segments | Blue inspector segments, import/search row, flatter form | Selected configuration detail and list density match intended composition |
| Routing | With no profile the whole left card collapsed to one sentence | Always display 3 selectable-looking modes, disabled when no profile | Modes visible even on fresh installation |
| Diagnostics | Duplicate controls, title icon and no result emphasis | Four tab labels in header, local-route result tile with truthful status | No simulated IP location, measured latency or zero-leak claim |
| Settings | Multiple tiny inline actions overflowing card rows | Compact reference rows, trailing menu/action, preserved operations | Four equal-height action rows, controls do not clip |
| CI screenshot coverage | All views empty because no .ovpn installed on runner | In-memory, screenshot-only profile fixture behind explicit launch flag | Only test snapshots show demo files; normal app remains unchanged |

### Important constraints

- Real status always comes from the helper and system APIs. Neither CI preview profiles nor reference artwork are production assets.
- UI-only ad-hoc CI artifact cannot establish a VPN session: final comparison must not imply that a mock connected state was achieved.
- Material appearance differs across macOS versions, active wallpaper, Dark Mode, Reduce Transparency and window focus. Test both a visually busy wallpaper and a plain background on real macOS.
- Pixel-exact fidelity remains unverified until both the target and the generated UI are captured at the same **logical window size and display scale**. The supplied reference is a montage with several downscaled windows, so it cannot be used as an absolute coordinate raster without knowing the source captures.
