package Tapper::Benchmark;

use strict;
use warnings;

my $hr_default_config = {
    select_cache        => 1,
    default_aggregation => 'min',
    tables              => {
        unit_table                       => 'bench_units',
        benchmark_table                  => 'benchs',
        benchmark_value_table            => 'bench_values',
        subsume_type_table               => 'bench_subsume_types',
        benchmark_backup_value_table     => 'bench_backup_values',
        additional_type_table            => 'bench_additional_types',
        additional_value_table           => 'bench_additional_values',
        additional_relation_table        => 'bench_additional_relations',
        additional_type_relation_table   => 'bench_additional_type_relations',
        backup_additional_relation_table => 'bench_backup_additional_relations',
    },
};

my $fn_add_subsumed_point = sub {

    my ( $or_self, $hr_atts ) = @_;

    $or_self->{query}->start_transaction();

    eval {

        # insert subsumed benchmark value
        $or_self->{query}->insert_benchmark_value(
            $hr_atts->{rows}[0]{bench_id},
            $hr_atts->{type_id},
            $hr_atts->{VALUE},
        );
        my $i_bench_value_id = $or_self->{query}->last_insert_id(
            $or_self->{config}{tables}{benchmark_value_table},
            'bench_value_id',
        );

        # insert subsumed benchmark additional values
        $or_self->{query}->copy_additional_values({
            new_bench_value_id => $i_bench_value_id,
            old_bench_value_id => $hr_atts->{rows}[0]{bench_value_id},
        });

        for my $hr_backup_row ( @{$hr_atts->{rows}} ) {

            if ( $hr_backup_row->{bench_subsume_type_rank} == 1 ) {
                if ( $hr_atts->{backup} ) {
                    # copy data rows to backup table
                    $or_self->{query}->copy_benchmark_backup_value({
                        new_bench_value_id => $i_bench_value_id,
                        old_bench_value_id => $hr_backup_row->{bench_value_id},
                    });
                    my $i_bench_backup_value_id = $or_self->{query}->last_insert_id(
                        $or_self->{config}{tables}{benchmark_backup_value_table},
                        'bench_backup_value_id',
                    );
                    $or_self->{query}->copy_benchmark_backup_additional_relations({
                        new_bench_value_id => $i_bench_backup_value_id,
                        old_bench_value_id => $hr_backup_row->{bench_value_id},
                    });
                }
            }
            else {
                # update bench_value_id in backup table
                $or_self->{query}->update_benchmark_backup_value({
                    new_bench_value_id => $i_bench_value_id,
                    old_bench_value_id => $hr_backup_row->{bench_value_id},
                });
            }

            # now lets remove the old rows
            $or_self->{query}->delete_benchmark_additional_relations(
                $hr_backup_row->{bench_value_id},
            );
            $or_self->{query}->delete_benchmark_value(
                $hr_backup_row->{bench_value_id},
            );

        }

    };

    $or_self->{query}->finish_transaction( $@ );

    return 1;

};

sub new {

    my ( $s_self, $hr_atts ) = @_;

    my $or_self = bless {}, $s_self;

    for my $s_key (qw/ dbh /) {
        if (! $hr_atts->{$s_key} ) {
            require Carp;
            Carp::confess("missing '$s_key' parameter");
            return;
        }
    }

    # get tapper benchmark configuration
    $or_self->{config} = { %{$hr_default_config} };

    if ( $hr_atts->{config} ) {
        require Hash::Merge;
        $or_self->{config} = {
            Hash::Merge
                ->new('LEFT_PRECEDENT')
                ->merge(
                    %{$hr_atts->{config}},
                    %{$or_self->{config}},
                )
        };
    }

    require CHI;
    if ( $or_self->{config}{select_cache} ) {
        $or_self->{cache} = CHI->new( driver => 'RawMemory', global => 1 );
    }

    my $s_module = "Tapper::Benchmark::Query::$hr_atts->{dbh}{Driver}{Name}";

    my $fn_new_sub;
    eval {
        require Module::Load;
        Module::Load::load( $s_module );
        $fn_new_sub = $s_module->can('new');
    };

    if ( $@ || !$fn_new_sub ) {
        require Carp;
        Carp::confess("database engine '$hr_atts->{dbh}{Driver}{Name}' not supported");
        return;
    }
    else {
        $or_self->{query} = $s_module->new({
            dbh    => $hr_atts->{dbh},
            debug  => $hr_atts->{debug} || 0,
            config => $or_self->{config},
        });
    }

    return $or_self;

}

