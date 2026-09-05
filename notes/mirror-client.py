#!/usr/bin/env python3
"""Headless Meshtastic screen-mirror client.

Speaks the phone API through meshtastic-python, arms display mirroring with a
hand-encoded AdminMessage (the released python protobufs predate these fields),
reassembles DisplayFrame chunks - MONO_VLSB full frames or RGB565 dirty rects -
into a canvas, and writes PNGs. Optionally injects input events so a caller can
capture before/after and prove remote control without a camera.
"""
import argparse
import struct
import sys
import time
import zlib

from meshtastic import portnums_pb2
from meshtastic.serial_interface import SerialInterface

# ── minimal protobuf reader ────────────────────────────────────────────────


def _varint(buf, i):
    result = shift = 0
    while True:
        b = buf[i]
        i += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, i
        shift += 7


def parse_fields(buf):
    """Returns {field_number: [values]} - ints for varints, bytes for length-delimited."""
    out, i = {}, 0
    while i < len(buf):
        key, i = _varint(buf, i)
        field, wire = key >> 3, key & 7
        if wire == 0:
            v, i = _varint(buf, i)
        elif wire == 2:
            ln, i = _varint(buf, i)
            v, i = buf[i : i + ln], i + ln
        elif wire == 5:
            v, i = buf[i : i + 4], i + 4
        elif wire == 1:
            v, i = buf[i : i + 8], i + 8
        else:
            raise ValueError(f"bad wire type {wire}")
        out.setdefault(field, []).append(v)
    return out


def first(fields, num, default=0):
    vals = fields.get(num)
    return vals[0] if vals else default


# ── protobuf writers (only what we need) ───────────────────────────────────


def _tag(field, wire):
    key, out = (field << 3) | wire, b""
    while True:
        b = key & 0x7F
        key >>= 7
        out += bytes([b | (0x80 if key else 0)])
        if not key:
            return out


def varint_field(field, value):
    out = _tag(field, 0)
    while True:
        b = value & 0x7F
        value >>= 7
        out += bytes([b | (0x80 if value else 0)])
        if not value:
            return out


def bytes_field(field, payload):
    return _tag(field, 2) + varint_field(0, len(payload))[1:] + payload


# AdminMessage field numbers from meshtastic/admin.proto on this branch
ADMIN_SET_DISPLAY_MIRROR = 51
ADMIN_GET_DISPLAY_FRAME = 50
ADMIN_SEND_INPUT_EVENT = 27


def admin_set_mirror(enabled):
    return varint_field(ADMIN_SET_DISPLAY_MIRROR, 1 if enabled else 0)


def admin_request_frame():
    return varint_field(ADMIN_GET_DISPLAY_FRAME, 1)


def admin_input_event(event_code, kb_char=0, touch_x=0, touch_y=0):
    ev = varint_field(1, event_code)
    if kb_char:
        ev += varint_field(2, kb_char)
    if touch_x:
        ev += varint_field(3, touch_x)
    if touch_y:
        ev += varint_field(4, touch_y)
    return bytes_field(ADMIN_SEND_INPUT_EVENT, ev)


# ── PNG output ─────────────────────────────────────────────────────────────


def write_png(path, width, height, rgb):
    raw = b"".join(b"\x00" + rgb[y * width * 3 : (y + 1) * width * 3] for y in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 6))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(png)


def rgb565_to_rgb(v):
    r5, g6, b5 = (v >> 11) & 0x1F, (v >> 5) & 0x3F, v & 0x1F
    return bytes(((r5 << 3) | (r5 >> 2), (g6 << 2) | (g6 >> 4), (b5 << 3) | (b5 >> 2)))


# ── mirror state ───────────────────────────────────────────────────────────

FORMAT_MONO_VLSB, FORMAT_RGB565 = 1, 2


