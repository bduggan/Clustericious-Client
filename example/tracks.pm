package Tracks;
use Clustericious::Client;

route 'mixes' => '/mixes.json';
route_doc mixes => 'Get a list of mixes.';
route_args mixes => [
    { name => 'api_key', type => '=s', modifies_url => "query", required => 1 },
    { name => 'per_page',type => '=i', modifies_url => "query", },
    { name => 'tags',    type => '=s', modifies_url => "query" },
];

1;