sub add_single_benchmark {

    my ( $or_self, $hr_benchmark, $hr_options ) = @_;

    my $hr_config = $or_self->{config};

    # benchmark
    my $i_benchmark_id;
    if ( $hr_benchmark->{NAME} ) {
        if (
            my $hr_bench_select = $or_self->{query}
                ->select_benchmark( $hr_benchmark->{NAME} )
                ->fetchrow_hashref()
        ) {
            $i_benchmark_id = $hr_bench_select->{bench_id};
        }
        else {
            my $i_unit_id;
            if ( $hr_benchmark->{UNIT} ) {
                if (
                    my $hr_unit_select = $or_self->{query}
                        ->select_unit( $hr_benchmark->{UNIT} )
                        ->fetchrow_hashref()
                ) {
                    $i_unit_id = $hr_unit_select->{bench_unit_id};
                }
                else {
                    $or_self->{query}->insert_unit(
                        $hr_benchmark->{UNIT},
                    );
                    $i_unit_id = $or_self->{query}->last_insert_id(
                        $hr_config->{tables}{unit_table},
                        'bench_unit_id',
                    );
                }
            }
            $or_self->{query}->insert_benchmark(
                $hr_benchmark->{NAME}, $i_unit_id,
            );
            $i_benchmark_id = $or_self->{query}->last_insert_id(
                $hr_config->{tables}{benchmark_table},
                'bench_id',
            );
        }
    }
    else {
        require Carp;
        Carp::confess('missing element "NAME"');
        return 0;
    }

    if (
        $hr_benchmark->{data}
        && ref( $hr_benchmark->{data} ) eq 'ARRAY'
        && @{$hr_benchmark->{data}}
    ) {

        my $i_benchmark_subsume_type_id = $or_self->{query}
            ->select_min_subsume_type()
            ->fetchrow_hashref()
            ->{bench_subsume_type_id}
        ;

        my $i_counter = 1;
        for my $hr_point ( @{$hr_benchmark->{data}} ) {

            if ( not exists $hr_point->{VALUE} ) {
                require Carp;
                if ( $hr_options->{force} ) {
                    Carp::cluck("missing parameter 'VALUE' in element $i_counter");
                }
                else {
                    Carp::confess("missing parameter 'VALUE' in element $i_counter");
                }
            }

            # benchmark value
            $or_self->{query}->insert_benchmark_value(
                $i_benchmark_id, $i_benchmark_subsume_type_id, $hr_point->{VALUE},
            );
            my $i_benchmark_value_id = $or_self->{query}->last_insert_id(
                $hr_config->{tables}{benchmark_value_table},
                'bench_value_id',
            );

            ADDITIONAL: for my $s_key ( keys %{$hr_point} ) {

                next ADDITIONAL if $s_key eq 'VALUE';

                # additional type
                my $i_addtype_id;
                if ( $or_self->{cache} ) {
                    $i_addtype_id = $or_self->{cache}->get("addtype||$s_key");
                }
                if ( !$i_addtype_id ) {
                    if (
                        my $hr_addtype_select = $or_self->{query}
                            ->select_addtype( $s_key )
                            ->fetchrow_hashref()
                    ) {
                        $i_addtype_id = $hr_addtype_select->{bench_additional_type_id};
                    }
                    else {
                        $or_self->{query}->insert_addtype(
                            $s_key,
                        );
                        $i_addtype_id = $or_self->{query}->last_insert_id(
                            $hr_config->{tables}{addition_type_table},
                            'bench_additional_type_id',
                        );
                    }
                    if ( $or_self->{cache} ) {
                        $or_self->{cache}->set( "addtype||$s_key" => $i_addtype_id );
                    }
                }

                # benchmark - additional type - relation
                my $b_inserted   = 0;
                my $s_addtyperel = "$i_benchmark_id|$i_addtype_id";
                if ( $or_self->{cache} ) {
                    if ( $or_self->{cache}->get("addtyperel||$s_addtyperel") ) {
                        $b_inserted = 1;
                    }
                }
                if (! $b_inserted ) {
                    if(!
                        $or_self->{query}
                            ->select_addtyperelation( $i_benchmark_id, $i_addtype_id )
                            ->fetchrow_hashref()
                    ) {
                        $or_self->{query}
                            ->insert_addtyperelation( $i_benchmark_id, $i_addtype_id )
                        ;
                    }
                    if ( $or_self->{cache} ) {
                        $or_self->{cache}->set("addtyperel||$s_addtyperel" => 1 );
                    }
                }

                # additional value
                my $i_addvalue_id;
                my $s_addvalue_key = "$i_addtype_id|$hr_point->{$s_key}";
                if ( $or_self->{cache} ) {
                    $i_addvalue_id = $or_self->{cache}->get("addvalue||$s_addvalue_key");
                }
                if (! $i_addvalue_id ) {
                    if (
                        my $hr_addvalue_select = $or_self->{query}
                            ->select_addvalue( $i_addtype_id, $hr_point->{$s_key} )
                            ->fetchrow_hashref()
                    ) {
                        $i_addvalue_id = $hr_addvalue_select->{bench_additional_value_id};
                    }
                    else {
                        $or_self->{query}->insert_addvalue(
                            $i_addtype_id, $hr_point->{$s_key},
                        );
                        $i_addvalue_id = $or_self->{query}->last_insert_id(
                            $hr_config->{tables}{addition_type_table},
                            'bench_additional_value_id',
                        );
                    }
                    if ( $or_self->{cache} ) {
                        $or_self->{cache}->set( "addvalue||$s_addvalue_key" => $i_addvalue_id );
                    }
                }

                # additional value relation
                $or_self->{query}->insert_addvaluerelation(
                    $i_benchmark_value_id, $i_addvalue_id,
                );

            } # ADDITIONAL

            $i_counter++;

        }
    }
    else {
        require Carp;
        Carp::confess('no benchmark data found');
        return 0;
    }

    return 1;

}

