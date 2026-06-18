# mini-tk demo — authentic Tk, runs unmodified on any canvas backend.
#   ./mini-tcl-sdl examples/tk-demo.tcl
#
# Demonstrates the full v1 widget set, both geometry managers, bindings, an
# entry you can type into, a checkbutton, a scale you can drag, and a canvas.

wm title . "mini-tk demo"

label .h -text "  mini-tk : a Tk essence  " \
    -background "30 60 120" -foreground "255 255 255"
pack .h -side top -fill x -pady 2

# --- a counter row laid out with pack -side left ----------------------------
frame .row -background "45 45 45"
pack .row -side top -fill x -pady 6
button .row.dec -text " - " -command {incr n -1}
label  .row.val -textvariable n -background "45 45 45" -foreground "255 230 120"
button .row.inc -text " + " -command {incr n}
set n 0
pack .row.dec -side left -padx 6 -pady 6
pack .row.val -side left -padx 10
pack .row.inc -side left -padx 6

# --- a form laid out with grid ----------------------------------------------
frame .form -background "45 45 45" -width 380 -height 90
pack .form -side top -fill x -pady 6
label .form.l1    -text "Name:" -background "45 45 45"
entry .form.name  -textvariable who -width 18
checkbutton .form.agree -text "I agree" -variable agree -background "45 45 45"
set who ""
set agree 0
grid .form.l1    -row 0 -column 0 -sticky w -padx 6 -pady 6
grid .form.name  -row 0 -column 1 -sticky w -padx 6 -pady 6
grid .form.agree -row 1 -column 0 -columnspan 2 -sticky w -padx 6

# --- a scale and a canvas ---------------------------------------------------
scale .vol -from 0 -to 100 -variable v -length 360
set v 30
pack .vol -side top -pady 6

canvas .c -width 360 -height 36 -background "0 0 0"
pack .c -side top -pady 4
.c create rectangle 4 4 120 32 -fill "80 160 255"
.c create text 10 12 -text "canvas widget item"

# click the counter label to reset, via a binding
bind .row.val <Button-1> {set n 0}

focus .form.name
