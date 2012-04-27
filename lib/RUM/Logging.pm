package RUM::Logging;

=head1 NAME

RUM::Logging - Common logging module

=head1 SYNOPSIS

  use RUM::Logger;

  my $log = RUM::Logger->get_logger();

  # Increase or decrease logging
  $log->more_logging(1);
  $log->less_logging(1);

  # Log some messages
  $log->trace("A trace level message");
  $log->debug("A debug level message");
  $log->info("A info level message");
  $log->warn("A warn level message");
  $log->error("A error level message");
  $log->fatal("A fatal level message");
  
  # See if a level will be logged
  if ($log->is_trace) { ... }
  if ($log->is_debug) { ... }
  if ($log->is_info) { ... }
  if ($log->is_warn) { ... }
  if ($log->is_error) { ... }
  if ($log->is_fatal) { ... }

  # Die with a log message 

=head1 DESCRIPTION

Initializes the logging system and provides logger classes for
components that need to do logging.

When RUM::Logging is first loaded, we check to see whether Log4perl is
installed. If so, we initialize Log4perl and use it for all
logging. If not, we use a home-grown logger that simply mimics the
most commonly used functions in Log4perl without any of the bells and
whistles.

=head2 With Log4perl

When Log4perl is installed, we will look in the following locations
for a Log4perl configuration file:

=over 4

=item 1.

The file named in the RUM_LOG_CONFIG environment variable, if
one exists.

=item 2.

F<rum_logging.conf> in the current directory.

=item 3.

F<~/.rum_logging.conf>  in the user's home directory.

=item 4.

F<conf/rum_logging.conf> - the default configuration file
that's included with RUM.

=back

Then any calls to get_logger() will just delegate to Log4perl.  Please
see L<Log::Log4perl> for more information about how to configure Log4perl.

=head3 Default configuration

The default configuration file in F<conf/rum_logging.conf> is designed
to provide the following behavior:

=over 4

=item * Some messages are printed to the screen (F<STDOUT>) and some to
a log file (F<rum.log>).

=item * INFO level messages from any packages that start with
RUM::Script:: are sent to the screen.

=item * INFO level messages from all packages are sent to the log file.

=back

=head2 Without Log4perl

If the user does not have Log4perl installed, we will simply use
L<RUM::Logger>. The default behavior is similar to what is described
above for Log4perl. The main difference is that without Log4perl we
will not attempt to read the F<rum_logging.conf> file, so the user
won't have fine-grained control over logging.

=cut

use strict;
use warnings;
use FindBin qw($Bin);
use RUM::Logger;
use File::Spec qw(splitpath);
use File::Path qw(mkpath);
use RUM::Lock;

our $LOGGING_DIR;

BEGIN { 

    if ($ENV{RUM_OUTPUT_DIR}) {
        $LOGGING_DIR = File::Spec->catfile($ENV{RUM_OUTPUT_DIR}, "log");
    }

    elsif ($0 =~ /rum_runner$/) {
        for (my $i = 0; $i < @ARGV; $i++) {
            local $_ = $ARGV[$i];
            if (/^(-o|--output|--out|--output-dir)/) {
                $LOGGING_DIR = File::Spec->catfile($ARGV[$i+1], "log");
                last;
            }
        }
    }

    if ($LOGGING_DIR) {
        mkpath($LOGGING_DIR);
    }
}

FindBin->again();

our $LOG4PERL = "Log::Log4perl";
our $LOGGER_CLASS;
our $LOG_FILE;
our $ERROR_LOG_FILE;

our $LOG4PERL_MISSING_MSG = <<EOF;
You don't seem to have $LOG4PERL installed. You may want to install it
via "cpan -i $LOG4PERL" so you can use advanced logging features.
EOF

$SIG{__DIE__} = sub {
    if($^S) {
        # We're in an eval {} and don't want log
        # this message but catch it later
        return;
    }
    RUM::Lock->release;
    RUM::Logging->get_logger("RUM::Death")->logdie(@_);
};

