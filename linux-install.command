#!/bin/bash
# Adds the exported Linux build (linux/SplineMaker.arm64) to Steam as a VR app with name and art.
#  1. Installs a .desktop launcher ("Spline Maker" + icon) for the app menu.
#  2. Creates or updates the Steam shortcut: name, icon, "Include in VR Library" (without it Steam
#     shows the app as a flat window and keeps input focus from the XR session), and library art.
# Steam keeps shortcuts in memory and overwrites shortcuts.vdf, and on SteamOS it can't be stopped
# (steam.service restarts it, and stopping the service ends the session). So the changes go through
# Steam's own JS API (SteamClient.Apps.*) over its CEF remote-debugging port, and apply live.
cd "$(dirname "$0")" || exit 1

# Double-clicked from the file manager: no terminal, so reopen in one to show the output.
if [ ! -t 0 ]; then
	for TERM_APP in konsole gnome-terminal xterm; do
		command -v "$TERM_APP" > /dev/null && exec "$TERM_APP" -e bash "$(pwd)/$(basename "$0")"
	done
	echo "No terminal found. Run $0 from a terminal." >&2
	exit 1
fi
trap 'read -r -p "Press Enter to close." _' EXIT

ROOT="$(pwd)"
EXE="$ROOT/linux/SplineMaker.arm64"
APP_NAME="Spline Maker"
STEAM_ICON="$ROOT/linux/SplineMaker.png"

if [ ! -x "$EXE" ]; then
	echo "Missing $EXE. Export the SteamFrame preset first."
	exit 1
fi

DESKTOP="$HOME/.local/share/applications/splinemaker.desktop"
mkdir -p "$(dirname "$DESKTOP")"
cat > "$DESKTOP" <<EOF2
[Desktop Entry]
Type=Application
Name=$APP_NAME
Comment=VR spline drawing and editing
Exec="$EXE"
Path=$ROOT/linux
Icon=$ROOT/icon.png
Terminal=false
Categories=Graphics;3DGraphics;
EOF2
chmod +x "$DESKTOP"
echo "Installed $DESKTOP"

python3 - "$EXE" "$APP_NAME" "$ROOT" "$STEAM_ICON" <<'PY'
import base64, glob, json, os, re, socket, struct, sys, urllib.request, zlib

exe, app_name, root, steam_icon = sys.argv[1:5]

# Steam rejects icon.png ("load icon ... failed: invalid format"); it accepts a 256px RGBA PNG.
def make_icon(src, dst, size=256):
	data = open(src, "rb").read()
	pos, idat = 8, b""
	while pos < len(data):
		n, kind = struct.unpack_from(">I4s", data, pos)
		chunk = data[pos + 8:pos + 8 + n]
		if kind == b"IHDR":
			w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", chunk)
		elif kind == b"IDAT":
			idat += chunk
		pos += 12 + n
	if depth != 8 or ctype not in (2, 6) or interlace:
		raise ValueError("unsupported PNG format in %s" % src)
	bpp = 4 if ctype == 6 else 3
	raw, stride = zlib.decompress(idat), w * bpp
	rows, prev = [], bytearray(stride)
	for y in range(h):
		f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
		for x in range(stride):
			a = line[x - bpp] if x >= bpp else 0
			b, c = prev[x], prev[x - bpp] if x >= bpp else 0
			if f == 1: line[x] = (line[x] + a) & 0xFF
			elif f == 2: line[x] = (line[x] + b) & 0xFF
			elif f == 3: line[x] = (line[x] + (a + b) // 2) & 0xFF
			elif f == 4:
				p = a + b - c
				pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
				line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 0xFF
		rows.append(line)
		prev = line
	out = bytearray()
	for y in range(size):  # box filter downscale
		out.append(0)
		y0, y1 = y * h // size, max(y * h // size + 1, (y + 1) * h // size)
		for x in range(size):
			x0, x1 = x * w // size, max(x * w // size + 1, (x + 1) * w // size)
			acc = [0, 0, 0, 0]
			for sy in range(y0, y1):
				for sx in range(x0, x1):
					px = rows[sy][sx * bpp:sx * bpp + bpp]
					for k in range(4):
						acc[k] += px[k] if k < bpp else 255
			n = (y1 - y0) * (x1 - x0)
			out += bytes(v // n for v in acc)
	def chunk(kind, body):
		return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))
	png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
	png += chunk(b"IDAT", zlib.compress(bytes(out), 9)) + chunk(b"IEND", b"")
	open(dst, "wb").write(png)

make_icon(os.path.join(root, "icon.png"), steam_icon)

