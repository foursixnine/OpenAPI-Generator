package OpenAPI::Generator::From::Mojolicious;

use strict;
use warnings;

use Carp qw(croak);
use File::Spec;
use Mojo::JSON qw(true false);
use Mojo::Util qw(camelize);

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
        $route, $method, $clean_path, $path_params, $conf, \%seen_op_ids, $spec
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
  my ($self, $route, $method, $clean_path, $path_params, $conf, $seen_op_ids, $spec) = @_;

  my $base_path = $conf->{base_path};

  # Route name mapping:
  # Only assign x-mojo-name if route is NOT nested under an intermediate path bridge.
  # Otherwise Mojolicious::Plugin::OpenAPI executes add_child($r) which severs intermediate bridges.
  my $mojo_name;
  if ($route->name && !$self->_has_intermediate_bridge($route, $base_path)) {
    my $methods = $route->methods || [];
    $mojo_name = @$methods > 1 ? $route->name . '_' . $method : $route->name;
  }

  # operationId is x-mojo-name for a route with a custom name that is not
  # bridged. Else it is "<method>_<name or path>": the plugin must not find a
  # bridged route by its name. Automatic route names are not used.
  my $base_id = $route->has_custom_name
    ? $route->name
    : ($clean_path =~ s/[^\w]+/_/gr);
  $base_id =~ s/^_//;
  $base_id =~ s/_$//;
  $base_id ||= 'operation';

  # Ensure operationId is unique across methods and shared route names
  my $id = ($route->has_custom_name && defined $mojo_name) ? $mojo_name : "${method}_${base_id}";
  my $op_id = $id;
  my $suffix = 1;
  while ($seen_op_ids->{$op_id}++) {
    $suffix++;
    $op_id = "${id}_${suffix}";
  }

  my %op = (
    operationId => $op_id,
    responses   => {},
  );
  $op{'x-mojo-name'} = $mojo_name if defined $mojo_name;

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

  # Set x-mojo-to if controller/action target exists
  my $to = $route->to;
  my ($ctrl_file, $ctrl_pkg);
  if ($to && ref $to eq 'HASH') {
    if ($to->{controller} && $to->{action}) {
      $op{'x-mojo-to'} = "$to->{controller}#$to->{action}";
      ($ctrl_file, $ctrl_pkg) = $self->_resolve_controller_file($route, $to->{controller}, $conf);
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

  # Enrich from controller POD documentation if available
  if ($ctrl_file && $to && ref $to eq 'HASH' && $to->{action}) {
    my $pod_data = $self->_parse_controller_pod_file($ctrl_file);
    if (my $pod = $pod_data->{$to->{action}}) {
      $op{summary}     //= $pod->{summary} if defined $pod->{summary};
      $op{description} //= $pod->{description} if defined $pod->{description};

      my $tag = $to->{controller};
      $tag =~ s/.*:://;
      $op{tags} //= [ lc $tag ];

      my @options = @{$pod->{options} || []};
      if (@options) {
        if ($method =~ m{^(?:get|delete|head)$}i) {
          $op{parameters} //= [];
          my %existing = map { ($_->{name} // '') . ':' . ($_->{in} // '') => $_ } @{$op{parameters}};
          for my $opt (@options) {
            if (my $p_param = $existing{$opt->{name} . ':path'}) {
              $p_param->{description} //= $opt->{description} if defined $opt->{description};
              $p_param->{example}     //= $opt->{example}     if defined $opt->{example};
              next;
            }
            next if $existing{$opt->{name} . ':query'};
            my %param = (
              name   => $opt->{name},
              in     => 'query',
              schema => { type => $opt->{type} // 'string' },
            );
            $param{required}    = true                if $opt->{required};
            $param{description} = $opt->{description} if defined $opt->{description};
            $param{example}     = $opt->{example}     if defined $opt->{example};
            push @{$op{parameters}}, \%param;
          }
        }
        elsif ($method =~ m{^(?:post|put|patch)$}i && $op{requestBody}) {
          my $content = $op{requestBody}{content} // {};
          for my $media (keys %$content) {
            next unless ref $content->{$media} eq 'HASH' && ref $content->{$media}{schema} eq 'HASH';
            my $schema = $content->{$media}{schema};
            $schema->{properties} //= {};
            for my $opt (@options) {
              my %prop = (
                type => $opt->{type} // 'string',
              );
              $prop{description} = $opt->{description} if defined $opt->{description};
              $prop{example}     = $opt->{example}     if defined $opt->{example};
              $schema->{properties}{$opt->{name}} //= \%prop;
              if ($opt->{required}) {
                $schema->{required} //= [];
                push @{$schema->{required}}, $opt->{name}
                  unless grep { $_ eq $opt->{name} } @{$schema->{required}};
              }
            }
          }
        }
      }
    }
  }

  # Authentication bridge detection
  if ($self->_has_auth_bridge($route, $conf)) {
    my $scheme = $conf->{security_scheme} // 'api_key';
    $op{security} //= [ { $scheme => [] } ];
    if ($spec) {
      $spec->{components} //= {};
      $spec->{components}{securitySchemes} //= {};
      $spec->{components}{securitySchemes}{$scheme} //= {
        type => 'apiKey',
        name => 'Authorization',
        in   => 'header',
      };
    }
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

sub _resolve_controller_file {
  my ($self, $route, $controller, $conf) = @_;

  return undef unless $controller;

  my @candidates;
  if ($controller =~ /::/) {
    push @candidates, $controller;
  }
  else {
    my $camel = camelize($controller);
    my $namespaces = ($route->root && $route->root->namespaces) ? $route->root->namespaces : [];
    for my $ns (@$namespaces) {
      push @candidates, "${ns}::${camel}";
    }
    push @candidates, $camel;
  }

  for my $pkg (@candidates) {
    my $rel = join('/', split(/::/, $pkg)) . '.pm';
    if (exists $INC{$rel} && -r $INC{$rel}) {
      return ($INC{$rel}, $pkg);
    }
    my @dirs = @INC;
    if (my $extra = $conf->{pod_dir} || $conf->{controller_dir}) {
      unshift @dirs, ref $extra eq 'ARRAY' ? @$extra : ($extra);
    }
    for my $dir (@dirs) {
      next unless defined $dir && length $dir;
      my $full = File::Spec->catfile($dir, split(/::/, $pkg)) . '.pm';
      if (-f $full && -r $full) {
        return ($full, $pkg);
      }
    }
  }

  return undef;
}

sub _extract_node_text {
  my ($self, $node) = @_;
  return '' unless defined $node;
  return $node unless ref $node;
  return '' unless ref $node eq 'ARRAY';
  my $text = '';
  for my $i (2 .. $#$node) {
    $text .= $self->_extract_node_text($node->[$i]);
  }
  return $text;
}

sub _parse_controller_pod_file {
  my ($self, $file) = @_;

  return $self->{_pod_cache}{$file} if exists $self->{_pod_cache}{$file};

  require Pod::Simple::SimpleTree;
  my $parser = Pod::Simple::SimpleTree->new;
  my $tree = eval { $parser->parse_file($file)->root };
  if ($@) {
    croak "Failed to parse controller POD from '$file': $@";
  }

  return ($self->{_pod_cache}{$file} = {}) unless $tree && ref $tree eq 'ARRAY';

  my %methods;
  my $nodes = [ @$tree[2 .. $#$tree] ];

  # Locate METHODS head1 section
  my $methods_over = undef;
  my $in_methods = 0;
  for my $node (@$nodes) {
    next unless ref $node eq 'ARRAY';
    my $tag = $node->[0] // '';
    if ($tag eq 'head1') {
      my $txt = $self->_extract_node_text($node);
      $in_methods = ($txt =~ m{^\s*METHODS\s*$}i) ? 1 : 0;
    }
    elsif ($in_methods && ($tag eq 'over-text' || $tag eq 'over-bullet')) {
      $methods_over = $node;
      last;
    }
  }

  # Fallback to first over block in document if no head1 METHODS
  if (!$methods_over) {
    for my $node (@$nodes) {
      if (ref $node eq 'ARRAY' && ($node->[0] eq 'over-text' || $node->[0] eq 'over-bullet')) {
        $methods_over = $node;
        last;
      }
    }
  }

  if ($methods_over) {
    my $cur_action = undef;
    my $children = [ @$methods_over[2 .. $#$methods_over] ];

    for my $child (@$children) {
      next unless ref $child eq 'ARRAY';
      my $ctag = $child->[0] // '';

      if ($ctag eq 'item-text') {
        my $txt = $self->_extract_node_text($child);
        if ($txt =~ /^\s*(\w+)(?:\s*\(\s*\))?\s*$/) {
          $cur_action = $1;
          $methods{$cur_action} = {
            summary     => undef,
            description => undef,
            options     => [],
            _paras      => [],
          };
        }
        else {
          $cur_action = undef;
        }
      }
      elsif ($cur_action) {
        if ($ctag eq 'over-text' || $ctag eq 'over-bullet') {
          my $cur_opt = undef;
          my $opt_children = [ @$child[2 .. $#$child] ];

          for my $opt_node (@$opt_children) {
            next unless ref $opt_node eq 'ARRAY';
            my $otag = $opt_node->[0] // '';

            if ($otag eq 'item-text') {
              my $opt_name = $self->_extract_node_text($opt_node);
              $opt_name =~ s/^\s+|\s+$//g;
              my $req = ($opt_name =~ s/\s*\((?:required|mandatory)\)\s*$//i) ? 1 : 0;
              $cur_opt = {
                name        => $opt_name,
                type        => 'string',
                description => undef,
                example     => undef,
                required    => $req,
              };
              push @{$methods{$cur_action}{options}}, $cur_opt;
            }
            elsif ($cur_opt && $otag eq 'Verbatim') {
              my $verb = $self->_extract_node_text($opt_node);
              if ($verb =~ /=>\s*(.+)$/m) {
                my $val = $1;
                $val =~ s/^\s+|\s+$//g;
                if ($val =~ /^['"](.*)['"]$/) {
                  $cur_opt->{type} = 'string';
                  $cur_opt->{example} = $1;
                }
                elsif ($val =~ /^-?\d+$/) {
                  $cur_opt->{type} = 'integer';
                  $cur_opt->{example} = int($val);
                }
                elsif ($val =~ /^-?\d+\.\d+$/) {
                  $cur_opt->{type} = 'number';
                  $cur_opt->{example} = 0 + $val;
                }
              }
            }
            elsif ($cur_opt && $otag eq 'Para') {
              my $p_text = $self->_extract_node_text($opt_node);
              $p_text =~ s/^\s+|\s+$//g;
              $cur_opt->{description} = $p_text;
              if ($p_text =~ /\b(?:mandatory|required)\b/i && $p_text !~ /\b(?:not\s+(?:mandatory|required)|optional)\b/i) {
                $cur_opt->{required} = 1;
              }
              if ($p_text =~ /\b(?:0\s+or\s+1|boolean)\b/i && $cur_opt->{type} ne 'string') {
                $cur_opt->{type} = 'integer';
              }
            }
          }
        }
        elsif ($ctag eq 'Para') {
          my $p_text = $self->_extract_node_text($child);
          $p_text =~ s/^\s+|\s+$//g;
          unless ($p_text =~ /options.*available/i) {
            push @{$methods{$cur_action}{_paras}}, $p_text;
          }
        }
      }
    }
  }

  for my $act (keys %methods) {
    my $data = $methods{$act};
    my @paras = @{delete $data->{_paras} || []};
    if (@paras) {
      my $full_text = join(' ', @paras);
      $data->{description} = $full_text;
      if ($full_text =~ m{^([^.!?\n]+[.!?])}) {
        $data->{summary} = $1;
      }
      else {
        $data->{summary} = $full_text;
      }
    }
  }

  return $self->{_pod_cache}{$file} = \%methods;
}

sub _has_auth_bridge {
  my ($self, $route, $conf) = @_;
  my $pattern = $conf->{security_bridge_pattern} // qr/(?:ensure_|auth)/i;
  my $cur = $route->parent;
  while ($cur) {
    my $name = $cur->name // '';
    return 1 if $name =~ $pattern;
    my $to = $cur->to;
    if (ref $to eq 'HASH') {
      my $cb_str = join(' ', grep { defined } values %$to);
      return 1 if $cb_str =~ $pattern;
    }
    $cur = $cur->parent;
  }
  return 0;
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
