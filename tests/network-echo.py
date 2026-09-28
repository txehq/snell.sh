"""Plain socket probes for the isolated Linux source-IP regression test."""
import socket
import sys
import threading

mode, address, port = sys.argv[1:4]
port = int(port)


def echo_tcp():
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((address, port))
    listener.listen()
    while True:
        connection, peer = listener.accept()
        connection.sendall(peer[0].encode())
        connection.close()


def echo_udp():
    listener = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    listener.bind((address, port))
    while True:
        _, peer = listener.recvfrom(100)
        listener.sendto(peer[0].encode(), peer)


if mode == "server":
    threading.Thread(target=echo_tcp, daemon=True).start()
    echo_udp()
else:
    protocol, expected = sys.argv[4:6]
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM if protocol == "udp" else socket.SOCK_STREAM)
    sock.settimeout(5)
    if mode == "bound-client":
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, b"ens3\0")
    sock.connect((address, port))
    if protocol == "udp":
        sock.send(b"test")
    actual = sock.recv(100).decode()
    assert actual == expected, (actual, expected)
    print(f"PASS: {mode} {protocol} source {actual}")
