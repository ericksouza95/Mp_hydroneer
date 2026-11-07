"""mpnet_harness.py: teste automatico do modo UDP da mpnet.dll, sem o jogo e sem Steam.

Cada participante e um processo Python separado ("agente") que:
  1. copia a DLL para uma pasta temporaria propria (a DLL le mpnet.token da pasta dela);
  2. escreve mpnet.token (linha 1 token, linha 2 modo) e carrega a DLL com ctypes;
  3. abre os pipes e roda o mesmo laco do Lua: comandos + POLL a cada ~16 ms.
O orquestrador conversa com os agentes por JSON em stdin/stdout e confere os eventos.

Uso:
  python tools/mpnet_harness.py                 # teste completo, codigo de saida 0 se tudo passar
  python tools/mpnet_harness.py --dll caminho   # outra DLL (padrao: native/mpnet/build/mpnet.dll)
  python tools/mpnet_harness.py --keep          # nao apaga as pastas temporarias (logs da DLL)
"""

import argparse
import ctypes
import hashlib
import json
import os
import random
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DLL = os.path.join(ROOT, "native", "mpnet", "build", "mpnet.dll")

OP_POLL, OP_HOST, OP_JOIN, OP_LEAVE, OP_INVITE, OP_SEND, OP_SET_LOBBY_DATA, OP_CLOSE_PEER = 1, 2, 3, 4, 5, 6, 7, 8
OP_SET_TITLE, OP_PEER_STATE = 9, 10
EV_NAMES = {1: "HELLO", 2: "ERROR", 3: "LOBBY_CREATED", 4: "LOBBY_ENTERED", 5: "MEMBER_JOINED",
            6: "MEMBER_LEFT", 7: "PACKET", 8: "JOIN_REQUESTED", 9: "SESSION_FAIL", 10: "SESSION_REQUEST",
            11: "PEER_STATE"}

ID_PREFIX = 0x7F00000000000000
FAKE_LOBBY = 0x7E00000000000001


def payload(tag, idx, size):
    """Carga deterministica: u32 tag, u32 indice, depois bytes pseudoaleatorios."""
    head = struct.pack("<II", tag, idx)
    return head + random.Random(tag * 1000003 + idx).randbytes(max(0, size - 8))


def sha(b):
    return hashlib.sha1(b).hexdigest()


# ====================================================================== agente

def decode_event(e):
    t = e[0]
    ev = {"t": EV_NAMES.get(t, str(t))}
    p = 1
    if t == 1:
        ev["version"], ev["self"], ev["app"], n = struct.unpack_from("<IQII", e, p)
        ev["name"] = e[p + 20:p + 20 + n].decode("utf-8", "replace")
    elif t == 2:
        (n,) = struct.unpack_from("<I", e, p)
        ev["message"] = e[p + 4:p + 4 + n].decode("utf-8", "replace")
    elif t == 3:
        ev["result"], ev["lobby"] = struct.unpack_from("<iQ", e, p)
    elif t == 4:
        ev["lobby"], ev["response"], ev["owner"] = struct.unpack_from("<QIQ", e, p)
    elif t == 5:
        ev["peer"], n = struct.unpack_from("<QI", e, p)
        ev["name"] = e[p + 12:p + 12 + n].decode("utf-8", "replace")
    elif t in (6, 10):
        (ev["peer"],) = struct.unpack_from("<Q", e, p)
    elif t == 7:
        ev["peer"], ev["ch"] = struct.unpack_from("<QB", e, p)
        data = e[p + 9:]
        ev["len"] = len(data)
        ev["sha"] = sha(data)
        if len(data) >= 8:
            ev["tag"], ev["idx"] = struct.unpack_from("<II", data, 0)
    elif t == 8:
        ev["lobby"], ev["friend"] = struct.unpack_from("<QQ", e, p)
    elif t == 9:
        ev["peer"], ev["error"] = struct.unpack_from("<QB", e, p)
    elif t == 11:
        (ev["peer"], ev["active"], ev["connecting"], ev["error"], ev["relay"],
         ev["bytes_queued"], ev["packets_queued"]) = struct.unpack_from("<QBBBBII", e, p)
    return ev


