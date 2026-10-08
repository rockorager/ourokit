"""A Wayland proxy that adds a fake ext-workspace-v1 manager to a compositor.

The test Sway (1.7) does not implement ext-workspace-v1. This proxy sits
between one client and Sway, forwards every message unchanged (with its file
descriptors), advertises one extra `ext_workspace_manager_v1` global, and
serves that manager itself: a group with a few workspaces whose state the test
changes through `rename`, and whose `activate` requests are applied on commit.

Only message boundaries are parsed, plus the few requests it intercepts:
wl_display.get_registry, wl_registry.bind of the fake global, and requests on
the fake objects. Nothing that carries file descriptors is intercepted.
"""
import array
import os
import selectors
import socket
import struct
import threading

FAKE_GLOBAL = 0x7FFF0001
INTERFACE = b"ext_workspace_manager_v1"
# Server-side ids, far above anything Sway allocates in a test.
FIRST_SERVER_ID = 0xFFFFF000
STATE_ACTIVE = 1
CAN_ACTIVATE = 1


def _string(value):
    data = value + b"\0"
    return struct.pack("<I", len(data)) + data + b"\0" * (-len(data) % 4)


def _array(data):
    return struct.pack("<I", len(data)) + data + b"\0" * (-len(data) % 4)


def _message(object_id, opcode, payload=b""):
    return struct.pack("<II", object_id, ((8 + len(payload)) << 16) | opcode) + payload


def _messages(buffer):
    """Yields complete (object, opcode, whole message) and the remainder."""
    offset, out = 0, []
    while len(buffer) - offset >= 8:
        object_id, word = struct.unpack_from("<II", buffer, offset)
        size = word >> 16
        if size < 8 or len(buffer) - offset < size:
            break
        out.append((object_id, word & 0xFFFF, bytes(buffer[offset:offset + size])))
        offset += size
    return out, buffer[offset:]


class WorkspaceProxy:
    def __init__(self, upstream, path, names=("One", "Two", "Three")):
        self.upstream, self.path = upstream, path
        self.workspaces = [{"name": name, "active": index == 0} for index, name in enumerate(names)]
        self.binds = 0          # Clients that bound the fake manager.
        self.activations = []   # Workspace names activated by commits.
        self.lock = threading.Lock()
        self.connections = []
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(path)
        self.listener.listen(4)
        self.stopping = False
        self.thread = threading.Thread(target=self._accept, daemon=True)
        self.thread.start()

    def close(self):
        self.stopping = True
        self.listener.close()
        for connection in list(self.connections):
            connection.close()
        if os.path.exists(self.path):
            os.unlink(self.path)

    def rename(self, index, name):
        """Changes a workspace name and publishes it at a done boundary."""
        with self.lock:
            self.workspaces[index]["name"] = name
            for connection in self.connections:
                connection.publish([index])

    def _accept(self):
        while not self.stopping:
            try:
                client, _ = self.listener.accept()
            except OSError:
                return
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.connect(self.upstream)
            connection = _Connection(self, client, server)
            self.connections.append(connection)
            threading.Thread(target=connection.run, daemon=True).start()


