"""Adapta comandos de build C/C++ convencionais ao driver do Zig.

O CMake usa ``-Wl,-v`` apenas para identificar o linker, mas o driver do Zig
0.13 não reconhece essa forma. O adaptador remove somente essa sondagem e
preserva todas as demais opções do build.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import re
import tempfile
from pathlib import Path


def main() -> int:
    if len(sys.argv) < 2:
        print("uso: zig-toolchain.py <cc|c++|ar> [argumentos...]", file=sys.stderr)
        return 2

    zig = shutil.which("zig")
    if zig is None:
        print("zig não encontrado no PATH", file=sys.stderr)
        return 127

    mode = sys.argv[1]
    arguments = [
        argument
        for argument in sys.argv[2:]
        if argument not in ("-Wl,-v", "-lpthread")
    ]
    if "-E" in arguments:
        # Clang treats `-o -` as stdout while Zig 0.13 creates a literal file
        # named "-". Omitting the pair preserves the intended preprocess output.
        arguments = [
            argument
            for index, argument in enumerate(arguments)
            if not (
                (argument == "-o" and index + 1 < len(arguments) and arguments[index + 1] == "-")
                or (argument == "-" and index > 0 and arguments[index - 1] == "-o")
            )
        ]

    # Alguns projetos compilam deliberadamente arquivos .c pelo compilador
    # C++. O Zig infere C pela extensão, então explicitamos a linguagem apenas
    # nesse caso e somente durante a compilação.
    if (
        mode == "c++"
        and "-c" in arguments
        and any(argument.lower().endswith(".c") for argument in arguments)
    ):
        arguments = ["-x", "c++", *arguments]

    temporary_responses: list[Path] = []
    filtered_arguments: list[str] = []
    try:
        for argument in arguments:
            if not argument.startswith("@"):
                filtered_arguments.append(argument)
                continue

            response_path = Path(argument[1:])
            response = response_path.read_text(encoding="utf-8")
            filtered = re.sub(r"(?<!\S)-lpthread(?!\S)", "", response)
            if filtered == response:
                filtered_arguments.append(argument)
                continue

            with tempfile.NamedTemporaryFile(
                mode="w",
                suffix=".rsp",
                delete=False,
                encoding="utf-8",
            ) as temporary:
                temporary.write(filtered)
                temporary_path = Path(temporary.name)
            temporary_responses.append(temporary_path)
            filtered_arguments.append(f"@{temporary_path}")

        return subprocess.run(
            [zig, mode, *filtered_arguments],
            check=False,
        ).returncode
    finally:
        for temporary_path in temporary_responses:
            temporary_path.unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
