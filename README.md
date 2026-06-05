# Champollion

Champollion is a decompiler for the Papyrus script language used in Skyrim, Fallout 4, Fallout 76, and Starfield. It produces a Papyrus Script file (`.psc`) from a compiled `.pex` binary. Decompiled scripts recompile to a functionally equivalent PEX binary.

This fork adds a **Qt6 GUI frontend** and integrates [Decompiled_PSC_Repair](https://www.nexusmods.com/starfield/mods/14894) by LBGSHI for post-processing Starfield scripts.

## Features

- Decompile `.pex` → `.psc` for Skyrim, Fallout 4, Fallout 76, and Starfield
- Optionally output human-readable assembly (`.pas`)
- Parallel decompilation for large batches
- Recursive directory scanning
- Qt6 GUI with drag-and-drop input, live log, and all CLI options exposed
- Integrated PSC Repair runner for Starfield (fixes guards, event sender types, fragment structure, and more so scripts compile in the Creation Kit)
- Inspect mode: view PEX header info and compile timestamps without decompiling

## Building

### Requirements

- CMake 3.15+
- C++20 compiler (GCC 12+, Clang 14+, MSVC 2022+)
- Boost (`program_options`)
- [{fmt}](https://github.com/fmtlib/fmt)
- **GUI only:** Qt6 (Widgets + Concurrent modules)

### CLI only

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc)
```

### CLI + GUI

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release -DCHAMPOLLION_BUILD_GUI=ON
cmake --build build -j$(nproc)
```

### With vcpkg (recommended on Windows)

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release -DCHAMPOLLION_BUILD_GUI=ON \
  -DCMAKE_TOOLCHAIN_FILE=$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake
cmake --build build -j$(nproc)
```

### Install

```bash
cmake --install build --prefix ./release
```

The install step copies the binary, `Decompiled_PSC_Repair.ps1`, and any required Qt runtime files to the prefix.

---

## CLI Usage

```
Champollion <files or directories> [options]
```

| Short | Long | Description |
|---|---|---|
| `-p <dir>` | `--psc <dir>` | Output directory for decompiled `.psc` files |
| `-a [<dir>]` | `--asm [<dir>]` | Write assembly `.pas` files to directory |
| `-c` | `--comment` | Annotate decompiled output with assembly instructions |
| `-e` | `--header` | Write header to decompiled `.psc` file |
| `-t` | `--threaded` | Parallel decompilation |
| `-r` | `--recursive` | Recursively scan directories for `.pex` files |
| `-s` | `--recreate-subdirs` | Recreate directory structure in output (Fallout 4 / Starfield) |
| `-g` | `--trace` | Trace decompilation and write rebuild logs |
|   | `--no-dump-tree` | Suppress node tree dump during tracing |
| `-d` | `--debug-funcs` | Decompile debug and compiler-generated functions |
|   | `--no-debug-line` | Omit debug line number comments |
| `-i` | `--print-info` | Print PEX header info and exit |
|   | `--print-compile-time` | Print compile timestamps and exit |
| `-v` | `--verbose` | Verbose output |
| `-V` | `--version` | Print version |
| `-h` | `--help` | Print help |

### Example

```bash
# Decompile all scripts in a directory, recursively, in parallel
Champollion ./pex -p ./psc -r -t -v

# Show info about a single file
Champollion MyScript.pex -i
```

---

## GUI Usage

Launch `ChampollionGUI`. Drag and drop `.pex` files or directories onto the input list, configure options, and click **Decompile**.

Additional GUI-only actions:
- **Show PEX Info** — equivalent to `--print-info`
- **Show Compile Times** — equivalent to `--print-compile-time`

### PSC Repair (Starfield)

After decompiling Starfield scripts, use the **PSC Repair** panel to run [Decompiled_PSC_Repair](https://www.nexusmods.com/starfield/mods/14894) by LBGSHI. This fixes guard blocks, event sender types, fragment structure, whitespace, and other issues so scripts compile cleanly in the Creation Kit.

Requires PowerShell 5.1 (Windows) or `pwsh` / PowerShell Core 7+ (Linux/macOS).

---

## Credits

- Original Champollion by [Orvid](https://github.com/Orvid/Champollion)
- [Decompiled_PSC_Repair](https://www.nexusmods.com/starfield/mods/14894) by LBGSHI

## License

LGPL v3 — see [LICENSE](LICENSE).
