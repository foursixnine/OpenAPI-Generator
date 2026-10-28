use strict;
use warnings;
use Test::More;

use Mojolicious::Lite;
use OpenAPI::Generator;

# Define sample routes with nested under bridge and typed placeholders
my $api = app->routes->under('/api');

# Route 1: Direct endpoint on base path
$api->get('/items/:id', [id => qr/\d+/])
  ->to(cb => sub {
    my $c = shift->openapi->valid_input or return;
    $c->render(openapi => { item_id => int($c->param('id')), name => 'Widget' });
  })
  ->name('get_item');

$api->post('/items')
  ->to(cb => sub {
    my $c = shift->openapi->valid_input or return;
    my $body = $c->req->json;
    $c->render(openapi => { item_id => 1, name => $body->{name} });
  }, openapi => {
    summary => 'Create an item',
    requestBody => {
      required => Mojo::JSON->true,
      content => {
        'application/json' => {
          schema => {
            type => 'object',
            required => ['name'],
            properties => { name => { type => 'string' } }
          }
        }
      }
    },
    responses => {
      200 => {
        description => 'Created item',
        content => {
          'application/json' => {
            schema => {
              type => 'object',
              required => ['item_id', 'name'],
              properties => {
                item_id => { type => 'integer' },
                name    => { type => 'string' }
              }
            }
          }
        }
      }
    }
  })
  ->name('create_item');

# Route 2: Multi-method route (GET and POST)
$api->any(['get', 'post'] => '/metrics')
  ->to(cb => sub {
    my $c = shift->openapi->valid_input or return;
    $c->render(openapi => { active => 1 });
  })
  ->name('metrics_collection');

# Route 3: DELETE route returning 204
$api->delete('/items/:id', [id => qr/\d+/])
  ->to(cb => sub {
    my $c = shift->openapi->valid_input or return;
    $c->rendered(204);
  })
  ->name('delete_item');

# Route 4: Nested bridge with ancestor placeholder and typed placeholder
my $group = $api->under('/groups/:group_id', [group_id => qr/\d+/]);
$group->get('/jobs/:job_id', [job_id => qr/\d+/])
  ->to(cb => sub {
    my $c = shift;
    $c->render(json => { group => int($c->param('group_id')), job => int($c->param('job_id')) });
  })
  ->name('get_group_job');

$group->get('/steps/<step:num>')
  ->to(cb => sub {
    my $c = shift;
    $c->render(json => { step => int($c->param('step')) });
  })
  ->name('get_step');

subtest 'generate openapi spec from mojolicious routes' => sub {
  my $spec = openapi_from(mojolicious => {
    app       => app,
    base_path => '/api',
    title     => 'Test API',
    version   => '1.2.3',
  });

  is $spec->{openapi}, '3.0.2', 'openapi version is 3.0.2';
  is $spec->{info}{title}, 'Test API', 'info title';
  is $spec->{info}{version}, '1.2.3', 'info version';
  is_deeply $spec->{servers}, [{url => '/api'}], 'servers configured';

  # Check nested route /groups/{group_id}/jobs/{job_id} inherits group_id from ancestor!
  ok exists $spec->{paths}{'/groups/{group_id}/jobs/{job_id}'}, 'nested path exists';
  my $job_op = $spec->{paths}{'/groups/{group_id}/jobs/{job_id}'}{get};
  ok $job_op, 'get operation exists on nested route';
  is $job_op->{operationId}, 'get_get_group_job', 'unique operationId generated';

  my @params = @{$job_op->{parameters} || []};
  is scalar(@params), 2, 'both ancestor and child path parameters present';
  my %params_by_name = map { $_->{name} => $_ } @params;
  ok exists $params_by_name{group_id}, 'group_id parameter found from parent under route';
  is $params_by_name{group_id}{schema}{type}, 'integer', 'group_id inferred as integer';
  ok exists $params_by_name{job_id}, 'job_id parameter found from endpoint';
  is $params_by_name{job_id}{schema}{type}, 'integer', 'job_id inferred as integer';

  # Check typed placeholder <step:num>
  ok exists $spec->{paths}{'/groups/{group_id}/steps/{step}'}, 'typed placeholder path converted';
  my $step_op = $spec->{paths}{'/groups/{group_id}/steps/{step}'}{get};
  my %step_params = map { $_->{name} => $_ } @{$step_op->{parameters}};
  is $step_params{step}{schema}{type}, 'integer', 'step:num typed placeholder mapped to integer';

  # Check multi-method route disambiguation
  ok exists $spec->{paths}{'/metrics'}, '/metrics path exists';
  ok exists $spec->{paths}{'/metrics'}{get}, 'get operation exists';
  ok exists $spec->{paths}{'/metrics'}{post}, 'post operation exists';
  is $spec->{paths}{'/metrics'}{get}{operationId}, 'metrics_collection_get', 'get operationId disambiguated';
  is $spec->{paths}{'/metrics'}{post}{operationId}, 'metrics_collection_post', 'post operationId disambiguated';
  is $spec->{paths}{'/metrics'}{get}{'x-mojo-name'}, 'metrics_collection_get', 'x-mojo-name disambiguated for GET';
  is $spec->{paths}{'/metrics'}{post}{'x-mojo-name'}, 'metrics_collection_post', 'x-mojo-name disambiguated for POST';

  # Check operationId is the same as x-mojo-name for a named route
  is $spec->{paths}{'/items/{id}'}{get}{operationId}, 'get_item', 'operationId is route name';
  is $spec->{paths}{'/items/{id}'}{get}{'x-mojo-name'}, 'get_item', 'x-mojo-name is route name';

  # Check DELETE route response (204 No Content has no content body)
  my $del_op = $spec->{paths}{'/items/{id}'}{delete};
  ok $del_op, 'delete operation exists';
  ok exists $del_op->{responses}{'204'}, '204 response exists';
  ok !exists $del_op->{responses}{'204'}{content}, '204 response has NO content body (RFC compliant)';
};

subtest 'operationId for unnamed and duplicate named routes' => sub {
  my $app = Mojolicious->new;
  $app->routes->get('/one')->to(cb => sub { })->name('dup');
  $app->routes->get('/two')->to(cb => sub { })->name('dup');
  $app->routes->get('/things/:id')->to(cb => sub { });
  my $spec = openapi_from(mojolicious => {app => $app, title => 'Ids', version => '1.0.0'});

  is $spec->{paths}{'/one'}{get}{operationId}, 'dup', 'first custom name used as operationId';
  is $spec->{paths}{'/two'}{get}{operationId}, 'dup_2', 'duplicate custom name gets a suffix';
  is $spec->{paths}{'/things/{id}'}{get}{operationId}, 'get_things_id', 'unnamed route keeps <method>_<path>';
  is $spec->{paths}{'/things/{id}'}{get}{'x-mojo-name'}, 'thingsid', 'unnamed route keeps its automatic x-mojo-name';
};

subtest 'integration with Mojolicious::Plugin::OpenAPI' => sub {
  my $spec = openapi_from(mojolicious => {
    app       => app,
    base_path => '/api',
    title     => 'Live Integration API',
    version   => '2.0.0',
    # Only register top-level OpenAPI endpoints for plugin validation
    include   => qr{^/api/items|^/api/metrics},
  });

  # Register OpenAPI plugin using generated specification
  plugin OpenAPI => { spec => $spec };

  use Test::Mojo;
  my $t = Test::Mojo->new;

  # Test GET /api (spec rendering)
  $t->get_ok('/api')
    ->status_is(200)
    ->json_is('/info/title', 'Live Integration API');

  # Test GET /api/items/123
  $t->get_ok('/api/items/123')
    ->status_is(200)
    ->json_is('/item_id', 123)
    ->json_is('/name', 'Widget');

  # Test POST /api/items valid input
  $t->post_ok('/api/items' => json => { name => 'Gadget' })
    ->status_is(200)
    ->json_is('/name', 'Gadget');

  # Test POST /api/items invalid input (schema validation rejection)
  $t->post_ok('/api/items' => json => {})
    ->status_is(400);

  # Test DELETE /api/items/123
  $t->delete_ok('/api/items/123')
    ->status_is(204);
};

done_testing;
