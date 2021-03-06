package Clustericious::Client::Meta::Route;

use strict;
use warnings;
use YAML::XS qw/LoadFile/;
use DateTime::Format::DateParse;
use Getopt::Long qw/GetOptionsFromArray/;
use Mojo::Base qw/-base/;
use Data::Dumper;
use Clustericious::Log;
use Clustericious::Client::Meta;

# ABSTRACT: metadata about a route'
# VERSION

=head1 DESCRIPTION

Keep track of metadata about a particular route.  This includes
documentation and attributes.

=head1 SYNOPSIS

    my $meta = Clustericious::Client::Meta::Route->new(
            client_class => 'Yars::Client',
            route_name => 'bucket_map,
        );
    $meta->get('auto_failover');

=cut


has 'client_class';
has 'route_name';

=head2 set

Set a route attribute.

  $meta->set(auto_failover => 1);

=cut

sub set {
    my $self = shift;
    return Clustericious::Client::Meta->add_route_attribute(
        $self->client_class, $self->route_name, @_ );
}

=head2 get

Get a route attribute.

 $meta->get('auto_failover');

=cut

sub get {
    my $self = shift;
    return Clustericious::Client::Meta->get_route_attribute(
        $self->client_class, $self->route_name, @_ );
}

=head2 doc

Get documentation for this route.

=cut

sub doc {
    my $self = shift;
    return Clustericious::Client::Meta->get_route_doc(
        $self->client_class, $self->route_name, @_
    );
}

=head2 set_doc

Set the documentation for a route.

=cut

sub set_doc {
    my $self = shift;
    return Clustericious::Client::Meta->add_route(
        $self->client_class, $self->route_name, @_
    );
}

=head2 client_class

The class of the client associated with this object.

=head2 route_name

The name of the route to which this object refers.

=head2 process_args

Process an array of arguments sent to this route.

This will look at the the route_arg specification that
has been set up for this route, and use it to turn
an array of parameters into hash for use by the method.

If any of the args have a 'preprocess' (list, yamldoc, datetime),
then those transformations are applied.

If any required parameters are missing, an exception is thrown.

If any parameters have an 'alt' entry or are abbreviated, the
full name is used instead.

Returns a hash of arguments, dies on failure.

See route_arg for a complete description of how arguments will
be processed.  Note that modifies_url entries are not processed
here; that occurs just before the request is made.

=cut

sub process_args {
    my $meta = shift;
    my @args = @_;
    my $cli;
    if (ref $args[0] eq 'HASH' && $args[0]{command_line}) {
        $cli = 1;
        shift @args;
    }
    my $route_args = $meta->get('args') or return @args;
    unless ($cli) {
        # method call, modify @args so that getopt will work.
        # Prepend a "--" for named params.
        my %valid;
        for (@$route_args) {
            next if $_->{positional};
            my @name = ( $_->{name} );
            if ($_->{alt}) {
                push @name, split '\|', $_->{alt};
            }
            my $type = $_->{type};
            $valid{$_} = $type for @name;
        }
        my @new;
        while (my $in = shift @args) {
            if (exists($valid{$in})) {
                push @new, "--$in";
                push @new, shift @args if @args && defined($valid{$in}) && length($valid{$in});
            } else {
                push @new, $in;
            }
        }

        @args = @new;
    }

    my %req = map { $_->{required} ? ($_->{name} => 1):() } @$route_args;
    my @getopt = map {
         $_->{name}
         .($_->{alt} ? "|$_->{alt}" : "")
         .($_->{type} || '')
         } @$route_args;

    my $doc = join "\n", "Valid options for '".$meta->route_name."' are :", $meta->route_args_string;

    my %method_args;
    Getopt::Long::Configure(qw/pass_through/); # TODO use OO interface
    GetOptionsFromArray(\@args, \%method_args, @getopt) or LOGDIE "Invalid options. $doc\n";

    # Check for positional args
    for (@$route_args) {
        next unless @args;
        my $spec = $_->{positional} or next;
        my $name = $_->{name};
        for ($spec) {
            /one/ and do {
                $method_args{$name} = shift @args;
                next;
            };
            /many/ and do {
                push @{ $method_args{$name} }, shift @args while @args;
                next;
            };
            die "unknown positional spec : $spec";
        }
    }

    # Check for required args
    for (@$route_args) {
        my $name = $_->{name};
        next unless $_->{required};
        next if exists($method_args{$name});
        LOGDIE "Missing value for required argument '$name'\n$doc\n";
    }

    LOGDIE "Unknown option : @args\n$doc\n" if @args;

    # Check for preprocessing of args
    for (@$route_args) {
        my $name = $_->{name};
        next unless $_->{preprocess};
        LOGDIE "internal error: cannot handle $_->{preprocess}" unless $_->{preprocess} =~ /yamldoc|list|datetime/;
        my $filename = $method_args{$name} or next;
        LOGDIE "Argument for $name should be a filename, an arrayref or - for STDIN" if $filename && $filename =~ /\n/;
        for ($_->{preprocess}) {
            /yamldoc/ and do {
                next if ref $filename;
                $method_args{$name} = ($filename eq "-" ? Load(join "",<STDIN>) : LoadFile($filename))
                        or LOGDIE "Error parsing yaml in ($filename)";
                next;
            };
            /list/ and do {
                next if ref $filename eq 'ARRAY';
                $method_args{$name} = [ map { chomp; $_ } IO::File->new("< $filename")->getlines ];
                next;
            };
            /^datetime$/ and do {
                $method_args{$name} = DateTime::Format::DateParse->parse_datetime($method_args{$name})->iso8601();
                next;
            };
        }
    }

    # Order the args properly
    my @method_args;
    for (@$route_args) {
        my $name = $_->{name};
        next unless exists($method_args{$name});
        push @method_args, $name => $method_args{$name};
    }
    return @method_args;
}

=head2 route_args_string

Construct documentation based on the arguments for a particular method.

=cut

sub route_args_string {
    my $self = shift;
    my $args = $self->get('args') or return "";
    my $str = "";
    for my $arg (@$args) {
        $str.= "   --$arg->{name}";
        if ($arg->{required}) {
            $str .= " (required)"
        } else {
            $str.= " (optional)"
        }
        for ($arg->{type} || 'bool') {
            /^=s/ and do { $str .= " string"; next; };
            /bool/ and do { $str .= " flag"; next; };
            print $arg->{type};
        }
        $str .= ($arg->{doc} // '');
        $str .= "\n";
    }
    return $str;

}

=head2 get_pod_doc

Extract a snippet of documentation from the METHODS section of the pod,
which describes the invocation of a particular method.

=cut

sub get_pod_doc {
    my $self = shift;
    my $client_class = $self->client_class;
    $client_class =~ s[::][/]g;
    $client_class .= '.pm';
    my $parser = Pod::POM->new();
    my $pom = $parser->parse_file($INC{$client_class}) or die "pod error : ".$parser->error;
    my $pod_doc;
    my $want = $self->route_name;
    for my $head1 ($pom->head1) {
        next unless $head1->title eq 'METHODS';
        for my $head2 ($head1->head2()) {
            next unless $head2->title =~ /\b$want\b/;
            $pod_doc = $head2->content;
        }
    }
    return $pod_doc;
}


=head1 SEE ALSO

Clustericious::Client::Meta

=cut

1;

