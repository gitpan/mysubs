package mysubs;

use 5.008001;

use strict;
use warnings;

use constant {
    UNDO    => 0,
    REDO    => 1,
};

use B::Hooks::EndOfScope;
use B::Hooks::OP::Annotation;
use B::Hooks::OP::Check;
use Carp qw(croak carp);
use Devel::Pragma qw(ccstash fqname my_hints new_scope on_require);
use Scalar::Util;
use XSLoader;

our $VERSION = '1.14';
our @CARP_NOT = qw(B::Hooks::EndOfScope);

XSLoader::load(__PACKAGE__, $VERSION);

my $DEBUG = xs_get_debug(); # flag indicating whether debug messages should be printed

# The key under which the $installed hash is installed in %^H i.e. 'mysubs'
# Defined as a preprocessor macro in mysubs.xs to ensure the Perl and XS are kept in sync
my $MYSUBS = xs_sig();

# accessors for the debug flags - note there is one for Perl ($DEBUG) and one defined
# in the XS (MYSUBS_DEBUG). The accessors ensure that the two are kept in sync
sub get_debug()   { $DEBUG }
sub set_debug($)  { xs_set_debug($DEBUG = shift || 0) }
sub start_trace() { set_debug(1) }
sub stop_trace()  { set_debug(0) }

# This logs glob transitions i.e. installations and uninstallations of globs - identified
# by their IDs (see below)
sub debug ($$$$$) {
    my ($class, $action, $fqname, $old, $new) = @_; 
    my $glold = glob_id($old);
    my $glnew = glob_id($new);
    carp "$class: $action $fqname ($glold => $glnew)";
}

# The unique identifier for a typeglob - formatted as a hex value
#
# There's a bit of indirection in the GV struct that means we have to reach inside
# it to get the moral equivalent of its Scalar::Util::refaddr(). That's done in XS,
# and this sub pretty-prints it as a hex value
sub glob_id($) {
    sprintf '0x%x', xs_glob_id($_[0]);
}

# return a deep copy of the $installed hash - a hash containing the installed
# subs after any invocation of mysubs::import or mysubs::unimport
#
# the hash is cloned to ensure that inner/nested scopes don't clobber/contaminate
# outer/previous scopes with their new bindings. Likewise, unimport installs
# a new hash to ensure that previous bindings aren't clobbered e.g.
#
#   {
#        package Foo;
#
#        use mysubs bar => sub { ... };
#
#        bar();
#
#        no mysubs; # don't clobber the bindings associated with the previous subroutine call
#   }
#
# The hash and array refs are copied, but the globs are preserved.

# XXX: for some reason, Clone's clone doesn't seem to work here
sub clone($) {
    my $orig = shift;
    return { map { $_ => [ @{$orig->{$_}} ] } keys %$orig };
}

# return true if $ref ISA $class - works with non-references, unblessed references and objects
sub _isa($$) {
    my ($ref, $class) = @_;
    return Scalar::Util::blessed(ref) ? $ref->isa($class) : ref($ref) eq $class;
}

# croak with the name of this package prefixed
sub pcroak(@) {
    croak __PACKAGE__, ': ', @_;
}

# load a perl module
sub load($) {
    my $symbol = shift;
    my $module = (fqname $symbol)[0];
    eval "require $module";
    pcroak "can't load $module: $@" if ($@);
}

# install a clone of the current typeglob for the supplied symbol and add a new CODE entry
# mst++ and phaylon++ for this idea
sub install_sub($$) {
    my ($symbol, $sub) = @_;
    my ($stash, $name) = fqname($symbol);

    no strict 'refs';

    my $old_glob = delete ${"$stash\::"}{$name};

    # create the new glob
    *{"$stash\::$name"} = $sub;

    # copy slots over from the old glob
    if ($old_glob) {
        for my $slot (qw(SCALAR ARRAY HASH IO FORMAT)) {
            *{"$stash\::$name"} = *{$old_glob}{$slot} if (defined *{$old_glob}{$slot});
        }
    }

    return wantarray ? ($old_glob, *{"$stash\::$name"}) : *{"$stash\::$name"};
}

# restore the typeglob that existed before the lexical sub was defined - or delete it if it didn't exist
sub glob_install($$) {
    my ($symbol, $glob) = @_;
    my ($stash, $name) = fqname($symbol);

    no strict 'refs';

    my $old_glob = delete ${"$stash\::"}{$name};
    ${"$stash\::"}{$name} = $glob if ($glob);

    return $old_glob;
}