def agent_main(args):
    out = sys.stdout
    tmp = tempfile.mkdtemp(prefix="mpnet_h_")
    dll = os.path.join(tmp, "mpnet.dll")
    shutil.copy(args.dll, dll)
    token = "h%d%06d" % (os.getpid(), random.randint(0, 999999))
    with open(os.path.join(tmp, "mpnet.token"), "w", newline="") as f:
        f.write(token + ("\r\n" + args.mode + "\r\n" if args.mode else ""))
    ctypes.WinDLL(dll)  # DllMain inicia a thread da DLL

    base = r"\\.\pipe\mpnet_" + token
    deadline = time.monotonic() + 15
    c2s = s2c = None
    while time.monotonic() < deadline:
        try:
            if c2s is None:
                c2s = open(base + "_c2s", "wb", buffering=0)
            s2c = open(base + "_s2c", "rb", buffering=0)
            break
        except OSError:
            time.sleep(0.02)
    if s2c is None:
        out.write(json.dumps({"ready": False, "tmp": tmp}) + "\n")
        out.flush()
        return 1

    lock = threading.Lock()
    pending = []
    events = []
    state = {"error": None, "polls": 0}

    def frame(b):
        return struct.pack("<I", len(b)) + b

    def write_all(b):
        mv = memoryview(b)
        while mv:
            n = c2s.write(mv)
            mv = mv[n:]

    def read_exact(n):
        buf = bytearray()
        while len(buf) < n:
            chunk = s2c.read(n - len(buf))
            if not chunk:
                raise EOFError("pipe fechado")
            buf += chunk
        return bytes(buf)

    def ticker():
        try:
            while True:
                with lock:
                    cmds = pending[:]
                    pending.clear()
                write_all(b"".join(frame(c) for c in cmds) + frame(bytes([OP_POLL])))
                (total,) = struct.unpack("<I", read_exact(4))
                body = read_exact(total)
                p = 8
                got = []
                while p < len(body):
                    (n,) = struct.unpack_from("<I", body, p)
                    got.append(decode_event(body[p + 4:p + 4 + n]))
                    p += 4 + n
                with lock:
                    events.extend(got)
                    state["polls"] += 1
                time.sleep(1 / 60)
        except Exception as ex:  # noqa: BLE001
            state["error"] = repr(ex)

    threading.Thread(target=ticker, daemon=True).start()
    out.write(json.dumps({"ready": True, "tmp": tmp, "pid": os.getpid()}) + "\n")
    out.flush()

    def queue(*cmds):
        with lock:
            pending.extend(cmds)

    for line in sys.stdin:
        req = json.loads(line)
        op = req["op"]
        res = {"ok": True}
        if op == "events":
            with lock:
                res["events"] = events[req.get("since", 0):]
                res["error"] = state["error"]
                res["polls"] = state["polls"]
        elif op == "host":
            queue(struct.pack("<BB", OP_HOST, req.get("max", 4)))
        elif op == "join":
            queue(struct.pack("<BQ", OP_JOIN, req.get("lobby", 0)))
        elif op == "leave":
            queue(bytes([OP_LEAVE]))
        elif op == "invite":
            queue(bytes([OP_INVITE]))
        elif op == "set_lobby_data":
            queue(bytes([OP_SET_LOBBY_DATA]) + b"k\0v")
        elif op == "close_peer":
            queue(struct.pack("<BQ", OP_CLOSE_PEER, req["peer"]))
        elif op == "peer_state":
            queue(bytes([OP_PEER_STATE]))
        elif op == "set_title":
            queue(bytes([OP_SET_TITLE]) + req["text"].encode("utf-8"))
        elif op == "send":
            cmds = []
            for i in range(req["count"]):
                data = payload(req["tag"], i, req["size"])
                cmds.append(struct.pack("<BQBB", OP_SEND, req["to"], req["type"], req["ch"]) + data)
            queue(*cmds)
        elif op == "quit":
            os._exit(0)
        else:
            res = {"ok": False, "error": "op desconhecida " + op}
        out.write(json.dumps(res) + "\n")
        out.flush()
    return 0


