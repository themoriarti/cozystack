import { describe, it, expect, vi } from "vitest"
import { planKeystrokes } from "./vnc-keymap.ts"
import { typeKeystrokes, DEFAULT_KEY_DELAY_MS, type KeySender } from "./vnc-typing.ts"

interface SentKey {
  keysym: number
  code: string
  down: boolean
}

function recorder(): { sender: KeySender; sent: SentKey[] } {
  const sent: SentKey[] = []
  return {
    sent,
    sender: {
      sendKey: (keysym, code, down) => {
        sent.push({ keysym, code, down })
      },
    },
  }
}

const noSleep = () => Promise.resolve()

function trace(sent: SentKey[]): string[] {
  return sent.map((k) => `${k.code}${k.down ? "↓" : "↑"}`)
}

// Every run starts by releasing the modifiers the host may still be holding.
const PRELUDE = 8

function typedTrace(sent: SentKey[]): string[] {
  return trace(sent.slice(PRELUDE))
}

describe("typeKeystrokes", () => {
  it("presses and releases each key in order", async () => {
    const { sender, sent } = recorder()

    const result = await typeKeystrokes(sender, planKeystrokes("ab").keystrokes, {
      sleep: noSleep,
    })

    expect(typedTrace(sent)).toEqual(["KeyA↓", "KeyA↑", "KeyB↓", "KeyB↑"])
    expect(result).toEqual({ typed: 2, stopped: "done" })
  })

  it("holds Shift across a run of shifted characters and releases it once", async () => {
    const { sender, sent } = recorder()

    await typeKeystrokes(sender, planKeystrokes("ABc").keystrokes, { sleep: noSleep })

    // The repeat for a late-delivered chord modifier lands in the middle and
    // deliberately leaves Shift alone: that one is ours, held for the capitals.
    expect(typedTrace(sent)).toEqual([
      "ShiftLeft↓",
      "KeyA↓",
      "KeyA↑",
      "KeyB↓",
      "KeyB↑",
      "ControlLeft↑",
      "ControlRight↑",
      "AltLeft↑",
      "AltRight↑",
      "MetaLeft↑",
      "MetaRight↑",
      "ShiftLeft↑",
      "KeyC↓",
      "KeyC↑",
    ])
  })

  it("releases a held modifier when the text ends", async () => {
    const { sender, sent } = recorder()

    await typeKeystrokes(sender, planKeystrokes("A").keystrokes, { sleep: noSleep })

    expect(trace(sent).at(-1)).toBe("ShiftLeft↑")
  })

  it("waits between key events so the guest keyboard buffer keeps up", async () => {
    const { sender } = recorder()
    const sleep = vi.fn(() => Promise.resolve())

    await typeKeystrokes(sender, planKeystrokes("ab").keystrokes, {
      sleep,
      delayMs: 7,
    })

    expect(sleep).toHaveBeenCalledTimes(PRELUDE + 4)
    expect(sleep).toHaveBeenCalledWith(7)
  })

  it("paces itself at the measured default when no delay is given", async () => {
    const { sender } = recorder()
    const sleep = vi.fn(() => Promise.resolve())

    await typeKeystrokes(sender, planKeystrokes("a").keystrokes, { sleep })

    // Measured, not chosen: at no pacing a 1000-character paste came back
    // with characters dropped and reordered, while 25 ms round-tripped clean.
    expect(sleep).toHaveBeenCalledWith(DEFAULT_KEY_DELAY_MS)
    expect(DEFAULT_KEY_DELAY_MS).toBe(25)
  })

  it("releases the chord modifiers again once a late delivery could have landed", async () => {
    const { sender, sent } = recorder()

    await typeKeystrokes(sender, planKeystrokes("abcdef").keystrokes, { sleep: noSleep })

    // On a Windows host noVNC sits on the first Ctrl for 100 ms and hands it
    // to the guest on a timer, which fires after the prelude has run. The
    // repeat is what catches that, and it happens once, not per character.
    const releases = trace(sent).filter((k) => k === "ControlLeft↑")
    expect(releases).toHaveLength(2)
  })

  it("reports progress as characters land", async () => {
    const { sender } = recorder()
    const onProgress = vi.fn()

    await typeKeystrokes(sender, planKeystrokes("abc").keystrokes, {
      sleep: noSleep,
      onProgress,
    })

    expect(onProgress.mock.calls).toEqual([
      [1, 3],
      [2, 3],
      [3, 3],
    ])
  })
})