sub add_multi_benchmark {

    my ( $or_self, $ar_data_points, $hr_options ) = @_;

    my $i_counter    = 1;
    my %h_benchmarks = ();
    for my $hr_data_point ( @{$ar_data_points} ) {

        for my $s_param (qw/ NAME VALUE /) {
            if ( not exists $hr_data_point->{$s_param} ) {
                require Carp;
                if ( $hr_options->{force} ) {
                    Carp::cluck("missing parameter '$s_param' in element $i_counter");
                }
                else {
                    Carp::confess("missing parameter '$s_param' in element $i_counter");
                }
            }
        }

        my ( $s_name, $s_unit ) = delete @{$hr_data_point}{qw/ NAME UNIT /};

        if (! $h_benchmarks{$s_name} ) {
            $h_benchmarks{$s_name} = {
                NAME    => $s_name,
                UNIT    => $s_unit,
                data    => [],
            };
        }
        else {
            $h_benchmarks{$s_name}{UNIT} ||= $s_unit;
        }

        push @{$h_benchmarks{$s_name}{data}}, $hr_data_point;

        $i_counter++;

    }
    for my $hr_benchmark ( values %h_benchmarks ) {
        $or_self->add_single_benchmark( $hr_benchmark, $hr_options );
    }

    return 1;

}

sub search {

    my ( $or_self, $hr_search ) = @_;

    return $or_self->{query}->select_benchmark_values(
        $hr_search
    );

}

sub search_array {

    my ( $or_self, $hr_search ) = @_;

    my $s_key;
    if ( $or_self->{cache} ) {
        require JSON::XS;
        $s_key = JSON::XS::encode_json($hr_search);
        if ( my $ar_search_data = $or_self->{cache}->get("search_array||$s_key") ) {
            return $ar_search_data;
        }
    }

    my $ar_result = $or_self
        ->search( $hr_search )
        ->fetchall_arrayref({})
    ;

    if ( $or_self->{cache} ) {
        $or_self->{cache}->set( "search_array||$s_key" => $ar_result );
    }

    return $ar_result;

}

