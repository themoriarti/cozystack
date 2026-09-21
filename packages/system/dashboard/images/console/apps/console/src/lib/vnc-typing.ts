import { XK_SHIFT_L, type Keystroke } from "./vnc-keymap.ts"

/**
 * Feed a planned key sequence to an RFB session.
 *
 * Every event is spaced out: qemu drains the emulated keyboard controller at
 * its own pace and a burst loses characters silently, which is why the
 * upstream KubeVirt console paces its paste the same way.
 */

export interface KeySender {
  sendKey(keysym: number, code: string, down: boolean): void
}

export interface TypeKeystrokesOptions {
  delayMs?: number
  signal?: AbortSignal
  isConnected?: () => boolean
  onProgress?: (typed: number, total: number) => void
  /** Injectable for tests; production uses a real timer. */
  sleep?: (ms: number) => Promise<void>
}

export interface TypeKeystrokesResult {
  typed: number
  stopped: "done" | "aborted" | "disconnected"
}

export const DEFAULT_KEY_DELAY_MS = 25

/**
 * How long noVNC may sit on a modifier before passing it to the guest.
 *
 * On a Windows host the first Ctrl keydown sends nothing: it arms AltGr
 * detection and starts a 100 ms timer, and the guest is told Ctrl is down only
 * when that timer expires or another key event arrives. Taking the shortcut on
 * the capture phase hides the V from noVNC, so the timer is what fires — after
 * the prelude below has already released a modifier the guest had not yet been
 * told about. Releasing once more past that window catches it.
 */
const LATE_MODIFIER_WINDOW_MS = 100

const SHIFT_KEY = { keysym: XK_SHIFT_L, code: "ShiftLeft" }

// Shift is ours to hold for capitals, so the repeat leaves it alone; the late
// delivery only ever concerns the chord modifiers.
const CHORD_MODIFIERS: ReadonlyArray<{ keysym: number; code: string }> = [
  { keysym: 0xffe3, code: "ControlLeft" },
  { keysym: 0xffe4, code: "ControlRight" },
  { keysym: 0xffe9, code: "AltLeft" },
  { keysym: 0xffea, code: "AltRight" },
  { keysym: 0xffe7, code: "MetaLeft" },
  { keysym: 0xffe8, code: "MetaRight" },
]

/**
 * Every modifier the guest may currently believe is down.
 *
 * The paste starts while the user is still holding the shortcut, and noVNC
 * told the guest about that modifier the moment it was pressed — the release
 * only follows on keyup. Typing into that state does not send characters, it
 * sends chords: under Ctrl an `m` is Return, so the guest runs whatever the
 * line already held. On macOS noVNC maps Cmd to Alt, so the same happens
 * there under Alt.
 */
const HOST_MODIFIERS: ReadonlyArray<{ keysym: number; code: string }> = [
  { keysym: 0xffe3, code: "ControlLeft" },
  { keysym: 0xffe4, code: "ControlRight" },
  { keysym: 0xffe9, code: "AltLeft" },
  { keysym: 0xffea, code: "AltRight" },
  { keysym: 0xffe7, code: "MetaLeft" },
  { keysym: 0xffe8, code: "MetaRight" },
  { keysym: XK_SHIFT_L, code: "ShiftLeft" },
  { keysym: 0xffe2, code: "ShiftRight" },
]

function timerSleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

export async function typeKeystrokes(
  sender: KeySender,
  keystrokes: readonly Keystroke[],
  options: TypeKeystrokesOptions = {},
): Promise<TypeKeystrokesResult> {
  const {
    delayMs = DEFAULT_KEY_DELAY_MS,
    signal,
    isConnected = () => true,
    onProgress,
    sleep = timerSleep,
  } = options

  let heldShift = false
  let typed = 0
  let eventsSincePrelude = 0
  let repeatedPrelude = false
  // Events whose pacing covers the window noVNC may hold a modifier for.
  const repeatAfter = Math.ceil(LATE_MODIFIER_WINDOW_MS / Math.max(delayMs, 1)) + 1

  const press = async (keysym: number, code: string, down: boolean) => {
    sender.sendKey(keysym, code, down)
    eventsSincePrelude++
    await sleep(delayMs)
  }

  const releaseModifiers = async () => {
    if (heldShift) {
      await press(SHIFT_KEY.keysym, SHIFT_KEY.code, false)
      heldShift = false
    }
  }

  // Clear the host's modifiers before the first character, so the paste types
  // what was pasted rather than chords built from it.
  if (keystrokes.length > 0) {
    for (const modifier of HOST_MODIFIERS) {
      if (!isConnected()) return { typed, stopped: "disconnected" }
      await press(modifier.keysym, modifier.code, false)
    }
    // The window is measured from here, not from the prelude's own events.
    eventsSincePrelude = 0
  }

  for (const stroke of keystrokes) {
    // A modifier noVNC was sitting on lands here, after the prelude cleared
    // one the guest had never been told about.
    if (!repeatedPrelude && eventsSincePrelude >= repeatAfter) {
      repeatedPrelude = true
      for (const modifier of CHORD_MODIFIERS) {
        if (!isConnected()) return { typed, stopped: "disconnected" }
        await press(modifier.keysym, modifier.code, false)
      }
    }

    // A dropped session takes precedence: releasing a modifier into a socket
    // that is gone is pointless, and the caller needs to hear why we stopped.
    if (!isConnected()) return { typed, stopped: "disconnected" }
    if (signal?.aborted) {
      await releaseModifiers()
      return { typed, stopped: "aborted" }
    }

    if (heldShift !== stroke.shift) {
      await press(SHIFT_KEY.keysym, SHIFT_KEY.code, stroke.shift)
      heldShift = stroke.shift
    }

    await press(stroke.keysym, stroke.code, true)
    await press(stroke.keysym, stroke.code, false)

    typed++
    onProgress?.(typed, keystrokes.length)
  }

  if (!isConnected()) return { typed, stopped: "disconnected" }
  await releaseModifiers()
  return { typed, stopped: "done" }
}
