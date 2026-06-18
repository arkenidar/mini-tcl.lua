# Canvas-only demo (no Tk): the LÖVE-style loop. canvas.loop stores this body and
# the host drives it per frame. Same script runs on desktop and (later) web.
#   ./mini-tcl-sdl examples/canvas-demo.tcl
canvas.loop {
    canvas.color 20 20 30
    canvas.clear
    set t [expr {[canvas.ticks] / 400.0}]
    canvas.color 80 160 255
    canvas.fill [expr {320 + 200 * cos($t)}] [expr {240 + 160 * sin($t)}] 16 16
    canvas.color 240 240 240
    canvas.text 12 12 "canvas.loop — bouncing square"
    canvas.present
}
