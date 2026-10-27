package OpenAPI::Generator::Util;

use strict;
use warnings;

use Carp;
use Exporter qw(import);

our @EXPORT_OK = qw(
  merge_definitions
);

my %HTTP_METHODS = map { $_ => 1 } qw(get post put delete patch options head trace);

sub merge_definitions {

  my(@definitions) = @_;

  croak 'no definitions to merge' unless @definitions;

  if (scalar @definitions == 1) {
    return $definitions[0];
  }

  my %common_def;

  for my $def (@definitions) {
    next unless ref $def eq 'HASH';

    # Root scalar and object metadata: openapi, swagger, info, externalDocs
    for my $root_key (qw(openapi swagger info externalDocs)) {
      next unless exists $def->{$root_key};
      if (!exists $common_def{$root_key}) {
        $common_def{$root_key} = $def->{$root_key};
      }
      elsif (ref $common_def{$root_key} eq 'HASH' && ref $def->{$root_key} eq 'HASH') {
        # Shallow merge dictionary fields (e.g., info)
        for my $k (keys %{$def->{$root_key}}) {
          $common_def{$root_key}{$k} //= $def->{$root_key}{$k};
        }
      }
    }

    # Root list metadata: servers, tags, security (deduplicated)
    for my $list_key (qw(servers tags security)) {
      next unless exists $def->{$list_key};
      $common_def{$list_key} //= [];
      if (ref $def->{$list_key} eq 'ARRAY') {
        for my $item (@{$def->{$list_key}}) {
          # Avoid duplicate entries based on string or shallow structure
          my $item_str = ref $item ? (eval { require Mojo::JSON; Mojo::JSON::encode_json($item) } || "$item") : "$item";
          my $exists = 0;
          for my $cur (@{$common_def{$list_key}}) {
            my $cur_str = ref $cur ? (eval { require Mojo::JSON; Mojo::JSON::encode_json($cur) } || "$cur") : "$cur";
            if ($cur_str eq $item_str) {
              $exists = 1;
              last;
            }
          }
          push @{$common_def{$list_key}}, $item unless $exists;
        }
      }
    }

    # paths
    if ($def->{paths} && ref $def->{paths} eq 'HASH') {
      while (my($path, $path_schema) = each %{$def->{paths}}) {
        next unless ref $path_schema eq 'HASH';
        while (my($key, $val) = each %{$path_schema}) {
          if ($HTTP_METHODS{lc $key}) {
            if (exists $common_def{paths}{$path}{$key}) {
              croak "$key $path duplicates";
            }
            $common_def{paths}{$path}{$key} = $val;
          }
          else {
            # Path-item level metadata: summary, description, parameters, servers
            $common_def{paths}{$path}{$key} //= $val;
          }
        }
      }
    }

    # components
    if ($def->{components} && ref $def->{components} eq 'HASH') {
      for my $comp_type (keys %{$def->{components}}) {
        my $items = $def->{components}{$comp_type};
        next unless ref $items eq 'HASH';
        while (my($name, $schema) = each %{$items}) {
          if (exists $common_def{components}{$comp_type}{$name}) {
            croak "$comp_type $name duplicates";
          }
          $common_def{components}{$comp_type}{$name} = $schema;
        }
      }
    }
  }

  return \%common_def;
}

1;

__END__

=head1 NAME

OpenAPI::Generator::Util - subroutines to manipulate openapi schemes

=head1 SYNOPSIS

  # merge definitions
  my $merged_def = merge_definitions(@definitions);

=head1 SUBROUTINES

=over 4

=item merge_definitions(@definitions)

Merge several OpenAPI definitions into one big. Preserves root metadata and merges paths and components.

=back

=head1 AUTHOR

Anton Fedotov, C<< <tosha.fedotov.2000 at gmail.com> >>

=head1 BUGS

Please report any bugs or feature requests to C<https://github.com/doojonio/OpenAPI-Generator/issues>

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

  perldoc OpenAPI::Generator::Util

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2021 by Anton Fedotov.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)