# this function is used to enter or leave a lexical context, where "context" means a set of
# lexical bindings in the form of globs with or without subroutines in the CODE slot
#
# for each lexical sub, import() creates or augments a hash that stores globs in the UNDO and REDO slots.
# these globs represent the before and after state of the glob corresponding to the supplied
# (fully-qualified) sub name. The UNDO glob is the glob prior to any declaration of a lexical
# sub with that name, and the REDO glob is the currently-active glob, with the most-recently
# defined lexical sub in its CODE slot.
#
# This data is used to clean up around compile-time requires: install is called to uninstall the
# current globs (UNDO); require() is called; then install is called again to reinstall the active
# globs (REDO). this ensures lexical subs don't leak across file boundaries if the current package
# is re-opened in a required file

sub install($$) {
    my ($installed, $action_id) = @_;

    for my $fqname (keys %$installed) {
        my $action = [ 'uninstalling', 'installing' ]->[$action_id];
        my $old_glob = glob_install($fqname, $installed->{$fqname}->[$action_id]);

        debug('mysubs', $action, $fqname, $old_glob, $installed->{$fqname}->[$action_id]) if ($DEBUG);
    }
}

# install one or more lexical subs in the current scope
#
# import() has to keep track of three things:
#
# 1) $installed keeps track of *all* currently active lexical subs so that they can be
#    uninstalled before (compile-time) require() and reinstalled afterwards
# 2) $restore keeps track of *all* active lexical subs in the outer scope
#    so that they can be restored at the end of the current scope
# 3) $unimport keeps track of which subs have been installed by *this* class (which may be a subclass of
#    mysubs) in this scope, so that they can be unimported with "no MyPragma (...)"
#
# In theory, restoration is done in two passes, the first over $installed and the second over $restore:
#
#     1) new/overridden: reinstate all the subs in $installed to their previous state in $restore (if any)
#     2) deleted: reinstate all the subs in $restore that are not defined in $installed (because
#        they were explicitly unimported)
# 
# In practice, as an optimization, an auxilliary hash ($remainder) is used to keep track of the
# elements of $restore that were removed (via unimport) from $installed. This reduces the overhead
# of the second pass so that it doesn't redundantly traverse elements covered by the first pass.

