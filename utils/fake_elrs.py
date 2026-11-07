"""A pretend ExpressLRS TX module, for utils/preview.py.

Answers CRSF device pings and parameter reads the way the ELRS firmware does
(3.x src/lib/LUA/lua.cpp, 4.x src/lib/tx-crsf): each parameter is sent as
parent, type, name and type-specific data, split into chunks of at most 56
bytes. The receiver answers pings too, as it does once linked.
"""

import math

PING, DEVICE_INFO, PARAM_ENTRY, PARAM_READ, PARAM_WRITE, ELRS_STATUS = (
    0x28, 0x29, 0x2B, 0x2C, 0x2D, 0x2E)
TX_MODULE, RECEIVER, RADIO = 0xEE, 0xEC, 0xEA
UINT8, TEXT_SELECTION, FOLDER, INFO, COMMAND = 0, 9, 11, 12, 13
CHUNK = 56


def cstr(text):
    return list(text.encode()) + [0]


def sel(name, options, value, unit="", parent=0):
    return {"type": TEXT_SELECTION, "name": name, "options": options,
            "value": value, "unit": unit, "parent": parent}


def folder(name, dyn=None, parent=0):
    return {"type": FOLDER, "name": name, "dyn": dyn, "parent": parent}


def uint8(name, value, lo, hi, parent=0, hidden=False):
    return {"type": UINT8, "name": name, "value": value, "min": lo, "max": hi,
            "parent": parent, "hidden": hidden}


def command(name, parent=0):
    return {"type": COMMAND, "name": name, "parent": parent}


def info(name, text, hidden=False):
    return {"type": INFO, "name": name, "text": text, "hidden": hidden}


class FakeElrs:
    def __init__(self, name, fields, serial=b"ELRS", silent=False, read_only=False, refuse=()):
        self.name, self.fields, self.serial, self.silent = name, fields, serial, silent
        self.read_only = read_only  # ignore writes, to test a failed send
        self.refuse = set(refuse)   # parameter names whose writes it ignores (ELRS can
                                    # refuse e.g. a rate change while connected)
        self.reads = []    # (field id, chunk) of every parameter read
        self.writes = []   # (field name, value) of every parameter write
        self.drop = set()  # (field id, chunk) replies to lose, once each
        self.vtx_sends = 0  # "Send VTx" presses

    def vtx_admin(self):
        """VTX Administrator's (band, channel, power): what ELRS sends to the
        FC on "Send VTx" and when a quad connects. Band 0 = Off."""
        band = "Band/Enable" if any(f["name"] == "Band/Enable" for f in self.fields) else "Band"
        return self.value(band), self.value("Channel"), self.value("Pwr Lvl")

    def id_of(self, name):
        return next(i + 1 for i, f in enumerate(self.fields) if f["name"] == name)

    def set(self, name, value):
        self.fields[self.id_of(name) - 1]["value"] = value

    def device_info(self, origin, name, field_count, serial):
        return ([RADIO, origin] + cstr(name) + list(serial) + [0, 0, 0, 0]
                + [0, 4, 1, 0] + [field_count, 1])

    def value(self, name):
        return self.fields[self.id_of(name) - 1]["value"]

    def payload(self, fid, status=0, info=""):
        f = self.fields[fid - 1]
        t = f["type"]
        out = [f.get("parent", 0), t | (0x80 if f.get("hidden") else 0)]
        out += cstr((f.get("dyn") or f["name"]) if t == FOLDER else f["name"])
        if t == TEXT_SELECTION:
            out += cstr(f["options"]) + [f["value"], 0, f["options"].count(";"), 0]
            out += cstr(f["unit"])
        elif t == UINT8:
            out += [f["value"], f["min"], f["max"], 0] + cstr("")
        elif t == FOLDER:
            out += [i + 1 for i, g in enumerate(self.fields) if g.get("parent") == fid] + [0xFF]
        elif t == COMMAND:
            out += [status, 200] + cstr(info)
        elif t == INFO:
            out += cstr(f["text"])
        return out

    def handle(self, command_id, data):
        """Replies to one frame from the radio, as (command, data) pairs."""
        if self.silent:
            return []
        if command_id == PING:
            return [(DEVICE_INFO, self.device_info(TX_MODULE, self.name, len(self.fields), self.serial)),
                    (DEVICE_INFO, self.device_info(RECEIVER, "RP3 RX", 12, b"ELRS"))]
        if command_id == PARAM_WRITE and data[0] == TX_MODULE:
            return self.write(data[2], data[3])
        if command_id != PARAM_READ or data[0] != TX_MODULE:
            return []
        fid, chunk = data[2], data[3]
        if (fid, chunk) in self.drop:
            self.drop.discard((fid, chunk))
            return []
        if not 1 <= fid <= len(self.fields):
            return []
        self.reads.append((fid, chunk))
        body = self.payload(fid)
        chunks = math.ceil(len(body) / CHUNK)
        if chunk >= chunks:
            return []
        part = body[chunk * CHUNK:(chunk + 1) * CHUNK]
        return [(PARAM_ENTRY, [RADIO, TX_MODULE, fid, chunks - chunk - 1] + part)]

    def write(self, fid, value):
        """A parameter write. A command answers with its new status
        ("Sending...") without being asked, as the firmware does."""
        if not 1 <= fid <= len(self.fields):
            return []
        f = self.fields[fid - 1]
        self.writes.append((f["name"], value))
        if self.read_only or f["name"] in self.refuse:
            return []
        if f["type"] == COMMAND:
            if f["name"] == "Send VTx" and value == 1:
                self.vtx_sends += 1
            body = self.payload(fid, status=2, info="Sending...")  # 2 = executing
            return [(PARAM_ENTRY, [RADIO, TX_MODULE, fid, 0] + body)]
        f["value"] = value
        return []


