# Tiny snit fixture for the 5.2a.1 dispatch tests.
# Exercises the §5.4.7 directive grammar: snit::type outer with typemethod,
# method, constructor, destructor, option, variable, typevariable,
# component, delegate method, delegate option, superclass.

snit::type ::demo::Widget {
    typevariable counter 0
    variable      state ""

    option -size  -default 10
    option -color -default "red"

    component   inner
    delegate option -reliefcolor to inner
    delegate method dump          to inner

    superclass ::demo::Base ::demo::Mixable

    typemethod build {args} {
        incr counter
        return [eval [linsert $args 0 $type create]]
    }

    constructor {args} {
        install inner using label .l
        $self configurelist $args
    }

    destructor {
        catch {destroy [$self winfo widget]}
    }

    method show {} {
        puts "state=$state"
        return $state
    }

    proc helper {x} {
        return [expr {$x * 2}]
    }
}
