
package MooseX::Storage::Engine;
use Moose;

our $VERSION = '0.01';

# the class marker when 
# serializing an object. 
our $CLASS_MARKER = '__CLASS__';

has 'storage' => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub {{}}
);

has 'seen' => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub {{}}
);

has 'object' => (is => 'rw', isa => 'Object');
has 'class'  => (is => 'rw', isa => 'Str');

## this is the API used by other modules ...

sub collapse_object {
	my $self = shift;

	# NOTE:
	# mark the root object as seen ...
	$self->seen->{$self->object} = undef;
	
    $self->map_attributes('collapse_attribute');
    $self->storage->{$CLASS_MARKER} = $self->object->meta->name;    
	return $self->storage;
}

sub expand_object {
    my ($self, $data) = @_;
    
	# NOTE:
	# mark the root object as seen ...
	$self->seen->{$data} = undef;    
    
    $self->map_attributes('expand_attribute', $data);
	return $self->storage;    
}

## this is the internal API ...

sub collapse_attribute {
    my ($self, $attr)  = @_;
    $self->storage->{$attr->name} = $self->collapse_attribute_value($attr) || return;
}

sub expand_attribute {
    my ($self, $attr, $data)  = @_;
    $self->storage->{$attr->name} = $self->expand_attribute_value($attr, $data->{$attr->name}) || return;
}

sub collapse_attribute_value {
    my ($self, $attr)  = @_;
	my $value = $attr->get_value($self->object);
	
	# NOTE:
	# this might not be enough, we might 
	# need to make it possible for the 
	# cycle checker to return the value
    $self->check_for_cycle_in_collapse($value) 
        if ref $value;
	
    if (defined $value && $attr->has_type_constraint) {
        my $type_converter = $self->find_type_handler($attr->type_constraint);
        (defined $type_converter)
            || confess "Cannot convert " . $attr->type_constraint->name;
        $value = $type_converter->{collapse}->($value);
    }
	return $value;
}

sub expand_attribute_value {
    my ($self, $attr, $value)  = @_;

	# NOTE:
	# (see comment in method above ^^)
    $self->check_for_cycle_in_expansion($value) 
        if ref $value;    
    
    if (defined $value && $attr->has_type_constraint) {
        my $type_converter = $self->find_type_handler($attr->type_constraint);
        $value = $type_converter->{expand}->($value);
    }
	return $value;
}

# NOTE:
# possibly these two methods will 
# be used by a cycle supporting 
# engine. However, I am not sure 
# if I can make a cycle one work 
# anyway.

sub check_for_cycle_in_collapse {
    my ($self, $value) = @_;
    (!exists $self->seen->{$value})
        || confess "Basic Engine does not support cycles";
    $self->seen->{$value} = undef;
}

sub check_for_cycle_in_expansion {
    my ($self, $value) = @_;
    (!exists $self->seen->{$value})
        || confess "Basic Engine does not support cycles";
    $self->seen->{$value} = undef;
}

# util methods ...

sub map_attributes {
    my ($self, $method_name, @args) = @_;
    map { 
        $self->$method_name($_, @args) 
    } grep {
        # Skip our special skip attribute :)
        !$_->isa('MooseX::Storage::Meta::Attribute::DoNotSerialize')
    } ($self->object || $self->class)->meta->compute_all_applicable_attributes;
}

## ------------------------------------------------------------------
## This is all the type handler stuff, it is in a state of flux
## right now, so this may change, or it may just continue to be 
## improved upon. Comments and suggestions are welcomed.
## ------------------------------------------------------------------

# NOTE:
# these are needed by the 
# ArrayRef and HashRef handlers
# below, so I need easy access 
my %OBJECT_HANDLERS = (
    expand => sub {
        my $data = shift;   
        (exists $data->{$CLASS_MARKER})
            || confess "Serialized item has no class marker";
        $data->{$CLASS_MARKER}->unpack($data);
    },
    collapse => sub {
        my $obj = shift;
        ($obj->can('does') && $obj->does('MooseX::Storage::Basic'))
            || confess "Bad object ($obj) does not do MooseX::Storage::Basic role";
        $obj->pack();
    },
);


