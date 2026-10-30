"""Stub for tools/h7_direct/h7_robust_write.py (no hardware).

    h7_robust_write.py CFG IMAGE BASE [--erase]

  STUB_DIRECT_LOG=path      append each call's arguments here
  STUB_DIRECT_FOREIGN=1     sector 0 holds other data: abort asking for --erase
                            unless --erase was given
  STUB_DIRECT_DIE=1         the link never gives consistent reads: abort
  STUB_DIRECT_NOWRITE=1     claim success without writing (a lying writer)

The image is written into the fake OpenOCD's flash (STUB_MEM_DIR/flash.bin),
so the wrapper's readback sees it.
"""
import os, sys

log = os.environ.get("STUB_DIRECT_LOG")
if log:
    with open(log, "a") as fh:
        fh.write("direct " + " ".join(sys.argv[1:]) + "\n")
erase = "--erase" in sys.argv[4:]
if erase:
    print("sector 0 erased", flush=True)
if os.environ.get("STUB_DIRECT_DIE") == "1":
    sys.exit("ABORT: cannot read ['0x8000000'] reliably - link too poor. Nothing rewritten.")
if os.environ.get("STUB_DIRECT_FOREIGN") == "1" and not erase:
    sys.exit("ABORT: words programmed with wrong data ['0x8000000'] - re-run with --erase")
data = open(sys.argv[2], "rb").read()
mem = os.environ.get("STUB_MEM_DIR")
if mem and os.environ.get("STUB_DIRECT_NOWRITE") != "1":
    path = os.path.join(mem, "flash.bin")
    off = int(sys.argv[3], 0) - 0x08000000
    os.makedirs(mem, exist_ok=True)
    flash = bytearray(open(path, "rb").read()) if os.path.exists(path) else bytearray()
    if len(flash) < off + len(data):
        flash += b"\xff" * (off + len(data) - len(flash))
    flash[off:off + len(data)] = data
    open(path, "wb").write(bytes(flash))
size = len(data)
print(f"{(size + 31) // 32} flash words to place (vector table last)", flush=True)
print("ROBUST_WRITE_DONE", flush=True)