class Mirror:
    def __init__(self):
        self.width = self.height = 0
        self.rgb = None          # canvas, w*h*3
        self.mono = None         # partial mono frame buffer
        self.mono_expect = 0
        self.rect = None         # partial rect buffer
        self.rect_expect = 0
        self.rect_meta = None
        self.frames = 0
        self.rects = 0

    def ensure(self, w, h):
        if (w, h) != (self.width, self.height) or self.rgb is None:
            self.width, self.height = w, h
            self.rgb = bytearray(w * h * 3)

    def handle(self, f):
        w, h = first(f, 1), first(f, 2)
        fmt = first(f, 3) or FORMAT_MONO_VLSB
        offset, total = first(f, 5), first(f, 6)
        data = first(f, 7, b"")
        rect_w, rect_h = first(f, 10), first(f, 11)
        if not w or not h or not total:
            return
        self.ensure(w, h)

        if fmt == FORMAT_RGB565 and rect_w:
            rect_x, rect_y = first(f, 8), first(f, 9)
            if offset == 0:
                self.rect = bytearray(total)
                self.rect_expect = 0
                self.rect_meta = (rect_x, rect_y, rect_w, rect_h)
            if self.rect is None or offset != self.rect_expect:
                self.rect = None
                return
            self.rect[offset : offset + len(data)] = data
            self.rect_expect += len(data)
            if self.rect_expect >= total:
                self._blit_rect()
                self.rect = None
                self.rects += 1
        elif fmt == FORMAT_MONO_VLSB:
            if offset == 0:
                self.mono = bytearray(total)
                self.mono_expect = 0
            if self.mono is None or offset != self.mono_expect:
                self.mono = None
                return
            self.mono[offset : offset + len(data)] = data
            self.mono_expect += len(data)
            if self.mono_expect >= total:
                self._render_mono()
                self.mono = None
                self.frames += 1

    def _blit_rect(self):
        x0, y0, rw, rh = self.rect_meta
        for row in range(rh):
            src = row * rw * 2
            for col in range(rw):
                v = self.rect[src + col * 2] | (self.rect[src + col * 2 + 1] << 8)
                dst = ((y0 + row) * self.width + (x0 + col)) * 3
                if 0 <= dst <= len(self.rgb) - 3:
                    self.rgb[dst : dst + 3] = rgb565_to_rgb(v)

    def _render_mono(self):
        for y in range(self.height):
            page = (y // 8) * self.width
            bit = 1 << (y % 8)
            for x in range(self.width):
                idx = page + x
                on = idx < len(self.mono) and (self.mono[idx] & bit)
                dst = (y * self.width + x) * 3
                self.rgb[dst : dst + 3] = b"\xff\xff\xff" if on else b"\x00\x00\x00"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="/dev/cu.usbmodem1101")
    ap.add_argument("--out", default="mirror")
    ap.add_argument("--settle", type=float, default=8.0, help="seconds to collect the first sync")
    ap.add_argument("--shots", type=int, default=1)
    ap.add_argument("--interval", type=float, default=5.0)
    ap.add_argument("--inject", default="", help="event_code[,x,y] injected between shot 1 and 2")
    args = ap.parse_args()

    mirror = Mirror()
    orig = SerialInterface._handleFromRadio

    def patched(self, payload, **kwargs):
        try:
            fields = parse_fields(payload)
            for raw in fields.get(20, []):
                mirror.handle(parse_fields(raw))
        except Exception as exc:  # keep the session alive; report at the end
            print(f"parse error: {exc}", file=sys.stderr)
        return orig(self, payload, **kwargs)

    SerialInterface._handleFromRadio = patched

    iface = SerialInterface(devPath=args.port)
    time.sleep(2)
    node_num = iface.myInfo.my_node_num
    print(f"connected: node={node_num:#x}")

    def send_admin(payload):
        iface.sendData(
            payload,
            destinationId=node_num,
            portNum=portnums_pb2.PortNum.ADMIN_APP,
            wantAck=False,
            wantResponse=False,
        )

    send_admin(admin_set_mirror(True))
    send_admin(admin_request_frame())
    print(f"mirror armed; collecting {args.settle}s ...")
    time.sleep(args.settle)

    for shot in range(args.shots):
        if shot:
            time.sleep(args.interval)
        if mirror.rgb is None:
            print(f"shot {shot}: NO FRAME RECEIVED")
            continue
        path = f"{args.out}{shot}.png"
        write_png(path, mirror.width, mirror.height, bytes(mirror.rgb))
        print(f"shot {shot}: {path} {mirror.width}x{mirror.height} frames={mirror.frames} rects={mirror.rects}")
        if shot == 0 and args.inject:
            parts = [int(p) for p in args.inject.split(",")]
            code = parts[0]
            x, y = (parts[1], parts[2]) if len(parts) >= 3 else (0, 0)
            send_admin(admin_input_event(code, touch_x=x, touch_y=y))
            print(f"injected event {code} at ({x},{y})")

    send_admin(admin_set_mirror(False))
    iface.close()


if __name__ == "__main__":
    main()
