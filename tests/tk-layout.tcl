# Headless Tk-essence scenario. Run via tests/tk-headless.lua under a mock
# backend (fixed 400x300 window, scripted events). Exercises widget creation,
# pack + grid geometry, per-widget commands, bindings, focus/typing, scale drag,
# and -command dispatch. Output is a stable transcript diffed by run-tests.sh.

wm title . "Demo"

# --- pack: a vertical counter stack ----------------------------------------
label  .title -text "Counter"
button .inc   -text "+" -command {incr count}
label  .show  -textvariable count
set count 0
pack .title -side top
pack .inc   -side top -pady 4
pack .show  -side top
update

puts "title : [winfo x .title] [winfo y .title] [winfo width .title] [winfo height .title]"
puts "inc   : [winfo x .inc] [winfo y .inc] [winfo width .inc] [winfo height .inc]"
puts "show  : [winfo x .show] [winfo y .show]"
puts "count=$count"

# click the button twice (down+up over it each time)
set cx [expr {[winfo x .inc] + 5}]
set cy [expr {[winfo y .inc] + 5}]
event mouse down $cx $cy
event mouse up   $cx $cy
event mouse down $cx $cy
event mouse up   $cx $cy
update
puts "after 2 clicks count=$count"
# the .show label uses -textvariable, so its rendered glyphs must include "2"
puts "drawn: [drawntext]"

# cget / configure round-trip on a widget command
.title configure -text "Hits"
puts "title text=[.title cget -text]"
.inc invoke
puts "after invoke count=$count"

# --- grid: a little form inside a frame -------------------------------------
frame .form -width 200 -height 80
entry .form.name -textvariable who -width 10
checkbutton .form.agree -text "Agree" -variable agree
set who ""
set agree 0
grid .form.name  -row 0 -column 0 -sticky w
grid .form.agree -row 1 -column 0 -sticky w
pack .form -side top -pady 6
update
puts "name  : [winfo x .form.name] [winfo y .form.name]"
puts "agree : [winfo x .form.agree] [winfo y .form.agree]"

# type into the entry
focus .form.name
event text H
event text i
update
puts "who=$who"

# toggle the checkbutton by clicking it
set ax [expr {[winfo x .form.agree] + 5}]
set ay [expr {[winfo y .form.agree] + 5}]
event mouse down $ax $ay
update
puts "agree=$agree"

# --- bind: a custom event handler -------------------------------------------
bind .show <Button-1> {set msg clicked}
set msg none
set sx [expr {[winfo x .show] + 2}]
set sy [expr {[winfo y .show] + 2}]
event mouse down $sx $sy
update
puts "msg=$msg"

puts "done"
