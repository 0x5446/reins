/**
 * Installing the Bridle as a background service.
 *
 * A person should pair once and then forget this exists. Leaving a terminal
 * window open forever is not a product, and neither is "remember to run this
 * after every reboot". On macOS that means a launchd agent; on Linux, a
 * systemd user unit. Both are written to the user's own domain, so nothing
 * here needs administrator rights.
 */

import { execFileSync } from 'node:child_process'
import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { homedir, platform } from 'node:os'
import { join } from 'node:path'
import { reinsHome } from './identity.ts'

/** Reverse-DNS label used for the launchd agent and the systemd unit. */
export const SERVICE_LABEL = 'app.reins.bridle'

/** Where the service writes its log, on either platform. */
export function serviceLogPath(): string {
  return join(reinsHome(), 'bridle.log')
}

/** What a service install did, so the CLI can explain it. */
export interface ServiceOutcome {
  /** Path of the file written or removed. */
  path: string
  /** One-line description for the operator. */
  detail: string
}

function launchAgentPath(): string {
  return join(homedir(), 'Library', 'LaunchAgents', `${SERVICE_LABEL}.plist`)
}

function systemdUnitPath(): string {
  return join(homedir(), '.config', 'systemd', 'user', `${SERVICE_LABEL}.service`)
}

function executable(): { command: string; args: string[] } {
  // argv[1] is this CLI's own entry point; reusing it keeps a globally
  // installed Bridle and a checked-out one both working.
  const entry = process.argv[1]
  if (entry === undefined) throw new Error('cannot determine the bridle executable path')
  return { command: process.execPath, args: [entry, 'start'] }
}

/**
 * Install and start the background service.
 * @returns what was written.
 * @throws {@link Error} on an unsupported platform.
 */
export function installService(): ServiceOutcome {
  const { command, args } = executable()
  const log = serviceLogPath()
  mkdirSync(reinsHome(), { recursive: true, mode: 0o700 })
  if (platform() === 'darwin') {
    const path = launchAgentPath()
    mkdirSync(join(homedir(), 'Library', 'LaunchAgents'), { recursive: true })
    writeFileSync(path, launchdPlist(command, args, log), { mode: 0o644 })
    runQuiet('launchctl', ['unload', path])
    execFileSync('launchctl', ['load', '-w', path], { stdio: 'ignore' })
    return { path, detail: 'launchd agent installed and started; it will come back after every login' }
  }
  if (platform() === 'linux') {
    const path = systemdUnitPath()
    mkdirSync(join(homedir(), '.config', 'systemd', 'user'), { recursive: true })
    writeFileSync(path, systemdUnit(command, args), { mode: 0o644 })
    execFileSync('systemctl', ['--user', 'daemon-reload'], { stdio: 'ignore' })
    execFileSync('systemctl', ['--user', 'enable', '--now', `${SERVICE_LABEL}.service`], { stdio: 'ignore' })
    return { path, detail: 'systemd user unit installed and started' }
  }
  throw new Error(`bridle service install is not supported on ${platform()}`)
}

/**
 * Stop and remove the background service.
 * @returns what was removed.
 * @throws {@link Error} on an unsupported platform.
 */
export function uninstallService(): ServiceOutcome {
  if (platform() === 'darwin') {
    const path = launchAgentPath()
    runQuiet('launchctl', ['unload', '-w', path])
    rmSync(path, { force: true })
    return { path, detail: 'launchd agent stopped and removed' }
  }
  if (platform() === 'linux') {
    const path = systemdUnitPath()
    runQuiet('systemctl', ['--user', 'disable', '--now', `${SERVICE_LABEL}.service`])
    rmSync(path, { force: true })
    runQuiet('systemctl', ['--user', 'daemon-reload'])
    return { path, detail: 'systemd user unit stopped and removed' }
  }
  throw new Error(`bridle service uninstall is not supported on ${platform()}`)
}

function runQuiet(command: string, args: string[]): void {
  try {
    execFileSync(command, args, { stdio: 'ignore' })
  } catch {
    // Unloading something that was never loaded is the ordinary first-install
    // path, not a failure worth reporting.
  }
}

function launchdPlist(command: string, args: string[], log: string): string {
  const programArguments = [command, ...args]
    .map(value => `    <string>${escapeXml(value)}</string>`)
    .join('\n')
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${SERVICE_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
${programArguments}
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>${escapeXml(log)}</string>
  <key>StandardErrorPath</key>
  <string>${escapeXml(log)}</string>
</dict>
</plist>
`
}

function systemdUnit(command: string, args: string[]): string {
  return `[Unit]
Description=Reins Bridle
After=network-online.target

[Service]
ExecStart=${[command, ...args].join(' ')}
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
`
}

function escapeXml(value: string): string {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
}
