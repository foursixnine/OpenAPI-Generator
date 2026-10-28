package FromMojolicious::SampleController;
use Mojo::Base 'Mojolicious::Controller', -signatures;

=pod

=head1 NAME

FromMojolicious::SampleController - Sample controller for test

=head1 METHODS

=over 4

=item list()

Retrieve list of sample items. Returns all items matching filter.

These options are currently available:

=over 2

=item limit

  limit => 25

Limit number of items to return.

=item active (required)

  active => 1

Filter by active status (0 or 1).

=back

=item create()

Create a new sample item. Creates and returns the created item.

These options are currently available:

=over 2

=item name

  name => 'Sample'

Mandatory name of the item.

=item count

  count => 5

Optional item count.

=back

=back

=cut

sub list ($self) {
  $self->render(json => []);
}

sub create ($self) {
  $self->render(json => { created => 1 });
}

1;
