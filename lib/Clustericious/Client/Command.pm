package Clustericious::Client::Command;

=head1 NAME

Clustericious::Client::Command - Command line type processing for clients.

=head1 SYNOPSIS

# in fooclient :

 use Foo::Client;
 use Clustericious::Client::Command;

 Clustericious::Client::Command->run(Foo::Client->new, @ARGV);

Then

 fooclient status
 fooclient --trace root status
 fooclient version
 fooclient foobject 31
 fooclient foobject_search --color beige
 fooclient --remote bar status

=head1 DESCRIPTION

Every method invocation of a Clustericious::Client object has
an analogous comand line call.  For instance, calling

     fooclient bar baz

may be equivalent to

     Foo::Client->new()->bar("baz")

The specifics of how each command maps from a method invocation
to a command line call (and to a RESTful call) are described in
Clustericious::Client.  Some methods use positional arguments (as
in the example above), others use named parameters, for instance,
mapping

    fooclient foo --name baz

to

    $client->foo(name => 'baz')

=head1 COMMON OPTIONS

The option --remote foo will specify that the 'remote' sections of
the config file should be used to load the configuration before processing
the options.

The options described in L<Log::Log4perl::CommandLine> may be used for
any command line call.

=cut

use strict;
use warnings;

use feature qw/:all/;
use File::Basename qw/basename/;
use YAML::XS qw(Load Dump LoadFile);
use Log::Log4perl qw/:easy/;
use Scalar::Util qw/blessed/;
use Data::Rmap qw/rmap_ref/;
use File::Temp;

use Clustericious::Log;
use Clustericious::Client::Meta;

our $VERSION = '0.83';

sub _usage {
    my $class = shift;
    my $client = shift;
    my $msg = shift;
    my $command = shift;
    my $name = basename($0);

    if ($command) {
        my $meta = Clustericious::Client::Meta::Route->new(
            client_class => ref $client,
            route_name => $command
        );
        say "";
        if (my $doc = $meta->doc) {
            say "$name $command $doc";
        } elsif ($client->can($command)) {
            say "$name $command";
        } else {
            say "Unknown command : $command";
        }
        if (my $description = $meta->get_pod_doc || $meta->get('description')) {
            chomp $description;
            say "\nDescription :\n    $description";
        }
        if (my $args = $meta->get('args')) {
            say "Arguments :\n".$meta->route_args_string;
        }
        return;
    }

    my $routes = Clustericious::Client::Meta->routes(ref $client);
    my $objects = Clustericious::Client::Meta->objects(ref $client);
    say $msg if $msg;
    say "Usage:";
    say <<EOPRINT if $routes && @$routes;
@{[ join "\n", map "       $name [opts] $_->[0] $_->[1]", @$routes ]}
EOPRINT
    say <<EOPRINT if $objects && @$objects;
       $name [opts] <object>
       $name [opts] <object> <keys>
       $name [opts] search <object> [--key value]
       $name [opts] create <object> [<filename list>]
       $name [opts] update <object> <keys> [<filename>]
       $name [opts] delete <object> <keys>

      <object> may be one of the following :
@{[ join "\n", map "      $_->[0] $_->[1]", @$objects ]}
EOPRINT

    say <<DONE;
    [opts] are described in Log::Log4perl::CommandLine and Clustericious::Client::Command.
DONE

    say "For help about a particular command, type $name help <command>.\n";

    exit 0;
}

=head1 METHODS

=head2 C<run>

 Clustericious::Client::Command->run(Some::Clustericious::Client->new, @ARGV);

=cut

our $Ssh = "ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o PasswordAuthentication=no";
sub _expand_remote_glob {
    # Given a glob, e.g. omidev.gsfc.nasa.gov:/devsips/app/*/doc/Description.txt
    # Return a list of filenames with the host prepended to each one, e.g.
    #       omidev.gsfc.nasa.gov:/devsips/app/foo-1/doc/Description.txt
    #       omidev.gsfc.nasa.gov:/devsips/app/bar-2/doc/Description.txt
    my $pattern = shift;
    return ( $pattern ) unless $pattern =~ /^(\S+):(.*)$/;
    my ($host,$file) = ( $1, $2 );
    return ( $pattern ) unless $file =~ /[*?]/;
    INFO "Remote glob : $host:$file";
    my $errs =  File::Temp->new();
    my @filenames = `$Ssh $host ls $file 2>$errs`;
    LOGDIE "Error ssh $host ls $file returned (code $?)".`tail -2 $errs` if $?;
    return map "$host:$_", @filenames;
}

sub _load_yaml {
    # _load_yaml can take a local filename or a remote ssh host + filename and
    # returns parsed yaml content.
    my $filename = shift;

    unless ($filename =~ /^(\S+):(.*)$/) {
        INFO "Loading $filename";
        my $parsed = LoadFile($filename) or LOGDIE "Invalid YAML : $filename\n";
        return $parsed;
    }

    my ($host,$file) = ($1,$2);
    INFO "Loading remote file $file from $host";
    my $errs =  File::Temp->new();
    my $content = `$Ssh $host cat $file 2>$errs`;
    if ($?) {
        LOGDIE "Error (code $?) running ssh $host cat $file : ".`tail -2 $errs`;
    }
    my $parsed = Load($content) or do {
        ERROR "Invalid YAML: $filename";
        return;
    };
    return $parsed;
}