# ====================================================================== orquestrador

class Agent:
    def __init__(self, name, dll, mode, loss=0):
        self.name = name
        env = dict(os.environ)
        env.pop("MPNET_UDP_LOSS", None)
        if loss:
            env["MPNET_UDP_LOSS"] = str(loss)  # a DLL descarta essa % dos envios
        self.proc = subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "agent", "--dll", dll, "--mode", mode],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1, env=env)
        self.ev = []
        self.tmp = None
        self.self_id = None
        self.dead = False

    def handshake(self):
        hello = json.loads(self.proc.stdout.readline() or "{}")
        self.tmp = hello.get("tmp")
        if not hello.get("ready"):
            raise RuntimeError("agente %s nao conectou aos pipes (pasta %s)" % (self.name, self.tmp))

    def rpc(self, **req):
        self.proc.stdin.write(json.dumps(req) + "\n")
        self.proc.stdin.flush()
        return json.loads(self.proc.stdout.readline())

    def refresh(self):
        if self.dead:
            return
        r = self.rpc(op="events", since=len(self.ev))
        if r.get("error"):
            raise RuntimeError("agente %s: %s" % (self.name, r["error"]))
        self.ev.extend(r["events"])

    def wait(self, cond, timeout):
        """Espera cond(lista_de_eventos) ficar verdadeira. Devolve (ok, segundos)."""
        t0 = time.monotonic()
        while True:
            self.refresh()
            if cond(self.ev):
                return True, time.monotonic() - t0
            if time.monotonic() - t0 > timeout:
                return False, time.monotonic() - t0
            time.sleep(0.05)

    def of(self, t, **kw):
        return [e for e in self.ev if e["t"] == t and all(e.get(k) == v for k, v in kw.items())]

    def kill(self):
        self.dead = True
        self.proc.kill()
        self.proc.wait()

    def close(self):
        if not self.dead:
            try:
                self.proc.stdin.write(json.dumps({"op": "quit"}) + "\n")
                self.proc.stdin.flush()
            except OSError:
                pass
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
            self.dead = True


def free_udp_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class Report:
    def __init__(self):
        self.rows = []

    def check(self, name, ok, detail=""):
        self.rows.append((name, bool(ok), detail))
        print("  [%s] %s %s" % ("PASS" if ok else "FAIL", name, detail), flush=True)
        return ok

    def table(self):
        w = max(len(r[0]) for r in self.rows)
        print()
        print("%-*s  %-6s  %s" % (w, "Verificacao", "Status", "Detalhe"))
        print("-" * (w + 2) + "  " + "-" * 6 + "  " + "-" * 40)
        for name, ok, detail in self.rows:
            print("%-*s  %-6s  %s" % (w, name, "PASS" if ok else "FAIL", detail))
        npass = sum(1 for r in self.rows if r[1])
        print("\n%d/%d verificacoes passaram" % (npass, len(self.rows)))
        return npass == len(self.rows)


def packets(agent, tag, peer=None):
    return [e for e in agent.of("PACKET") if e.get("tag") == tag and (peer is None or e["peer"] == peer)]


def check_stream(rep, name, agent, tag, sender, ch, count, size, timeout, ordered=True, min_count=None):
    need = count if min_count is None else min_count
    ok, dt = agent.wait(lambda ev: len(packets(agent, tag)) >= count, timeout)
    if not ok and min_count is not None:  # nao confiavel: aceita perda pequena
        ok, _ = agent.wait(lambda ev: len(packets(agent, tag)) >= need, 0.5)
    got = packets(agent, tag)
    bad_from = [e for e in got if e["peer"] != sender or e["ch"] != ch]
    bad_sha = [e for e in got if e["sha"] != sha(payload(tag, e["idx"], size)) or e["len"] != size]
    idxs = [e["idx"] for e in got]
    in_order = idxs == list(range(count)) if ordered else len(set(idxs)) == len(idxs)
    passed = len(got) >= need and not bad_from and not bad_sha and in_order
    detail = "%d/%d recebidos em %.2fs, remetente errado %d, conteudo errado %d, %s" % (
        len(got), count, dt, len(bad_from), len(bad_sha), "em ordem" if in_order else "FORA DE ORDEM/duplicado")
    return rep.check(name, passed, detail)


