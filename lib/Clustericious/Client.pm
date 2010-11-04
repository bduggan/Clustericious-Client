package Clustericious::Client;

use strict; no strict 'refs';
use warnings;

our $VERSION = '0.03';

=head1 NAME

Clustericious::Client - Constructor for clients of Clustericious apps

=head1 SYNOPSIS

 package Foo::Client;

 use Clustericious::Client;

 route 'welcome' => '/';                   # GET /

 route status;                             # GET /status

 route myobj => [ 'MyObject' ];            # GET /myobj

 route something => GET => '/some/';

 route remove => DELETE => '/something/';

 object 'obj';                             # Defaults to /obj

 object 'foo' => '/something/foo';         # Can override the URL

 route status => \"Get the status";        # Scalar refs are documentation

 ----------------------------------------------------------------------

 use Foo::Client;

 my $f = Foo::Client->new();
 my $f = Foo::Client->new(server_url => 'http://someurl');
 my $f = Foo::Client->new(app => 'MyApp'); # For testing...

 my $welcome = $f->welcome();              # GET /

 my $status = $f->status();                # GET /status

 my $myobj = $f->myobj('key');             # GET /myobj/key, MyObject->new()

 my $something = $f->something('this');    # GET /some/this

 $f->remove('foo');                        # DELETE /something/foo

 my $obj = $f->obj('this', 27);            # GET /obj/this/27
 # Returns either 'Foo::Client::Obj' or 'Clustericious::Client::Object'

 $f->obj({ set => 'this' });               # POST /obj

 $f->obj('this', 27, { set => 'this' });   # POST /obj/this/27

 $f->obj_delete('this', 27);               # DELETE /obj/this/27

 my $obj = $f->foo('this');                # GET /something/foo/this
 
=head1 DESCRIPTION

Some very simple helper functions with a clean syntax to build a REST
type client suitable for Clustericious applications.

The builder functions add methods to the client object that translate
into basic REST functions.  All of the 'built' methods return undef on
failure of the REST/HTTP call, and auto-decode the returned body into
a data structure if it is application/json.

=cut

use base 'Mojo::Base';

use Mojo::Client;
use Mojo::ByteStream qw/b/;
use JSON::XS;
use Clustericious::Config;
use Clustericious::Client::Object;
use Clustericious::Client::Meta;
use MojoX::Log::Log4perl;
use Log::Log4perl qw/:easy/;

=head1 ATTRIBUTES

This class inherits from L<Mojo::Base>, and handles attributes like
that class.  The following additional attributes are used.

=head2 C<client>

A client to process the HTTP stuff with.  Defaults to a
L<Mojo::Client>.

You can use the L<Mojo::Client> asynchronous stuff with callbacks and
$f->client->async and $f->client->process.

=head2 C<app>

For testing, you can specify a Mojolicious app name.

=head2 C<server_url>

You can override the URL prefix for the client, otherwise it
will look it up in the config file.

=head2 C<res>

After an HTTP error, the built methods return undef.  This function
will return the L<Mojo::Message::Response> from the server.

res->code and res->message are the returned HTTP code and message.

=cut

__PACKAGE__->attr(server_url => '');
__PACKAGE__->attr([qw(res client)]);

sub import
{
    my $class = shift;
    my $caller = caller;

    push @{"${caller}::ISA"}, $class unless $caller->isa($class);
    *{"${caller}::route"} = \&route;
    *{"${caller}::object"} = \&object;
    *{"${caller}::import"} = sub {};
}

=head1 METHODS

=head2 C<new>

 my $f = Foo::Client->new();
 my $f = Foo::Client->new(server_url => 'http://someurl');
 my $f = Foo::Client->new(app => 'MyApp'); # For testing...

=cut 

sub new
{
    my $self = shift->SUPER::new(@_);

    if ($self->{app})
    {
        my $client = Mojo::Client->new(app => $self->{app})
            or return undef;

        $self->client($client);
    }
    else
    {
        $self->client(Mojo::Client->new);
        if (not length $self->server_url)
        {
            (my $appname = ref $self) =~ s/:.*$//;
            $self->server_url(Clustericious::Config->new($appname)->url);
        }
    }

    $self->client->keep_alive_timeout($ENV{CLUSTERICIOUS_KEEP_ALIVE_TIMEOUT} || 300);
    my $logger = MojoX::Log::Log4perl->new;
    $self->client->log($logger);
    if ( $logger->is_trace ) {
        my $elapsed;
        my $started;
        $self->client->ioloop->timer( 2 => sub { $elapsed = 2; $started = time; } );
        $self->client->ioloop->on_tick(
            sub {
                return unless $started;
                return if $elapsed >= time - $started;
                $elapsed = time - $started;
                $logger->trace("waiting $elapsed");
            }
        );
    }

    return $self;
}

=head2 C<errorstring>

