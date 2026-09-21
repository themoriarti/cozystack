import { describe, it, expect, vi, afterEach } from "vitest"
import { screen, waitFor, cleanup, act, fireEvent } from "@testing-library/react"
import { K8sClient } from "@cozystack/k8s-client"
import { renderWithK8sProvider } from "../../test-utils/render.tsx"
import { VncTab } from "./VncTab.tsx"
import type { ApplicationDefinition, ApplicationInstance } from "@cozystack/types"

const { FakeRFB } = vi.hoisted(() => {
  class FakeRFB extends EventTarget {
    static instances: FakeRFB[] = []
    sendKey = vi.fn()
    disconnect = vi.fn()
    sendCtrlAltDel = vi.fn()
    focus = vi.fn()
    scaleViewport = false
    resizeSession = false
    canvas: HTMLCanvasElement

    // The real RFB builds a focusable canvas inside the target element and
    // takes the keyboard from it; the paste shortcut keys off exactly that.
    constructor(target: HTMLElement) {
      super()
      this.canvas = document.createElement("canvas")
      this.canvas.tabIndex = -1
      target.appendChild(this.canvas)
      FakeRFB.instances.push(this)
    }
  }
  return { FakeRFB }
})

vi.mock("@novnc/novnc/lib/rfb", () => ({ default: FakeRFB }))

const ad: ApplicationDefinition = {
  apiVersion: "cozystack.io/v1alpha1",
  kind: "ApplicationDefinition",
  metadata: { name: "virtual-machine" },
  spec: {
    application: {
      kind: "VMInstance",
      plural: "vminstances",
      singular: "vm-instance",
      openAPISchema: "{}",
    },
  },
}

const instance: ApplicationInstance = {
  apiVersion: "apps.cozystack.io/v1alpha1",
  kind: "VMInstance",
  metadata: { name: "demo-vm", namespace: "tenant-root" },
}

function runningClient() {
  const client = new K8sClient()
  vi.spyOn(client, "list").mockResolvedValue({
    apiVersion: "kubevirt.io/v1",
    kind: "VirtualMachineList",
    metadata: {},
    items: [
      {
        apiVersion: "kubevirt.io/v1",
        kind: "VirtualMachine",
        metadata: { name: "vm-instance-demo-vm" },
        status: { printableStatus: "Running" },
      },
    ],
  })
  vi.spyOn(client, "watch").mockReturnValue(() => {})
  return client
}

interface Session {
  rfb: InstanceType<typeof FakeRFB>
  sink: HTMLTextAreaElement
}

async function connectedSession(): Promise<Session> {
  const { container } = renderWithK8sProvider(<VncTab ad={ad} instance={instance} />, {
    client: runningClient(),
  })

  await waitFor(() => expect(FakeRFB.instances).toHaveLength(1))
  const rfb = FakeRFB.instances[0]
  act(() => {
    rfb.dispatchEvent(new CustomEvent("connect"))
  })
  rfb.canvas.focus()

  const sink = container.querySelector("textarea")
  if (!sink) throw new Error("paste sink missing")
  return { rfb, sink }
}

function pressPaste(init: KeyboardEventInit = {}): KeyboardEvent {
  const event = new KeyboardEvent("keydown", {
    key: "v",
    code: "KeyV",
    ctrlKey: true,
    bubbles: true,
    cancelable: true,
    ...init,
  })
  act(() => {
    ;(document.activeElement ?? document).dispatchEvent(event)
  })
  return event
}

function paste(sink: HTMLTextAreaElement, text: string) {
  fireEvent.paste(sink, { clipboardData: { getData: () => text } })
}

function pressedKeys(rfb: InstanceType<typeof FakeRFB>): string[] {
  return rfb.sendKey.mock.calls.filter(([, , down]) => down).map(([, code]) => code)
}

afterEach(() => {
  cleanup()
  FakeRFB.instances.length = 0
  vi.clearAllMocks()
})

describe("VncTab paste shortcut", () => {
  it("moves the focus to the paste sink on Ctrl+V", async () => {
    const { sink } = await connectedSession()

    pressPaste()

    expect(document.activeElement).toBe(sink)
  })

  it("accepts Cmd+V the same way", async () => {
    const { sink } = await connectedSession()

    pressPaste({ ctrlKey: false, metaKey: true })

    expect(document.activeElement).toBe(sink)
  })

  it("hides the shortcut from noVNC, which would cancel the paste", async () => {
    const { rfb } = await connectedSession()
    const seenByNoVnc = vi.fn()
    rfb.canvas.addEventListener("keydown", seenByNoVnc)

    const event = pressPaste()

    expect(seenByNoVnc).not.toHaveBeenCalled()
    // Not prevented: cancelling the keydown would cancel the browser's paste.
    expect(event.defaultPrevented).toBe(false)
  })

  it("leaves a bare V to the guest", async () => {
    const { sink, rfb } = await connectedSession()

    pressPaste({ ctrlKey: false })

    expect(document.activeElement).toBe(rfb.canvas)
    expect(document.activeElement).not.toBe(sink)
  })

  it("ignores the shortcut while the focus sits outside the console", async () => {
    const { sink } = await connectedSession()
    const outside = document.createElement("input")
    document.body.appendChild(outside)
    outside.focus()

    pressPaste()

    expect(document.activeElement).toBe(outside)
    expect(document.activeElement).not.toBe(sink)
    outside.remove()
  })
})

describe("VncTab pasted text", () => {
  it("types what the browser pasted into the session", async () => {
    const { rfb, sink } = await connectedSession()

    pressPaste()
    paste(sink, "hi")

    await waitFor(() => expect(pressedKeys(rfb)).toEqual(["KeyH", "KeyI"]))
  })

  it("hands the keyboard back to the console", async () => {
    const { rfb, sink } = await connectedSession()

    pressPaste()
    paste(sink, "x")

    await waitFor(() => expect(rfb.focus).toHaveBeenCalled())
  })

  it("types nothing once the session has dropped", async () => {
    const { rfb, sink } = await connectedSession()
    act(() => {
      rfb.dispatchEvent(new CustomEvent("disconnect", { detail: { clean: true } }))
    })

    paste(sink, "gone")

    await waitFor(() => expect(rfb.sendKey).not.toHaveBeenCalled())
  })

  it("keeps nothing of the pasted text in the sink", async () => {
    const { sink } = await connectedSession()

    pressPaste()
    paste(sink, "secret")

    expect(sink.value).toBe("")
  })
})

describe("VncTab paste feedback in the toolbar", () => {
  it("counts the characters while they are typed", async () => {
    const { sink } = await connectedSession()

    pressPaste()
    paste(sink, "abcdef")

    expect(await screen.findByText(/pasting 1\/6/i)).toBeInTheDocument()
    await waitFor(() => expect(screen.getByText(/^Connected$/)).toBeInTheDocument())
  })

  it("reports characters the guest layout cannot type", async () => {
    const { sink } = await connectedSession()

    pressPaste()
    paste(sink, "привет")

    expect(await screen.findByText(/6 chars not on layout/i)).toBeInTheDocument()
  })
})