sub import_for {
    my ($class, $namespace, %bindings) = @_;

    # return unless (%bindings);

    my $autoload = delete $bindings{-autoload};
    my $debug = delete $bindings{-debug};
    my $hints = my_hints;
    my $caller = ccstash();
    my $installed;

    if (defined $debug) {
        my $old_debug = get_debug();
        if ($debug != $old_debug) {
            set_debug($debug);
            on_scope_end { set_debug($old_debug) };
        }
    }

    if (new_scope($MYSUBS)) {
        my $top_level = 0;
        my $restore = $hints->{$MYSUBS};

        if ($restore) {
            $installed = $hints->{$MYSUBS} = clone($restore); # clone
        } else {
            $top_level = 1;
            $restore = {};
            $installed = $hints->{$MYSUBS} = {}; # create

            # when a compile-time require (or do FILE) is performed, uninstall all
            # lexical subs (UNDO) and the check hook (xs_leave) beforehand,
            # and reinstate the lexical subs and check hook afterwards

            on_require(
                sub { my $hash = shift; install($hash->{$MYSUBS}, UNDO); xs_leave() },
                sub { my $hash = shift; install($hash->{$MYSUBS}, REDO); xs_enter() }
            );

            xs_enter();
        }

        # keep it around for runtime i.e. prototype()
        xs_cache($installed);

        on_scope_end {
            my $hints = my_hints; # refresh the %^H reference - doesn't work without this
            my $installed = $hints->{$MYSUBS};

            # this hash records (or will record) the lexical subs unimported from
            # the current scope
            my $remainder = { %$restore };

            for my $fqname (keys %$installed) {
                if (exists $restore->{$fqname}) {
                    unless (xs_glob_eq($installed->{$fqname}->[REDO], $restore->{$fqname}->[REDO])) {
                        $class->debug(
                            'restoring (overridden)',
                            $fqname,
                            $installed->{$fqname}->[REDO],
                            $restore->{$fqname}->[REDO]
                        ) if ($DEBUG);
                        glob_install($fqname, $restore->{$fqname}->[REDO]);
                    }
                } else {
                    $class->debug(
                        'deleting',
                        $fqname,
                        $installed->{$fqname}->[REDO],
                        $installed->{$fqname}->[UNDO]
                    ) if ($DEBUG);
                    glob_install($fqname, $installed->{$fqname}->[UNDO]);
                }

                delete $remainder->{$fqname};
            }

            for my $fqname (keys %$remainder) {
                $class->debug(
                    'restoring (unimported)',
                    $fqname,
                    $restore->{$fqname}->[UNDO],
                    $restore->{$fqname}->[REDO]
                ) if ($DEBUG);
                glob_install($fqname, $restore->{$fqname}->[REDO]);
            }
        };

        # disable mysubs altogether when we leave the top-level scope in which it was enabled
        # XXX this must be done here i.e. *after* the scope restoration handler
        on_scope_end \&xs_leave if ($top_level);
    } else {
        $installed = $hints->{$MYSUBS}; # augment
    }

    # Note: the namespace-specific unimport data is stored under a mysubs-flavoured name (e.g. "mysubs(MyPragma)")
    # rather than the unadorned class name (e.g. "MyPragma"). The subclass might well have its own
    # uses for $^H{$namespace}, so we keep our mitts off it
    #
    # Also, the unadorned class name can't be used as the unimport key if the class being used is "mysubs"
    # itself (i.e. "use mysubs qw(...)" rather than "use MyPragma qw(...)") because
    # "mysubs" is already spoken for as the installed hash key ($MYSUBS)

    my $subclass = "$MYSUBS($namespace)";
    my $unimport;

    # never use the $namespace as the identifier for new_scope() - see above
    if (new_scope($subclass)) {
        my $temp = $hints->{$subclass};
        $unimport = $hints->{$subclass} = $temp ? { %$temp } : {}; # clone/create
    } else {
        $unimport = $hints->{$subclass}; # augment
    }

    for my $name (keys %bindings) {
        my $sub = $bindings{$name};

        # normalize bindings
        unless (_isa($sub, 'CODE')) {
            $sub = do {
                load($sub) if (($sub =~ s/^\+//) || $autoload);
                no strict 'refs';
                *{$sub}{CODE}
            } || pcroak "can't find subroutine: '$sub'";
        }

        my $fqname = fqname($name, $caller);
        my ($old, $new) = install_sub($fqname, $sub);

        if (exists $installed->{$fqname}) {
            $class->debug('redefining', $fqname, $old, $new) if ($DEBUG);
            $installed->{$fqname}->[REDO] = $new;
        } else {
            $class->debug('creating', $fqname, $old, $new) if ($DEBUG);
            $installed->{$fqname} = [];
            $installed->{$fqname}->[UNDO] = $old;
            $installed->{$fqname}->[REDO] = $new;
        }

        $unimport->{$fqname} = $new;
    }
}

sub import {
    my $class = shift; # ignore invocant
    $class->import_for($class, @_);
}
   
# uninstall one or more lexical subs from the current scope
sub unimport_for {
    my $class = shift;
    my $namespace = shift;
    my $hints = my_hints;
    my $subclass = "$MYSUBS($namespace)";
    my $unimport;

    return unless (($^H & 0x20000) && ($unimport = $hints->{$subclass}));

    my $caller = ccstash();
    my @subs = @_ ? (map { scalar(fqname($_, $caller)) } @_) : keys(%$unimport);
    my $installed = $hints->{$MYSUBS};
    my $new_installed = clone($installed);
    my $deleted = 0;

    for my $fqname (@subs) {
        my $glob = $unimport->{$fqname};

        if ($glob) { # the glob this module/subclass installed
            # if the current glob ($installed->{$fqname}->[REDO]) is the glob this module installed ($unimport->{$fqname})
            if (xs_glob_eq($glob, $installed->{$fqname}->[REDO])) {
                my $old = $installed->{$fqname}->[REDO];
                my $new = $installed->{$fqname}->[UNDO];

                $class->debug('unimporting', $fqname, $old, $new) if ($DEBUG);
                glob_install($fqname, $installed->{$fqname}->[UNDO]); # restore the glob to its pre-lexical sub state

                # what import adds, unimport taketh away
                delete $new_installed->{$fqname};
                delete $unimport->{$fqname};

                ++$deleted;
            } else {
                carp "$namespace: attempt to unimport a shadowed lexical sub: $fqname";
            }
        } else {
            carp "$namespace: attempt to unimport an undefined lexical sub: $fqname";
        }
    }

    if ($deleted) {
        xs_cache($hints->{$MYSUBS} = $new_installed);
    }
}

sub unimport {
    my $class = shift;
    $class->unimport_for($class, @_);
}

1;

__END__

=head1 NAME

mysubs - lexical subroutines

=head1 SYNOPSIS

    package MyPragma;

    use base qw(mysubs);

    sub import {
        my $class = shift;

        $class->SUPER::import(
             foo   => sub { ... },
             chomp => \&mychomp
        );
    }

=cut

=pod

    #!/usr/bin/env perl

    {
        use MyPragma;

        foo(...);
        chomp ...;
    }

    foo(...);  # error: Undefined subroutine &main::foo
    chomp ...; # builtin

=head1 DESCRIPTION

C<mysubs> is a lexically-scoped pragma that implements lexical subroutines i.e. subroutines
whose use is restricted to the lexical scope in which they are imported or declared.

The C<use mysubs> statement takes a list of key/value pairs in which the keys are subroutine
names and the values are subroutine references or strings containing the package-qualified names
of the subroutines. In addition, C<mysubs> options may be passed.

The following example summarizes the type of keys and values that can be supplied.

    {
        use mysubs
            foo      => sub ($) { ... },     # anonymous sub value
            bar      => \&bar,               # code ref value
            chomp    => 'main::mychomp',     # sub name value
            dump     => '+Data::Dump::dump', # load Data::Dump
           'My::foo' => \&foo,               # package-qualified sub name
           -autoload => 1,                   # load modules for all sub name values
           -debug    => 1                    # show diagnostic messages
        ;

        foo(...);                            # OK
        prototype('foo')                     # '$'
        My::foo(...);                        # OK
        bar;                                 # OK
        chomp ...;                           # override builtin
        dump ...;                            # override builtin
    }

    foo(...);                                # error: Undefined subroutine &main::foo
    My::foo(...);                            # error: Undefined subroutine &My::foo
    prototype('foo')                         # undef
    chomp ...;                               # builtin
    dump ...;                                # builtin

=head1 OPTIONS

C<mysubs> options are prefixed with a hyphen to distinguish them from subroutine names.
The following options are supported:

=head2 -autoload

If the value is a package-qualified subroutine name, then the module can be automatically loaded.
This can either be done on a per-subroutine basis by prefixing the name with a C<+>, or for
all named values by supplying the C<-autoload> option with a true value e.g.

    use mysubs
         foo      => 'MyFoo::foo',
         bar      => 'MyBar::bar',
         baz      => 'MyBaz::baz',
        -autoload => 1;
or

    use MyFoo;
    use MyBaz;

    use mysubs
         foo =>  'MyFoo::foo',
         bar => '+MyBar::bar', # autoload MyBar
         baz =>  'MyBaz::baz';

The C<-autoload> option should not be confused with lexical C<AUTOLOAD> subroutines, which are also supported. e.g.

    use mysubs AUTOLOAD => sub { ... };

    foo(); # OK - AUTOLOAD
    bar(); # ditto
    baz(); # ditto

=head2 -debug

A trace of the module's actions can be enabled or disabled lexically by supplying the C<-debug> option
with a true or false value. The trace is printed to STDERR.

e.g.

    use mysubs
         foo   => \&foo,
         bar   => sub { ... },
        -debug => 1;

=head1 METHODS

=head2 import

C<mysubs::import> can be called indirectly via C<use mysubs> or can be overridden by subclasses to create
lexically-scoped pragmas that export subroutines whose use is restricted to the calling scope e.g.

    package MyPragma;

    use base qw(mysubs);

    sub import {
        my $class = shift;

        $class->SUPER::import(
             foo   => sub { ... },
             chomp => \&mychomp
        );
    }

Client code can then import lexical subs from the module:

    #!/usr/bin/env perl

    {
        use MyPragma;

        foo(...);
        chomp ...;
    }

    foo(...);  # error: Undefined subroutine &main::foo
    chomp ...; # builtin

The C<import> method is implemented as a wrapper around C<L<import_for|/import_for>>.

=head2 import_for

C<mysubs> methods are installed and uninstalled for a particular client of the C<mysubs> library.
Typically, this client is identified by its class name i.e. the first argument passed
to the C<L<mysubs::import|/import>> method. Note: if C<mysubs-E<gt>import> is called implicitly (via C<use mysubs ...>)
or explicitly, then the client identifier is "mysubs" i.e. C<mysubs> can function as a client of itself.

The C<import_for> method allows an identifier to be specified explicitly without subclassing C<mysubs> e.g.

    package MyPragma;

    use base qw(Whatever); # we can't/don't want to subclass mysubs

    use mysubs (); # don't import anything

    sub import {
        my $class = shift;
        $class->SUPER::import(...); # call Whatever::import
        mysubs->import_for($class, foo => sub { ... }, ...);
    }

The installed subs can then be uninstalled by passing the same identifier to the
C<L<unimport_for|/unimport_for>> method.

Note that the C<import_for> identifier has nothing to do with the package the lexical subs will be
installed into. Lexical subs are always installed into the package specified in the package-qualified sub name,
or the package of the currently-compiling scope.

C<mysubs-E<gt>import> is implemented as a call to C<mysubs-E<gt>import_for> i.e.

    package MyPragma;

    use base qw(mysubs);

    sub import {
        my $class = shift;
        $class->SUPER::import(foo => sub { ... });
    }

- is equivalent to:

    package MyPragma;

    use mysubs ();

    sub import {
        my $class = shift;
        mysubs->import_for($class, foo => sub { ... });
    }

=head2 unimport

C<mysubs::unimport> removes the specified lexical subs from the current scope, or all lexical subs 
if no arguments are supplied.

    use mysubs foo => \&foo;

    {
        use mysubs
            bar => sub { ... },
            baz => 'Baz::baz';

        foo ...;
        bar(...);
        baz;

        no mysubs qw(foo);

        foo ...;  # error: Undefined subroutine &main::foo

        no mysubs;

        bar(...); # error: Undefined subroutine &main::bar
        baz;      # error: Undefined subroutine &main::baz
    }

    foo ...; # ok

Unimports are specific to the class supplied in the C<no> statement, so pragmas that subclass
C<mysubs> inherit an C<unimport> method that only removes the subs they installed e.g.

    {
        use MyPragma qw(foo bar baz);

        use mysubs quux => \&quux;

        foo;
        quux(...);

        no MyPragma qw(foo); # unimports foo
        no MyPragma;         # unimports bar and baz
        no mysubs;           # unimports quux
    }

As with the C<L<import|/import>> method, C<unimport> is implemented as a wrapper around
C<L<unimport_for|/unimport_for>>.

=head2 unimport_for

This method complements the C<L<import_for|/import_for>> method. i.e. it allows the identifier for a group of lexical
subs to be specified explicitly. The identifier should match the one supplied in the
corresponding C<import_for> method e.g.

    package MyPragma;

    use mysubs ();

    sub import {
        my $class = shift;
        mysubs->import_for($class, foo => sub { ... });
    }

    sub unimport {
        my $class = shift;
        mysubs->unimport_for($class, @_);
    }

As with the C<import_for> method, the identifier is used to refer to a group of lexical
subs, and has nothing to do with the package from which those subs will be uninstalled.
As with the import methods, the unimport methods always operate on (i.e. uninstall lexical subs from)
the package in the package-qualified sub name, or the package of the currently-compiling scope.

=head1 CAVEATS

Lexical subs cannot be called by symbolic reference e.g.

This works:

    use mysubs
        foo      => sub { ... }, 
        AUTOLOAD => sub { ... }
    ;

    my $foo = \&foo;

    foo();    # OK - named
    bar();    # OK - AUTOLOAD
    $foo->(); # OK - reference

This doesn't work:

    use mysubs
        foo      => sub { ... }, 
        AUTOLOAD => sub { ... }
    ;

    my $foo = 'foo';
    my $bar = 'bar';

    no strict 'refs';

    &{$foo}(); # not foo
    &{$bar}(); # not AUTOLOAD

=head1 VERSION

1.14

=head1 SEE ALSO

=over

=item * L<Sub::Lexical|Sub::Lexical>

=item * L<Method::Lexical|Method::Lexical>

=back

=head1 AUTHOR

chocolateboy <chocolate@cpan.org>, with thanks to mst (Matt S Trout), phaylon (Robert Sedlacek),
and Paul Fenwick for the idea.

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2008-2011 by chocolateboy

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

=cut