sub _init {
    my ($class) = @_;

    unless ($LOGGING_DIR) {
        _init_rum_logger();
        return;
    }

    # TODO: Get SGE_TASK_ID out of here.
    my $chunk = $ENV{RUM_CHUNK} || $ENV{SGE_TASK_ID};
    # Sometimes SGE_TASK_ID is set to 'undefined'
    undef $chunk if defined($chunk) && $chunk eq 'undefined';
    $LOG_FILE       = $class->log_file($chunk);
    $ERROR_LOG_FILE = $class->error_log_file($chunk);
    mkdir $LOGGING_DIR if $LOGGING_DIR;
    $LOGGER_CLASS or _init_log4perl() or _init_rum_logger();
}

our @LOG4PERL_CONFIGS = (
        $ENV{RUM_LOG_CONFIG} || "",      # RUM_LOG_CONFIG environment variable
        "rum_logging.conf",              # rum_logging.conf in current dir
        "$ENV{HOME}/.rum_logging.conf",  # ~/.rum_logging.conf
        "$Bin/../conf/rum_logging.conf",  # config file included in distribution
    );

push @LOG4PERL_CONFIGS, map { "$_/RUM/conf/rum_logging.conf" } @INC;

__PACKAGE__->_init;

sub _init_log4perl {
    # Try to load Log::Log4perl, and if we can't just return so we
    # fall back to RUM::Logger.
    eval {
        require "Log/Log4perl.pm";
        my $resp = "LOG::Log4perl"->import(qw(:no_extra_logdie_message));
        # This prevents a duplicate die message from being printed
        $Log::Log4perl::LOGDIE_MESSAGE_ON_STDERR = 0;
        die if $ENV{RUM_HIDE_LOG4PERL};
    };
    if ($@) {
        warn $LOG4PERL_MISSING_MSG unless $ENV{RUM_WARNED_LOG4PERL_MISSING}++;
        return;
    }

    # Now try to initialize Log::Log4perl with a config file.
    my @configs = grep { -r } @LOG4PERL_CONFIGS;
    my $config = $configs[0];
    eval {
        Log::Log4perl->init($config);
        my $log = Log::Log4perl->get_logger();
        $log->debug("$0 initializing, dir is $LOGGING_DIR using log4perl config at $config");
    };
    if ($@) {
        warn "Error initializing $LOG4PERL with $config: $@";
    }
    
    $LOGGER_CLASS = $LOG4PERL;
}

sub _init_rum_logger {
    $LOGGER_CLASS = "RUM::Logger";
    $LOGGER_CLASS->init();
}

=head1 CLASS METHODS

=over 4

=item get_logger

=item get_logger($name)

With a $name argument, returns a logger with the given $name. Without
$name, uses the package name of the caller as the name. For example:

  package Foo::Bar;

  use RUM::Logging;

  my $log = RUM::Logging->get_logger();

  # $log's name will be "Foo::Bar"

=cut

sub get_logger {
    my ($self, $name) = @_;

    unless ($LOGGER_CLASS) {
        _init_rum_logger;
    }

    unless (defined($name)) {
        my ($package) = caller(0);
        $name = $package;
    }
    return $LOGGER_CLASS->get_logger($name);
}

=item log_file($chunk)

Return the log file name for the given chunk, or the master log file
name if chunk is not a positive number.

=cut

sub log_file {
    my ($class, $chunk) = @_;
    return unless $LOGGING_DIR;
    my $file = $chunk ? sprintf("rum_%03d.log", $chunk) : "rum.log";
    return "$LOGGING_DIR/$file";
}

=item error_log_file($chunk)

Return the error log file name for the given chunk, or the master
error log file name if chunk is not a positive number.

=cut

sub error_log_file {
    my ($class, $chunk) = @_;
    return unless $LOGGING_DIR;
    my $file = $chunk ? sprintf("rum_errors_%03d.log", $chunk) : "rum_errors.log";
    return "$LOGGING_DIR/$file";
}

=back

=head1 AUTHOR

Mike DeLaurentis (delaurentis@gmail.com)

=head1 COPYRIGHT

Copyright 2012 University of Pennsylvania

=cut

1;