TLM = "Std;Off;1:128;1:64;1:32;1:16;1:8;1:4;1:2;Race"
POWER = "10;25;50;100;250;500;1000"
DYNAMIC = "Off;Dyn;AUX9;AUX10;AUX11;AUX12"

# ELRS 4.x LR1121 rates. The firmware blanks the other band's rates, so the
# list has empty entries; the value indexes into the whole list.
_LR1121 = ["100Hz Full(-112dBm)", "150Hz(-112dBm)", "50Hz(-115dBm)", "100Hz Full(-112dBm)",
           "150Hz(-112dBm)", "250Hz(-108dBm)", "333Hz Full(-105dBm)", "500Hz(-105dBm)",
           "DK250(-103dBm)", "DK500(-103dBm)", "K1000(-103dBm)", "D50Hz(-112dBm)",
           "25Hz(-123dBm)", "50Hz(-120dBm)", "100Hz(-117dBm)", "100Hz Full(-112dBm)",
           "200Hz(-112dBm)", "200Hz Full(-111dBm)", "250Hz(-111dBm)", "K1000 Full(-101dBm)"]
RATES_LR1121_24 = ";".join(r if 2 <= i <= 10 else "" for i, r in enumerate(_LR1121))
RATES_SX1280 = ("50Hz(-115dBm);100Hz Full(-112dBm);150Hz(-112dBm);250Hz(-108dBm);"
                "333Hz Full(-105dBm);500Hz(-105dBm);D250(-104dBm);D500(-104dBm);"
                "F500(-104dBm);F1000(-104dBm)")


def mk3_internal(**kw):
    """TX16S MK3 internal module: ELRS 4.x on an LR1121, 500Hz on 2.4GHz."""
    return FakeElrs("RM TX16S MK3", [
        sel("RF Band", "915MHz;2.4GHz;X-Band", 1),
        sel("Packet Rate", RATES_LR1121_24, 7),
        sel("Telem Ratio", TLM, 0, " (1:64)"),
        sel("Switch Mode", "8ch;16ch Rate/2;12ch Mixed", 0),
        sel("Antenna Mode", "Gemini;Ant 1;Ant 2;Switch", 0),
        sel("Link Mode", "Normal;MAVLink", 0),
        sel("Model Match", "Off;On", 0, " (ID: 1)"),
        folder("TX Power", "TX Power (250 Dyn)"),
        sel("Max Power", POWER, 4, "mW", parent=8),
        sel("Dynamic", DYNAMIC, 1, parent=8),
        sel("Fan Thresh", "10mW;25mW;50mW;100mW;250mW;500mW;1000mW;2000mW;Never", 3, parent=8),
        folder("VTX Administrator", "VTX Admin (R:3:1)"),
        sel("Band/Enable", "Disabled;A;B;E;F;R;L", 5, parent=12),
        uint8("Channel", 3, 1, 8, parent=12),
        sel("Pwr Lvl", "-;1;2;3;4;5;6;7;8", 1, parent=12),
        sel("Pitmode", "Off;On", 0, parent=12),
        command("Send VTx", parent=12),
        folder("WiFi Connectivity"),
        command("Enable WiFi", parent=18),
        command("Enable Rx WiFi", parent=18),
        command("BLE Joystick"),
        command("Bind"),
        info("4.1.0", "FCC915"),
    ], **kw)


