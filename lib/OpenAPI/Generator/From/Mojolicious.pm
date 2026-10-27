package OpenAPI::Generator::From::Mojolicious;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::JSON qw(true false);

my %HTTP_METHODS = map { $_ => 1 } qw(get post put delete patch options head trace);

sub new {
  bless {}, shift;
}

sub generate {
  my ($self, $conf) = @_;

  croak 'Configuration must be a HASH reference' unless ref $conf eq 'HASH';

  my $app = $conf->{app};
  if ($app && !ref $app) {
    eval "require $app; 1" or croak "Cannot load Mojolicious app class '$app': $@";
    $app = $app->new;
  }

  my $routes = $conf->{routes} || ($app ? $app->routes : undef);
  croak 'Must provide either "app" or "routes" in configuration' unless $routes;

  my $openapi_ver = $conf->{openapi} // '3.0.2';
  my $title       = $conf->{title}
    // ($app && $app->can('moniker') ? $app->moniker : undef)
    // ($app ? ref($app) : 'Mojolicious Application')
    // 'API Specification';
  my $version     = $conf->{version}
    // ($app && eval { $app->VERSION } ? $app->VERSION : undef)
    // '1.0.0';

  my $base_path = $conf->{base_path};
  my @servers;
  if ($conf->{servers}) {
    @servers = @{$conf->{servers}};
  }
  elsif (defined $base_path && length $base_path) {
    @servers = ({url => $base_path});
  }

  my %spec = (
    openapi => $openapi_ver,
    info    => {
      title   => $title,
      version => "$version",
    },
    paths => {},
  );

  $spec{servers} = \@servers if @servers;

  if (my $desc = $conf->{description}) {
    $spec{info}{description} = $desc;
  }

  if (my $components = $conf->{components}) {
    $spec{components} = $components;
  }

  $self->_introspect_routes($routes, \%spec, $conf);

  return \%spec;
}