sub search_hash {

    my ( $or_self, $hr_search ) = @_;

    my $s_key;
    if ( $or_self->{cache} ) {
        require JSON::XS;
        $s_key = JSON::XS::encode_json($hr_search);
        if ( my $hr_search_data = $or_self->{cache}->get( "search_hash||$s_key" ) ) {
            return $hr_search_data;
        }
    }

    if (! $hr_search->{keys} ) {
        require Carp;
        Carp::confess(q#cannot get hash search result without 'keys'#);
        return;
    }

    my $hr_result = $or_self
        ->search( $hr_search )
        ->fetchall_hashref($hr_search->{keys})
    ;

    if ( $or_self->{cache} ) {
        $or_self->{cache}->set( "search_hash||$s_key" => $hr_result )
    }

    return $hr_result;

}

sub subsume {

    my ( $or_self, $hr_options ) = @_;

    for my $s_parameter (qw/ subsume_type /) {
        if (! $hr_options->{$s_parameter}) {
            require Carp;
            Carp::confess("missing parameter '$s_parameter'");
            return;
        }
    }

    # check if subsume type exists
    my $hr_subsume_type = $or_self->{query}
        ->select_subsume_type( $hr_options->{subsume_type} )
        ->fetchrow_hashref()
    ;
    if (! $hr_subsume_type ) {
        require Carp;
        Carp::confess("subsume type '$hr_options->{subsume_type}' not exists");
        return;
    }
    if ( $hr_subsume_type->{bench_subsume_type_rank} == 1 ) {
        require Carp;
        Carp::confess("cannot subsume with type '$hr_options->{subsume_type}'");
        return;
    }

    # looking for values with with a higher rank subsume type
    if (
        $or_self->{query}
            ->select_check_subsumed_values({
                date_to           => $hr_options->{date_to},
                date_from         => $hr_options->{date_from},
                subsume_type_id   => $hr_subsume_type->{bench_subsume_type_id},
            })
            ->rows()
    ) {
        require Carp;
        Carp::confess(
            "cannot use subsume type '$hr_options->{subsume_type}' " .
            'because a higher rank subsume type is already used for this date period'
        );
        return;
    }

    # look if excluded additional types really exists
    my @a_excluded_adds;
    if ( $hr_options->{exclude_additionals} ) {
        for my $s_additional_type ( @{$hr_options->{exclude_additionals}} ) {
            if (
                my $hr_addtype = $or_self->{query}
                    ->select_addtype( $s_additional_type )
                    ->fetchrow_hashref()
            ) {
                push @a_excluded_adds, $hr_addtype->{bench_additional_type_id}
            }
            else {
                require Carp;
                Carp::confess( "additional type '$s_additional_type' not exists" );
                return;
            }
        }
    }

    # get all data points for subsume
    my $or_data_values = $or_self->{query}->select_data_values_for_subsume({
        date_to             => $hr_options->{date_to},
        date_from           => $hr_options->{date_from},
        exclude_additionals => \@a_excluded_adds,
        subsume_type_id     => $hr_subsume_type->{bench_subsume_type_id},
    });

    require DateTime::Format::Strptime;
    my $or_strp = DateTime::Format::Strptime->new( pattern => '%F %T', );

    my @a_rows;
    my $i_counter   = 0;
    my $i_sum_value = 0;
    my $b_backup    = ((not exists $hr_options->{backup}) || $hr_options->{backup}) ? 1 : 0;
    my $s_last_key  = q##;

    while ( my $hr_values = $or_data_values->fetchrow_hashref() ) {

        my $s_act_key = join '__',
            $hr_values->{bench_id},
            $or_strp->parse_datetime( $hr_values->{created_at} )->strftime( $hr_subsume_type->{datetime_strftime_pattern} ),
            $hr_values->{additionals} || q##,
        ;

        if ( $s_last_key ne $s_act_key ) {

            if ( $i_counter ) {
                $or_self->$fn_add_subsumed_point({
                    rows    => \@a_rows,
                    VALUE   => $i_sum_value / $i_counter,
                    backup  => $b_backup,
                    type_id => $hr_subsume_type->{bench_subsume_type_id}
                });
            }

            @a_rows         = ();
            $i_counter      = 0;
            $i_sum_value    = 0;
            $s_last_key     = $s_act_key;

        }

        $i_counter   += 1;
        $i_sum_value += $hr_values->{bench_value};

        push @a_rows, $hr_values;

    }

    if ( $i_counter ) {
        $or_self->$fn_add_subsumed_point({
            rows    => \@a_rows,
            VALUE   => $i_sum_value / $i_counter,
            backup  => $b_backup,
            type_id => $hr_subsume_type->{bench_subsume_type_id}
        });
    }

    return 1;

}

1;

__END__

=pod

=head1 NAME

Tapper::Benchmark - Save and search benchmark points by database

=head1 SYNOPSIS

    require YAML::Syck;
    require Tapper::Benchmark;
    my $or_bench = Tapper::Benchmark->new({
        dbh    => $or_dbh,
        debug  => 0,
        config => YAML::Syck::LoadFile('~/conf/tapper_benchmark.conf'),
    });

    my $b_success = $or_bench->add_single_benchmark({
        NAME => 'testbenchmark',
        UNIT => 'example unit',
        testplanid => 813,
        DATA => [
            {
                VALUE          => 123.45,
                testrun_id     => 123,
                machine        => 'mx1.small',
                benchmark_date => '2013-09-25 12:12:00',
            },{
                VALUE          => 122.88,
                testrun_id     => 123,
                machine        => 'mx1.large',
                benchmark_date => '2013-09-23 13:02:14',
            },
            ...
        ],
    },{
        force => 1,
    });

    my $b_success = $or_bench->add_multi_benchmark([
        {
            NAME           => 'testbenchmark',
            UNIT           => 'example unit',
            VALUE          => 123.45,
            testrun_id     => 123,
            machine        => 'mx1.small',
            benchmark_date => '2013-09-25 12:12:00',
        },{
            NAME           => 'testbenchmark',
            UNIT           => 'example unit',
            VALUE          => 122.88,
            testrun_id     => 123,
            machine        => 'mx1.large',
            benchmark_date => '2013-09-23 13:02:14',
        },
        ...
    ],{
        force => 1,
    });

    my $or_benchmark_points = $or_bench->search({
        select      => [
            'testrun_id',
            'machine',
        ],
        where       => [
            ['!=', 'machine', 'mx1.small'     ],
            ['=' , 'bench'  , 'testbenchmark' ],
        ],
        order_by    => [
            'machine',
            ['ASC','testrun_id',{ numeric => 1 }]
        ],
        limit       => 2,
        offset      => 1,
    });

    while my $hr_data_point ( $or_benchmark_points->fetchrow_hashref() ) {
        ...
    }

    my $b_success = $or_bench->subsume({
        subsume_type        => 'month',
        exclude_additionals => [qw/ benchmark_date /],
        date_from           => '2013-01-01 00:00:00',
        date_to             => '2014-01-01 00:00:00',
    });

=head1 DESCRIPTION

B<Tapper::Benchmark> is a module for adding benchmark points in a standardised
way to the the database. A search function with complexe filters already exists.

=head2 Class Methods

=head3 new

=over

=item

Create a new B<Tapper::Benchmark> object.

    my $or_bench = Tapper::Benchmark->new({
        dbh    => $or_dbh,
        debug  => 0,
        config => YAML::Syck::LoadFile('~/conf/tapper_benchmark.conf'),
    });

=over

=item dbh

A B<DBI> database handle.

=item config [optional]

Containing the path to the Tapper::Benchmark-Configuration-File. See
B<Configuration> for details.

=item debug [optional]

Setting C<debug> to a true value results in multiple debugging informations
written to STDOUT. The default is 0.

=back

=head3 add_single_benchmark

=over

=item

Add one or more data points to a single benchmark to the database.

    my $b_success = $or_bench->add_single_benchmark({
        NAME => 'testbenchmark',
        UNIT => 'example unit',
        data => [
            {
                VALUE          => 123.45,
            },{
                VALUE          => 122.88,
                testrun_id     => 123,
                machine        => 'mx1.large',
                benchmark_date => '2013-09-23 13:02:14',
            },{
                VALUE          => 122.88,
                testrun_id     => 123,
            },
            ...
        ],
    },{
        force => 1
    });

=over

=item 1. Parameter Hash => NAME

The name of the benchmark for grouping benchmark data points.

=item 1. Parameter Hash => data

This parameter contains the benchmark data points. It's an array of hashes. The
element C<VALUE> is the only required element in this hashes. The C<VALUE> is
the benchmark data point value.

=item 1. Parameter Hash => UNIT [optional]

Containing a unit for benchmark data point values.

=item 2. Parameter Hash => force [optional]

Ignore forgivable errors while writing.

=back

=head3 add_multi_benchmark

=over

=item

Add one or more data points for multiple benchmarks to the database.

    my $b_success = $or_bench->add_multi_benchmark([
        {
            NAME           => 'testbenchmark 1',
            UNIT           => undef,
            VALUE          => 123.45,
        },{
            NAME           => 'testbenchmark 2',
            VALUE          => 122.88,
            testrun_id     => 123,
            machine        => 'mx1.large',
            benchmark_date => '2013-09-23 13:02:14',
        },{
            NAME           => 'testbenchmark 1',
            UNIT           => 'example unit',
            VALUE          => 122.88,
            testrun_id     => 123,
        },
        ...
    ],{
        force => 1
    });

=over

=item 1. Parameter Array of Hashes => NAME

The name of the benchmark for grouping benchmark data points.

=item 1. Parameter Hash => VALUE

The value is the benchmark data point value.

=item 1. Parameter Hash => UNIT [optional]

Containing a unit for benchmark data point values.

=item 1. Parameter Hash => all others

All other elements in the hashes are additional values added to this data point.

=item 2. Parameter Hash => force [optional]

Ignore forgivable errors while writing.

=back

=head3 search

=over

=item

Search for benchmark data points in the database. Function returns a DBI
Statement Handle.

    my $or_benchmark_points = $or_bench->search({
        select      => [
            'testrun_id',
            'machine',
        ],
        where       => [
            ['!=', 'machine', 'mx1.small'     ],
            ['=' , 'bench'  , 'testbenchmark' ],
        ],
        where_sql   => q#,
            AND NOT(
                   ${testrun_id} = 123
                OR ${bench_value} = '144'
            )
        #,
        limit       => 2,
        offset      => 1,
        order_by    => [
            'machine',
            ['ASC','testrun_id']
        ],
    });

=over

=item select [optional]

An Array of Strings or Array References containing additional selected columns.
The default selected columns are:
    bench           - name of benchmark
    bench_unit      - benchmark unit [optional]
    bench_value     - value of benchmark data point
    bench_value_id  - unique benchmark data point identifier
    bench_date      - benchmark data point created date in format YYYY-MM-DD HH:II:SS

Add additional data "testrun_id" and "machine" as columns to selection.

    ...
        select      => [
            'testrun_id',
            'machine',
        ],
    ...

Do the same as above.

    ...
        select      => [
            ['','testrun_id'],
            ['','machine'],
        ],
    ...

Get the maximum "testrun_id" of all selected data points. All other columns
without an aggregation become the C<default_aggregation> from
Tapper::Benchmark-Configuration. Possible aggregation types are:

    - min = minimum
    - max = maximum
    - avg = average
    - gem = geometric mean
    - sum = summary
    - cnt = count
    - cnd = distinct value count

    ...
        select      => [
            ['max','testrun_id'],
            'machine',
        ],
    ...

A aggregation is also possible for the default columns.

    ...
        select      => [
            ['max','testrun_id'],
            ['avg','bench_value'],
        ],
    ...

=item where [optional]

An Array of Array References containing restrictions for benchmark data points.

    ...
        where       => [
            ['!=', 'machine', 'mx1.small'     ],
            ['=' , 'bench'  , 'testbenchmark' ],
        ],
    ...

1. Parameter in Sub-Array = restriction operator

    =           - equal
    !=          - not equal
    <           - lower
    >           - greater
    <=          - lower equal
    >=          - greater equal
    like        - SQL LIKE
    not like    - SQL NOT LIKE

2. Parameter in Sub-Array = restricted column

A restriction is possible for additional values and the default columns.

3 - n. Parameters in Sub-Array = value for restriction

In general there is just a single value. For '=' and '!=' a check for multiple
values is possible. In SQL it is implemented with IN and NOT IN.

=item where_sql [optional]

A String containing an additional where clause. Please use this feature just if
the "where" parameter is not sufficient to restrict.

=item order_by [optional]

An Array of Strings or an Array of Array References determining the order of
returned benchmark data points.

Array of Strings:
    column to sort with default order direction "ASC" (ascending)

Array of Array References
    1. Element: column to sort
    2. Element: order direction with possible values "ASC" (ascending) and "DESC" (descending)
    3. Element: hash of additional options. Possible values:
        numeric: Set a true value for a numeric sort

    ...
        order_by    => [
            'machine',
            ['benchmark_date','DESC']
            ['testrun_id','ASC',{numeric => 1}]
        ],
    ...

=item limit [optional]

An integer value which determine the number of returned benchmark data points.

=item offset [optional]

An integer value which determine the number of omitted benchmark data points.

=back

=head3 search_array

=over

=item

Returning all benchmark data points as Array of Hashes.

    my $or_benchmark_points = $or_bench->search_array({
        select      => [
            'testrun_id',
            'machine',
        ],
        where       => [
            ['!=', 'machine', 'mx1.small'     ],
            ['=' , 'bench'  , 'testbenchmark' ],
        ],
        limit       => 2,
        offset      => 1,
        order_by    => [
            'machine',
            ['ASC','testrun_id']
        ],
    });

=back

=head3 search_hash

=over

=item

Returning all benchmark data points as Hash of Hashes. As compared to search
C<search_array> this function needs the parameter C<keys>. C<keys> is an Array
of Strings which determine the columns used as the keys for the nested hashes.
Every "key" create a new nested hash.

    my $or_benchmark_points = $or_bench->search_array({
        keys        => [
            'testrun_id',
            'machine',
            'bench_value_id',
        ],
        select      => [
            'testrun_id',
            'machine',
        ],
        where       => [
            ['!=', 'machine', 'mx1.small'     ],
            ['=' , 'bench'  , 'testbenchmark' ],
        ],
        limit       => 2,
        offset      => 1,
        order_by    => [
            'machine',
            ['ASC','testrun_id']
        ],
    });

=head3 subsume

=over

=item

This is a maintenance function for reducing the number of data points in the
database. Calling this function reduces the rows in the benchmark values table
by building an average value for all benchmark data points grouped by specfic
columns. By default all old grouped columns will be added to backup tables for
rebuilding the original state.
It is highly recommended to do this periodically for better search performance.

    my $b_success = $or_bench->subsume({
        subsume_type        => 'month',
        exclude_additionals => [qw/ benchmark_date /],
        date_from           => '2013-01-01 00:00:00',
        date_to             => '2014-01-01 00:00:00',
        backup              => 0,
    });

=over

=item subsume_type

The subsume of benchmark data points is made by group with the following
elements:

 - bench_id
 - additional data values ( Example: testrun_id, machine )
 - specific data range ( subsume_type ).
   The possible subsume types are stored in the
   extrapolation_type_table ( Tapper::Benchmark-Configuration ). By default there
   are the following types: "second", "minute", "hour", "day", "week", "month",
   "year".

=item date_from

Begin of subsume period.

=item date_to

End of subsume period.

=item exclude_additionals

Array Reference of additional values that should be excluded from grouping.

=item backup

By default all subsumed rows will be inserted to backup tables. If this
isn't desired a false value must be passed.

=back

=head1 Configuration

=over

=item

The following elements are required in configuration:

=over

=item default_aggregation

Default aggregation used for non aggregated columns if an aggregation on any
other column is found.

=item tables

Containing the names of the tables used bei B<Tapper::Benchmark>

    tables => {
        unit_table                       => 'bench_units',
        benchmark_table                  => 'benchs',
        benchmark_value_table            => 'bench_values',
        benchmark_backup_value_table     => 'bench_backup_values',
        subsume_type_table               => 'bench_subsume_types',
        additional_type_table            => 'bench_additional_types',
        additional_value_table           => 'bench_additional_values',
        additional_relation_table        => 'bench_additional_relations',
        additional_type_relation_table   => 'bench_additional_type_relations',
        backup_additional_relation_table => 'bench_backup_additional_relations',
    }

=item select_cache [optional]

In case of a true value the module cache some select results