describe("typeKeystrokes and the host's own modifiers", () => {
  it("releases every modifier the host may hold before the first character", async () => {
    const { sender, sent } = recorder()

    await typeKeystrokes(sender, planKeystrokes("a").keystrokes, { sleep: noSleep })

    // The paste begins while the user is still holding the shortcut, and the
    // guest was told that modifier is down. Typing into that state sends
    // chords, not characters: under Ctrl an "m" is Return.
    expect(trace(sent).slice(0, PRELUDE)).toEqual([
      "ControlLeft↑",
      "ControlRight↑",
      "AltLeft↑",
      "AltRight↑",
      "MetaLeft↑",
      "MetaRight↑",
      "ShiftLeft↑",
      "ShiftRight↑",
    ])
  })

  it("does not send the prelude when there is nothing to type", async () => {
    const { sender, sent } = recorder()

    await typeKeystrokes(sender, planKeystrokes("").keystrokes, { sleep: noSleep })

    expect(sent).toEqual([])
  })
})

describe("typeKeystrokes interruption", () => {
  it("stops on abort and releases the modifier it was holding", async () => {
    const { sender, sent } = recorder()
    const controller = new AbortController()
    let sleeps = 0
    const sleep = () => {
      // Abort once the prelude is done and a character has gone in, which is
      // where a user cancelling a paste actually lands.
      if (++sleeps > PRELUDE + 2) controller.abort()
      return Promise.resolve()
    }

    const result = await typeKeystrokes(sender, planKeystrokes("ABC").keystrokes, {
      sleep,
      signal: controller.signal,
    })

    expect(result.stopped).toBe("aborted")
    expect(result.typed).toBe(1)
    expect(trace(sent).at(-1)).toBe("ShiftLeft↑")
    expect(typedTrace(sent)[0]).toBe("ShiftLeft↓")
  })

  it("stops typing when the session drops and sends nothing more", async () => {
    const { sender, sent } = recorder()
    let connected = true
    let sleeps = 0

    const result = await typeKeystrokes(sender, planKeystrokes("abc").keystrokes, {
      // Drop it after the prelude and the first character, where a session
      // actually goes: inside the prelude nothing is pressed yet, so the
      // assertion below would hold no matter what the loop did.
      sleep: () => {
        if (++sleeps > PRELUDE + 2) connected = false
        return Promise.resolve()
      },
      isConnected: () => connected,
    })

    // The drop lands mid-character, so that one finishes and the loop stops
    // at the next check rather than typing the rest.
    expect(result).toEqual({ typed: 2, stopped: "disconnected" })
    expect(typedTrace(sent)).toEqual(["KeyA↓", "KeyA↑", "KeyB↓", "KeyB↑"])
  })

  it("does not try to release modifiers into a dropped session", async () => {
    const { sender, sent } = recorder()
    let connected = true
    let sleeps = 0

    await typeKeystrokes(sender, planKeystrokes("AB").keystrokes, {
      // Shift goes down for the capital, then the session drops: the release
      // must not be sent into a socket that is gone.
      sleep: () => {
        if (++sleeps > PRELUDE + 2) connected = false
        return Promise.resolve()
      },
      isConnected: () => connected,
    })

    expect(typedTrace(sent)).toEqual(["ShiftLeft↓", "KeyA↓", "KeyA↑"])
  })

  it("leaves the last modifier alone when the session dies on the final character", async () => {
    const { sender, sent } = recorder()
    let connected = true
    let sleeps = 0

    // "A" is prelude + Shift down + the character, so the drop lands after the
    // loop has finished and the run reaches its closing release — the one path
    // where that release is reachable at all.
    await typeKeystrokes(sender, planKeystrokes("A").keystrokes, {
      sleep: () => {
        if (++sleeps >= PRELUDE + 3) connected = false
        return Promise.resolve()
      },
      isConnected: () => connected,
    })

    expect(typedTrace(sent)).toEqual(["ShiftLeft↓", "KeyA↓", "KeyA↑"])
    expect(trace(sent).at(-1)).not.toBe("ShiftLeft↑")
  })

  it("sends nothing at all when the session is already down", async () => {
    const { sender, sent } = recorder()

    const result = await typeKeystrokes(sender, planKeystrokes("a").keystrokes, {
      sleep: noSleep,
      isConnected: () => false,
    })

    expect(sent).toEqual([])
    expect(result).toEqual({ typed: 0, stopped: "disconnected" })
  })
})