sub run {
    my $class = shift;
    my $client = shift;
    my @args = @_ ? @_ : @ARGV;
    our $TESTING;

    return $class->_usage($client,"") if !$args[0];
    return $class->_usage($client,"") if @args==1 && $args[0] =~ /help$/;

    if (@args==2 && $args[0] eq 'help') {
        return $class->_usage($client,"Help for $args[1] :",$args[1]);
    }
    if (@args==2 && $args[1] eq '--help') {
        return $class->_usage($client,"Help for $args[0] :",$args[0]);
    }

    # Preprocessing for any common args, e.g. --remote
    my $arg;
    ARG :
    while ($arg = shift @args) {
        for ($arg) {
            /--remote/ and do {
                my $remote = shift @args;
                TRACE "Using remote $remote";
                $client->remote($remote);
                next ARG;
            };
            last ARG;
        }
    }

    my $method = $arg or $class->_usage($client,"No such command : $arg");

    # Map some alternative command line forms.
    my $try_stdin;
    if ( $method eq 'create' ) {
        $method = shift @args or $class->_usage( $client, "Missing <object>" );
        $try_stdin = 1;
    }

    if ( $method =~ /^(delete|search)$/ ) { # e.g. search -> app_search
        $method = ( shift @args ) . '_' . $method;
    }

    unless ($client->can($method)) {
        $class->_usage($client, "Unrecognized argument : $method");
        return;
    }

    my $meta = Clustericious::Client::Meta::Route->new(
        route_name   => $method,
        client_class => ref $client
    );

    if ($meta->get('args')) {
        # No heuristics for args.

        my $obj = $client->$method({ command_line => 1 }, @args);

        ERROR $client->errorstring if $client->has_error;

        # Copied from below, until that code is deprecated.
        if ( blessed($obj) && $obj->isa("Mojo::Transaction") ) {
            if ( my $res = $obj->success ) {
                print $res->code," ",$res->default_message,"\n";
            } else {
                my ( $message, $code ) = $obj->error;
                ERROR $code if $code;
                ERROR $message;
            }
        } elsif (ref $obj eq 'HASH' && keys %$obj == 1 && $obj->{text}) {
            print $obj->{text};
        } elsif ($client->tx && $client->tx->req->method eq 'POST' && $meta->get("quiet_post")) {
            my $msg = $client->res->code." ".$client->res->default_message;
            my $got = $client->res->json;
            if ($got && ref $got eq 'HASH' and keys %$got==1 && $got->{text}) {
                $msg .= " ($got->{text})";
            }
            INFO $msg;
        } else {
           print _prettyDump($obj) unless $TESTING;
        }
        return;
    }

    # Code below here should be deprecated, these are various heuristics for argument processing.

    my @extra_args = ( '/dev/null' );
    my $have_filenames;

    # Assume we have files and/or remote globs
    if ( !$meta->get('dont_read_files') && @args > 0 && ( -r $_[-1] || $_[-1] =~ /^\S+:/ ) ) {
        $have_filenames = 1;
        @extra_args = ();
        while (my $arg = pop @args) {
            if ($arg =~ /^\S+:/) {
                push @extra_args, _expand_remote_glob($arg);
            } elsif (-e $arg) {
                push @extra_args, $arg;
            } else {
                LOGDIE "Do not know how to interpret argument : $arg";
            }
        }
    } elsif ( $try_stdin && (-r STDIN) && @args==0) {
        my $content = join '', <STDIN>;
        $content = Load($content);
        LOGDIE "Invalid yaml content in $method" unless $content;
        push @args, $content;
    }

    # Finally, run :
    for my $arg (@extra_args) {
        my $obj;
        if ($have_filenames) {
            $obj = $client->$method(@args, _load_yaml($arg));
        } else {
            $obj = $client->$method(@args);
        }
        ERROR $client->errorstring if $client->errorstring;
        next unless $obj;

        if ( blessed($obj) && $obj->isa("Mojo::Transaction") ) {
            if ( my $res = $obj->success ) {
                print $res->code," ",$res->default_message,"\n";
            } else {
                my ( $message, $code ) = $obj->error;
                ERROR $code if $code;
                ERROR $message;
            }
        } elsif (ref $obj eq 'HASH' && keys %$obj == 1 && $obj->{text}) {
            print $obj->{text};
        } elsif ($client->tx && $client->tx->req->method eq 'POST' && $meta->get("quiet_post")) {
            my $msg = $client->res->code." ".$client->res->default_message;
            my $got = $client->res->json;
            if ($got && ref $got eq 'HASH' and keys %$got==1 && $got->{text}) {
                $msg .= " ($got->{text})";
            }
            INFO $msg;
        } else {
           print _prettyDump($obj) unless $TESTING;
        }
    }
    return;
}

sub _prettyDump {
    my $what = shift;
    rmap_ref { $_ = $_->iso8601() if ref($_) eq 'DateTime' } $what;
    return Dump($what);
}


1;
