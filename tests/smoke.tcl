# smoke test for mini-tcl (run in script mode: mini-tcl tests/smoke.tcl one two)

# --- script arguments ---
puts "argv0-ok=[string match *smoke.tcl $argv0]"
puts "argc=$argc"
puts "argv=$argv"
puts "first=[lindex $argv 0] second=[lindex $argv 1]"

# --- set / append / incr / unset / info exists ---
set x 5
puts "x=$x"
append x ab
puts "x=$x"
set n 10
incr n
incr n 5
puts "n=$n"
puts "exists-n=[info exists n]"
unset n
puts "exists-n=[info exists n]"

# --- expr ---
puts [expr 2 + 3 * 4]
puts [expr {(2 + 3) * 4}]
puts [expr {10 / 4.0}]
puts [expr {7 % 3}]
puts [expr {2 ** 10}]
puts [expr {1 < 2 && 3 >= 3}]
puts [expr {!0}]
puts [expr {"abc" eq "abc"}]
puts [expr {"abc" ne "abd"}]
puts [expr {1 ? 111 : 222}]
puts [expr {sqrt(16)}]
puts [expr {max(3, min(9, 7))}]
set y 6
puts [expr {$y * [expr {$y + 1}]}]

# --- if / elseif / else ---
set v 15
if {$v < 10} {
    puts small
} elseif {$v < 20} {
    puts medium
} else {
    puts large
}

# --- while + break/continue ---
set i 0
set out ""
while {$i < 10} {
    incr i
    if {$i == 3} { continue }
    if {$i == 6} { break }
    append out "$i,"
}
puts "while=$out"

# --- for ---
set out ""
for {set k 0} {$k < 5} {incr k} {
    append out "$k"
}
puts "for=$out"

# --- foreach (single and multiple vars) ---
set out ""
foreach f {a b c} {
    append out "<$f>"
}
puts "foreach=$out"
set out ""
foreach {p q} {1 one 2 two} {
    append out "$p=$q "
}
puts "pairs=$out"

# --- proc / return / global / default args / varargs ---
proc square {a} {
    return [expr {$a * $a}]
}
puts "square=[square 9]"

proc greet {name {greeting Hello}} {
    return "$greeting, $name"
}
puts [greet World]
puts [greet World Ciao]

proc sum {args} {
    set total 0
    foreach a $args { incr total $a }
    return $total
}
puts "sum=[sum 1 2 3 4]"

set counter 0
proc bump {} {
    global counter
    incr counter
}
bump
bump
puts "counter=$counter"

# --- recursion ---
proc fact {n} {
    if {$n <= 1} { return 1 }
    return [expr {$n * [fact [expr {$n - 1}]]}]
}
puts "fact5=[fact 5]"

# --- string ---
puts [string length "hello world"]
puts [string toupper "hello"]
puts [string tolower "HeLLo"]
puts "[string trim "  spaced  "]|"
puts [string reverse abc]
puts [string index abcdef 2]
puts [string index abcdef end]
puts [string range abcdef 1 3]
puts [string range abcdef 2 end]
puts [string repeat ab 3]
puts [string equal foo foo]
puts [string compare apple banana]
puts [string first lo "hello world"]
puts [string match "h*o" "hello"]

# --- lists ---
set l [list a b "c d" e]
puts "list=$l"
puts "llength=[llength $l]"
puts "lindex2=[lindex $l 2]"
puts "lindexend=[lindex $l end]"
puts "lrange=[lrange $l 1 2]"
set l2 {}
lappend l2 x
lappend l2 y z
puts "lappend=$l2"
puts "split=[split a,b,,c ,]"
puts "join=[join {a b c} -]"

# --- eval / catch / error ---
puts "eval=[eval puts hi]"
set rc [catch {error boom} msg]
puts "catch=$rc msg=$msg"
set rc [catch {expr {1 + 1}} msg]
puts "catch=$rc msg=$msg"
set rc [catch {nosuchcommand} msg]
puts "catch=$rc msg=$msg"

# --- comments and ; separators ---
set a 1; set b 2  ;# this is a trailing comment
puts "ab=$a$b"

puts done