sub _introspect_routes {
  my ($self, $root, $spec, $conf) = @_;

  my $base_path       = $conf->{base_path};
  my $strip_base_path = $conf->{strip_base_path} // ($base_path ? 1 : 0);
  my $include         = $conf->{include};
  my $exclude         = $conf->{exclude};

  my %seen_op_ids;
  my @queue = ($root);

  while (@queue) {
    my $route = shift @queue;

    # Collect children to traverse all branch nodes
    if (my $children = $route->children) {
      push @queue, @$children;
    }

    # Only process terminal endpoint routes
    next unless $route->is_endpoint;
    next if $route->is_websocket;

    my $raw_path = $route->to_string // '';
    next unless length $raw_path;

    # Exclude OpenAPI internal documentation and spec routes
    next if $raw_path =~ m{/openapi(?:\.[a-z]+)?$}i;
    next if $raw_path =~ m{/api(?:\.(?:json|html))?$}i && ($route->name // '') =~ m{openapi};
    next if $route->name && $route->name =~ m{openapi_documentation};

    # Apply user include/exclude filters
    if ($include) {
      if (ref $include eq 'CODE') {
        next unless $include->($route, $raw_path);
      }
      elsif (ref $include eq 'Regexp') {
        next unless $raw_path =~ $include;
      }
      else {
        next unless index($raw_path, $include) == 0;
      }
    }

    if ($exclude) {
      if (ref $exclude eq 'CODE') {
        next if $exclude->($route, $raw_path);
      }
      elsif (ref $exclude eq 'Regexp') {
        next if $raw_path =~ $exclude;
      }
      else {
        next if index($raw_path, $exclude) == 0;
      }
    }

    # Normalize consecutive slashes
    my $oa_path = $raw_path;
    $oa_path =~ s{//+}{/}g;

    # Strip base_path with strict boundary check if requested
    if ($strip_base_path && defined $base_path && length $base_path) {
      $oa_path =~ s{^\Q$base_path\E(?=/|$)}{};
      $oa_path = '/' . $oa_path unless $oa_path =~ m{^/};
    }

    # Convert Mojolicious placeholders to OpenAPI 3 {param}
    my ($clean_path, $path_params) = $self->_convert_path_placeholders($route, $oa_path);

    my $methods = $route->methods;
    my @http_methods = ($methods && @$methods)
      ? map { lc $_ } grep { $HTTP_METHODS{lc $_} } @$methods
      : ('get');

    for my $method (@http_methods) {
      my $op = $self->_build_operation(
        $route, $method, $clean_path, $path_params, $conf, \%seen_op_ids
      );
      $spec->{paths}{$clean_path}{$method} = $op;
    }
  }
}

sub _has_intermediate_bridge {
  my ($self, $route, $base_path) = @_;
  my $cur = $route->parent;
  while ($cur) {
    if ($cur->parent && $cur->pattern && length $cur->pattern->unparsed) {
      my $p = $cur->to_string // '';
      $p =~ s{//+}{/}g;
      if (!defined $base_path || length $base_path == 0) {
        return 1 if $p ne '/' && length $p;
      }
      elsif ($p ne $base_path && $p =~ m{^\Q$base_path\E/}) {
        return 1;
      }
    }
    $cur = $cur->parent;
  }
  return 0;
}

sub _collect_ancestor_placeholders {
  my ($self, $route) = @_;

  my @placeholders;
  my %constraints;
  my %token_types;
  my %seen_param;

  # Traverse from current route up through parents to root
  my $cur = $route;
  while ($cur) {
    my $pattern = $cur->pattern;
    if ($pattern) {
      my $names = $pattern->placeholders || [];
      for my $name (@$names) {
        next if $seen_param{$name}++;
        push @placeholders, $name;
      }

      my $con = $pattern->constraints || {};
      for my $k (keys %$con) {
        $constraints{$k} //= $con->{$k};
      }

      if ($pattern->can('tree') && $pattern->tree) {
        for my $node (@{$pattern->tree}) {
          next unless ref $node eq 'ARRAY' && ($node->[0] // '') eq 'placeholder';
          my $pname = $node->[1][0] if ref $node->[1] eq 'ARRAY';
          my $ptype = $node->[2] // 'standard';
          $token_types{$pname} //= $ptype if $pname;
        }
      }
    }
    $cur = $cur->parent;
  }

  return (\@placeholders, \%constraints, \%token_types);
}

sub _convert_path_placeholders {
  my ($self, $route, $path) = @_;

  my ($placeholders, $constraints, $token_types) =
    $self->_collect_ancestor_placeholders($route);

  # Extract typed placeholders from raw path: e.g. <param:type> or <:param>
  my %explicit_types;
  while ($path =~ m{<([a-zA-Z_]\w*)(?::([a-zA-Z_]\w*))?>}g) {
    my ($name, $type_tag) = ($1, $2);
    $explicit_types{$name} = $type_tag if $type_tag;
  }

  my @params;
  for my $p (@$placeholders) {
    my $type_str = 'string';
    my $tag = $explicit_types{$p} // '';

    if ($tag eq 'num' || $tag eq 'int' || $tag eq 'integer') {
      $type_str = 'integer';
    }
    elsif (my $re = $constraints->{$p}) {
      my $re_str = "$re";
      if ($re_str =~ m{\\d\+} || $re_str =~ m{\[0-9\]\+} || $re_str =~ m{\[1-9\]}) {
        $type_str = 'integer';
      }
      elsif ($re_str =~ m{true\|false}i) {
        $type_str = 'boolean';
      }
    }

    my %param = (
      name     => $p,
      in       => 'path',
      required => true,
      schema   => { type => $type_str },
    );

    my $t = $token_types->{$p} // '';
    if ($t eq 'wildcard') {
      $param{'x-mojo-placeholder'} = '*';
    }
    elsif ($t eq 'relaxed') {
      $param{'x-mojo-placeholder'} = '#';
    }

    push @params, \%param;
  }

  # Normalize placeholders in path string to RFC 6570 OpenAPI {param}:
  # 1. <param:type>, <param>, <:param>, <*param>, <#param>
  $path =~ s{<[:*#]?([a-zA-Z_]\w*)(?::[a-zA-Z_]\w*)?>}{{$1}}g;
  # 2. Standard unbracketed :param, *param, #param
  $path =~ s{[:*#]([a-zA-Z_]\w*)}{{$1}}g;

  return ($path, \@params);
}

sub _build_operation {
  my ($self, $route, $method, $clean_path, $path_params, $conf, $seen_op_ids) = @_;

  my $base_path = $conf->{base_path};

  # Ensure operationId is unique across methods and shared route names
  my $base_id = $route->has_custom_name
    ? $route->name
    : ($clean_path =~ s/[^\w]+/_/gr);
  $base_id =~ s/^_//;
  $base_id =~ s/_$//;
  $base_id ||= 'operation';

  my $op_id = "${method}_${base_id}";
  my $suffix = 1;
  while ($seen_op_ids->{$op_id}++) {
    $suffix++;
    $op_id = "${method}_${base_id}_${suffix}";
  }

  my %op = (
    operationId => $op_id,
    responses   => {},
  );

  # Set valid response structures (RFC 7231 / RFC 9110 compliant)
  if ($method eq 'delete') {
    $op{responses}{'204'} = {
      description => 'No Content',
    };
  }
  else {
    $op{responses}{'200'} = {
      description => 'Successful response',
      content     => {
        'application/json' => {
          schema => { type => 'object' },
        },
      },
    };
  }
  $op{responses}{'400'} = { description => 'Invalid request error' };
  $op{responses}{'500'} = { description => 'Internal server error' };

  # Route name mapping:
  # Only assign x-mojo-name if route is NOT nested under an intermediate path bridge.
  # Otherwise Mojolicious::Plugin::OpenAPI executes add_child($r) which severs intermediate bridges.
  my $is_bridged = $self->_has_intermediate_bridge($route, $base_path);
  if ($route->name && !$is_bridged) {
    my $methods = $route->methods || [];
    if (@$methods > 1) {
      $op{'x-mojo-name'} = $route->name . '_' . $method;
    }
    else {
      $op{'x-mojo-name'} = $route->name;
    }
  }

  # Set x-mojo-to if controller/action target exists
  my $to = $route->to;
  if ($to && ref $to eq 'HASH') {
    if ($to->{controller} && $to->{action}) {
      $op{'x-mojo-to'} = "$to->{controller}#$to->{action}";
    }
  }

  # Add path parameters
  if ($path_params && @$path_params) {
    $op{parameters} = [@$path_params];
  }

  # Add requestBody for write methods
  if ($method =~ m{^(?:post|put|patch)$}i) {
    $op{requestBody} = {
      required => true,
      content  => {
        'application/json' => {
          schema => { type => 'object' },
        },
      },
    };
  }

  # Merge inline route annotations if provided via ->to(openapi => { ... })
  if ($to && ref $to eq 'HASH' && ref $to->{openapi} eq 'HASH') {
    my $override = $to->{openapi};
    for my $k (keys %$override) {
      if ($k eq 'responses' && ref $override->{$k} eq 'HASH') {
        for my $code (keys %{$override->{$k}}) {
          $op{responses}{$code} = $override->{$k}{$code};
        }
      }
      elsif ($k eq 'parameters' && ref $override->{$k} eq 'ARRAY') {
        # Deduplicate parameters by name and 'in' location
        my %by_key;
        for my $p (@{$op{parameters} // []}) {
          $by_key{($p->{name} // '') . ':' . ($p->{in} // '')} = $p;
        }
        for my $p (@{$override->{$k}}) {
          $by_key{($p->{name} // '') . ':' . ($p->{in} // '')} = $p;
        }
        $op{parameters} = [values %by_key];
      }
      else {
        $op{$k} = $override->{$k};
      }
    }
  }

  return \%op;
}

1;

__END__

=head1 NAME

OpenAPI::Generator::From::Mojolicious - Auto-generate OpenAPI specifications from Mojolicious routes!

=head1 SYNOPSIS

  use OpenAPI::Generator;
  use Mojolicious::Lite;

  get '/items/:id', [id => qr/\d+/] => sub { ... } => 'get_item';

  # Generate OpenAPI v3 specification directly from routes
  my $spec = openapi_from(mojolicious => {
    app       => app,
    base_path => '/api',
    title     => 'My API',
    version   => '1.0.0',
  });

  # Directly use with Mojolicious::Plugin::OpenAPI
  plugin OpenAPI => { spec => $spec };

=head1 DESCRIPTION

C<OpenAPI::Generator::From::Mojolicious> introspects the Mojolicious route tree
(C<$app-E<gt>routes>) and generates a complete, valid OpenAPI 3.0 specification.

=cut
