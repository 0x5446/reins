# Screenshot Spec — 6.9" set (1320 × 2868)

One set covers everything: 6.9" screenshots auto-scale to every smaller
iPhone tier, and the app is iPhone-only so no iPad set exists. Apple accepts
`1320 × 2868` portrait for the 6.9" slot (also 1290×2796 / 1260×2736 — use
1320×2868, the top of the scaling chain).

**Hard rules** (from Apple's screenshot specifications):
- PNG or JPG, portrait, **no alpha channel / no transparency** (upload
  rejects it since 2026-07). Flatten on export:
  `sips -s format jpeg in.png --out out.jpg` or re-export PNG without alpha.
- 1–10 images per localization; we ship 6.
- Must show the app in use — real UI, no mock features.

## Frames and caption overlays: recommendation

**Ship raw, full-bleed UI screenshots. No device frame, no overlaid marketing
text.** Reasons:

- It is the cheapest path that is fully compliant: a screenshot straight off
  a 6.9" device/simulator is already exactly 1320×2868, and "the app in use"
  is satisfied by definition.
- Device frames + text panels mean a design template, font choices, and
  re-export every time the UI shifts — real cost, and for a developer-tool
  audience plain UI converts fine (Termius, Blink, Working Copy all ship
  raw or near-raw shots).
- The captions below are written anyway: they double as the overlay text if
  a designed set is ever wanted later, and as alt/marketing copy now.

## Capture setup (once)

- Device: iPhone 16 Pro Max / 17 Pro Max, or the matching simulator
  (screenshots come out native 1320×2868). The push shot works in the
  simulator too: `xcrun simctl push` + Device → Lock.
- Status bar hygiene (simulator):
  `xcrun simctl status_bar booted override --time 9:41 --batteryLevel 100 --batteryState charged --cellularBars 4 --operatorName ""`
- Content hygiene: neutral machine name (edit `machineName` in
  `~/.reins/bridle.json`, e.g. `studio`), a throwaway demo repo with generic
  paths, no API keys, no real project names. Dark and light both look
  intentional; pick **one** appearance for the whole set (dark reads more
  "terminal-native" for this audience).
- Stage real sessions via a Bridle on the demo Mac — the transcript,
  approval, and trace content must be genuine app output.

## The six shots

Filenames are the deliverable names for the main session's capture pass.
**Upload order ≠ filename order** — the first three appear in search results,
so lead with the most distinctive screens:

**Recommended upload order: approval → conversation → sessions → push →
models → photo.**

| # | File | Screen to capture | Staging | Caption (≤ ~60 chars, title case not needed) |
|---|---|---|---|---|
| 1 | `approval.png` | An approval card: tool name, full command, diff, Approve/Deny buttons visible | Ask the agent to edit a file so the request carries a readable diff (a small, legible one — 5–10 lines) | **Nothing runs without you. The full command and diff, then your call.** |
| 2 | `conversation.png` | A live session mid-stream: reasoning section open or freshly collapsed, a tool-call card, streaming text | Prompt something multi-step ("add a retry to the fetch helper") and shoot mid-run | **Watch it work — reasoning, tool calls, and diffs, streaming live.** |
| 3 | `sessions.png` | Session list grouped by workspace, ≥2 workspaces, a waiting approval/question pinned at top, machine switcher visible | Two demo workspaces, one session left in a waiting state | **Everything running on your Mac. Whatever needs you is on top.** |
| 4 | `push.png` | Lock screen showing a Reins notification, e.g. "Bash needs permission — <session> on studio" | Background the app, trigger an approval, lock the phone; shoot the lock screen. (This is the app's own local notification with the real words — accurate to how the product works, since the remote push carries no content.) | **The ask finds you. The content never touches anyone's servers.** |
| 5 | `models.png` | Model picker with reasoning-effort control visible | Open the picker from a session | **Pick the model and how hard it thinks. Mid-conversation.** |
| 6 | `photo.png` | Composer with an attached photo of a hand-drawn UI sketch, prompt text like "build this screen" | Photograph a real napkin/whiteboard sketch beforehand; attach via the photo button (up to 4 attach) | **Sketch it on paper, shoot it, send it. The agent takes it from there.** |

Caption placement if overlays are ever added: top 20% of the frame, app UI
never cropped below the first content row. Until then these captions are
unused metadata — keep them with the assets.

## Checks before upload

- [ ] All six exactly 1320×2868, portrait.
- [ ] No alpha channel: `sips -g hasAlpha *.png` → all `no`.
- [ ] No real paths, repo names, machine names, keys in any frame.
- [ ] Status bar consistent across the set.
- [ ] `push.png` shows a notification whose text matches what the shipped
      app actually posts (`Notifier.swift` formats: "<tool> needs permission"
      / question title / "Finished").
- [ ] App Preview video: **skip for v1** (optional; 15–30 s, 886×1920 — a
      separate deliverable from the reviewer demo video, do not confuse the
      two).