# Runs a JS expression in Steam's SharedJSContext via the Chrome DevTools protocol (minimal websocket client).
def steam_eval(expr, port=8080):
	targets = json.load(urllib.request.urlopen("http://127.0.0.1:%d/json" % port, timeout=5))
	url = next(t["webSocketDebuggerUrl"] for t in targets if t["title"] == "SharedJSContext")
	s = socket.create_connection(("127.0.0.1", port), timeout=30)
	s.sendall(("GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
		"Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n"
		% (url.split(str(port), 1)[1], port, base64.b64encode(os.urandom(16)).decode())).encode())
	buf = b""
	while b"\r\n\r\n" not in buf:
		buf += s.recv(4096)
	buf = buf.split(b"\r\n\r\n", 1)[1]
	msg = json.dumps({"id": 1, "method": "Runtime.evaluate",
		"params": {"expression": expr, "awaitPromise": True, "returnByValue": True}}).encode()
	n, mask = len(msg), os.urandom(4)
	hdr = bytes([0x81, 0x80 | n]) if n < 126 else b"\x81\xfe" + struct.pack(">H", n) if n < 65536 else b"\x81\xff" + struct.pack(">Q", n)
	s.sendall(hdr + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(msg)))
	def need(k):
		nonlocal buf
		while len(buf) < k:
			buf += s.recv(65536)
	data = b""
	while True:
		need(2)
		fin, n, off = buf[0] & 0x80, buf[1] & 0x7F, 2
		if n == 126: need(4); n, off = struct.unpack(">H", buf[2:4])[0], 4
		elif n == 127: need(10); n, off = struct.unpack(">Q", buf[2:10])[0], 10
		need(off + n)
		data, buf = data + buf[off:off + n], buf[off + n:]
		if fin:
			reply, data = json.loads(data), b""
			if reply.get("id") == 1:
				result = reply["result"]
				if "exceptionDetails" in result:
					raise RuntimeError(result["exceptionDetails"])
				return result["result"].get("value")

# Binary VDF: 0x00 map, 0x01 string, 0x02 int32, 0x08 end of map. Only read, to find an existing shortcut.
def read_map(b, i):
	out = []
	while True:
		t = b[i]; i += 1
		if t == 0x08:
			return out, i
		j = b.index(0, i); key = b[i:j].decode("utf-8", "replace"); i = j + 1
		if t == 0x00:
			val, i = read_map(b, i)
		elif t == 0x01:
			j = b.index(0, i); val = b[i:j].decode("utf-8", "replace"); i = j + 1
		elif t == 0x02:
			val = struct.unpack_from("<i", b, i)[0]; i += 4
		else:
			raise ValueError("unknown vdf type %d" % t)
		out.append([t, key, val])

appid = 0
grids = []
for vdf in glob.glob(os.path.expanduser("~/.local/share/Steam/userdata/*/config/shortcuts.vdf")):
	grids.append(os.path.join(os.path.dirname(vdf), "grid"))
	data = open(vdf, "rb").read()
	shortcuts, _ = read_map(data, data.index(0, 1) + 1)  # 0x00 "shortcuts" 0x00 <map> 0x08
	for entry in shortcuts:
		fields = {f[1].lower(): f[2] for f in entry[2]}
		if os.path.basename(exe) in fields.get("exe", ""):
			appid = fields["appid"] & 0xFFFFFFFF

# SetCustomArtworkForApp asset types: 0 portrait capsule, 1 hero, 2 logo, 3 wide capsule, 4 icon.
art = [("icon.png", 0), ("icon-banner.jpg", 1), ("icon-banner.jpg", 3)]
args = {
	"appid": appid, "name": app_name, "exe": '"%s"' % exe, "dir": os.path.dirname(exe) + "/", "icon": steam_icon,
	"art": [[base64.b64encode(open(os.path.join(root, src), "rb").read()).decode(), src.rsplit(".", 1)[1], kind]
		for src, kind in art],
}
js = """(async (a) => {
	const apps = SteamClient.Apps;
	const id = a.appid || await apps.AddShortcut(a.name, a.exe, a.dir, "");
	apps.SetShortcutName(id, a.name);
	apps.SetShortcutExe(id, a.exe);
	apps.SetShortcutStartDir(id, a.dir);
	apps.SetShortcutIcon(id, a.icon);
	apps.SetShortcutIsVR(id, true);
	for (const [data, ext, kind] of a.art)
		await apps.SetCustomArtworkForApp(id, data, ext, kind);
	return id;
})(%s)""" % json.dumps(args)
try:
	appid = steam_eval(js) & 0xFFFFFFFF
except OSError as e:
	print("Couldn't reach Steam (%s). Start Steam and rerun, or set it by hand: right-click the"
		" shortcut → Properties → Shortcut → enable \"Include in VR Library\"." % e)
	sys.exit(1)
print("%s Steam shortcut %d: name, icon, VR app, library art" % ("Updated" if args["appid"] else "Created", appid))

# Earlier versions of this script copied art straight into grid/ under the appids of since-removed shortcuts.
sources = {open(os.path.join(root, src), "rb").read() for src, _ in art}
for grid in grids:
	for name in os.listdir(grid) if os.path.isdir(grid) else []:
		m = re.fullmatch(r"(\d+)(_hero|p)?\.(jpg|png)", name)
		path = os.path.join(grid, name)
		if m and int(m.group(1)) != appid and open(path, "rb").read() in sources:
			os.remove(path)
PY
