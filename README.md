# Elevator Chime

> Keeping it vertical,<br>
> forever elevator.<br>
> Riding the escalator<br>
> to the something that is greater.<br>

<div style="text-align: right;">-- Nujabes & Cyne - Feather</div><br>

Elevator Chime is a Zig reimplementation of [Chime](https://github.com/Dr-Nekoma/chime).

`zig build test` executes the triangle numbers and short multiplication example programs.

`zig build chaff` reads a chaff assembly file from stdin, compiles it and writes the result to stdout.

`zig build run -- <compiled-file>` loads and executes a compiled program.

A plain `zig build` produces two executables: `elevator-chime`, which is the program called by `zig build run`, and `chaff`, which is called by `zig build chaff`.

See `build.zig.zon` for compiler version.