After an error, this returns an error string made up of the server
error code and message.  (use res->code and res->message to get the
parts)

(e.g. "Error: (500) Internal Server Error")

=cut

sub errorstring
{
    my $self = shift;
    $self->res->error
      || sprintf( "(%d) %s", $self->res->code, $self->res->message );
}

=head1 FUNCTIONS

=head2 C<route>

 route 'subname';                    # GET /subname
 route subname => '/url';            # GET /url
 route subname => GET => '/url';     # GET /url
 route subname => POST => '/url';    # POST /url
 route subname => DELETE => '/url';  # DELETE /url
 route subname => ['SomeObjectClass'];
 route subname \"<documentation> <for> <some> <args>";

Makes a method subname() that does the REST action.  Any scalar
arguments are tacked onto the end of the url.  If you pass a hash
reference, the method changes to POST and the hash is encoded into the
body as application/json.  

A scalar reference as the final argument adds documentation
about arguments for this route.

=cut 

sub route
{
    my $subname = shift;
    my $objclass = ref $_[0] eq 'ARRAY' ? shift->[0] : undef;
    my $doc      = ref $_[-1] eq 'SCALAR' ? ${ pop() } : "";
    my $url      = pop || "/$subname";
    my $method   = shift || 'GET';

    Clustericious::Client::Meta->add_route(scalar caller(),$subname,$doc);
    if ($objclass)
    {
        eval "require $objclass";

        *{caller() . "::$subname"} = 
        sub
        {
            my $self = shift;
            $objclass->new($self->_doit($method,$url,@_), $self);
        };
    }
    else
    {
        *{caller() . "::$subname"} = sub { shift->_doit($method,$url,@_); };
    }

}

=head2 C<object>

 object 'objname';                   # defaults to URL /objname
 object objname => '/some/url';

Creates two methods, one named with the supplied objname() (used for
create, retrieve, update), and one named objname_delete().

Any scalar arguments to the created functions are tacked onto the end
of the url.  Performs a GET by default, but if you pass a hash
reference, the method changes to POST and the hash is encoded into the
body as application/json.

The 'object' routes will automatically look for a class named with the
object name, but upper case first letter and first after any
underscores, which are removed:

 object 'myobj';    Foo::Client::Myobj;
 object 'my_obj';   Foo::Client::MyObj;

If such a class isn't found, object will default to returning a
L<Clustericious::Client::Object>.

=cut 

sub object
{
    my $objname = shift;
    my $url     = shift || "/$objname";
    my $doc     = ref $_[-1] eq 'SCALAR' ? ${ pop() } : '';
    my $caller  = caller;

    my $objclass = "${caller}::" .
        join('', map { ucfirst } split('_', $objname)); # foo_bar => FooBar

    eval "require $objclass";

    $objclass = 'Clustericious::Client::Object' unless $objclass->can('new');

    Clustericious::Client::Meta->add_object(scalar caller(),$objname,$doc);

    *{"${caller}::$objname"} = 
    sub
    {
        my $self = shift;
        my $data = $self->_doit(GET => $url, @_);
        $objclass->new($data, $self);
    };

    *{"${caller}::${objname}_delete"} = 
        sub { shift->_doit(DELETE => $url, @_) };
}


sub _doit
{
    my $self = shift;
    my ($method, $url, @args) = @_;

    $url = $self->server_url . $url if $self->server_url;

    my $cb;
    my $body = '';
    my $headers = {};

    while (my $arg = shift @args)
    {
        if (ref $arg eq 'HASH')
        {
            $method = 'POST';
            $body = encode_json $arg;
            $headers = { 'Content-Type' => 'application/json' };
        }
        elsif (ref $arg eq 'CODE')
        {
            $cb = $self->_mycallback($arg);
        }
        else
        {
            $url .= "/$arg";
        }
    }

    DEBUG "Sending $method request to $url";
    return $self->client->build_tx($method, $url, $headers, $body, $cb) if $cb;

    my $tx = $self->client->build_tx($method, $url, $headers, $body);

    $self->client->process($tx);

    $self->res($tx->res);

    unless ($tx->res->is_status_class(200)) {
        ERROR "Error trying to $method $url : ".$tx->error;
        return undef;
    }

    TRACE "Got response : ".$tx->res;
    return $tx->res->headers->content_type eq 'application/json'
           ? decode_json($tx->res->body)
           : $tx->res->body;
}

sub _mycallback
{
    my $self = shift;
    my $cb = shift;
    sub 
    {
        my ($client, $tx) = @_;

        $self->res($tx->res);

        if ($tx->res->is_status_class(200))
        {
            my $body = $tx->res->headers->content_type eq 'application/json'
                ? decode_json($tx->res->body) : $tx->res->body;

            $cb->($body ? $body : 1);
        }
        else
        {
            $cb->();
        }
    }
}

1;
