import os
import pty
import subprocess
from pathlib import Path

for answer, expected in [(b"1\n", "74.219.23.237@ens3"), (b"99\n2\n", "74.219.23.240@ens3")]:
    master, slave = pty.openpty()
    try:
        process = subprocess.Popen(
            [os.environ.get("BASH_BIN", "bash"), str(Path(__file__).with_name("ip-binding.sh")), "--menu"],
            stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        os.write(master, answer)
        try:
            output, _ = process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
            raise
        assert process.returncode == 0, output.decode()
        assert f"SELECTED={expected}" in output.decode(), output.decode()
    finally:
        os.close(master)
        os.close(slave)
print("PASS: public-IP picker with two addresses on one interface")
