# canary.tcl — P4.0 invocability probe + v1.4 spec canary
# Exercises: basic proc, itcl class, oo::class create, oo::define (F2),
#            trace add variable (F3), method_dispatch + receiver_hint.
package require Itcl

namespace eval ::canary {

    proc greet {who} {
        puts "hello $who"
        return $who
    }

    itcl::class Widget {
        public variable name ""
        constructor {n} { set name $n }
        public method show {} { puts "widget: $name" }
    }

    oo::class create Logger {
        constructor {} {}
        method log {msg} { puts "log: $msg" }
    }

    # F2 canary: oo::define augmenting form
    oo::define Logger {
        method warn {msg} { puts "warn: $msg" }
        method error {msg} { puts "error: $msg" }
        forward shout error
        mixin SomeMixin
    }

    proc demo {obj} {
        # method_dispatch — receiver_hint should be "$obj"
        $obj show
        # F3 canary: trace add variable — name should be "onChange", NOT "trace add variable"
        trace add variable ::canary::flag write [list $obj onChange]
        # Tier 4 walked body — call inside oo::define BODY is normal
        ::canary::greet "world"
    }
}