my %TYPES = (
    # These are boring ones, so they use the identity function ...
    'Int'      => { expand => sub { shift }, collapse => sub { shift } },
    'Num'      => { expand => sub { shift }, collapse => sub { shift } },
    'Str'      => { expand => sub { shift }, collapse => sub { shift } },
    # These are the trickier ones, (see notes)
    # NOTE:
    # Because we are nice guys, we will check 
    # your ArrayRef and/or HashRef one level 
    # down and inflate any objects we find. 
    # But this is where it ends, it is too
    # expensive to try and do this any more  
    # recursively, when it is probably not 
    # nessecary in most of the use cases.
    # However, if you need more then this, subtype 
    # and add a custom handler.    
    'ArrayRef' => { 
        expand => sub {
            my $array = shift;
            foreach my $i (0 .. $#{$array}) {
                next unless ref($array->[$i]) eq 'HASH' 
                         && exists $array->[$i]->{$CLASS_MARKER};
                $array->[$i] = $OBJECT_HANDLERS{expand}->($array->[$i])
            }
            $array;
        }, 
        collapse => sub { 
            my $array = shift;   
            # NOTE:         
            # we need to make a copy cause
            # otherwise it will affect the 
            # other real version.
            [ map {
                blessed($_)
                    ? $OBJECT_HANDLERS{collapse}->($_)
                    : $_
            } @$array ] 
        } 
    },
    'HashRef'  => { 
        expand   => sub {
            my $hash = shift;
            foreach my $k (keys %$hash) {
                next unless ref($hash->{$k}) eq 'HASH' 
                         && exists $hash->{$k}->{$CLASS_MARKER};
                $hash->{$k} = $OBJECT_HANDLERS{expand}->($hash->{$k})
            }
            $hash;            
        }, 
        collapse => sub {
            my $hash = shift;   
            # NOTE:         
            # we need to make a copy cause
            # otherwise it will affect the 
            # other real version.
            +{ map {
                blessed($hash->{$_})
                    ? ($_ => $OBJECT_HANDLERS{collapse}->($hash->{$_}))
                    : ($_ => $hash->{$_})
            } keys %$hash }            
        } 
    },
    'Object'   => \%OBJECT_HANDLERS,
    # NOTE:
    # The sanity of enabling this feature by 
    # default is very questionable.
    # - SL
    #'CodeRef' => {
    #    expand   => sub {}, # use eval ...
    #    collapse => sub {}, # use B::Deparse ...        
    #} 
);

sub add_custom_type_handler {
    my ($class, $type_name, %handlers) = @_;
    (exists $handlers{expand} && exists $handlers{collapse})
        || confess "Custom type handlers need an expand *and* a collapse method";
    $TYPES{$type_name} = \%handlers;
}

sub remove_custom_type_handler {
    my ($class, $type_name) = @_;
    delete $TYPES{$type_name} if exists $TYPES{$type_name};
}

sub find_type_handler {
    my ($self, $type_constraint) = @_;
    
    # this should handle most type usages
    # since they they are usually just 
    # the standard set of built-ins
    return $TYPES{$type_constraint->name} 
        if exists $TYPES{$type_constraint->name};
      
    # the next possibility is they are 
    # a subtype of the built-in types, 
    # in which case this will DWIM in 
    # most cases. It is probably not 
    # 100% ideal though, but until I 
    # come up with a decent test case 
    # it will do for now.
    foreach my $type (keys %TYPES) {
        return $TYPES{$type} 
            if $type_constraint->is_subtype_of($type);
    }
    
    # NOTE:
    # the reason the above will work has to 
    # do with the fact that custom subtypes
    # are mostly used for validation of 
    # the guts of a type, and not for some
    # weird structural thing which would 
    # need to be accomidated by the serializer.
    # Of course, mst or phaylon will probably  
    # do something to throw this assumption 
    # totally out the door ;)
    # - SL
    
    # NOTE:
    # if this method hasnt returned by now
    # then we have no been able to find a 
    # type constraint handler to match 
    confess "Cannot handle type constraint (" . $type_constraint->name . ")";    
}

1;

__END__

=pod

=head1 NAME

MooseX::Storage::Engine

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 METHODS

=head2 Accessors

=over 4

=item B<class>

=item B<object>

=item B<storage>

=item B<seen>

=back

=head2 API

=over 4

=item B<expand_object>

=item B<collapse_object>

=back

=head2 ...

=over 4

=item B<collapse_attribute>

=item B<collapse_attribute_value>

=item B<expand_attribute>

=item B<expand_attribute_value>

=item B<check_for_cycle_in_collapse>

=item B<check_for_cycle_in_expansion>

=item B<map_attributes>

=back

=head2 Type Constraint Handlers

=over 4

=item B<find_type_handler>

=item B<add_custom_type_handler>

=item B<remove_custom_type_handler>

=back

=head2 Introspection

=over 4

=item B<meta>

=back

=head1 BUGS

All complex software has bugs lurking in it, and this module is no 
exception. If you find a bug please either email me, or add the bug
to cpan-RT.

=head1 AUTHOR

Chris Prather E<lt>chris.prather@iinteractive.comE<gt>

Stevan Little E<lt>stevan.little@iinteractive.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2007 by Infinity Interactive, Inc.

L<http://www.iinteractive.com>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut


