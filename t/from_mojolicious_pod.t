use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use lib "$RealBin/samples";

use Mojolicious::Lite;
use OpenAPI::Generator;
use OpenAPI::Generator::From::Mojolicious;

# Register controller namespace and routes
push @{app->routes->namespaces}, 'FromMojolicious';

app->routes->get('/samples')->to('sample_controller#list')->name('list_samples');
app->routes->post('/samples')->to('sample_controller#create')->name('create_sample');

my $auth = app->routes->under('/auth')->to(cb => sub { 1 })->name('api_ensure_user');
$auth->get('/secure')->to('sample_controller#list')->name('get_secure_samples');

subtest 'controller pod parsing directly' => sub {
  my $gen = OpenAPI::Generator::From::Mojolicious->new;
  my $file = "$RealBin/samples/FromMojolicious/SampleController.pm";
  my $pod = $gen->_parse_controller_pod_file($file);

  ok exists $pod->{list}, 'list action found in POD';
  ok exists $pod->{create}, 'create action found in POD';
  ok !exists $pod->{limit}, 'option limit is NOT polluted into actions';
  ok !exists $pod->{name}, 'option name is NOT polluted into actions';

  is $pod->{list}{summary}, 'Retrieve list of sample items.', 'summary extracted for list';
  like $pod->{list}{description}, qr/Returns all items matching filter/, 'description extracted for list';

  my @list_opts = @{$pod->{list}{options} || []};
  is scalar(@list_opts), 2, 'list action has 2 options';
  my %opts_by_name = map { $_->{name} => $_ } @list_opts;

  is $opts_by_name{limit}{type}, 'integer', 'limit option inferred as integer';
  is $opts_by_name{limit}{example}, 25, 'limit option example value';

  is $opts_by_name{active}{required}, 1, 'active option recognized as required';
  is $opts_by_name{active}{type}, 'integer', 'active option boolean/0,1 inferred as integer';

  is_deeply $pod->{list}{fields}, [], 'list action has no fields';
  is_deeply [map { $_->{name} } @{$pod->{create}{options}}], ['name', 'count'], 'create options exclude fields';
  my %fields = map { $_->{name} => $_ } @{$pod->{create}{fields} || []};
  is_deeply [sort keys %fields], ['created', 'draft'], 'create action has 2 fields';
  is $fields{created}{type}, 'integer', 'created field inferred as integer';
  is $fields{created}{required}, 1, 'created field recognized as required';
  is $fields{draft}{type}, 'boolean', 'draft field with "boolean" in the description stays boolean';
  is ref $fields{draft}{example}, 'JSON::PP::Boolean', 'draft example is a JSON boolean';
  ok !$fields{draft}{example}, 'draft example is false';
  unlike $pod->{create}{description}, qr/fields.*returned/i, 'fields intro not in description';
};

subtest 'openapi_from mojolicious with controller POD enrichment' => sub {
  my $spec = openapi_from(mojolicious => {
    app       => app,
    base_path => '/',
    title     => 'Sample Test API',
    version   => '1.0.0',
    pod_dir   => ["$RealBin/samples/FromMojolicious"],
  });

  # Verify GET /samples enriched from POD
  ok exists $spec->{paths}{'/samples'}{get}, 'GET /samples path exists';
  my $get_op = $spec->{paths}{'/samples'}{get};
  is $get_op->{summary}, 'Retrieve list of sample items.', 'summary populated';
  is $get_op->{tags}[0], 'sample_controller', 'controller tag populated';
  is $get_op->{'x-mojo-to'}, 'sample_controller#list', 'x-mojo-to preserved';

  my %params = map { $_->{name} => $_ } @{$get_op->{parameters} || []};
  ok exists $params{limit}, 'limit query parameter added from POD';
  is $params{limit}{in}, 'query', 'limit parameter in query';
  is $params{limit}{schema}{type}, 'integer', 'limit schema type is integer';

  ok exists $params{active}, 'active query parameter added from POD';
  ok $params{active}{required}, 'active query parameter is required';

  # Verify POST /samples requestBody enriched from POD
  ok exists $spec->{paths}{'/samples'}{post}, 'POST /samples path exists';
  my $post_op = $spec->{paths}{'/samples'}{post};
  is $post_op->{summary}, 'Create a new sample item.', 'POST summary populated';
  my $schema = $post_op->{requestBody}{content}{'application/json'}{schema};
  ok $schema, 'requestBody schema generated';
  is $schema->{properties}{name}{type}, 'string', 'name property inferred as string';
  is $schema->{properties}{name}{example}, 'Sample', 'name property example';
  is $schema->{properties}{count}{type}, 'integer', 'count property inferred as integer';
  is_deeply $schema->{required}, ['name'], 'name is in required list';

  # Verify 200 response schemas from POD fields
  is_deeply $get_op->{responses}{200}{content}{'application/json'}{schema}, {type => 'object'},
    'GET response schema stays generic without POD fields';
  my $res = $post_op->{responses}{200}{content}{'application/json'}{schema};
  is $res->{type}, 'object', 'POST response schema is an object';
  is $res->{properties}{created}{type}, 'integer', 'created response property is integer';
  is $res->{properties}{draft}{type}, 'boolean', 'draft response property is boolean';
  is_deeply $res->{required}, ['created'], 'created is in response required list';

  # Verify Auth bridge and securitySchemes
  ok exists $spec->{paths}{'/auth/secure'}{get}, 'GET /auth/secure exists';
  my $sec_op = $spec->{paths}{'/auth/secure'}{get};
  is_deeply $sec_op->{security}, [{api_key => []}], 'security block added for auth bridge';
  ok exists $spec->{components}{securitySchemes}{api_key}, 'components.securitySchemes.api_key declared';
};

done_testing;