def seq_left(agent, start):
    return [e["peer"] for e in agent.ev[start:] if e["t"] == "MEMBER_LEFT"]


def run(args):
    dll = os.path.abspath(args.dll)
    if not os.path.exists(dll):
        print("DLL nao encontrada: " + dll)
        return 2
    rep = Report()
    port = free_udp_port()
    host_id = ID_PREFIX | port
    print("DLL %s, host na porta %d" % (dll, port), flush=True)
    agents = []

    def spawn(name, mode, loss=0):
        a = Agent(name, dll, mode, loss)
        agents.append(a)
        return a

    try:
        S = spawn("S", "")  # sem linha de modo: caminho Steam
        H = spawn("H", "udp host %d" % port)
        A = spawn("A", "udp client 127.0.0.1:%d" % port)
        B = spawn("B", "udp client 127.0.0.1:%d" % port)
        for a in (S, H, A, B):
            a.handshake()

        # ---- Steam sem steam_api64.dll: erro, sem travar
        ok, _ = S.wait(lambda ev: any(e["t"] == "ERROR" for e in ev), 5)
        msgs = [e["message"] for e in S.of("ERROR")]
        time.sleep(0.3)
        S.refresh()
        rep.check("Steam sem steam_api64: EV_ERROR, sem HELLO", ok and any("Steam" in m for m in msgs) and not S.of("HELLO"),
                  repr(msgs[:1]))

        # ---- HELLO
        hello_ok = True
        details = []
        for a in (H, A, B):
            ok, _ = a.wait(lambda ev: any(e["t"] == "HELLO" for e in ev), 5)
            h = a.of("HELLO")[0] if ok else {}
            a.self_id = h.get("self")
            good = (ok and h["version"] == 3 and h["app"] == 0 and (h["self"] >> 56) == 0x7F
                    and h["name"] == "udp-%d" % (h["self"] & 0xFFFF))
            hello_ok &= good
            details.append("%s=%s" % (a.name, h.get("name")))
        hello_ok &= H.self_id == host_id
        rep.check("HELLO v3, ids 0x7F..|porta, nome udp-<porta>", hello_ok, ", ".join(details))

        # ---- HOST
        H.rpc(op="host", max=4)
        ok, dt = H.wait(lambda ev: len(H.of("MEMBER_JOINED")) >= 1, 5)
        seq = [e["t"] for e in H.ev if e["t"] in ("LOBBY_CREATED", "LOBBY_ENTERED", "MEMBER_JOINED")]
        lc = H.of("LOBBY_CREATED")
        le = H.of("LOBBY_ENTERED")
        rep.check("HOST: LOBBY_CREATED, LOBBY_ENTERED, MEMBER_JOINED(self)",
                  ok and seq == ["LOBBY_CREATED", "LOBBY_ENTERED", "MEMBER_JOINED"]
                  and lc[0]["result"] == 1 and lc[0]["lobby"] == FAKE_LOBBY
                  and le[0]["lobby"] == FAKE_LOBBY and le[0]["response"] == 1 and le[0]["owner"] == host_id
                  and H.of("MEMBER_JOINED")[0]["peer"] == host_id, "%s" % seq)

        # ---- JOIN A, depois B
        def joined_ok(agent, expect):
            ok, dt = agent.wait(lambda ev: len(agent.of("MEMBER_JOINED")) >= len(expect), 5)
            ent = agent.of("LOBBY_ENTERED")
            mj = [e["peer"] for e in agent.of("MEMBER_JOINED")]
            good = ok and ent and ent[0]["response"] == 1 and ent[0]["owner"] == host_id and ent[0]["lobby"] == FAKE_LOBBY \
                and mj == expect
            return good, dt, mj

        A.rpc(op="join", lobby=FAKE_LOBBY)
        good, dt, mj = joined_ok(A, [host_id, A.self_id])
        okh, _ = H.wait(lambda ev: [e["peer"] for e in H.of("MEMBER_JOINED")] == [host_id, A.self_id], 3)
        rep.check("JOIN A: LOBBY_ENTERED + roster no cliente e no host", good and okh, "em %.2fs, A viu %d membros" % (dt, len(mj)))

        B.rpc(op="join", lobby=0)
        good, dt, mj = joined_ok(B, [host_id, A.self_id, B.self_id])
        okh, _ = H.wait(lambda ev: [e["peer"] for e in H.of("MEMBER_JOINED")] == [host_id, A.self_id, B.self_id], 3)
        oka, _ = A.wait(lambda ev: [e["peer"] for e in A.of("MEMBER_JOINED")] == [host_id, A.self_id, B.self_id], 3)
        rep.check("JOIN B: roster completo em B, MEMBER_JOINED(B) em H e A", good and okh and oka, "em %.2fs" % dt)

        # ---- nao confiavel host <-> cliente (1200 bytes)
        H.rpc(op="send", to=A.self_id, type=0, ch=0, count=50, size=1200, tag=1)
        A.rpc(op="send", to=host_id, type=1, ch=1, count=50, size=1200, tag=2)
        check_stream(rep, "Nao confiavel H->A, 50 x 1200 B", A, 1, host_id, 0, 50, 1200, 5, ordered=False, min_count=45)
        check_stream(rep, "Nao confiavel A->H, 50 x 1200 B", H, 2, A.self_id, 1, 50, 1200, 5, ordered=False, min_count=45)
        H.rpc(op="send", to=A.self_id, type=0, ch=0, count=1, size=1201, tag=3)  # deve ser recusado

        # ---- confiavel: 200 KB e 500 pequenas, nos dois sentidos, mais 1 MB de B
        H.rpc(op="send", to=A.self_id, type=2, ch=1, count=1, size=200_000, tag=10)
        A.rpc(op="send", to=host_id, type=3, ch=2, count=1, size=200_000, tag=11)
        H.rpc(op="send", to=A.self_id, type=2, ch=2, count=500, size=64, tag=12)
        A.rpc(op="send", to=host_id, type=2, ch=3, count=500, size=64, tag=13)
        B.rpc(op="send", to=host_id, type=2, ch=0, count=1, size=1 << 20, tag=14)
        check_stream(rep, "Confiavel H->A, 200 KB", A, 10, host_id, 1, 1, 200_000, 15)
        check_stream(rep, "Confiavel A->H, 200 KB", H, 11, A.self_id, 2, 1, 200_000, 15)
        check_stream(rep, "Confiavel H->A, 500 mensagens em ordem", A, 12, host_id, 2, 500, 64, 15)
        check_stream(rep, "Confiavel A->H, 500 mensagens em ordem", H, 13, A.self_id, 3, 500, 64, 15)
        check_stream(rep, "Confiavel B->H, 1 MB", H, 14, B.self_id, 0, 1, 1 << 20, 20)
        A.refresh()
        rep.check("Nao confiavel acima de 1200 B e recusado", not packets(A, 3), "%d recebidos" % len(packets(A, 3)))

        # ---- cliente -> cliente pelo host
        A.rpc(op="send", to=B.self_id, type=2, ch=3, count=300, size=100, tag=20)
        A.rpc(op="send", to=B.self_id, type=2, ch=3, count=1, size=100_000, tag=21)
        A.rpc(op="send", to=B.self_id, type=0, ch=1, count=20, size=500, tag=22)
        B.rpc(op="send", to=A.self_id, type=3, ch=0, count=50, size=300, tag=23)
        check_stream(rep, "Relay confiavel A->B, 300 em ordem, from=A", B, 20, A.self_id, 3, 300, 100, 15)
        check_stream(rep, "Relay confiavel A->B, 100 KB, from=A", B, 21, A.self_id, 3, 1, 100_000, 15)
        check_stream(rep, "Relay nao confiavel A->B, from=A", B, 22, A.self_id, 1, 20, 500, 5, ordered=False, min_count=18)
        check_stream(rep, "Relay confiavel B->A, 50 em ordem, from=B", A, 23, B.self_id, 0, 50, 300, 15)
        H.refresh()
        rep.check("Host nao recebe o que e para outro cliente", not packets(H, 20) and not packets(H, 22), "")
        tag21 = packets(B, 21)
        if tag21:
            idx20 = [i for i, e in enumerate(B.ev) if e["t"] == "PACKET" and e.get("tag") == 20]
            idx21 = [i for i, e in enumerate(B.ev) if e["t"] == "PACKET" and e.get("tag") == 21]
            rep.check("Relay: ordem entre mensagens do mesmo canal", max(idx20) < min(idx21), "")

        # ---- PEER_STATE
        A.rpc(op="peer_state")
        H.rpc(op="peer_state")
        ok1, _ = A.wait(lambda ev: len(A.of("PEER_STATE")) >= 2, 3)
        ok2, _ = H.wait(lambda ev: len(H.of("PEER_STATE")) >= 2, 3)
        ps_a = {e["peer"]: e for e in A.of("PEER_STATE")}
        ps_h = {e["peer"]: e for e in H.of("PEER_STATE")}
        good = (ok1 and ok2 and set(ps_a) == {host_id, B.self_id} and set(ps_h) == {A.self_id, B.self_id}
                and ps_a[host_id]["relay"] == 0 and ps_a[B.self_id]["relay"] == 1
                and all(e["active"] == 1 and e["connecting"] == 0 and e["error"] == 0 for e in list(ps_a.values()) + list(ps_h.values()))
                and all(e["relay"] == 0 for e in ps_h.values()))
        rep.check("PEER_STATE: ativo, relay=1 so cliente->cliente", good,
                  "A: %s" % {hex(k): (v["relay"], v["packets_queued"]) for k, v in ps_a.items()})

        # ---- comandos sem efeito no UDP e SET_TITLE nao travam
        A.rpc(op="invite")
        A.rpc(op="set_lobby_data")
        A.rpc(op="set_title", text="harness")
        n0 = len(A.ev)
        time.sleep(0.3)
        A.refresh()
        rep.check("INVITE/SET_LOBBY_DATA/SET_TITLE sem erro", not [e for e in A.ev[n0:] if e["t"] == "ERROR"], "")

        # ---- 4o membro entra, 5o e recusado
        C = spawn("C", "udp client 127.0.0.1:%d" % port)
        D = spawn("D", "udp client 127.0.0.1:%d" % port)
        C.handshake()
        D.handshake()
        for a in (C, D):
            a.wait(lambda ev: any(e["t"] == "HELLO" for e in ev), 5)
            a.self_id = a.of("HELLO")[0]["self"]
        C.rpc(op="join", lobby=0)
        good, dt, mj = joined_ok(C, [host_id, A.self_id, B.self_id, C.self_id])
        rep.check("JOIN C: 4o membro aceito", good, "roster %d" % len(mj))
        D.rpc(op="join", lobby=0)
        ok, dt = D.wait(lambda ev: bool(D.of("LOBBY_ENTERED")), 5)
        ent = D.of("LOBBY_ENTERED")
        time.sleep(0.5)
        D.refresh()
        H.refresh()
        rep.check("JOIN D: 5o membro recusado (response 4)",
                  ok and ent[0]["response"] == 4 and not D.of("MEMBER_JOINED") and not H.of("MEMBER_JOINED", peer=D.self_id),
                  "response=%s em %.2fs" % (ent[0]["response"] if ent else None, dt))

        # ---- LEAVE de cliente
        marks = {a.name: len(a.ev) for a in (H, A, B, C)}
        C.rpc(op="leave")
        ok, _ = C.wait(lambda ev: len(seq_left(C, marks["C"])) >= 4, 3)
        left_c = seq_left(C, marks["C"])
        okh = all(x.wait(lambda ev, x=x: C.self_id in seq_left(x, marks[x.name]), 3)[0] for x in (H, A, B))
        rep.check("LEAVE C: MEMBER_LEFT de todos em C (ele por ultimo) e de C nos outros",
                  ok and okh and sorted(left_c[:3]) == sorted([host_id, A.self_id, B.self_id]) and left_c[3] == C.self_id, "")

        # ---- CLOSE_PEER: D entra (agora cabe) e o host o remove
        D.rpc(op="join", lobby=0)
        good, dt, _ = D.wait(lambda ev: len(D.of("MEMBER_JOINED")) >= 4, 5) + (None,)
        mD = len(D.ev)
        mA = len(A.ev)
        H.rpc(op="close_peer", peer=D.self_id)
        ok, _ = D.wait(lambda ev: len(seq_left(D, mD)) >= 4, 3)
        okA, _ = A.wait(lambda ev: D.self_id in seq_left(A, mA), 3)
        ld = seq_left(D, mD)
        rep.check("CLOSE_PEER: host remove D, D sai (ele por ultimo)", good and ok and okA and ld[-1] == D.self_id, "")

        # ---- queda por silencio: mata B
        mH, mA = len(H.ev), len(A.ev)
        t0 = time.monotonic()
        B.kill()
        okh, _ = H.wait(lambda ev: B.self_id in seq_left(H, mH), 9)
        th = time.monotonic() - t0
        oka, _ = A.wait(lambda ev: B.self_id in seq_left(A, mA), 3)
        rep.check("Timeout: B morto -> MEMBER_LEFT(B) no host e em A apos ~5 s", okh and oka and 4.0 <= th <= 8.0, "%.2fs" % th)

        # ---- LEAVE do host
        mH, mA = len(H.ev), len(A.ev)
        H.rpc(op="leave")
        okh, _ = H.wait(lambda ev: len(seq_left(H, mH)) >= 2, 3)
        oka, _ = A.wait(lambda ev: len(seq_left(A, mA)) >= 2, 3)
        lh, la = seq_left(H, mH), seq_left(A, mA)
        rep.check("LEAVE host: todos saem, cada um por ultimo",
                  okh and oka and lh == [A.self_id, host_id] and la == [host_id, A.self_id], "H=%d A=%d" % (len(lh), len(la)))

        # ---- cliente perde o host por silencio; JOIN sem host da erro em 10 s
        H.rpc(op="host", max=4)
        mA = len(A.ev)
        A.rpc(op="join", lobby=0)
        ok, _ = A.wait(lambda ev: len([e for e in A.ev[mA:] if e["t"] == "MEMBER_JOINED"]) >= 2, 5)
        rep.check("Rehost: A entra de novo na sala", ok, "")
        mA = len(A.ev)
        mD = len(D.ev)
        t0 = time.monotonic()
        H.kill()
        D.rpc(op="join", lobby=0)
        oka, _ = A.wait(lambda ev: len(seq_left(A, mA)) >= 2, 9)
        ta = time.monotonic() - t0
        la = seq_left(A, mA)
        rep.check("Timeout: host morto -> A sai (ele por ultimo)", oka and la == [host_id, A.self_id] and 4.0 <= ta <= 8.0,
                  "%.2fs" % ta)
        okd, _ = D.wait(lambda ev: any(e["t"] == "ERROR" for e in D.ev[mD:]), 13)
        td = time.monotonic() - t0
        rep.check("JOIN sem host: EV_ERROR apos 10 s", okd and 9.0 <= td <= 12.5, "%.2fs" % td)
        A.refresh()
        rep.check("Nenhum SESSION_FAIL/ERROR inesperado em A",
                  not A.of("SESSION_FAIL") and not A.of("ERROR"), "")

        # ---- retransmissao: nova sala com 20% de perda em todos os envios
        LOSS = 20
        port2 = free_udp_port()
        host2 = ID_PREFIX | port2
        H2 = spawn("H2", "udp host %d" % port2, LOSS)
        A2 = spawn("A2", "udp client 127.0.0.1:%d" % port2, LOSS)
        B2 = spawn("B2", "udp client 127.0.0.1:%d" % port2, LOSS)
        for a in (H2, A2, B2):
            a.handshake()
            a.wait(lambda ev, a=a: bool(a.of("HELLO")), 5)
            a.self_id = a.of("HELLO")[0]["self"]
        H2.rpc(op="host", max=4)
        H2.wait(lambda ev: bool(H2.of("MEMBER_JOINED")), 5)
        A2.rpc(op="join", lobby=0)
        A2.wait(lambda ev: len(A2.of("MEMBER_JOINED")) >= 2, 10)
        B2.rpc(op="join", lobby=0)
        ok, _ = B2.wait(lambda ev: len(B2.of("MEMBER_JOINED")) >= 3, 10)
        ok2, _ = A2.wait(lambda ev: len(A2.of("MEMBER_JOINED")) >= 3, 10)
        rep.check("Perda %d%%: entrada de A2 e B2 com HELLO repetido" % LOSS, ok and ok2, "")
        H2.rpc(op="send", to=A2.self_id, type=2, ch=1, count=1, size=200_000, tag=30)
        A2.rpc(op="send", to=host2, type=2, ch=2, count=500, size=64, tag=31)
        A2.rpc(op="send", to=B2.self_id, type=2, ch=3, count=200, size=700, tag=32)
        B2.rpc(op="send", to=A2.self_id, type=2, ch=0, count=1, size=300_000, tag=33)
        check_stream(rep, "Perda %d%%: confiavel H2->A2, 200 KB" % LOSS, A2, 30, host2, 1, 1, 200_000, 20)
        check_stream(rep, "Perda %d%%: confiavel A2->H2, 500 em ordem" % LOSS, H2, 31, A2.self_id, 2, 500, 64, 20)
        check_stream(rep, "Perda %d%%: relay A2->B2, 200 em ordem" % LOSS, B2, 32, A2.self_id, 3, 200, 700, 20)
        check_stream(rep, "Perda %d%%: relay B2->A2, 300 KB" % LOSS, A2, 33, B2.self_id, 0, 1, 300_000, 20)
        time.sleep(1.0)
        for a in (H2, A2, B2):
            a.refresh()
        dups = len(packets(A2, 30)) + len(packets(H2, 31)) + len(packets(B2, 32)) + len(packets(A2, 33)) - (1 + 500 + 200 + 1)
        lost_member = sum(len(a.of("MEMBER_LEFT")) + len(a.of("SESSION_FAIL")) for a in (H2, A2, B2))
        rep.check("Perda %d%%: sem duplicatas e sem queda de membro" % LOSS, dups == 0 and lost_member == 0,
                  "extras=%d, saidas/falhas=%d" % (dups, lost_member))
    except Exception as ex:  # noqa: BLE001
        import traceback
        traceback.print_exc()
        rep.check("Excecao no harness", False, repr(ex))
    finally:
        for a in agents:
            a.close()

    all_ok = rep.table()
    if not all_ok or args.keep:
        for a in agents:
            print("log %s: %s" % (a.name, os.path.join(a.tmp or "?", "mpnet.log")))
    else:
        time.sleep(0.3)
        for a in agents:
            if a.tmp:
                shutil.rmtree(a.tmp, ignore_errors=True)
    print("RESULTADO:", "PASS" if all_ok else "FAIL")
    return 0 if all_ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("role", nargs="?", default="test", choices=["test", "agent"])
    ap.add_argument("--dll", default=DEFAULT_DLL)
    ap.add_argument("--mode", default="")
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()
    if args.role == "agent":
        sys.exit(agent_main(args))
    sys.exit(run(args))


if __name__ == "__main__":
    main()