class _Connection:
    def __init__(self, proxy, client, server):
        self.proxy, self.client, self.server = proxy, client, server
        self.registries = set()
        self.manager = None
        self.group = None
        self.handles = []       # Server id per workspace index.
        self.pending = []       # Workspace indexes with activate requested.
        self.closed = False

    def close(self):
        self.closed = True
        for sock in (self.client, self.server):
            try:
                sock.close()
            except OSError:
                pass

    def _send(self, sock, data, fds=()):
        ancillary = [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", fds))] if fds else []
        sock.sendmsg([data], ancillary)
        for fd in fds:
            os.close(fd)

    def _to_client(self, data):
        self._send(self.client, data)

    def publish(self, indexes):
        """Sends the given workspaces' state followed by done (locked by caller)."""
        if self.manager is None:
            return
        out = b""
        for index in indexes:
            workspace, handle = self.proxy.workspaces[index], self.handles[index]
            out += _message(handle, 1, _string(workspace["name"].encode()))
            out += _message(handle, 3, struct.pack("<I", STATE_ACTIVE if workspace["active"] else 0))
        out += _message(self.manager, 2)
        self._to_client(out)

    def _bound(self, manager):
        self.manager = manager
        self.proxy.binds += 1
        next_id = FIRST_SERVER_ID
        self.group = next_id
        out = _message(manager, 0, struct.pack("<I", self.group))
        for index, workspace in enumerate(self.proxy.workspaces):
            next_id += 1
            self.handles.append(next_id)
            out += _message(manager, 1, struct.pack("<I", next_id))
            out += _message(next_id, 0, _string(f"workspace-{index + 1}".encode()))
            out += _message(next_id, 2, _array(struct.pack("<I", index)))
            out += _message(next_id, 4, struct.pack("<I", CAN_ACTIVATE))
            out += _message(self.group, 3, struct.pack("<I", next_id))
        self._to_client(out)
        self.publish(range(len(self.proxy.workspaces)))

    def _intercept(self, object_id, opcode, message):
        """Handles a client request; returns True when it must not be forwarded."""
        if object_id == 1 and opcode == 1:  # wl_display.get_registry(new_id)
            registry = struct.unpack_from("<I", message, 8)[0]
            self.registries.add(registry)
            # The client created the registry; advertise the fake global on it.
            # The request itself is forwarded in stream order.
            with self.proxy.lock:
                self._to_client(_message(registry, 0, struct.pack("<I", FAKE_GLOBAL) + _string(INTERFACE) + struct.pack("<I", 1)))
            return False
        if object_id in self.registries and opcode == 0:  # wl_registry.bind
            name = struct.unpack_from("<I", message, 8)[0]
            if name != FAKE_GLOBAL:
                return False
            length = struct.unpack_from("<I", message, 12)[0]
            offset = 16 + length + (-length % 4)
            _version, new_id = struct.unpack_from("<II", message, offset)
            with self.proxy.lock:
                self._bound(new_id)
            return True
        if object_id == self.manager:
            if opcode == 0:  # commit
                with self.proxy.lock:
                    for index in self.pending:
                        for other, workspace in enumerate(self.proxy.workspaces):
                            workspace["active"] = other == index
                        self.proxy.activations.append(self.proxy.workspaces[index]["name"])
                    if self.pending:
                        self.pending = []
                        self.publish(range(len(self.proxy.workspaces)))
            return True
        if object_id == self.group:
            return True
        if object_id in self.handles:
            if opcode == 1:  # activate
                self.pending.append(self.handles.index(object_id))
            return True
        return False

    def run(self):
        selector = selectors.DefaultSelector()
        selector.register(self.client, selectors.EVENT_READ, "client")
        selector.register(self.server, selectors.EVENT_READ, "server")
        buffers = {"client": b"", "server": b""}
        fds = {"client": [], "server": []}
        try:
            while not self.closed:
                for key, _ in selector.select():
                    side = key.data
                    data, ancillary, _, _ = key.fileobj.recvmsg(65536, socket.CMSG_SPACE(28 * 4))
                    if not data:
                        return
                    for level, kind, payload in ancillary:
                        if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                            received = array.array("i")
                            received.frombytes(payload[:len(payload) - len(payload) % 4])
                            fds[side].extend(received)
                    messages, buffers[side] = _messages(buffers[side] + data)
                    forward = b""
                    with self.proxy.lock if side == "server" else _NoLock():
                        for object_id, opcode, message in messages:
                            if side == "client" and self._intercept(object_id, opcode, message):
                                continue
                            forward += message
                        if forward:
                            # File descriptors stay in stream order; libwayland
                            # queues them until a message consumes them.
                            target = self.server if side == "client" else self.client
                            self._send(target, forward, fds[side])
                            fds[side] = []
        except OSError:
            pass
        finally:
            selector.close()
            self.close()


class _NoLock:
    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False
