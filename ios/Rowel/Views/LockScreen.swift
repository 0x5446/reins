/// What sits over the app when it is covered or locked.
///
/// One opaque view for two jobs. As a cover it is what the app switcher
/// photographs instead of someone's transcript, so it has to be fully opaque and
/// has to appear the instant the app stops being frontmost — a blur or a fade
/// would be a picture of a transcript with an effect on it.
///
/// As a lock screen it says why, once, in a sentence. Nobody reads a lock screen
/// twice, and someone who has forgotten they turned this on deserves the reason
/// rather than a padlock.

import SwiftUI

struct LockScreen: View {
    @Environment(AppLock.self) private var lock

    var body: some View {
        ZStack {
            // Opaque, not a material. A material over the app switcher's
            // snapshot is still the snapshot.
            Palette.paper.ignoresSafeArea()

            VStack(spacing: Metrics.gap) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.tertiary)

                if lock.isLocked {
                    Text("Rowel is locked")
                        .font(.system(size: 20, weight: .semibold))

                    Text("It can approve commands on your Mac, so it locks itself when you put it down.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 280)

                    Button {
                        Task { await lock.unlock() }
                    } label: {
                        Text(lock.lastAttemptRefused ? "Try again" : "Unlock")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 12)
                            .background(Palette.accent, in: Capsule())
                    }
                    .disabled(lock.authenticating)
                    .padding(.top, Metrics.tight)
                }
            }
            .padding(Metrics.gap)
        }
        // The unlock prompt comes up on its own the first time. Making someone
        // tap a button to be shown a Face ID sheet is a tap that carries no
        // decision — but the button stays, because a cancelled prompt has to
        // leave something to press.
        .task {
            guard lock.isLocked, !lock.lastAttemptRefused else { return }
            await lock.unlock()
        }
    }
}
