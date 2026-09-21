import { describe, it, expect, vi, afterEach } from "vitest"
import { openSerialStream, serialConsoleUrl, type SerialSocket } from "./serial-stream.ts"

class FakeSocket implements SerialSocket {
  static last: FakeSocket | null = null
  sent: unknown[] = []
  closed = false
  binaryType = ""
  onopen: (() => void) | null = null
  onclose: ((e: { code: number; reason: string }) => void) | null = null
  onerror: (() => void) | null = null
  onmessage: ((e: { data: unknown }) => void) | null = null

  url: string
  protocols?: string | string[]

  constructor(url: string, protocols?: string | string[]) {
    this.url = url
    this.protocols = protocols
    FakeSocket.last = this
  }

  send(data: unknown) {
    this.sent.push(data)
  }

  close() {
    this.closed = true
  }
}

function open(handlers: Parameters<typeof openSerialStream>[1] = {}) {
  const stream = openSerialStream("ws://host/console", handlers, (url, protocols) => new FakeSocket(url, protocols))
  const socket = FakeSocket.last!
  return { stream, socket }
}

function decodeSent(value: unknown): string {
  return new TextDecoder().decode(value as Uint8Array)
}

afterEach(() => {
  FakeSocket.last = null
})

describe("serialConsoleUrl", () => {
  it("addresses the VMI console subresource through the /k8s prefix", () => {
    expect(serialConsoleUrl("http:", "console.example", "tenant-root", "vm-demo")).toBe(
      "ws://console.example/k8s/apis/subresources.kubevirt.io/v1/namespaces/tenant-root/virtualmachineinstances/vm-demo/console",
    )
  })

  it("upgrades to wss when the page is served over https", () => {
    expect(serialConsoleUrl("https:", "console.example", "ns", "vm")).toMatch(/^wss:\/\//)
  })
})

describe("openSerialStream", () => {
  it("asks for the protocol virt-api speaks", () => {
    const { socket } = open()

    expect(socket.protocols).toEqual(["plain.kubevirt.io"])
  })

  it("sends keystrokes as binary — virt-api drops text frames on the floor", () => {
    const { stream, socket } = open()

    stream.send("ls\n")

    expect(socket.sent).toHaveLength(1)
    expect(ArrayBuffer.isView(socket.sent[0])).toBe(true)
    expect(decodeSent(socket.sent[0])).toBe("ls\n")
  })

  it("encodes non-ASCII as UTF-8 rather than one byte per character", () => {
    const { stream, socket } = open()

    stream.send("привет")

    expect(decodeSent(socket.sent[0])).toBe("привет")
    expect((socket.sent[0] as Uint8Array).length).toBe(12)
  })

  it("decodes what the guest writes back", () => {
    const onData = vi.fn()
    const { socket } = open({ onData })

    socket.onmessage?.({ data: new TextEncoder().encode("hello").buffer })

    expect(onData).toHaveBeenCalledWith("hello")
  })

  it("keeps multi-byte characters whole across chunk boundaries", () => {
    const onData = vi.fn()
    const { socket } = open({ onData })
    const bytes = new TextEncoder().encode("привет")

    socket.onmessage?.({ data: bytes.slice(0, 5).buffer })
    socket.onmessage?.({ data: bytes.slice(5).buffer })

    expect(onData.mock.calls.map(([text]) => text).join("")).toBe("привет")
  })

  it("reports the connection opening and closing", () => {
    const onOpen = vi.fn()
    const onClose = vi.fn()
    const { socket } = open({ onOpen, onClose })

    socket.onopen?.()
    socket.onclose?.({ code: 1006, reason: "gone" })

    expect(onOpen).toHaveBeenCalled()
    expect(onClose).toHaveBeenCalledWith({ code: 1006, reason: "gone" })
  })

  it("drops writes once closed instead of throwing at the caller", () => {
    const { stream, socket } = open()

    stream.close()
    stream.send("ignored")

    expect(socket.closed).toBe(true)
    expect(socket.sent).toEqual([])
  })

  it("reports a close only once, however the socket ends", () => {
    const onClose = vi.fn()
    const { socket } = open({ onClose })

    socket.onerror?.()
    socket.onclose?.({ code: 1006, reason: "" })

    expect(onClose).toHaveBeenCalledTimes(1)
  })
})
