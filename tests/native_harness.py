#!/usr/bin/env python3
"""Deterministic regressions for native verification startup and shutdown."""
import errno
import os
from pathlib import Path
import socket
import struct
import sys
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

import application_services as services
import secure_entry
from session_native import Peer


class NativeHarness(unittest.TestCase):
    def test_peer_drains_requests_after_client_close(self):
        # Queue all requests and close BEFORE the peer accepts. Its first
        # delete_id reply must hit EPIPE, regardless of thread scheduling.
        for unlock in (False, True):
            with self.subTest(unlock=unlock), tempfile.TemporaryDirectory() as directory:
                peer = Peer(Path(directory))
                fd = os.memfd_create('peer-shutdown')
                peer.objects[2] = ('wl_shm_pool', {'fd': fd})
                peer.objects[3] = ('ext_session_lock_v1', {'acknowledged': True})
                with socket.socket(socket.AF_UNIX) as client:
                    client.connect(peer.path)
                    # wl_shm_pool.destroy (1), then ext_session_lock_v1.unlock_and_destroy (2).
                    client.sendall(struct.pack('<II', 2, (8 << 16) | 1) +
                                   (struct.pack('<II', 3, (8 << 16) | 2) if unlock else b''))
                peer.run()
                self.assertIsNone(peer.failure)
                self.assertNotIn(2, peer.objects)
                self.assertEqual(peer.unlocks, int(unlock))
                with self.assertRaises(OSError) as closed:
                    os.fstat(fd)
                self.assertEqual(closed.exception.errno, errno.EBADF)

    def test_peer_still_rejects_invalid_unlock_after_client_close(self):
        with tempfile.TemporaryDirectory() as directory:
            peer = Peer(Path(directory))
            peer.objects[2] = ('wl_shm_pool', {'fd': os.memfd_create('peer-invalid')})
            peer.objects[3] = ('ext_session_lock_v1', {'acknowledged': False})
            with socket.socket(socket.AF_UNIX) as client:
                client.connect(peer.path)
                client.sendall(struct.pack('<IIII', 2, (8 << 16) | 1, 3, (8 << 16) | 2))
            peer.run()
            self.assertIsInstance(peer.failure, AssertionError)
            self.assertEqual(str(peer.failure), 'unlock before locked acknowledgement')
            self.assertEqual(peer.unlocks, 0)

    def test_secure_entry_waits_for_peer(self):
        # Hold unlock consumption until verify joins the peer. Checking the
        # counter immediately after process exit must fail, without any sleeps.
        joining = threading.Event()
        request = secure_entry.SecurePeer.request
        join = threading.Thread.join

        def held_request(peer, obj, opcode, body):
            if peer.objects[obj][0] == 'ext_session_lock_v1' and opcode == 2:
                self.assertTrue(joining.wait(5), 'verification never joined the peer')
            return request(peer, obj, opcode, body)

        def release_and_join(thread, *args, **kwargs):
            joining.set()
            return join(thread, *args, **kwargs)

        with patch.object(secure_entry.SecurePeer, 'request', held_request), \
             patch.object(threading.Thread, 'join', release_and_join):
            secure_entry.verify()

    def test_endpoint_is_not_window_readiness(self):
        with tempfile.TemporaryDirectory() as directory, socket.socket(socket.AF_UNIX) as endpoint:
            root = Path(directory)
            path = root / 'ourokit/dev/test'
            path.parent.mkdir(parents=True)
            endpoint.bind(str(path))
            process = Mock()
            process.poll.return_value = None
            replies = [{'structuredContent': {'windows': windows}} for windows in (
                [],
                [{'window': 'main', 'ready': True}, {'window': 'peer', 'ready': False}],
                [{'window': 'main', 'ready': True}, {'window': 'peer', 'ready': True}],
            )]
            with patch.object(services, 'call', side_effect=[ConnectionRefusedError(), *replies]) as call:
                self.assertEqual(services.development_path(root, process, windows=('main', 'peer')), path)
                self.assertEqual(call.call_count, 4)
                call.assert_called_with(path, 'runtime.inspect')
            # Startup readiness must not turn arbitrary RPC failures into retries.
            with patch.object(services, 'call', return_value={'rpcError': {'code': -32603}}) as call:
                with self.assertRaisesRegex(AssertionError, 'rpcError'):
                    services.development_path(root, process, windows=('main',))
                call.assert_called_once()


if __name__ == '__main__':
    # The build supplies the binary argument used by the native test modules.
    unittest.main(argv=[sys.argv[0]])