def mk2_ranger_micro(**kw):
    """Ranger Micro on the MK2: ELRS 3.x on an SX1280, 250Hz, telemetry 1:16."""
    return FakeElrs("RadioMaster Ranger Micro", [
        sel("Packet Rate", RATES_SX1280, 3),
        sel("Telem Ratio", TLM, 5, " (5859bps)"),
        sel("Switch Mode", "Wide;Hybrid", 1),
        sel("Model Match", "Off;On", 0, " (ID: 1)"),
        folder("TX Power", "TX Power (100)"),
        sel("Max Power", POWER, 3, "mW", parent=5),
        sel("Dynamic", DYNAMIC, 0, parent=5),
        folder("VTX Administrator"),
        sel("Band", "Off;A;B;E;F;R;L", 0, parent=8),
        uint8("Channel", 1, 1, 8, parent=8),
        sel("Pwr Lvl", "-;1;2;3;4;5;6;7;8", 0, parent=8),
        sel("Pitmode", "Off;On", 0, parent=8),
        command("Send VTx", parent=8),
        folder("WiFi Connectivity"),
        command("Enable WiFi", parent=14),
        command("Bind"),
        info("Bad/Good", "0/250", hidden=True),
        info("3.6.3", "ISM2G4"),
    ], **kw)


# --- The quad's flight controller -------------------------------------------

MSP_REQ, MSP_RESP, MSP_WRITE = 0x7A, 0x7B, 0x7C
FC = 0xC8
MSP_VTX_CONFIG, MSP_VTXTABLE_BAND, MSP_VTXTABLE_POWERLEVEL = 88, 137, 138

# An HDZero-style Betaflight VTX table: bands A and B empty, E1, F2, F4 and
# R1-R8, two power levels. (Illustrative; check `vtxtable` on your own FC.)
HDZERO_BANDS = [
    ("BOSCAM_A", "A", [0] * 8),
    ("BOSCAM_B", "B", [0] * 8),
    ("BOSCAM_E", "E", [5705, 0, 0, 0, 0, 0, 0, 0]),
    ("FATSHARK", "F", [0, 5760, 0, 5800, 0, 0, 0, 0]),
    ("RACEBAND", "R", [5658, 5695, 5732, 5769, 5806, 5843, 5880, 5917]),
]
HDZERO_POWERS = [(25, "25 "), (200, "200")]


def u16(value):
    return [value & 0xFF, (value >> 8) & 0xFF]


class FakeFc:
    """Betaflight answering MSP over CRSF the way src/main/telemetry/
    msp_shared.c frames replies: status (start flag, sequence, version),
    size and command, then payload, in chunks of at most `chunk` bytes."""

    def __init__(self, band=5, ch=3, power=1, pit=0, vtx_type=5,
                 bands=HDZERO_BANDS, powers=HDZERO_POWERS, chunk=58):
        self.band, self.ch, self.power, self.pit, self.vtx_type = band, ch, power, pit, vtx_type
        self.bands, self.powers, self.chunk = bands, powers, chunk
        self.seq = 0
        self.requests = []  # MSP commands asked for
        self.drop = set()   # commands whose next reply is lost

    def freq(self):
        if 1 <= self.band <= len(self.bands) and 1 <= self.ch <= 8:
            return self.bands[self.band - 1][2][self.ch - 1]
        return 0

    def apply_vtx_admin(self, band, ch, power):
        """MSP_SET_VTX_CONFIG from ELRS VTX Admin: band/channel index, power."""
        self.band, self.ch = band, ch
        if power:
            self.power = power

    def reply(self, cmd, payload):
        if cmd == MSP_VTX_CONFIG:
            return ([self.vtx_type, self.band, self.ch, self.power, self.pit] + u16(self.freq())
                    + [1, 0] + u16(0) + [1, len(self.bands), 8, len(self.powers)])
        if cmd == MSP_VTXTABLE_BAND and payload and 1 <= payload[0] <= len(self.bands):
            name, letter, freqs = self.bands[payload[0] - 1]
            body = [payload[0], 8] + list(name.ljust(8).encode()) + [ord(letter), 1, 8]
            for f in freqs:
                body += u16(f)
            return body
        if cmd == MSP_VTXTABLE_POWERLEVEL and payload and 1 <= payload[0] <= len(self.powers):
            value, label = self.powers[payload[0] - 1]
            return [payload[0]] + u16(value) + [3] + list(label.ljust(3).encode())
        return None  # Betaflight answers unknown or invalid requests with an error

    def handle(self, data):
        """One request frame (dest, origin, status, size, cmd, payload) ->
        reply frames (dest, origin, MSP chunk)."""
        status = data[2]
        if not status & 0x10:
            return []  # only single-chunk requests are sent to it
        version = (status >> 5) & 0x03
        size, cmd = data[3], data[4]
        self.requests.append(cmd)
        if cmd in self.drop:
            self.drop.discard(cmd)
            return []
        body = self.reply(cmd, data[5:5 + size])
        error = body is None
        body = body or []
        frames, first = [], True
        while first or body:
            if first:
                head = [0x10 | self.seq | (version << 5) | (0x80 if error else 0), len(body), cmd]
            else:
                head = [self.seq | (version << 5)]
            self.seq = (self.seq + 1) % 16
            room = self.chunk - len(head)
            frames.append((MSP_RESP, [0xEA, FC] + head + body[:room]))
            body, first = body[room:], False
        return frames
